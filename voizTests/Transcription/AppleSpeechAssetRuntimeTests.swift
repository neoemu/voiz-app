import Testing
import Foundation

// Testes do `AppleSpeechAssetRuntime` — a implementação de **produção** do `AppleSpeechRuntime`, a
// mesma que `AppleSpeechAnalyzerEngine.make()` monta.
//
// Mesmo princípio da T2.2 depois do CRITICO do Farol: o dublê está no lugar do **framework**
// (`AppleSpeechCalls`), abaixo da ponte, então a ordem de chamadas e o `catch` que classifica o
// erro são literalmente os de produção. O que sobra fora do teste é `AppleSpeechAnalyzerCalls`,
// que só encaminha chamada para o `Speech`.
//
// Cada teste aqui trava uma armadilha medida pela sonda da T0.2 (DECISOES, 2026-08-07). Elas não
// são hipóteses: são comportamentos observados do `AssetInventory` nesta versão do macOS.

/// Framework de fala falso, no lugar exato do `Speech`.
///
/// Guarda `reservedLocales` de verdade porque a pergunta mais importante deste arquivo — "o
/// `release()` derrubou a reserva?" — só é respondível com o estado, não com um contador.
actor FakeAppleSpeechCalls: AppleSpeechCalls {
    private let available: Bool
    private let supportedLocales: Set<AppleSpeechLocale>
    private var statuses: [AppleSpeechLocale: AppleSpeechAssetStatus]
    /// Status que o locale assume depois de uma instalação. Deixar em `.supported` simula a
    /// instalação que "deu certo" sem o asset ficar utilizável.
    private let statusAfterInstall: AppleSpeechAssetStatus
    /// A `assetInstallationRequest` veio `nil` (nada a instalar)?
    private let installRequestAvailable: Bool
    private let reserveFailure: (any Error)?
    private let installFailure: (any Error)?
    private let activateFailure: (any Error)?
    private let runFailure: (any Error)?
    private let output: AppleSpeechRuntimeOutput

    /// Reservas vivas. `reserve` devolve `false` quando o locale já está aqui — exatamente como o
    /// `AssetInventory` (armadilha 2 da T0.2).
    private(set) var reservedLocales: Set<AppleSpeechLocale> = []
    /// Ordem das chamadas. É o que prova "reservou ANTES de ler o status", e não só "reservou".
    private(set) var callLog: [String] = []
    private(set) var reserveCount = 0
    private(set) var statusReads = 0
    private(set) var installCount = 0
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var runCount = 0
    private(set) var contexts: [TranscriptionContext] = []

    private var active: AppleSpeechLocale?

    init(
        available: Bool = true,
        supportedLocales: Set<AppleSpeechLocale> = Set(AppleSpeechLocale.allCases),
        statuses: [AppleSpeechLocale: AppleSpeechAssetStatus] = [
            .portugueseBrazil: .installed,
            .englishUS: .installed
        ],
        statusAfterInstall: AppleSpeechAssetStatus = .installed,
        installRequestAvailable: Bool = true,
        preReserved: Set<AppleSpeechLocale> = [],
        reserveFailure: (any Error)? = nil,
        installFailure: (any Error)? = nil,
        activateFailure: (any Error)? = nil,
        runFailure: (any Error)? = nil,
        output: AppleSpeechRuntimeOutput = .init(
            segments: [AppleSpeechTranscriptSegment(text: "bom dia", start: 0, end: 1, confidence: 0.8)],
            processingTime: 0.03
        )
    ) {
        self.available = available
        self.supportedLocales = supportedLocales
        self.statuses = statuses
        self.statusAfterInstall = statusAfterInstall
        self.installRequestAvailable = installRequestAvailable
        self.reservedLocales = preReserved
        self.reserveFailure = reserveFailure
        self.installFailure = installFailure
        self.activateFailure = activateFailure
        self.runFailure = runFailure
        self.output = output
    }

    // MARK: AppleSpeechCalls

    var isAvailable: Bool {
        get async {
            callLog.append("isAvailable")
            return available
        }
    }

    func isSupported(_ locale: AppleSpeechLocale) async -> Bool {
        callLog.append("isSupported")
        return supportedLocales.contains(locale)
    }

    @discardableResult
    func reserve(_ locale: AppleSpeechLocale) async throws -> Bool {
        callLog.append("reserve")
        reserveCount += 1
        if let reserveFailure { throw reserveFailure }
        return reservedLocales.insert(locale).inserted
    }

    var maximumReservedLocales: Int {
        get async {
            callLog.append("maximumReservedLocales")
            return 5
        }
    }

    func status(_ locale: AppleSpeechLocale) async -> AppleSpeechAssetStatus {
        callLog.append("status")
        statusReads += 1
        return statuses[locale] ?? .unsupported
    }

    @discardableResult
    func installAsset(_ locale: AppleSpeechLocale) async throws -> Bool {
        callLog.append("installAsset")
        installCount += 1
        // Espelha a armadilha 4 da T0.2: a própria request reserva.
        reservedLocales.insert(locale)
        if let installFailure { throw installFailure }
        guard installRequestAvailable else { return false }
        statuses[locale] = statusAfterInstall
        return true
    }

    func activateAnalyzer(_ locale: AppleSpeechLocale) async throws {
        callLog.append("activateAnalyzer")
        activateCount += 1
        if let activateFailure { throw activateFailure }
        active = locale
    }

    var activeLocale: AppleSpeechLocale? {
        get async { active }
    }

    func run(
        samples: [Float],
        sampleRate: Double,
        locale: AppleSpeechLocale,
        context: TranscriptionContext = TranscriptionContext()
    ) async throws -> AppleSpeechRuntimeOutput {
        contexts.append(context)
        callLog.append("run")
        runCount += 1
        if let runFailure { throw runFailure }
        return output
    }

    func deactivateAnalyzer() async {
        callLog.append("deactivateAnalyzer")
        deactivateCount += 1
        active = nil
        // Note o que NÃO acontece: nada é removido de `reservedLocales`. Se um dia acontecer, o
        // teste `releaseKeepsTheLocaleReservation` quebra — que é o ponto.
    }
}

