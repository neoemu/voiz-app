import Testing
import Foundation

// Testes do adapter da T3.3. O que está sob teste é o **adapter**: ciclo de vida do analyzer
// (single-flight, cache negativo, unload que solta de verdade), serialização do runtime,
// cancelamento, validação do pedido e montagem do resultado. Reconhecimento de fala é do
// `SpeechAnalyzer`, que aqui é sempre dublê — nenhum teste reserva locale, baixa asset do sistema
// ou toca no framework `Speech`.
//
// O dublê é **bloqueável**, pela mesma razão da T2.2: sem poder segurar uma carga no meio, testes
// de concorrência provam só o caminho sequencial.

// MARK: - Dublê do runtime

/// Falhas que o dublê sabe levantar, cobrindo os ramos do mapeamento de erro do motor.
nonisolated enum FakeAppleSpeechFailure: Sendable {
    case runtime(AppleSpeechRuntimeError)
    case cancellation
    /// Erro de terceiro (o que viria do `Speech`/`AVFAudio` na vida real).
    case foreign(String)

    var error: any Error {
        switch self {
        case .runtime(let error): return error
        case .cancellation: return CancellationError()
        case .foreign(let message):
            return NSError(
                domain: "fake.speechanalyzer",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

/// Runtime do SpeechAnalyzer falso: conta chamadas, registra o que recebeu, falha sob encomenda e
/// — o que importa para concorrência — sabe **segurar** uma carga até o teste soltar.
actor FakeAppleSpeechRuntime: AppleSpeechRuntime {
    private let output: AppleSpeechRuntimeOutput
    private let loadFailure: FakeAppleSpeechFailure?
    private let transcribeFailure: FakeAppleSpeechFailure?

    private(set) var loadCount = 0
    private(set) var transcribeCount = 0
    private(set) var contexts: [TranscriptionContext] = []
    private(set) var releaseCount = 0
    private(set) var loadedModels: [TranscriptionModelID] = []
    private(set) var requestedSampleRates: [Double] = []
    private(set) var lastSampleCount = 0
    /// Maior número de chamadas simultâneas dentro do runtime. Se passar de 1, a vaga única do
    /// motor não está segurando nada.
    private(set) var peakConcurrency = 0
    /// Ordem em que as chamadas entraram e saíram. É o que deixa um teste afirmar "a descarga
    /// aconteceu **depois** de a análise terminar", e não só "aconteceu".
    private(set) var callLog: [String] = []
    /// Quantas cargas presas no portão foram canceladas. O `onCancel` dispara no instante do
    /// `cancel()`, então é o sinal de que o trecho síncrono do `unload` já rodou.
    private(set) var loadCancellations = 0
    /// O dublê guarda um "analyzer" de verdade: `load` põe, `release` tira. É o que deixa um teste
    /// distinguir "o motor diz que não está preparado" de "o motor diz que está preparado sobre um
    /// analyzer que não existe".
    private(set) var residentModel: TranscriptionModelID?

    private var active = 0
    private let loadHold: TestGate
    private var loadIsGated: Bool
    private var transcribeGate: [CheckedContinuation<Void, Never>] = []
    private var transcribeIsGated = false

    init(
        output: AppleSpeechRuntimeOutput = .init(
            segments: [AppleSpeechTranscriptSegment(text: "olá do speechanalyzer", start: 0, end: 1.5, confidence: 0.8)],
            processingTime: 0.05
        ),
        loadFailure: FakeAppleSpeechFailure? = nil,
        transcribeFailure: FakeAppleSpeechFailure? = nil,
        gateLoad: Bool = false,
        gateTranscribe: Bool = false
    ) {
        self.output = output
        self.loadFailure = loadFailure
        self.transcribeFailure = transcribeFailure
        self.loadIsGated = gateLoad
        self.transcribeIsGated = gateTranscribe
        self.loadHold = TestGate(open: !gateLoad)
    }

    // MARK: Controle do teste

    /// Solta todas as cargas seguras e desliga o portão.
    func openLoadGate() {
        loadIsGated = false
        loadHold.open()
    }

    func openTranscribeGate() {
        transcribeIsGated = false
        transcribeGate.forEach { $0.resume() }
        transcribeGate.removeAll()
    }

    /// Quantas cargas chegaram ao portão (cumulativo). Equivale ao antigo `loadGate.count` enquanto
    /// o portão está fechado e uma carga só está presa — o caso que os testes observam.
    var gatedLoadCount: Int { loadHold.arrivals }

    /// Espera a N-ésima carga chegar ao portão. Evento, não `waitUntil` em `gatedLoadCount`.
    func waitForGatedLoad(_ count: Int = 1) async -> Bool {
        await loadHold.waitForArrivals(count)
    }

    func noteLoadCancelled() {
        loadCancellations += 1
    }

    // MARK: AppleSpeechRuntime

    func load(model: TranscriptionModelID) async throws {
        loadCount += 1
        loadedModels.append(model)
        enter()
        callLog.append("load-start")
        defer {
            callLog.append("load-end")
            leave()
        }
        await interleave()

        if loadIsGated {
            await withTaskCancellationHandler {
                await loadHold.wait()
            } onCancel: {
                Task { await self.noteLoadCancelled() }
            }
        }
        if let loadFailure { throw loadFailure.error }
        residentModel = model
    }

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        model: TranscriptionModelID,
        context: TranscriptionContext = TranscriptionContext()
    ) async throws -> AppleSpeechRuntimeOutput {
        contexts.append(context)
        transcribeCount += 1
        lastSampleCount = samples.count
        requestedSampleRates.append(sampleRate)
        enter()
        callLog.append("transcribe-start")
        defer {
            callLog.append("transcribe-end")
            leave()
        }
        // Espelha a guarda do `AppleSpeechAssetRuntime`: sem analyzer ativo, erro visível — e com
        // uma descrição própria, para o teste distinguir esta mentira de um honesto "não preparado".
        guard residentModel == model else {
            throw AppleSpeechRuntimeError.runtimeFailure(FakeAppleSpeechRuntime.missingAnalyzer)
        }
        await interleave()

        if transcribeIsGated {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                transcribeGate.append(continuation)
            }
        }
        if let transcribeFailure { throw transcribeFailure.error }
        return output
    }

    /// `release` participa do contador de concorrência como qualquer outra operação do runtime.
    /// Sem isso, soltar o analyzer em cima de uma análise viva não apareceria no `peakConcurrency`.
    func release() async {
        releaseCount += 1
        enter()
        callLog.append("release-start")
        defer {
            callLog.append("release-end")
            leave()
        }
        residentModel = nil
        await interleave()
    }

    static let missingAnalyzer = "analyzer ausente no runtime"

    private func enter() {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
    }

    private func leave() {
        active -= 1
    }

    /// Suspende no meio do "trabalho".
    ///
    /// Sem isto o dublê não consegue observar sobreposição alguma: sem ponto de suspensão entre
    /// `enter` e `leave`, o próprio ator do dublê serializa tudo e `peakConcurrency` seria 1 mesmo
    /// com o motor deixando duas análises entrarem juntas.
    private func interleave() async {
        for _ in 0..<4 {
            await Task.yield()
            peakConcurrency = max(peakConcurrency, active)
        }
    }
}

/// Caixa para observar de fora se um trabalho já resolveu, sem bloquear ninguém esperando por ele.
actor AppleSpeechOutcomeBox {
    private(set) var resolved = false
    private(set) var failure: TranscriptionEngineFailure?

    func record(_ error: (any Error)?) {
        resolved = true
        failure = error as? TranscriptionEngineFailure
    }
}

/// Coletor de `LoadEvent` seguro para passar ao motor como observador.
actor AppleSpeechLoadEventLog {
    private(set) var events: [AppleSpeechAnalyzerEngine.LoadEvent] = []

    func append(_ event: AppleSpeechAnalyzerEngine.LoadEvent) {
        events.append(event)
    }

    nonisolated var sink: @Sendable (AppleSpeechAnalyzerEngine.LoadEvent) -> Void {
        { event in Task { await self.append(event) } }
    }
}

// MARK: - Atalhos

nonisolated enum AppleSpeechFixtures {
    /// O candidato que o roteador produz para o SpeechAnalyzer no caminho normal (pt-BR).
    static func candidate(
        model: TranscriptionModelID = .appleSystemSpeechPTBR,
        rank: Int = 0,
        origin: TranscriptionSelectionOrigin = .automatic
    ) -> TranscriptionRoutingCandidate {
        TranscriptionRoutingCandidate(
            engine: .appleSpeechAnalyzer,
            model: model,
            rank: rank,
            origin: origin
        )
    }

    static func request(
        useCase: TranscriptionUseCase = .dictation,
        language: TranscriptionLanguage? = .portugueseBrazil,
        seconds: Double = 2,
        sampleRate: Double = TranscriptionAudio.defaultSampleRate
    ) -> TranscriptionRequest {
        TranscriptionRequest(
            useCase: useCase,
            language: language,
            audio: TranscriptionAudio(
                samples: [Float](repeating: 0, count: Int(seconds * sampleRate)),
                sampleRate: sampleRate
            )
        )
    }

    /// Um motor pronto para transcrever: analyzer "ativo".
    static func preparedEngine(
        runtime: FakeAppleSpeechRuntime,
        model: TranscriptionModelID = .appleSystemSpeechPTBR,
        descriptor: TranscriptionEngineDescriptor = .appleSpeechAnalyzer
    ) async throws -> AppleSpeechAnalyzerEngine {
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime, descriptor: descriptor)
        try await engine.prepare(model: model)
        return engine
    }

    /// Deixa as tarefas recém-criadas chegarem à primeira suspensão. Heurística, e assumida como
    /// tal: serve só para posicionar um trabalho *dentro* da fila da vaga antes de cancelá-lo.
    static func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// Espera até `condition` valer, ou desiste. Sincroniza com trabalho já disparado mas ainda não
    /// chegado ao dublê. O prazo é o do `waitUntil` compartilhado (30s): 500 `yield`s media
    /// starvation da suíte, não o evento.
    static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        seconds: Double = 30
    ) async -> Bool {
        await voizTests.waitUntil(seconds: seconds, condition)
    }

    /// Observa de fora se um trabalho resolve dentro do prazo, sem pendurar a suíte quando não
    /// resolve — é assim que uma regressão de fila vira FALHA em vez de travamento.
    static func resolution(
        of work: @escaping @Sendable () async throws -> Void,
        timeoutMilliseconds: Int = 30_000
    ) async -> AppleSpeechOutcomeBox {
        let outcome = AppleSpeechOutcomeBox()
        Task {
            do {
                try await work()
                await outcome.record(nil)
            } catch {
                await outcome.record(error)
            }
        }
        var waited = 0
        while await !outcome.resolved && waited < timeoutMilliseconds / 50 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        return outcome
    }
}

