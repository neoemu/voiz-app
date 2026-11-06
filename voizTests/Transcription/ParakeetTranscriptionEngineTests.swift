import Testing
import Foundation

// Testes do adapter da T2.2. O que está sob teste é o **adapter**: ciclo de vida dos pesos
// (single-flight, cache negativo, unload que libera de verdade), serialização do runtime,
// cancelamento, validação do pedido e montagem do resultado. Reconhecimento de fala é do
// `ParakeetTranscriptionService`, que aqui é sempre dublê — nenhum teste baixa modelo, carrega
// CoreML ou toca em FluidAudio.
//
// O dublê é **bloqueável**: sem poder segurar uma carga no meio, testes de concorrência provam
// só o caminho sequencial — foi assim que o `prepare` não-single-flight passou na primeira
// rodada.

// MARK: - Dublê do runtime

/// Falhas que o dublê sabe levantar, cobrindo os ramos do mapeamento de erro do motor.
nonisolated enum FakeParakeetFailure: Sendable {
    case runtime(ParakeetRuntimeError)
    case cancellation
    /// Erro de terceiro (o que viria do FluidAudio na vida real).
    case foreign(String)

    var error: any Error {
        switch self {
        case .runtime(let error): return error
        case .cancellation: return CancellationError()
        case .foreign(let message):
            return NSError(
                domain: "fake.parakeet",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

/// Runtime Parakeet falso: conta chamadas, registra o que recebeu, falha sob encomenda e — o que
/// importa para concorrência — sabe **segurar** uma carga até o teste soltar.
actor FakeParakeetRuntime: ParakeetRuntime {
    private let output: ParakeetRuntimeOutput
    private let loadFailure: FakeParakeetFailure?
    private let transcribeFailure: FakeParakeetFailure?

    private(set) var loadCount = 0
    private(set) var transcribeCount = 0
    private(set) var releaseCount = 0
    private(set) var loadedModels: [TranscriptionModelID] = []
    private(set) var requestedLanguages: [TranscriptionLanguage?] = []
    private(set) var lastSampleCount = 0
    /// Maior número de chamadas simultâneas dentro do runtime. Se passar de 1, a vaga única do
    /// motor não está segurando nada.
    private(set) var peakConcurrency = 0
    /// Ordem em que as chamadas entraram e saíram. É o que deixa um teste afirmar "a descarga
    /// aconteceu **depois** de a inferência terminar", e não só "aconteceu".
    private(set) var callLog: [String] = []
    /// Quantas cargas presas no portão foram canceladas. O `onCancel` dispara no instante do
    /// `cancel()`, então é o sinal de que o trecho síncrono do `unload` já rodou — sem ele, abrir
    /// o portão pode ganhar a corrida do `unload` e o teste vira moeda.
    private(set) var loadCancellations = 0
    /// O dublê guarda "pesos" de verdade: `load` põe, `release` tira. É o que deixa um teste
    /// distinguir "o motor diz que não está preparado" de "o motor diz que está preparado sobre
    /// pesos que não existem" — a mentira que o MAIOR do unload×prepare descrevia.
    private(set) var residentModel: TranscriptionModelID?

    private var active = 0
    private let loadHold: TestGate
    private var loadIsGated: Bool
    private var transcribeGate: [CheckedContinuation<Void, Never>] = []
    private var transcribeIsGated = false

    init(
        output: ParakeetRuntimeOutput = .init(
            text: "olá do parakeet",
            confidence: 0.8,
            duration: 1.5,
            processingTime: 0.05
        ),
        loadFailure: FakeParakeetFailure? = nil,
        transcribeFailure: FakeParakeetFailure? = nil,
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

    // MARK: ParakeetRuntime

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
        language: TranscriptionLanguage?,
        model: TranscriptionModelID
    ) async throws -> ParakeetRuntimeOutput {
        transcribeCount += 1
        lastSampleCount = samples.count
        requestedLanguages.append(language)
        enter()
        callLog.append("transcribe-start")
        defer {
            callLog.append("transcribe-end")
            leave()
        }
        // Espelha a guarda do `ParakeetServiceRuntime`: sem pesos, erro visível — e com uma
        // descrição própria, para o teste distinguir esta mentira de um honesto "não preparado".
        guard residentModel == model else {
            throw ParakeetRuntimeError.runtimeFailure(FakeParakeetRuntime.missingWeights)
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
    /// Sem isso, um `cleanup()` rodando em cima de uma inferência viva não aparecia no
    /// `peakConcurrency` — foi assim que o CRITICO da troca de modelo passou batido.
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

    static let missingWeights = "pesos ausentes no runtime"

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
    /// `enter` e `leave`, o próprio ator do dublê serializa tudo e `peakConcurrency` seria 1
    /// mesmo com o motor deixando duas inferências entrarem juntas. Um mutante que removesse a
    /// vaga única do motor passaria no teste — foi exatamente o que a mutação controlada mostrou.
    private func interleave() async {
        for _ in 0..<4 {
            await Task.yield()
            peakConcurrency = max(peakConcurrency, active)
        }
    }
}

/// Caixa para observar de fora se um trabalho já resolveu, sem bloquear ninguém esperando por
/// ele. Usada onde "resolveu dentro do prazo?" é a própria asserção.
actor ParakeetOutcomeBox {
    private(set) var resolved = false
    private(set) var failure: TranscriptionEngineFailure?

    func record(_ error: (any Error)?) {
        resolved = true
        failure = error as? TranscriptionEngineFailure
    }
}

/// Coletor de `LoadEvent` seguro para passar ao motor como observador.
actor LoadEventLog {
    private(set) var events: [ParakeetTranscriptionEngine.LoadEvent] = []

    func append(_ event: ParakeetTranscriptionEngine.LoadEvent) {
        events.append(event)
    }

    nonisolated var sink: @Sendable (ParakeetTranscriptionEngine.LoadEvent) -> Void {
        { event in Task { await self.append(event) } }
    }
}

// MARK: - Atalhos

nonisolated enum ParakeetFixtures {
    /// O candidato que o roteador produz para o Parakeet no caminho normal.
    static func candidate(
        model: TranscriptionModelID = .parakeetTDT06BV3,
        rank: Int = 0,
        origin: TranscriptionSelectionOrigin = .automatic
    ) -> TranscriptionRoutingCandidate {
        TranscriptionRoutingCandidate(engine: .parakeet, model: model, rank: rank, origin: origin)
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

    /// O segundo modelo do runtime Parakeet. Hoje não existe no catálogo de produção; é o lugar
    /// do TAGARELA CoreML na Onda 5, e é o que permite exercitar troca de modelo.
    static let secondModel = TranscriptionModelID("parakeet-tdt-0.6b-v3-ptBR-tagarela")

    /// Um Parakeet hipotético com dois modelos. O descritor de produção tem um só, e com um só a
    /// troca de modelo — o caminho onde os pesos antigos são liberados — é intestável.
    static var twoModelDescriptor: TranscriptionEngineDescriptor {
        var descriptor = TranscriptionEngineDescriptor.parakeet
        descriptor.models.append(
            TranscriptionModelDescriptor(
                id: secondModel,
                engine: .parakeet,
                productName: "TAGARELA (hipotético)",
                weight: .heavy,
                downloadBytes: 600 * 1024 * 1024,
                hardware: .appleSiliconNeuralEngine
            )
        )
        return descriptor
    }

    /// Um motor pronto para transcrever: pesos "carregados".
    static func preparedEngine(
        runtime: FakeParakeetRuntime,
        model: TranscriptionModelID = .parakeetTDT06BV3,
        descriptor: TranscriptionEngineDescriptor = .parakeet
    ) async throws -> ParakeetTranscriptionEngine {
        let engine = ParakeetTranscriptionEngine(runtime: runtime, descriptor: descriptor)
        try await engine.prepare(model: model)
        return engine
    }

    /// Deixa as tarefas recém-criadas chegarem à primeira suspensão.
    ///
    /// Heurística, e assumida como tal: serve só para posicionar um trabalho *dentro* da fila da
    /// vaga antes de cancelá-lo. Nenhuma asserção depende de quantos yields foram precisos — se a
    /// tarefa ainda não tiver entrado na fila, o teste continua correto, só testa a borda de
    /// entrada em vez da saída da fila.
    static func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    /// Espera até `condition` valer, ou desiste. Serve para sincronizar com trabalho que já foi
    /// disparado mas ainda não chegou ao dublê. O prazo é o do `waitUntil` compartilhado (30s):
    /// 500 `yield`s media starvation da suíte, não o evento.
    static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        seconds: Double = 30
    ) async -> Bool {
        await voizTests.waitUntil(seconds: seconds, condition)
    }
}

@Suite("Motor Parakeet (adapter da T2.2)")
struct ParakeetTranscriptionEngineTests {

    // MARK: - Fidelidade ao catálogo

    @Test("O motor responde pelo descritor do Parakeet no catálogo de produção")
    func descriptorMatchesShippingCatalog() async {
        let engine = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime())

        #expect(engine.descriptor == TranscriptionCatalog.shipping.descriptor(for: .parakeet))
    }

    @Test("As capacidades declaradas são as que o Parakeet tem hoje no app")
    func declaredCapabilitiesMatchTheService() async {
        let descriptor = ParakeetTranscriptionEngine(runtime: FakeParakeetRuntime()).descriptor

        #expect(descriptor.engine == .parakeet)
        // Era multilíngue com autodetecção enquanto o app carregava o modelo base da NVIDIA. Os
        // pesos passaram a ser o fine-tune pt-BR na Onda 5, e ele ESQUECEU as outras línguas:
        // medido em 27/08/2026, "We deployed the new cluster last week" volta como "Nós amplamos
        // uma cluster na noite". Não é degradação — é inglês transcrito como português fonético,
        // com confiança. Enquanto for esse o modelo, declarar inglês aqui manda quem fala inglês
        // para o motor errado, e declarar autodetecção o elege no modo automático (o default).
        #expect(descriptor.detectsLanguageAutomatically == false)
        #expect(descriptor.supportedLanguages == [.portuguese])
        // Sem streaming: o adapter é só lote, então a prévia da reunião nunca cai aqui.
        #expect(descriptor.supportsBatch)
        #expect(!descriptor.supportsStreaming)
        #expect(!descriptor.supportedUseCases.contains(.meetingPreview))
        // Modelo CoreML pesado: Apple Silicon com Neural Engine.
        #expect(descriptor.hardware == .appleSiliconNeuralEngine)
        #expect(descriptor.models.map(\.id) == [.parakeetTDT06BV3])
        #expect(descriptor.models.allSatisfy { $0.weight == .heavy })
        // Ainda em avaliação — a T2.2 não muda isso.
        #expect(descriptor.isExperimental)
        // Última posição da ordem automática: o WhisperKit continua sendo a primeira escolha.
        #expect(descriptor.automaticPriority > TranscriptionEngineDescriptor.whisperKit.automaticPriority)
    }

    // MARK: - prepare: single-flight

    @Test("prepare carrega o serviço uma vez só para o mesmo modelo")
    func prepareIsIdempotent() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        try await engine.prepare(model: .parakeetTDT06BV3)
        try await engine.prepare(model: .parakeetTDT06BV3)

        #expect(await runtime.loadCount == 1)
    }

    @Test("prepare concorrente aguarda a MESMA carga — uma carga só, sucesso para todos")
    func concurrentPrepareSharesASingleLoad() async throws {
        let runtime = FakeParakeetRuntime(gateLoad: true)
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        // Oito chamadas simultâneas com a carga presa no portão. Sem single-flight, as sete
        // últimas veriam o serviço "ocupado" e receberiam modelUnavailable espúrio.
        async let waiters: [Void] = withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await engine.prepare(model: .parakeetTDT06BV3) }
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
        // E o resultado é utilizável: os pesos ficaram residentes.
        _ = try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        #expect(await runtime.transcribeCount == 1)
    }

    @Test("Modelo que não é do Parakeet nem chega ao runtime")
    func prepareRejectsForeignModel() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.prepare(model: .whisperSmall)
        }
        #expect(await runtime.loadCount == 0)
    }

    @Test("Pedido de modelo desconhecido não evicta o modelo que está funcionando")
    func unknownModelDoesNotEvictTheResidentOne() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.prepare(model: .whisperSmall)
        }

        // A validação do id acontece antes de tocar em estado (contrato, item 13): nada foi
        // liberado, nada foi latchado, e o modelo bom continua trabalhando.
        #expect(await runtime.releaseCount == 0)
        #expect(await runtime.residentModel == .parakeetTDT06BV3)
        _ = try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        #expect(await runtime.transcribeCount == 1)
    }

    // MARK: - prepare: cache negativo

    @Test("Modelo que falhou fica travado: 40 lotes não viram 40 downloads")
    func failedModelIsLatched() async throws {
        let runtime = FakeParakeetRuntime(
            loadFailure: .runtime(.modelsUnavailable("download interrompido"))
        )
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        for _ in 0..<5 {
            await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
                try await engine.prepare(model: .parakeetTDT06BV3)
            }
        }
        // Uma tentativa só: o latch é simétrico ao `failedModel` do motor do Whisper. Quando
        // limpar é decisão da T2.3/T2.5, não do motor.
        #expect(await runtime.loadCount == 1)
    }

    @Test("unload solta o latch e uma nova carga é tentada")
    func unloadClearsTheFailureLatch() async throws {
        let runtime = FakeParakeetRuntime(loadFailure: .runtime(.modelsUnavailable("sem rede")))
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.prepare(model: .parakeetTDT06BV3)
        }
        await engine.unload()
        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.prepare(model: .parakeetTDT06BV3)
        }

        #expect(await runtime.loadCount == 2)
    }

    @Test("Cancelamento na carga não entra no cache negativo")
    func cancelledLoadIsNotLatched() async throws {
        let runtime = FakeParakeetRuntime(loadFailure: .cancellation)
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        for _ in 0..<3 {
            await #expect(throws: TranscriptionEngineFailure.cancelled) {
                try await engine.prepare(model: .parakeetTDT06BV3)
            }
        }
        // Cada tentativa é uma tentativa de verdade: cancelar não condena o modelo.
        #expect(await runtime.loadCount == 3)
    }

    @Test("modelUnavailable permite fallback; cancelled não")
    func fallbackPolicyPerFailure() {
        #expect(TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3).allowsFallback)
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)
    }

    // MARK: - unload

    @Test("unload libera os pesos de verdade e exige nova carga")
    func unloadReleasesWeights() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await engine.unload()

        // A descarga real (AsrManager.cleanup()) foi pedida ao runtime — não é só esquecer estado.
        #expect(await runtime.releaseCount == 1)
        // E o motor não finge estar pronto: sem novo prepare, não transcreve.
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        try await engine.prepare(model: .parakeetTDT06BV3)
        #expect(await runtime.loadCount == 2)
    }

    @Test("unload durante uma carga em voo: o modelo não ressuscita")
    func unloadDuringLoadDoesNotResurrectTheModel() async throws {
        let runtime = FakeParakeetRuntime(gateLoad: true)
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        let preparing = Task { try await engine.prepare(model: .parakeetTDT06BV3) }
        #expect(await runtime.waitForGatedLoad())

        let unloading = Task { await engine.unload() }
        // Só abre o portão depois de o `unload` ter cancelado a carga: sem esta sincronização a
        // carga poderia terminar antes de o unload começar, e o teste passaria por acaso.
        #expect(await ParakeetFixtures.waitUntil { await runtime.loadCancellations == 1 })
        // A carga presa só termina quando o teste abre o portão; o unload tem de esperá-la.
        await runtime.openLoadGate()
        await unloading.value

        // Quem pediu a carga recebe cancelamento, não sucesso mentiroso.
        await #expect(throws: TranscriptionEngineFailure.cancelled) { try await preparing.value }
        // E o modelo NÃO ficou residente por baixo do unload.
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        #expect(await runtime.releaseCount >= 1)
    }

    @Test("unload espera a inferência em voo antes de soltar os pesos")
    func unloadWaitsForInFlightInference() async throws {
        let runtime = FakeParakeetRuntime(gateTranscribe: true)
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        let working = Task {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        #expect(await ParakeetFixtures.waitUntil { await runtime.transcribeCount == 1 })

        let unloading = Task { await engine.unload() }
        // Enquanto a inferência está presa, o unload não pode ter soltado nada.
        #expect(await runtime.releaseCount == 0)

        await runtime.openTranscribeGate()
        _ = try await working.value
        await unloading.value

        #expect(await runtime.releaseCount == 1)
        // O que importa não é ter soltado, é ter soltado **depois**: puxar o AsrManager por baixo
        // de uma inferência viva é corrida, não economia de memória.
        let log = await runtime.callLog
        let transcribeEnd = log.firstIndex(of: "transcribe-end")
        let release = log.firstIndex(of: "release-start")
        #expect(transcribeEnd != nil && release != nil && transcribeEnd! < release!)
        #expect(await runtime.peakConcurrency == 1)
    }

    // MARK: - Serialização do runtime

    @Test("Duas inferências concorrentes não entram juntas no runtime")
    func inferenceIsSerialized() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try await engine.transcribe(
                        ParakeetFixtures.request(),
                        candidate: ParakeetFixtures.candidate()
                    )
                }
            }
            while (try? await group.next()) != nil {}
        }

        #expect(await runtime.transcribeCount == 6)
        // O ator sozinho não garante isto: ele libera o executor em todo `await`. Quem garante é
        // a vaga única do motor.
        #expect(await runtime.peakConcurrency == 1)
    }

    @Test("Troca de modelo espera a inferência em voo antes de soltar os pesos antigos")
    func modelSwitchDrainsInferenceFirst() async throws {
        let runtime = FakeParakeetRuntime(gateTranscribe: true)
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: runtime,
            descriptor: ParakeetFixtures.twoModelDescriptor
        )

        let working = Task {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        #expect(await ParakeetFixtures.waitUntil { await runtime.transcribeCount == 1 })

        let switching = Task { try await engine.prepare(model: ParakeetFixtures.secondModel) }
        // Com a inferência presa, a troca não pode ter soltado nada: `AsrManager.cleanup()` por
        // baixo de uma inferência viva era o CRITICO — o `prepare` chamava `release()` sem tomar
        // a vaga, violando a precondição que o próprio serviço documenta.
        #expect(await runtime.releaseCount == 0)

        await runtime.openTranscribeGate()
        _ = try await working.value
        try await switching.value

        #expect(await runtime.peakConcurrency == 1)
        let log = await runtime.callLog
        let inferenceEnd = log.firstIndex(of: "transcribe-end")
        let releaseStart = log.firstIndex(of: "release-start")
        #expect(inferenceEnd != nil && releaseStart != nil && inferenceEnd! < releaseStart!)
        // Garantia pós-prepare (contrato, item 12): terminou com exatamente o modelo pedido
        // residente e sem nada de antes em voo.
        #expect(await runtime.residentModel == ParakeetFixtures.secondModel)
    }

    @Test("Caminho rápido do prepare devolve sem drenar a inferência em voo — é decisão, não descuido")
    func fastPathPrepareDoesNotDrainInflightInference() async throws {
        let runtime = FakeParakeetRuntime(gateTranscribe: true)
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        let working = Task {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        #expect(await ParakeetFixtures.waitUntil { await runtime.transcribeCount == 1 })

        // Modelo pedido já é o residente: devolve na hora, com a inferência ainda dentro do
        // runtime. A garantia forte do item 12 ("nada de antes em voo") vale quando houve carga;
        // aqui vale só "o modelo pedido está residente". Fazer este caminho enfileirar
        // transformaria um `prepare` barato — que o coordenador chama por lote — numa espera pela
        // inferência anterior.
        let outcome = ParakeetOutcomeBox()
        let quick = Task {
            do {
                try await engine.prepare(model: .parakeetTDT06BV3)
                await outcome.record(nil)
            } catch {
                await outcome.record(error)
            }
        }
        var waited = 0
        while await !outcome.resolved && waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }

        #expect(await outcome.resolved, "o caminho rápido entrou na fila da vaga")
        #expect(await outcome.failure == nil)
        #expect(await runtime.transcribeCount == 1)
        // E nada foi recarregado nem liberado.
        #expect(await runtime.loadCount == 1)
        #expect(await runtime.releaseCount == 0)

        await runtime.openTranscribeGate()
        _ = try await working.value
        _ = await quick.value
    }

    @Test("unload que se cruza com prepare: o que o motor diz e o que o runtime tem concordam")
    func unloadRacingPrepareNeverLies() async throws {
        // O interleaving muda a cada execução — o que não pode mudar é a invariante. Sem a
        // exclusão mútua do ciclo de vida, o unload soltava os pesos recém-carregados e deixava
        // o motor afirmando estar preparado sobre eles.
        for _ in 0..<25 {
            let runtime = FakeParakeetRuntime(gateLoad: true)
            let engine = ParakeetTranscriptionEngine(runtime: runtime)

            let first = Task { try await engine.prepare(model: .parakeetTDT06BV3) }
            #expect(await runtime.waitForGatedLoad())

            let unloading = Task { await engine.unload() }
            #expect(await ParakeetFixtures.waitUntil { await runtime.loadCancellations == 1 })
            // O unload está suspenso esperando a carga moribunda: é exatamente aqui que um
            // prepare novo se intercalava.
            let second = Task { try await engine.prepare(model: .parakeetTDT06BV3) }

            await runtime.openLoadGate()
            await unloading.value
            _ = try? await first.value
            _ = try? await second.value

            var failure: TranscriptionEngineFailure?
            do {
                _ = try await engine.transcribe(
                    ParakeetFixtures.request(),
                    candidate: ParakeetFixtures.candidate()
                )
            } catch let error as TranscriptionEngineFailure {
                failure = error
            }

            switch failure {
            case nil:
                // Disse que estava preparado — e estava mesmo.
                #expect(await runtime.residentModel == .parakeetTDT06BV3)
            case .modelUnavailable:
                // Honesto: não está preparado. O coordenador prepara de novo.
                break
            case .engineInternal(FakeParakeetRuntime.missingWeights):
                Issue.record("motor afirmou estar preparado sobre pesos já descartados")
            case .some(let other):
                Issue.record("falha inesperada: \(other)")
            }
        }
    }

    @Test("Carga e inferência disputam a mesma vaga")
    func loadAndInferenceShareTheSlot() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime)
        try await engine.prepare(model: .parakeetTDT06BV3)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await engine.transcribe(
                    ParakeetFixtures.request(),
                    candidate: ParakeetFixtures.candidate()
                )
            }
            group.addTask { await engine.unload() }
            group.addTask { try await engine.prepare(model: .parakeetTDT06BV3) }
            while (try? await group.next()) != nil {}
        }

        #expect(await runtime.peakConcurrency == 1)
    }

    // MARK: - LoadEvent

    @Test("Os eventos de carga carregam id de geração monotônico")
    func loadEventsCarryGeneration() async throws {
        let log = LoadEventLog()
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime, observer: log.sink)

        try await engine.prepare(model: .parakeetTDT06BV3)
        await engine.unload()
        #expect(await ParakeetFixtures.waitUntil { await log.events.count == 3 })

        let events = await log.events
        #expect(events[0] == .loading(model: .parakeetTDT06BV3, generation: 1))
        #expect(events[1] == .ready(model: .parakeetTDT06BV3, generation: 1))
        #expect(events[2] == .unloaded(generation: 2))
    }

    @Test("Falha de carga vira evento failed com a mesma geração")
    func failedLoadEmitsFailedEvent() async throws {
        let log = LoadEventLog()
        let runtime = FakeParakeetRuntime(loadFailure: .runtime(.modelsUnavailable("sem rede")))
        let engine = ParakeetTranscriptionEngine(runtime: runtime, observer: log.sink)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.prepare(model: .parakeetTDT06BV3)
        }
        #expect(await ParakeetFixtures.waitUntil { await log.events.count == 2 })

        let events = await log.events
        #expect(events[0] == .loading(model: .parakeetTDT06BV3, generation: 1))
        #expect(events[1] == .failed(
            model: .parakeetTDT06BV3,
            failure: .modelUnavailable(.parakeetTDT06BV3),
            generation: 1
        ))
    }

    @Test("Uma carga superada não emite ready — o store não vê o modelo morto ficar pronto")
    func supersededLoadEmitsNoReady() async throws {
        let log = LoadEventLog()
        let runtime = FakeParakeetRuntime(gateLoad: true)
        let engine = ParakeetTranscriptionEngine(runtime: runtime, observer: log.sink)

        let preparing = Task { try await engine.prepare(model: .parakeetTDT06BV3) }
        #expect(await runtime.waitForGatedLoad())
        let unloading = Task { await engine.unload() }
        #expect(await ParakeetFixtures.waitUntil { await runtime.loadCancellations == 1 })
        await runtime.openLoadGate()
        await unloading.value
        _ = try? await preparing.value

        let events = await log.events
        #expect(!events.contains { if case .ready = $0 { return true } else { return false } })
    }

    // MARK: - transcribe

    @Test("transcribe NÃO prepara sozinho: sem pesos, modelUnavailable")
    func transcribeDoesNotAutoPrepare() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        // Carregar 600 MB por trás de uma fila de lotes desfaria a prioridade do coordenador.
        #expect(await runtime.loadCount == 0)
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Candidato com modelo diferente do preparado não é atendido")
    func transcribeRefusesAnotherModel() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate(model: .whisperSmall)
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("O resultado carrega texto, segmento único e proveniência do candidato")
    func resultCarriesTextSegmentAndProvenance() async throws {
        let runtime = FakeParakeetRuntime(
            output: ParakeetRuntimeOutput(
                text: "bom dia",
                confidence: 0.9,
                duration: 1.25,
                processingTime: 0.07
            )
        )
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)
        let candidate = ParakeetFixtures.candidate(origin: .userSelection)

        let result = try await engine.transcribe(
            ParakeetFixtures.request(useCase: .meetingFinal),
            candidate: candidate
        )

        #expect(result.text == "bom dia")
        // Uma utterance só: o Parakeet v3 não segmenta.
        #expect(result.segments.count == 1)
        #expect(result.segments.first?.text == "bom dia")
        #expect(result.segments.first?.start == 0)
        #expect(result.segments.first?.end == 1.25)
        #expect(result.segments.first?.confidence == 0.9)
        #expect(result.processingTime == 0.07)
        #expect(await runtime.lastSampleCount == 32_000)
        #expect(result.provenance == TranscriptionProvenance(
            engine: .parakeet,
            model: .parakeetTDT06BV3,
            useCase: .meetingFinal,
            origin: .userSelection,
            candidateRank: 0
        ))
    }

    @Test("Candidato de fallback marca o rank na proveniência")
    func fallbackCandidateKeepsRank() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(runtime: FakeParakeetRuntime())

        let result = try await engine.transcribe(
            ParakeetFixtures.request(),
            candidate: ParakeetFixtures.candidate(rank: 2)
        )

        #expect(result.provenance.candidateRank == 2)
        #expect(result.provenance.isFallback)
    }

    /// Antes este teste afirmava que pedido automático saía como português.
    ///
    /// Fazia sentido com o modelo base multilíngue: assumir pt era um palpite razoável. Com o
    /// fine-tune pt-BR o palpite virou perigoso — quem fala inglês receberia português fonético
    /// confiante. O adapter agora recusa, e a recusa é o comportamento que este teste guarda.
    @Test("Pedido automático é recusado — o Parakeet não detecta idioma")
    func automaticRequestIsRefused() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: (any Error).self) {
            _ = try await engine.transcribe(
                ParakeetFixtures.request(language: nil),
                candidate: ParakeetFixtures.candidate()
            )
        }
        // E o runtime não chega a ser chamado: a recusa acontece antes da inferência.
        #expect(await runtime.requestedLanguages.isEmpty)
    }

    @Test("Português pedido é repassado ao runtime — o Parakeet não reporta detecção")
    func requestedLanguageIsEchoed() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        let result = try await engine.transcribe(
            ParakeetFixtures.request(language: .portuguese),
            candidate: ParakeetFixtures.candidate()
        )

        #expect(result.detectedLanguage == .portuguese)
        #expect(await runtime.requestedLanguages == [.portuguese])
    }

    /// Inglês deixou de ser aceito quando os pesos viraram o fine-tune pt-BR.
    @Test("Inglês é recusado em vez de sair como português fonético")
    func englishIsRefused() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: (any Error).self) {
            _ = try await engine.transcribe(
                ParakeetFixtures.request(language: .englishUS),
                candidate: ParakeetFixtures.candidate()
            )
        }
        #expect(await runtime.requestedLanguages.isEmpty)
    }

    @Test("O texto sai aparado")
    func textIsTrimmed() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(output: ParakeetRuntimeOutput(text: "  oi \n"))
        )

        let result = try await engine.transcribe(
            ParakeetFixtures.request(),
            candidate: ParakeetFixtures.candidate()
        )

        #expect(result.text == "oi")
        #expect(result.segments.first?.text == "oi")
    }

    @Test("Texto vazio não vira segmento vazio")
    func emptyTextProducesNoSegment() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(output: ParakeetRuntimeOutput(text: "   "))
        )

        let result = try await engine.transcribe(
            ParakeetFixtures.request(),
            candidate: ParakeetFixtures.candidate()
        )

        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }

    @Test("Sem duração reportada, o segmento cobre o áudio pedido")
    func segmentFallsBackToRequestDuration() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(output: ParakeetRuntimeOutput(text: "oi", duration: 0))
        )

        let result = try await engine.transcribe(
            ParakeetFixtures.request(seconds: 3),
            candidate: ParakeetFixtures.candidate()
        )

        #expect(result.segments.first?.end == 3)
    }

    // MARK: - Pedidos recusados antes de gastar a vaga

    @Test("Áudio vazio é inválido e não chega ao runtime")
    func emptyAudioIsRejected() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.invalidAudio("áudio vazio")) {
            try await engine.transcribe(
                ParakeetFixtures.request(seconds: 0),
                candidate: ParakeetFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Áudio fora de 16 kHz é inválido — o serviço assume essa taxa ponta a ponta")
    func wrongSampleRateIsRejected() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.transcribe(
                ParakeetFixtures.request(sampleRate: 48_000),
                candidate: ParakeetFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("Áudio inválido não permite fallback: o próximo motor receberia o mesmo áudio")
    func invalidAudioDoesNotFallBack() {
        #expect(!TranscriptionEngineFailure.invalidAudio("áudio vazio").allowsFallback)
    }

    @Test("Idioma que o motor não fala é recusado")
    func unsupportedLanguageIsRejected() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)
        let french = TranscriptionLanguage("fr-FR")

        await #expect(throws: TranscriptionEngineFailure.languageUnsupported(french)) {
            try await engine.transcribe(
                ParakeetFixtures.request(language: french),
                candidate: ParakeetFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    @Test("A prévia da reunião não é deste motor — ela exige streaming")
    func streamingUseCaseIsRejected() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.self) {
            try await engine.transcribe(
                ParakeetFixtures.request(useCase: .meetingPreview),
                candidate: ParakeetFixtures.candidate()
            )
        }
        #expect(await runtime.transcribeCount == 0)
    }

    // MARK: - Cancelamento

    @Test("Trabalho já cancelado não gasta download nem inferência")
    func cancelledTaskDoesNoWork() async throws {
        let runtime = FakeParakeetRuntime()
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)
        let loadsBefore = await runtime.loadCount

        let task = Task {
            // Cancelado antes de qualquer trabalho: as bordas têm de barrar na entrada.
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate()
            )
        }
        task.cancel()
        await #expect(throws: TranscriptionEngineFailure.cancelled) { _ = try await task.value }

        #expect(await runtime.transcribeCount == 0)
        #expect(await runtime.loadCount == loadsBefore)
    }

    @Test("Cancelamento DURANTE a inferência não vira sucesso, mesmo ela terminando normalmente")
    func cancellationDuringInferenceIsNotDeliveredAsSuccess() async throws {
        let runtime = FakeParakeetRuntime(gateTranscribe: true)
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        let work = Task {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        #expect(await ParakeetFixtures.waitUntil { await runtime.transcribeCount == 1 })

        // `AsrManager.transcribe` não é interrompível por dentro: cancelado no meio, ele termina
        // normalmente assim mesmo. Sem a borda posterior, o motor entregava esse texto como
        // sucesso de um trabalho que alguém mandou parar.
        work.cancel()
        await runtime.openTranscribeGate()

        await #expect(throws: TranscriptionEngineFailure.cancelled) { _ = try await work.value }
    }

    @Test("Trabalho cancelado sai da fila da vaga em vez de segurar a vez")
    func cancelledWorkLeavesTheQueue() async throws {
        let runtime = FakeParakeetRuntime(gateTranscribe: true)
        let engine = try await ParakeetFixtures.preparedEngine(runtime: runtime)

        let holder = Task {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        #expect(await ParakeetFixtures.waitUntil { await runtime.transcribeCount == 1 })

        let queued = Task {
            try await engine.transcribe(ParakeetFixtures.request(), candidate: ParakeetFixtures.candidate())
        }
        await ParakeetFixtures.settle()
        queued.cancel()

        // A prova está em resolver AGORA, com a vaga ainda ocupada e o portão fechado: sem o
        // `withTaskCancellationHandler` este trabalho só voltaria quando chegasse a vez dele.
        //
        // A espera é observada de fora, com prazo, em vez de um `await` direto: assim a regressão
        // vira FALHA em vez de pendurar a suíte — e nada fica bloqueado esperando um `Task.value`
        // que talvez nunca resolva.
        let outcome = ParakeetOutcomeBox()
        let watcher = Task {
            do {
                _ = try await queued.value
                await outcome.record(nil)
            } catch {
                await outcome.record(error)
            }
        }
        var waited = 0
        while await !outcome.resolved && waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }

        #expect(await outcome.resolved, "o trabalho cancelado ficou preso na fila até chegar a vez dele")
        #expect(await outcome.failure == .cancelled)
        // E ele saiu sem nunca ter tocado o runtime.
        #expect(await runtime.transcribeCount == 1)

        await runtime.openTranscribeGate()
        _ = try await holder.value
        _ = await watcher.value
    }

    @Test("Quem espera o single-flight também respeita o próprio cancelamento")
    func singleFlightWaiterRechecksCancellation() async throws {
        let runtime = FakeParakeetRuntime(gateLoad: true)
        let engine = ParakeetTranscriptionEngine(runtime: runtime)

        let first = Task { try await engine.prepare(model: .parakeetTDT06BV3) }
        #expect(await runtime.waitForGatedLoad())
        let waiter = Task { try await engine.prepare(model: .parakeetTDT06BV3) }
        await ParakeetFixtures.settle()
        waiter.cancel()

        await runtime.openLoadGate()
        try await first.value

        await #expect(throws: TranscriptionEngineFailure.cancelled) { try await waiter.value }
        // O cancelamento do aguardante não derruba a carga de quem a iniciou.
        #expect(await runtime.loadCount == 1)
        #expect(await runtime.residentModel == .parakeetTDT06BV3)
    }

    @Test("Cancelamento vindo do runtime vira cancelled e não tenta outro motor")
    func cancellationFromRuntimeIsPreserved() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(transcribeFailure: .runtime(.cancelled))
        )

        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate()
            )
        }
    }

    // MARK: - Tradução de erro

    @Test("Falha de inferência vira engineInternal, que permite fallback")
    func runtimeFailureBecomesEngineInternal() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(
                transcribeFailure: .runtime(.runtimeFailure("joint decision falhou"))
            )
        )

        await #expect(throws: TranscriptionEngineFailure.engineInternal("joint decision falhou")) {
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate()
            )
        }
        #expect(TranscriptionEngineFailure.engineInternal("x").allowsFallback)
    }

    @Test("Runtime que sumiu no meio da inferência vira modelUnavailable")
    func modelsUnavailableDuringTranscribeBecomesModelUnavailable() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(
                transcribeFailure: .runtime(.modelsUnavailable("Parakeet não carregado"))
            )
        )

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate()
            )
        }
    }

    @Test("Modelo que o runtime não sabe carregar vira modelUnavailable")
    func unsupportedModelBecomesModelUnavailable() async throws {
        let engine = ParakeetTranscriptionEngine(
            runtime: FakeParakeetRuntime(loadFailure: .runtime(.unsupportedModel(.parakeetTDT06BV3)))
        )

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try await engine.prepare(model: .parakeetTDT06BV3)
        }
    }

    @Test("Erro de terceiro vira engineInternal com a descrição técnica")
    func foreignErrorBecomesEngineInternal() async throws {
        let engine = try await ParakeetFixtures.preparedEngine(
            runtime: FakeParakeetRuntime(transcribeFailure: .foreign("CoreML compilou errado"))
        )

        await #expect(throws: TranscriptionEngineFailure.engineInternal("CoreML compilou errado")) {
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate()
            )
        }
    }
}