/// `failure` guardado como `any Error` exigiria Sendable; estas fábricas evitam isso mantendo o
/// erro concreto na construção.
nonisolated enum AppleSpeechCallErrors {
    static func cancellation() -> any Error { CancellationError() }
    static func urlCancelled() -> any Error {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    }
    static func poolFull() -> any Error {
        AppleSpeechCallFailure.reservationRefused("maximumReservedLocales atingido")
    }
    static func noFormat() -> any Error { AppleSpeechCallFailure.noCompatibleAudioFormat }
    static func notActive() -> any Error { AppleSpeechCallFailure.analyzerNotActive }
    static func foreign(_ message: String) -> any Error {
        NSError(domain: "fake.speech", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@Suite("Ponte de produção do SpeechAnalyzer (AppleSpeechAssetRuntime)")
struct AppleSpeechAssetRuntimeTests {

    // MARK: - Armadilhas do AssetInventory (T0.2)

    @Test("Reserva vem ANTES de ler o status — sem ela, .supported não distingue nada")
    func reserveHappensBeforeReadingStatus() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        try await runtime.load(model: .appleSystemSpeechPTBR)

        let log = await calls.callLog
        let reserve = log.firstIndex(of: "reserve")
        let status = log.firstIndex(of: "status")
        #expect(reserve != nil && status != nil && reserve! < status!)
        // A armadilha 1 da T0.2: sem reserva, o status de um asset já no disco é `.supported`, e o
        // app baixaria de novo o que já tem.
        #expect(await calls.reservedLocales.contains(.portugueseBrazil))
    }

    @Test("reserve devolvendo false (já estava reservado) é sucesso, não falha")
    func alreadyReservedIsSuccess() async throws {
        // Estado real desta máquina depois da sonda da T0.2: pt-BR já reservado.
        let calls = FakeAppleSpeechCalls(preReserved: [.portugueseBrazil])
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        try await runtime.load(model: .appleSystemSpeechPTBR)

        #expect(await calls.reserveCount == 1)
        #expect(await calls.activeLocale == .portugueseBrazil)
    }

    @Test("Asset já instalado NÃO dispara assetInstallationRequest")
    func installedAssetSkipsTheInstallationRequest() async throws {
        let calls = FakeAppleSpeechCalls(statuses: [.portugueseBrazil: .installed])
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        try await runtime.load(model: .appleSystemSpeechPTBR)

        // Armadilha 4 da T0.2: a request reserva implicitamente, então ela não pode ser usada como
        // consulta barata "tem algo para baixar?".
        #expect(await calls.installCount == 0)
        #expect(await calls.statusReads == 1)
    }

    @Test("Asset ausente é instalado e o status é RELIDO para confirmar")
    func missingAssetIsInstalledAndRechecked() async throws {
        let calls = FakeAppleSpeechCalls(
            statuses: [.englishUS: .supported],
            statusAfterInstall: .installed
        )
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        try await runtime.load(model: .appleSystemSpeechENUS)

        #expect(await calls.installCount == 1)
        // Duas leituras: a que decidiu instalar e a que confirmou. Confiar só no retorno da
        // instalação deixaria o motor anunciar um locale que não funciona.
        #expect(await calls.statusReads == 2)
        #expect(await calls.activeLocale == .englishUS)
    }

    @Test("Instalação que não chega a installed falha — recuperável, não silenciosa")
    func installThatDoesNotLandInInstalledFails() async throws {
        let calls = FakeAppleSpeechCalls(
            statuses: [.englishUS: .supported],
            statusAfterInstall: .supported
        )
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.self) {
            try await runtime.load(model: .appleSystemSpeechENUS)
        }
        #expect(await calls.activateCount == 0)
    }

    @Test("Request nil (nada a instalar) com status ainda fora de installed também falha")
    func nilInstallationRequestWithoutInstalledStatusFails() async throws {
        let calls = FakeAppleSpeechCalls(
            statuses: [.englishUS: .supported],
            installRequestAvailable: false
        )
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.self) {
            try await runtime.load(model: .appleSystemSpeechENUS)
        }
        #expect(await calls.activateCount == 0)
    }

    @Test("Cada load remede o status do zero — instalação de asset é revogável")
    func everyLoadRemeasuresTheStatus() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        try await runtime.load(model: .appleSystemSpeechPTBR)
        await runtime.release()
        try await runtime.load(model: .appleSystemSpeechPTBR)

        // Armadilha 5 da T0.2: num processo o locale terminou instalado e num posterior estava
        // ausente. Cachear "já instalado" dentro do runtime seria assumir permanência que a sonda
        // demonstrou não existir.
        #expect(await calls.statusReads == 2)
        #expect(await calls.reserveCount == 2)
    }

    @Test("release solta o analyzer e MANTÉM a reserva do locale")
    func releaseKeepsTheLocaleReservation() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        try await runtime.load(model: .appleSystemSpeechPTBR)

        await runtime.release()

        #expect(await calls.deactivateCount == 1)
        #expect(await calls.activeLocale == nil)
        // A DECISÃO da T3.3: liberar a reserva derrubaria o status de `.installed` para
        // `.supported` com o asset intacto no disco (medido na T0.2), e o próximo `prepare`
        // pareceria um download pendente. O pool tem 5 vagas e o Voiz usa 2.
        #expect(await calls.reservedLocales.contains(.portugueseBrazil))
    }

    // MARK: - Locale indisponível (erro recuperável)

    @Test("SpeechTranscriber indisponível vira localeUnsupported sem tocar na reserva")
    func unavailableTranscriberIsLocaleUnsupported() async throws {
        let calls = FakeAppleSpeechCalls(available: false)
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.localeUnsupported(
            "SpeechTranscriber indisponível nesta build do sistema"
        )) {
            try await runtime.load(model: .appleSystemSpeechPTBR)
        }
        #expect(await calls.reserveCount == 0)
    }

    @Test("Locale que o sistema não fala vira localeUnsupported sem gastar vaga do pool")
    func unsupportedLocaleDoesNotReserve() async throws {
        let calls = FakeAppleSpeechCalls(supportedLocales: [.englishUS])
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.localeUnsupported("pt-BR")) {
            try await runtime.load(model: .appleSystemSpeechPTBR)
        }
        #expect(await calls.reserveCount == 0)
    }

    @Test("Status unsupported depois da reserva também vira localeUnsupported")
    func unsupportedStatusIsLocaleUnsupported() async throws {
        let calls = FakeAppleSpeechCalls(statuses: [.portugueseBrazil: .unsupported])
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.localeUnsupported("pt-BR")) {
            try await runtime.load(model: .appleSystemSpeechPTBR)
        }
        #expect(await calls.installCount == 0)
    }

    @Test("Pool de reservas cheio é caso próprio, com o tamanho do pool na mensagem")
    func refusedReservationIsReservationPoolFull() async throws {
        let calls = FakeAppleSpeechCalls(reserveFailure: AppleSpeechCallErrors.poolFull())
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        var caught: AppleSpeechRuntimeError?
        do {
            try await runtime.load(model: .appleSystemSpeechPTBR)
        } catch let error as AppleSpeechRuntimeError {
            caught = error
        }
        guard case .reservationPoolFull(let description) = caught else {
            Issue.record("esperava reservationPoolFull, veio \(String(describing: caught))")
            return
        }
        // A mensagem tem de dizer o que aconteceu e o tamanho do pool: "recusada" sozinho não
        // deixa ninguém — nem o log, nem a UI da Onda 6 — saber que a saída é liberar um idioma.
        #expect(description.contains("pt-BR"))
        #expect(description.contains("máximo 5"))
        #expect(await calls.statusReads == 0)
    }

    @Test("Pool cheio NUNCA libera a reserva de outro locale para abrir vaga")
    func poolFullNeverReleasesSomebodyElsesReservation() async throws {
        // en-US já reservado (é o outro locale do app, possivelmente de uma sessão viva).
        let calls = FakeAppleSpeechCalls(
            preReserved: [.englishUS],
            reserveFailure: AppleSpeechCallErrors.poolFull()
        )
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.self) {
            try await runtime.load(model: .appleSystemSpeechPTBR)
        }

        // DECISOES T3.3 (c): liberar a reserva alheia derrubaria o `status` daquele locale de
        // `.installed` para `.supported` (medido na T0.2) — o app quebraria o idioma do vizinho
        // para atender este pedido. Falhar de forma recuperável é melhor que "recuperar-se" assim.
        #expect(await calls.reservedLocales == [.englishUS])
    }

    @Test("Pool cheio é recuperável no motor: o coordenador cai para o WhisperKit")
    func poolFullIsRecoverableAtTheEngine() async throws {
        let calls = FakeAppleSpeechCalls(reserveFailure: AppleSpeechCallErrors.poolFull())
        let engine = AppleSpeechAnalyzerEngine(runtime: AppleSpeechAssetRuntime(calls: calls))

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR)) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
        #expect(TranscriptionEngineFailure.modelUnavailable(.appleSystemSpeechPTBR).allowsFallback)
    }

    // MARK: - Coleta com prazo (a vaga única do motor está na mão)

    @Test("Coletor que fecha dentro do prazo devolve os segmentos")
    func collectionWithinDeadlinePassesThrough() async throws {
        let expected = [AppleSpeechTranscriptSegment(text: "oi", start: 0, end: 1)]
        let collector = Task<[AppleSpeechTranscriptSegment], any Error> { expected }

        // Teto só deste teste. O coletor devolve na hora; o que disputa o pool é o
        // filho do TaskGroup que lê `collector.value`. Com 5 s rígidos, máquina
        // carregada deixa o dorminhoco ganhar (suíte 63 s → collectionTimedOut(5.0)).
        // Produção continua em deadline(forAudioSeconds:) = max(10, s*4) — intocada.
        // O teto segue finito: collect() que nunca devolve o coletor ainda estoura.
        // O irmão collectionThatNeverEndsTimesOut prova o outro lado.
        let segments = try await AppleSpeechBatchCollection.collect(collector, timeout: 60)

        #expect(segments == expected)
        // Caminho do prazo cancela o coletor. Se os segmentos vieram e ele segue
        // vivo, o dorminhoco não ganhou — é o que este teste afirma, sem relógio.
        #expect(!collector.isCancelled)
    }

    @Test("Coletor que nunca fecha estoura o prazo em vez de prender o motor para sempre")
    func collectionThatNeverEndsTimesOut() async throws {
        // O cenário real: a sequência de resultados do transcritor não termina depois do
        // `finalize`. Esta espera roda COM A VAGA na mão, então sem prazo o motor inteiro — e o
        // `unload`, que toma a vaga de forma não-cancelável — ficaria preso para sempre.
        let collector = Task<[AppleSpeechTranscriptSegment], any Error> {
            for _ in 0..<10_000 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { throw CancellationError() }
            }
            return []
        }

        await #expect(throws: AppleSpeechCallFailure.collectionTimedOut(0.2)) {
            _ = try await AppleSpeechBatchCollection.collect(collector, timeout: 0.2)
        }
        // E o coletor não fica vivo segurando a sequência: ele é Task não estruturada, então o
        // cancelamento tem de ser explícito.
        #expect(collector.isCancelled)
    }

    @Test("Prazo estourado permite fallback — o lote é bom, quem não respondeu foi este motor")
    func collectionTimeoutIsRecoverable() async throws {
        let failure = AppleSpeechAssetRuntime.failure(from: AppleSpeechCallFailure.collectionTimedOut(12))

        guard case .runtimeFailure(let description) = failure else {
            Issue.record("esperava runtimeFailure, veio \(failure)")
            return
        }
        #expect(description.contains("12"))
        // `runtimeFailure` → `engineInternal`, cujo allowsFallback é verdadeiro.
        #expect(TranscriptionEngineFailure.engineInternal(description).allowsFallback)
    }

    @Test("Cancelamento de quem chamou alcança o coletor não estruturado")
    func cancellingTheCallerCancelsTheCollector() async throws {
        let collector = Task<[AppleSpeechTranscriptSegment], any Error> {
            for _ in 0..<10_000 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { throw CancellationError() }
            }
            return []
        }

        let waiting = Task {
            _ = try await AppleSpeechBatchCollection.collect(collector, timeout: 30)
        }
        // Deixa a espera entrar no grupo antes de cancelar.
        for _ in 0..<200 { await Task.yield() }
        waiting.cancel()
        _ = try? await waiting.value

        #expect(await AppleSpeechFixtures.waitUntil { collector.isCancelled })
    }

    @Test("O prazo é proporcional ao áudio, com piso para lotes curtos")
    func deadlineScalesWithAudio() {
        // Folgado de propósito: a fumaça mediu RTFx entre 60x e 130x, então 4x tempo real é ~250
        // vezes o normal — dispara só se a sequência não fechar, nunca por máquina lenta.
        #expect(AppleSpeechBatchCollection.deadline(forAudioSeconds: 0) == 10)
        #expect(AppleSpeechBatchCollection.deadline(forAudioSeconds: 1) == 10)
        #expect(AppleSpeechBatchCollection.deadline(forAudioSeconds: 30) == 120)
        #expect(AppleSpeechBatchCollection.deadline(forAudioSeconds: 8.77) > 30)
    }

    // MARK: - Cancelamento

    @Test("Cancelamento durante a carga vira cancelled, não asset quebrado")
    func cancellationDuringLoadIsDetected() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        let task = Task { () -> AppleSpeechRuntimeError? in
            do {
                try await runtime.load(model: .appleSystemSpeechPTBR)
                return nil
            } catch let error as AppleSpeechRuntimeError {
                return error
            }
        }
        task.cancel()

        #expect(await task.value == .cancelled)
    }

    @Test("Download abortado vira cancelled — senão o modelo entraria no cache negativo")
    func cancelledDownloadIsNotAssetFailure() async throws {
        let calls = FakeAppleSpeechCalls(
            statuses: [.englishUS: .supported],
            installFailure: AppleSpeechCallErrors.cancellation()
        )
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.cancelled) {
            try await runtime.load(model: .appleSystemSpeechENUS)
        }
    }

    @Test("Download cancelado pela URLSession também conta como cancelamento")
    func urlCancellationIsCancellation() async throws {
        let calls = FakeAppleSpeechCalls(
            statuses: [.englishUS: .supported],
            installFailure: AppleSpeechCallErrors.urlCancelled()
        )
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.cancelled) {
            try await runtime.load(model: .appleSystemSpeechENUS)
        }
    }

    // MARK: - Modelo

    @Test("Modelo que não é deste motor é recusado antes de tocar no framework")
    func unknownModelIsRefused() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.unsupportedModel(.whisperSmall)) {
            try await runtime.load(model: .whisperSmall)
        }
        await #expect(throws: AppleSpeechRuntimeError.unsupportedModel(.whisperSmall)) {
            _ = try await runtime.transcribe(samples: [0], sampleRate: 16_000, model: .whisperSmall)
        }
        #expect(await calls.callLog.isEmpty)
    }

    // MARK: - Análise

    @Test("Sem analyzer ativo, o runtime recusa em vez de reservar e baixar sozinho")
    func transcribeRequiresAnActiveAnalyzer() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.assetUnavailable(
            "analyzer de pt-BR não está ativo"
        )) {
            _ = try await runtime.transcribe(
                samples: [0],
                sampleRate: 16_000,
                model: .appleSystemSpeechPTBR
            )
        }
        #expect(await calls.runCount == 0)
        #expect(await calls.reserveCount == 0)
    }

    @Test("Depois de release, transcrever volta a ser erro visível — não reativação silenciosa")
    func transcribeAfterReleaseIsAVisibleError() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        try await runtime.load(model: .appleSystemSpeechPTBR)
        _ = try await runtime.transcribe(samples: [0], sampleRate: 16_000, model: .appleSystemSpeechPTBR)
        await runtime.release()

        await #expect(throws: AppleSpeechRuntimeError.self) {
            _ = try await runtime.transcribe(
                samples: [0],
                sampleRate: 16_000,
                model: .appleSystemSpeechPTBR
            )
        }
        #expect(await calls.runCount == 1)
    }

    @Test("Analyzer de outro locale não atende o pedido")
    func analyzerOfAnotherLocaleIsRefused() async throws {
        let calls = FakeAppleSpeechCalls()
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        try await runtime.load(model: .appleSystemSpeechPTBR)

        await #expect(throws: AppleSpeechRuntimeError.self) {
            _ = try await runtime.transcribe(
                samples: [0],
                sampleRate: 16_000,
                model: .appleSystemSpeechENUS
            )
        }
        #expect(await calls.runCount == 0)
    }

    @Test("O resultado do framework chega inteiro ao motor")
    func outputIsForwarded() async throws {
        let expected = AppleSpeechRuntimeOutput(
            segments: [
                AppleSpeechTranscriptSegment(text: "bom dia", start: 0, end: 1.2, confidence: 0.91)
            ],
            processingTime: 0.42
        )
        let calls = FakeAppleSpeechCalls(output: expected)
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        try await runtime.load(model: .appleSystemSpeechPTBR)

        let output = try await runtime.transcribe(
            samples: [0, 0],
            sampleRate: 16_000,
            model: .appleSystemSpeechPTBR
        )

        #expect(output == expected)
    }

    @Test("Formato incompatível vira audioFormatUnsupported")
    func noCompatibleFormatIsAudioFormatUnsupported() async throws {
        let calls = FakeAppleSpeechCalls(runFailure: AppleSpeechCallErrors.noFormat())
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        try await runtime.load(model: .appleSystemSpeechPTBR)

        await #expect(throws: AppleSpeechRuntimeError.audioFormatUnsupported(
            "o transcritor não oferece formato compatível com 16 kHz mono"
        )) {
            _ = try await runtime.transcribe(
                samples: [0],
                sampleRate: 16_000,
                model: .appleSystemSpeechPTBR
            )
        }
    }

    @Test("Aquecimento sem formato compatível já falha no load")
    func activationWithoutCompatibleFormatFailsTheLoad() async throws {
        let calls = FakeAppleSpeechCalls(activateFailure: AppleSpeechCallErrors.noFormat())
        let runtime = AppleSpeechAssetRuntime(calls: calls)

        await #expect(throws: AppleSpeechRuntimeError.audioFormatUnsupported(
            "o transcritor não oferece formato compatível com 16 kHz mono"
        )) {
            try await runtime.load(model: .appleSystemSpeechPTBR)
        }
    }

    @Test("Framework recusando por analyzer inativo vira assetUnavailable")
    func analyzerNotActiveBecomesAssetUnavailable() async throws {
        let calls = FakeAppleSpeechCalls(runFailure: AppleSpeechCallErrors.notActive())
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        try await runtime.load(model: .appleSystemSpeechPTBR)

        await #expect(throws: AppleSpeechRuntimeError.assetUnavailable("analyzer não está ativo")) {
            _ = try await runtime.transcribe(
                samples: [0],
                sampleRate: 16_000,
                model: .appleSystemSpeechPTBR
            )
        }
    }

    @Test("Erro de terceiro na análise vira runtimeFailure com a descrição técnica")
    func foreignErrorBecomesRuntimeFailure() async throws {
        let calls = FakeAppleSpeechCalls(runFailure: AppleSpeechCallErrors.foreign("analyzer abortou"))
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        try await runtime.load(model: .appleSystemSpeechPTBR)

        await #expect(throws: AppleSpeechRuntimeError.runtimeFailure("analyzer abortou")) {
            _ = try await runtime.transcribe(
                samples: [0],
                sampleRate: 16_000,
                model: .appleSystemSpeechPTBR
            )
        }
    }

    // MARK: - Motor de produção montado por baixo

    @Test("Locale indisponível pelo caminho real permite fallback no motor")
    func realBridgeReportsRecoverableFailure() async throws {
        // Ponte de produção montada por baixo do motor de produção: nada injetado no meio.
        let calls = FakeAppleSpeechCalls(supportedLocales: [])
        let engine = AppleSpeechAnalyzerEngine(runtime: AppleSpeechAssetRuntime(calls: calls))

        await #expect(throws: TranscriptionEngineFailure.languageUnsupported(.portugueseBrazil)) {
            try await engine.prepare(model: .appleSystemSpeechPTBR)
        }
        // O requisito da T3.3: sem locale, o coordenador tem de poder tentar o próximo candidato.
        #expect(TranscriptionEngineFailure.languageUnsupported(.portugueseBrazil).allowsFallback)
    }

    @Test("Caminho feliz pelo caminho real: prepara, transcreve e devolve proveniência")
    func realBridgeHappyPath() async throws {
        let calls = FakeAppleSpeechCalls()
        let engine = AppleSpeechAnalyzerEngine(runtime: AppleSpeechAssetRuntime(calls: calls))

        try await engine.prepare(model: .appleSystemSpeechPTBR)
        let result = try await engine.transcribe(
            AppleSpeechFixtures.request(),
            candidate: AppleSpeechFixtures.candidate()
        )

        #expect(result.text == "bom dia")
        #expect(result.detectedLanguage == .portugueseBrazil)
        #expect(result.provenance.engine == .appleSpeechAnalyzer)
        #expect(result.provenance.model == .appleSystemSpeechPTBR)

        await engine.unload()
        // E o unload real, ponta a ponta, continua sem derrubar a reserva.
        #expect(await calls.deactivateCount == 1)
        #expect(await calls.reservedLocales.contains(.portugueseBrazil))
    }
}