@Suite("Motor Apple SpeechAnalyzer (adapter da T3.3)")
struct AppleSpeechAnalyzerEngineTests {

    // MARK: - Fidelidade ao catálogo

    @Test("O motor responde pelo descritor do SpeechAnalyzer no catálogo de produção")
    func descriptorMatchesShippingCatalog() async {
        let engine = AppleSpeechAnalyzerEngine(runtime: FakeAppleSpeechRuntime())

        #expect(engine.descriptor == TranscriptionCatalog.shipping.descriptor(for: .appleSpeechAnalyzer))
    }

    @Test("As capacidades declaradas são as do SpeechAnalyzer medido na T0.2")
    func declaredCapabilitiesMatchTheProbe() async {
        let descriptor = AppleSpeechAnalyzerEngine(runtime: FakeAppleSpeechRuntime()).descriptor

        #expect(descriptor.engine == .appleSpeechAnalyzer)
        // O locale é fixo no módulo: não existe detecção de idioma. É este campo que faz o
        // roteador excluir o motor de um pedido automático.
        #expect(!descriptor.detectsLanguageAutomatically)
        // Um por idioma do seletor, todos confirmados em `SpeechTranscriber.supportedLocales`
        // nesta máquina (29/08/2026). Sem locale aqui, o idioma cai no Whisper.
        #expect(
            descriptor.supportedLanguages == [
                .portugueseBrazil, .englishUS, .spanishSpain, .frenchFrance,
                .germanGermany, .japaneseJapan, .chineseChina
            ]
        )
        #expect(descriptor.supportsBatch)
        // Exige Apple Silicon (a sonda da T0.2 só rodou em Apple Silicon).
        #expect(descriptor.hardware.requiresAppleSilicon)
        // Nada é baixado por nós (modelo do sistema)...
        #expect(descriptor.models.allSatisfy { $0.downloadBytes == 0 })
        // ...mas o peso é `.heavy` CONSERVADOR até a medição de RSS na Onda 3: `weight` é peso na
        // MÁQUINA, e este motor mantém retenção `.processLifetime` — RAM real, a mesma que o
        // `unload()` existe para liberar. Classificar por `downloadBytes == 0` faria o coordenador
        // contabilizar zero e permitir um large-v3-turbo residente junto.
        #expect(descriptor.models.allSatisfy { $0.weight == .heavy })
    }

    @Test("O motor é ÚNICO por processo: duas montagens devolvem a mesma instância")
    func sharedEngineIsUniquePerProcess() async {
        var secondFactoryCalls = 0

        let first = AppleSpeechAnalyzerEngine.shared { FakeAppleSpeechRuntime() }
        let second = AppleSpeechAnalyzerEngine.shared {
            secondFactoryCalls += 1
            return FakeAppleSpeechRuntime()
        }

        // `AssetInventory` (pool de reservas) e `SpeechModels` (retenção) são estado do PROCESSO:
        // `endRetention()` é static e não tem parâmetro de dono. Duas instâncias seriam dois punhos
        // sobre o mesmo recurso — o unload de uma encerraria a retenção da outra, que continuaria
        // afirmando estar preparada sobre modelos já soltos.
        #expect(first === second)
        // E a segunda montagem nem constrói um runtime: se construísse, seria um segundo dono do
        // recurso global esperando a vez de causar dano.
        #expect(secondFactoryCalls == 0)
    }

    @Test("O observador é instalado explicitamente, porque a instância é compartilhada")
    func observerIsInstalledExplicitly() async throws {
        let log = AppleSpeechLoadEventLog()
        let runtime = FakeAppleSpeechRuntime()
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        // Sem observador: nada é emitido para ninguém.
        try await engine.prepare(model: .appleSystemSpeechPTBR)
        await engine.setObserver(log.sink)
        await engine.unload()

        #expect(await AppleSpeechFixtures.waitUntil { await log.events.count == 1 })
        #expect(await log.events == [.unloaded(generation: 2)])

        // E remover é igualmente explícito — numa instância compartilhada, trocar o observador em
        // silêncio seria roubar os eventos do dono anterior sem ele perceber.
        await engine.setObserver(nil)
        try await engine.prepare(model: .appleSystemSpeechPTBR)
        await AppleSpeechFixtures.settle()
        #expect(await log.events.count == 1)
    }

    @Test("Um modelo por locale, e cada um só atende o idioma dele")
    func oneModelPerLocale() {
        let descriptor = TranscriptionEngineDescriptor.appleSpeechAnalyzer

        #expect(descriptor.models.map(\.id) == AppleSpeechLocale.allCases.map(\.model))

        // Cada modelo atende o idioma dele e **nenhum outro**. Um `languages:` copiado de outro
        // caso — o erro fácil com sete entradas iguais — faria o roteador mandar áudio alemão ao
        // modelo espanhol, e o Apple não degrada nesse caso: ele devolve vazio.
        for locale in AppleSpeechLocale.allCases {
            let model = descriptor.model(locale.model)
            #expect(model?.supports(language: locale.language) == true)
            for outro in AppleSpeechLocale.allCases where outro != locale {
                #expect(
                    model?.supports(language: outro.language) == false,
                    "\(locale.rawValue) aceitou \(outro.rawValue)"
                )
            }
        }
        // Fixar um default faria o modelo do locale errado ser tentado antes do certo.
        #expect(descriptor.defaultModel == nil)
    }

    @Test("O locale sai do id do modelo, e o id volta do locale, sem par trocado")
    func localeComesFromTheModelID() {
        #expect(AppleSpeechLocale(model: .appleSystemSpeechPTBR) == .portugueseBrazil)
        #expect(AppleSpeechLocale(model: .appleSystemSpeechENUS) == .englishUS)
        #expect(AppleSpeechLocale(model: .whisperSmall) == nil)

        // Ida e volta em TODOS os locales: com sete pares escritos à mão em três `switch`
        // (`init(model:)`, `model`, `language`), trocar dois é o erro fácil — e o sintoma seria a
        // proveniência gravada dizer que o japonês foi transcrito pelo modelo alemão.
        for locale in AppleSpeechLocale.allCases {
            #expect(AppleSpeechLocale(model: locale.model) == locale)
            #expect(locale.language.rawValue == locale.rawValue)
            #expect(Language(rawValue: locale.language.primaryCode)?.appleSpeechLocale == locale)
        }
        #expect(AppleSpeechLocale.allCases.count == Language.allCases.count)

        // Sete idiomas para um pool de 5 reservas (T0.2): quem passar de cinco recebe
        // `reservationPoolFull` e cai para o Whisper naquele idioma. É degradação conhecida.
        #expect(AppleSpeechLocale.allCases.count > 5)
    }

    @Test("O roteador escolhe o modelo do idioma pedido")
    func routerPicksTheModelOfTheRequestedLanguage() {
        let router = TranscriptionRouter()

        for (language, expected) in [
            (TranscriptionLanguage.portugueseBrazil, TranscriptionModelID.appleSystemSpeechPTBR),
            (TranscriptionLanguage.englishUS, TranscriptionModelID.appleSystemSpeechENUS)
        ] {
            let plan = router.plan(
                for: TranscriptionRoutingContext(
                    useCase: .dictation,
                    language: language,
                    hardware: TranscriptionHardwareProfile(
                        architecture: .appleSilicon,
                        hasNeuralEngine: true,
                        physicalMemoryBytes: 16 * 1024 * 1024 * 1024
                    ),
                    selection: .automatic
                )
            )
            let candidate = plan.candidates.first { $0.engine == .appleSpeechAnalyzer }
            #expect(candidate?.model == expected)
        }
    }

    // MARK: - prepare: single-flight

    @Test("prepare reserva e aquece uma vez só para o mesmo locale")
    func prepareIsIdempotent() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        try await engine.prepare(model: .appleSystemSpeechPTBR)
        try await engine.prepare(model: .appleSystemSpeechPTBR)

        #expect(await runtime.loadCount == 1)
    }

    @Test("prepare concorrente aguarda a MESMA carga — uma reserva e um download só")
    func concurrentPrepareSharesASingleLoad() async throws {
        let runtime = FakeAppleSpeechRuntime(gateLoad: true)
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        // Oito chamadas simultâneas com a carga presa no portão. Sem single-flight, as sete
        // últimas disputariam a reserva do mesmo locale e o download do mesmo asset.
        async let waiters: [Void] = withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await engine.prepare(model: .appleSystemSpeechPTBR) }
            }
            var done: [Void] = []
            for try await result in group { done.append(result) }
            return done
        }

        #expect(await runtime.waitForGatedLoad())
        await runtime.openLoadGate()
        let results = try await waiters

        #expect(results.count == 8)
        #expect(await runtime.loadCount == 1)
        // E o resultado é utilizável: o analyzer ficou ativo.
        _ = try await engine.transcribe(
            AppleSpeechFixtures.request(),
            candidate: AppleSpeechFixtures.candidate()
        )
        #expect(await runtime.transcribeCount == 1)
    }

    @Test("Modelo que não é deste motor nem chega ao runtime")
    func prepareRejectsForeignModel() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.prepare(model: .whisperSmall)
        }
        #expect(await runtime.loadCount == 0)
    }

    @Test("Pedido de modelo desconhecido não evicta o locale que está funcionando")
    func unknownModelDoesNotEvictTheResidentOne() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.prepare(model: .whisperSmall)
        }

        // A validação do id acontece antes de tocar em estado (contrato, item 13): nada foi solto,
        // nada foi latchado, e o locale bom continua trabalhando.
        #expect(await runtime.releaseCount == 0)
        #expect(await runtime.residentModel == .appleSystemSpeechPTBR)
        _ = try await engine.transcribe(
            AppleSpeechFixtures.request(),
            candidate: AppleSpeechFixtures.candidate()
        )
        #expect(await runtime.transcribeCount == 1)
    }

    // MARK: - prepare: cache negativo

    @Test("Locale que falhou fica travado: 40 lotes não viram 40 tentativas de instalar asset")
    func failedModelIsLatched() async throws {
        let runtime = FakeAppleSpeechRuntime(
            loadFailure: .runtime(.assetUnavailable("download interrompido"))
        )
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        for _ in 0..<5 {
            await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
                try await engine.prepare(model: .appleSystemSpeechPTBR)
            }
        }
        #expect(await runtime.loadCount == 1)
    }

    @Test("unload solta o latch — e a instalação de asset é revogável, então retentar importa")
    func unloadClearsTheFailureLatch() async throws {
        let runtime = FakeAppleSpeechRuntime(loadFailure: .runtime(.assetUnavailable("sem rede")))
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
        await engine.unload()
        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }

        #expect(await runtime.loadCount == 2)
    }

    @Test("Cancelamento na carga não entra no cache negativo")
    func cancelledLoadIsNotLatched() async throws {
        let runtime = FakeAppleSpeechRuntime(loadFailure: .cancellation)
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        for _ in 0..<3 {
            await #expect(throws: TranscriptionEngineFailure.cancelled) {
                try await engine.prepare(model: .appleSystemSpeechPTBR)
            }
        }
        #expect(await runtime.loadCount == 3)
    }

    @Test("Locale e asset indisponíveis são RECUPERÁVEIS; cancelamento e áudio inválido não")
    func fallbackPolicyPerFailure() {
        // O requisito da T3.3: sem asset pt-BR o coordenador tem de poder cair para o WhisperKit.
        #expect(TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR).allowsFallback)
        #expect(TranscriptionEngineFailure.languageUnsupported(.portugueseBrazil).allowsFallback)
        #expect(TranscriptionEngineFailure.engineInternal("x").allowsFallback)
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)
        #expect(!TranscriptionEngineFailure.invalidAudio("áudio vazio").allowsFallback)
    }

    // MARK: - unload

    @Test("unload solta o analyzer de verdade e exige nova carga")
    func unloadReleasesTheAnalyzer() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await engine.unload()

        #expect(await runtime.releaseCount == 1)
        // E o motor não finge estar pronto: sem novo prepare, não transcreve.
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        try await engine.prepare(model: .appleSystemSpeechPTBR)
        #expect(await runtime.loadCount == 2)
    }

    @Test("unload durante uma carga em voo: o analyzer não ressuscita")
    func unloadDuringLoadDoesNotResurrectTheAnalyzer() async throws {
        let runtime = FakeAppleSpeechRuntime(gateLoad: true)
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        let preparing = Task { try await engine.prepare(model: .appleSystemSpeechPTBR) }
        #expect(await runtime.waitForGatedLoad())

        let unloading = Task { await engine.unload() }
        // Só abre o portão depois de o `unload` ter cancelado a carga: sem esta sincronização a
        // carga poderia terminar antes de o unload começar, e o teste passaria por acaso.
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.loadCancellations == 1 })
        await runtime.openLoadGate()
        await unloading.value

        await #expect(throws: TranscriptionEngineFailure.cancelled) { try await preparing.value }
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await runtime.releaseCount >= 1)
    }

    @Test("unload espera a análise em voo antes de soltar o analyzer")
    func unloadWaitsForInFlightInference() async throws {
        let runtime = FakeAppleSpeechRuntime(gateTranscribe: true)
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        let working = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.transcribeCount == 1 })

        let unloading = Task { await engine.unload() }
        #expect(await runtime.releaseCount == 0)

        await runtime.openTranscribeGate()
        _ = try await working.value
        await unloading.value

        #expect(await runtime.releaseCount == 1)
        // O que importa não é ter soltado, é ter soltado **depois**.
        let log = await runtime.callLog
        let transcribeEnd = log.firstIndex(of: "transcribe-end")
        let release = log.firstIndex(of: "release-start")
        #expect(transcribeEnd != nil && release != nil && transcribeEnd! < release!)
        #expect(await runtime.peakConcurrency == 1)
    }

    // MARK: - Serialização do runtime

    @Test("Duas análises concorrentes não entram juntas no runtime")
    func inferenceIsSerialized() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try await engine.transcribe(
                        AppleSpeechFixtures.request(),
                        candidate: AppleSpeechFixtures.candidate()
                    )
                }
            }
            while (try? await group.next()) != nil {}
        }

        #expect(await runtime.transcribeCount == 6)
        // O ator sozinho não garante isto: ele libera o executor em todo `await`.
        #expect(await runtime.peakConcurrency == 1)
    }

    @Test("Troca de locale espera a análise em voo antes de soltar o analyzer antigo")
    func localeSwitchDrainsInferenceFirst() async throws {
        let runtime = FakeAppleSpeechRuntime(gateTranscribe: true)
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        let working = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.transcribeCount == 1 })

        let switching = Task { try await engine.prepare(model: .appleSystemSpeechENUS) }
        // Com a análise presa, a troca não pode ter soltado nada.
        #expect(await runtime.releaseCount == 0)

        await runtime.openTranscribeGate()
        _ = try await working.value
        try await switching.value

        #expect(await runtime.peakConcurrency == 1)
        let log = await runtime.callLog
        let inferenceEnd = log.firstIndex(of: "transcribe-end")
        let releaseStart = log.firstIndex(of: "release-start")
        #expect(inferenceEnd != nil && releaseStart != nil && inferenceEnd! < releaseStart!)
        // Garantia pós-prepare (contrato, item 12): terminou com exatamente o locale pedido ativo.
        #expect(await runtime.residentModel == .appleSystemSpeechENUS)
    }

    @Test("Caminho rápido do prepare devolve sem drenar a análise em voo — é decisão, não descuido")
    func fastPathPrepareDoesNotDrainInflightInference() async throws {
        let runtime = FakeAppleSpeechRuntime(gateTranscribe: true)
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        let working = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.transcribeCount == 1 })

        // Locale pedido já é o residente: devolve na hora, com a análise ainda dentro do runtime.
        let outcome = await AppleSpeechFixtures.resolution {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }

        #expect(await outcome.resolved, "o caminho rápido entrou na fila da vaga")
        #expect(await outcome.failure == nil)
        #expect(await runtime.transcribeCount == 1)
        #expect(await runtime.loadCount == 1)
        #expect(await runtime.releaseCount == 0)

        await runtime.openTranscribeGate()
        _ = try await working.value
    }

    @Test("unload que se cruza com prepare: o que o motor diz e o que o runtime tem concordam")
    func unloadRacingPrepareNeverLies() async throws {
        // O interleaving muda a cada execução — o que não pode mudar é a invariante.
        for _ in 0..<25 {
            let runtime = FakeAppleSpeechRuntime(gateLoad: true)
            let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

            let first = Task { try await engine.prepare(model: .appleSystemSpeechPTBR) }
            #expect(await runtime.waitForGatedLoad())

            let unloading = Task { await engine.unload() }
            #expect(await AppleSpeechFixtures.waitUntil { await runtime.loadCancellations == 1 })
            // O unload está suspenso esperando a carga moribunda: é exatamente aqui que um prepare
            // novo se intercala.
            let second = Task { try await engine.prepare(model: .appleSystemSpeechPTBR) }

            await runtime.openLoadGate()
            await unloading.value
            _ = try? await first.value
            _ = try? await second.value

            var failure: TranscriptionEngineFailure?
            do {
                _ = try await engine.transcribe(
                    AppleSpeechFixtures.request(),
                    candidate: AppleSpeechFixtures.candidate()
                )
            } catch let error as TranscriptionEngineFailure {
                failure = error
            }

            switch failure {
            case nil:
                // Disse que estava preparado — e estava mesmo.
                #expect(await runtime.residentModel == .appleSystemSpeechPTBR)
            case .modelUnavailable:
                // Honesto: não está preparado. O coordenador prepara de novo.
                break
            case .engineInternal(FakeAppleSpeechRuntime.missingAnalyzer):
                Issue.record("motor afirmou estar preparado sobre um analyzer já descartado")
            case .some(let other):
                Issue.record("falha inesperada: \(other)")
            }
        }
    }

    @Test("Carga e análise disputam a mesma vaga")
    func loadAndInferenceShareTheSlot() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)
        try await engine.prepare(model: .appleSystemSpeechPTBR)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await engine.transcribe(
                    AppleSpeechFixtures.request(),
                    candidate: AppleSpeechFixtures.candidate()
                )
            }
            group.addTask { await engine.unload() }
            group.addTask { try await engine.prepare(model: .appleSystemSpeechPTBR) }
            while (try? await group.next()) != nil {}
        }

        #expect(await runtime.peakConcurrency == 1)
    }

    // MARK: - LoadEvent

    @Test("Os eventos de carga carregam id de geração monotônico")
    func loadEventsCarryGeneration() async throws {
        let log = AppleSpeechLoadEventLog()
        let runtime = FakeAppleSpeechRuntime()
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime, observer: log.sink)

        try await engine.prepare(model: .appleSystemSpeechPTBR)
        await engine.unload()
        #expect(await AppleSpeechFixtures.waitUntil { await log.events.count == 3 })

        let events = await log.events
        #expect(events[0] == .loading(model: .appleSystemSpeechPTBR, generation: 1))
        #expect(events[1] == .ready(model: .appleSystemSpeechPTBR, generation: 1))
        #expect(events[2] == .unloaded(generation: 2))
    }

    @Test("Falha de carga vira evento failed com a mesma geração")
    func failedLoadEmitsFailedEvent() async throws {
        let log = AppleSpeechLoadEventLog()
        let runtime = FakeAppleSpeechRuntime(loadFailure: .runtime(.assetUnavailable("sem rede")))
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime, observer: log.sink)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
        #expect(await AppleSpeechFixtures.waitUntil { await log.events.count == 2 })

        let events = await log.events
        #expect(events[0] == .loading(model: .appleSystemSpeechPTBR, generation: 1))
        #expect(events[1] == .failed(
            model: .appleSystemSpeechPTBR,
            failure: .modelUnavailable(.appleSystemSpeechPTBR),
            generation: 1
        ))
    }

    @Test("Uma carga superada não emite ready")
    func supersededLoadEmitsNoReady() async throws {
        let log = AppleSpeechLoadEventLog()
        let runtime = FakeAppleSpeechRuntime(gateLoad: true)
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime, observer: log.sink)

        let preparing = Task { try await engine.prepare(model: .appleSystemSpeechPTBR) }
        #expect(await runtime.waitForGatedLoad())
        let unloading = Task { await engine.unload() }
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.loadCancellations == 1 })
        await runtime.openLoadGate()
        await unloading.value
        _ = try? await preparing.value

        let events = await log.events
        #expect(!events.contains { if case .ready = $0 { return true } else { return false } })
    }

    // MARK: - transcribe

    @Test("transcribe NÃO prepara sozinho: sem analyzer, modelUnavailable")
    func transcribeDoesNotAutoPrepare() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        // Reservar locale e baixar asset por trás de uma fila de lotes desfaria a prioridade do
        // coordenador.
        #expect(await runtime.loadCount == 0)
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Candidato com locale diferente do preparado não é atendido")
    func transcribeRefusesAnotherLocale() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechENUS)) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(language: .englishUS),
                candidate: AppleSpeechFixtures.candidate(model: .appleSystemSpeechENUS)
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("O resultado carrega texto, segmentos e proveniência do candidato")
    func resultCarriesTextSegmentsAndProvenance() async throws {
        let runtime = FakeAppleSpeechRuntime(
            output: AppleSpeechRuntimeOutput(
                segments: [
                    AppleSpeechTranscriptSegment(text: "bom dia", start: 0, end: 1.25, confidence: 0.9),
                    AppleSpeechTranscriptSegment(text: "tudo bem", start: 1.25, end: 2, confidence: 0.7)
                ],
                processingTime: 0.07
            )
        )
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)
        let candidate = AppleSpeechFixtures.candidate(origin: .userSelection)

        let result = try await engine.transcribe(
            AppleSpeechFixtures.request(useCase: .meetingFinal),
            candidate: candidate
        )

        #expect(result.text == "bom dia tudo bem")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 1.25)
        #expect(result.segments[0].confidence == 0.9)
        #expect(result.segments[1].start == 1.25)
        #expect(result.segments[1].end == 2)
        #expect(result.processingTime == 0.07)
        #expect(await runtime.lastSampleCount == 32_000)
        #expect(await runtime.requestedSampleRates == [16_000])
        #expect(result.provenance == TranscriptionProvenance(
            engine: .appleSpeechAnalyzer,
            model: .appleSystemSpeechPTBR,
            useCase: .meetingFinal,
            origin: .userSelection,
            candidateRank: 0
        ))
    }

    @Test("O idioma reportado é o locale do modelo — o motor sabe, não detecta")
    func detectedLanguageIsTheModelLocale() async throws {
        let ptEngine = try await AppleSpeechFixtures.preparedEngine(runtime: FakeAppleSpeechRuntime())
        let ptResult = try await ptEngine.transcribe(
            AppleSpeechFixtures.request(language: .portugueseBrazil),
            candidate: AppleSpeechFixtures.candidate()
        )
        #expect(ptResult.detectedLanguage == .portugueseBrazil)

        let enEngine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(),
            model: .appleSystemSpeechENUS
        )
        let enResult = try await enEngine.transcribe(
            AppleSpeechFixtures.request(language: .englishUS),
            candidate: AppleSpeechFixtures.candidate(model: .appleSystemSpeechENUS)
        )
        #expect(enResult.detectedLanguage == .englishUS)
    }

    @Test("Candidato de fallback marca o rank na proveniência")
    func fallbackCandidateKeepsRank() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: FakeAppleSpeechRuntime())

        let result = try await engine.transcribe(
            AppleSpeechFixtures.request(),
            candidate: AppleSpeechFixtures.candidate(rank: 2)
        )

        #expect(result.provenance.candidateRank == 2)
        #expect(result.provenance.isFallback)
    }

    @Test("O texto sai aparado e trecho vazio não vira segmento")
    func textIsTrimmedAndEmptyPiecesDropped() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(
                output: AppleSpeechRuntimeOutput(segments: [
                    AppleSpeechTranscriptSegment(text: "  oi \n", start: 0, end: 1),
                    AppleSpeechTranscriptSegment(text: "   ", start: 1, end: 2)
                ])
            )
        )

        let result = try await engine.transcribe(
            AppleSpeechFixtures.request(),
            candidate: AppleSpeechFixtures.candidate()
        )

        #expect(result.text == "oi")
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.text == "oi")
    }

    @Test("Nada reconhecido é texto vazio sem segmento")
    func noSegmentsMeansEmptyText() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(output: AppleSpeechRuntimeOutput(segments: []))
        )

        let result = try await engine.transcribe(
            AppleSpeechFixtures.request(),
            candidate: AppleSpeechFixtures.candidate()
        )

        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }

    @Test("Trecho único sem faixa de tempo cobre o áudio pedido")
    func singleSegmentWithoutTimeRangeCoversTheRequest() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(
                output: AppleSpeechRuntimeOutput(segments: [
                    AppleSpeechTranscriptSegment(text: "oi", start: 0, end: 0)
                ])
            )
        )

        let result = try await engine.transcribe(
            AppleSpeechFixtures.request(seconds: 3),
            candidate: AppleSpeechFixtures.candidate()
        )

        #expect(result.segments.first?.end == 3)
    }

    // MARK: - Pedidos recusados antes de gastar a vaga

    @Test("Áudio vazio é inválido e não chega ao runtime")
    func emptyAudioIsRejected() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.invalidAudio("áudio vazio")) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(seconds: 0),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Áudio fora de 16 kHz é inválido — o pipeline do app é 16 kHz mono ponta a ponta")
    func wrongSampleRateIsRejected() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(sampleRate: 48_000),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Pedido com detecção automática de idioma é recusado: o locale é fixo")
    func automaticLanguageIsRejected() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(language: nil),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Idioma que não é o do locale preparado é recusado — nada de transcrever no locale errado")
    func languageMismatchWithTheModelLocaleIsRejected() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        // Modelo pt-BR, pedido en-US: o texto sairia no locale errado, sem ninguém perceber.
        await #expect(throws: TranscriptionEngineFailure.languageUnsupported(.englishUS)) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(language: .englishUS),
                candidate: AppleSpeechFixtures.candidate(model: .appleSystemSpeechPTBR)
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Idioma que o motor não fala é recusado")
    func unsupportedLanguageIsRejected() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)
        let french = TranscriptionLanguage("fr-FR")

        await #expect(throws: TranscriptionEngineFailure.languageUnsupported(french)) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(language: french),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("A prévia da reunião não é deste adapter: ela é a sessão progressiva da T4.2")
    func streamingUseCaseIsRejected() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        // O descritor declara `supportsStreaming` (a T4.2 é do mesmo motor), então este adapter
        // precisa barrar a prévia por conta própria.
        #expect(engine.descriptor.supportsStreaming)
        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(useCase: .meetingPreview),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    // MARK: - Cancelamento

    @Test("Trabalho já cancelado não gasta reserva nem análise")
    func cancelledTaskDoesNoWork() async throws {
        let runtime = FakeAppleSpeechRuntime()
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)
        let loadsBefore = await runtime.loadCount

        let task = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        task.cancel()
        await #expect(throws: TranscriptionEngineFailure.cancelled) { _ = try await task.value }

        #expect(await runtime.transcribeCount == 0)
        #expect(await runtime.loadCount == loadsBefore)
    }

    @Test("Cancelamento DURANTE a análise não vira sucesso, mesmo ela terminando normalmente")
    func cancellationDuringInferenceIsNotDeliveredAsSuccess() async throws {
        let runtime = FakeAppleSpeechRuntime(gateTranscribe: true)
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        let work = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.transcribeCount == 1 })

        work.cancel()
        await runtime.openTranscribeGate()

        await #expect(throws: TranscriptionEngineFailure.cancelled) { _ = try await work.value }
    }

    @Test("Trabalho cancelado sai da fila da vaga em vez de segurar a vez")
    func cancelledWorkLeavesTheQueue() async throws {
        let runtime = FakeAppleSpeechRuntime(gateTranscribe: true)
        let engine = try await AppleSpeechFixtures.preparedEngine(runtime: runtime)

        let holder = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        #expect(await AppleSpeechFixtures.waitUntil { await runtime.transcribeCount == 1 })

        let queued = Task {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
        await AppleSpeechFixtures.settle()
        queued.cancel()

        // A prova está em resolver AGORA, com a vaga ainda ocupada e o portão fechado.
        let outcome = await AppleSpeechFixtures.resolution { _ = try await queued.value }

        #expect(await outcome.resolved, "o trabalho cancelado ficou preso na fila até chegar a vez dele")
        #expect(await outcome.failure == .cancelled)
        #expect(await runtime.transcribeCount == 1)

        await runtime.openTranscribeGate()
        _ = try await holder.value
    }

    @Test("Quem espera o single-flight também respeita o próprio cancelamento")
    func singleFlightWaiterRechecksCancellation() async throws {
        let runtime = FakeAppleSpeechRuntime(gateLoad: true)
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)

        let first = Task { try await engine.prepare(model: .appleSystemSpeechPTBR) }
        #expect(await runtime.waitForGatedLoad())
        let waiter = Task { try await engine.prepare(model: .appleSystemSpeechPTBR) }
        await AppleSpeechFixtures.settle()
        waiter.cancel()

        await runtime.openLoadGate()
        try await first.value

        await #expect(throws: TranscriptionEngineFailure.cancelled) { try await waiter.value }
        #expect(await runtime.loadCount == 1)
        #expect(await runtime.residentModel == .appleSystemSpeechPTBR)
    }

    @Test("Cancelamento vindo do runtime vira cancelled e não tenta outro motor")
    func cancellationFromRuntimeIsPreserved() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(transcribeFailure: .runtime(.cancelled))
        )

        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
    }

    // MARK: - Tradução de erro

    @Test("Locale indisponível vira languageUnsupported, que permite fallback")
    func localeUnsupportedBecomesLanguageUnsupported() async throws {
        let engine = AppleSpeechAnalyzerEngine(
            runtime: FakeAppleSpeechRuntime(loadFailure: .runtime(.localeUnsupported("pt-BR")))
        )

        await #expect(throws: TranscriptionEngineFailure.languageUnsupported(.portugueseBrazil)) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
    }

    @Test("Asset indisponível vira modelUnavailable, que permite fallback")
    func assetUnavailableBecomesModelUnavailable() async throws {
        let engine = AppleSpeechAnalyzerEngine(
            runtime: FakeAppleSpeechRuntime(loadFailure: .runtime(.assetUnavailable("sem espaço")))
        )

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
    }

    @Test("Modelo que o runtime não sabe atender vira modelUnavailable")
    func unsupportedModelBecomesModelUnavailable() async throws {
        let engine = AppleSpeechAnalyzerEngine(
            runtime: FakeAppleSpeechRuntime(
                loadFailure: .runtime(.unsupportedModel(.appleSystemSpeechPTBR))
            )
        )

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
    }

    @Test("Formato recusado vira engineInternal, e não invalidAudio: o áudio é o de sempre")
    func audioFormatUnsupportedBecomesEngineInternal() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(
                transcribeFailure: .runtime(.audioFormatUnsupported("sem formato compatível"))
            )
        )

        // `invalidAudio` proibiria fallback, condenando o pedido por um defeito só deste motor.
        await #expect(throws: TranscriptionEngineFailure.engineInternal("sem formato compatível")) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
    }

    @Test("Falha de análise vira engineInternal, que permite fallback")
    func runtimeFailureBecomesEngineInternal() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(
                transcribeFailure: .runtime(.runtimeFailure("analyzer abortou"))
            )
        )

        await #expect(throws: TranscriptionEngineFailure.engineInternal("analyzer abortou")) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
    }

    @Test("Erro de terceiro vira engineInternal com a descrição técnica")
    func foreignErrorBecomesEngineInternal() async throws {
        let engine = try await AppleSpeechFixtures.preparedEngine(
            runtime: FakeAppleSpeechRuntime(transcribeFailure: .foreign("AVAudioConverter falhou"))
        )

        await #expect(throws: TranscriptionEngineFailure.engineInternal("AVAudioConverter falhou")) {
            try await engine.transcribe(
                AppleSpeechFixtures.request(),
                candidate: AppleSpeechFixtures.candidate()
            )
        }
    }
}
