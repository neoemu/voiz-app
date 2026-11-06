import Foundation

// Dublês para os testes dos contratos da T1.2.
//
// Os motores reais só nascem na Onda 2, então tudo aqui é falso de propósito: motores que não
// carregam pesos, catálogos que descrevem hardware que não temos na mesa (o Intel simulado) e
// uma sessão de streaming que emite eventos combinados. O que está sendo testado é o contrato,
// não o reconhecimento de fala.

// MARK: - Perfis de hardware

nonisolated extension TranscriptionHardwareProfile {
    /// Mac Apple Silicon com folga de memória — o caso normal.
    static let appleSilicon16GB = TranscriptionHardwareProfile(
        architecture: .appleSilicon,
        hasNeuralEngine: true,
        physicalMemoryBytes: 16 * 1024 * 1024 * 1024
    )

    /// Intel simulado: sem Neural Engine. É o cenário que o plano exige cobrir sem ter um
    /// Intel disponível — nele nenhum modelo CoreML pesado pode ser oferecido.
    static let intel8GB = TranscriptionHardwareProfile(
        architecture: .intel,
        hasNeuralEngine: false,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024
    )

    /// Apple Silicon apertado de memória (4 GB), para testar o mínimo dos modelos pesados.
    static let appleSilicon4GB = TranscriptionHardwareProfile(
        architecture: .appleSilicon,
        hasNeuralEngine: true,
        physicalMemoryBytes: 4 * 1024 * 1024 * 1024
    )
}

// MARK: - Ids falsos

nonisolated extension TranscriptionEngineID {
    static let fakeAlpha = TranscriptionEngineID("fake-alpha")
    static let fakeBravo = TranscriptionEngineID("fake-bravo")
    static let fakeCharlie = TranscriptionEngineID("fake-charlie")
}

nonisolated extension TranscriptionModelID {
    static let fakeLight = TranscriptionModelID("fake-light")
    static let fakeHeavy = TranscriptionModelID("fake-heavy")
    static let fakePtOnly = TranscriptionModelID("fake-pt-only")
}

// MARK: - Fábricas de descritor

nonisolated enum TranscriptionFixtures {
    /// Descritor mínimo e permissivo; cada teste sobrescreve só o que lhe interessa.
    static func engine(
        _ id: TranscriptionEngineID,
        languages: [TranscriptionLanguage] = [.portuguese, .english],
        detectsLanguage: Bool = true,
        useCases: Set<TranscriptionUseCase> = Set(TranscriptionUseCase.allCases),
        batch: Bool = true,
        streaming: Bool = true,
        hardware: TranscriptionHardwareRequirement = .none,
        models: [TranscriptionModelDescriptor]? = nil,
        defaultModel: TranscriptionModelID? = nil,
        priority: Int = 0,
        priorityOverrides: [TranscriptionUseCase: Int] = [:],
        experimental: Bool = false
    ) -> TranscriptionEngineDescriptor {
        TranscriptionEngineDescriptor(
            engine: id,
            productName: id.rawValue,
            supportedLanguages: languages,
            detectsLanguageAutomatically: detectsLanguage,
            supportedUseCases: useCases,
            supportsBatch: batch,
            supportsStreaming: streaming,
            hardware: hardware,
            models: models ?? [model(.fakeLight, engine: id)],
            defaultModel: defaultModel,
            automaticPriority: priority,
            automaticPriorityOverrides: priorityOverrides,
            isExperimental: experimental
        )
    }

    static func model(
        _ id: TranscriptionModelID,
        engine: TranscriptionEngineID,
        languages: [TranscriptionLanguage] = [],
        weight: TranscriptionModelWeight = .light,
        downloadBytes: Int64 = 1024,
        hardware: TranscriptionHardwareRequirement = .none
    ) -> TranscriptionModelDescriptor {
        TranscriptionModelDescriptor(
            id: id,
            engine: engine,
            productName: id.rawValue,
            languages: languages,
            weight: weight,
            downloadBytes: downloadBytes,
            hardware: hardware
        )
    }

    /// Contexto padrão: Apple Silicon, ditado em pt-BR, modo automático.
    static func context(
        useCase: TranscriptionUseCase = .dictation,
        language: TranscriptionLanguage? = .portugueseBrazil,
        hardware: TranscriptionHardwareProfile = .appleSilicon16GB,
        selection: TranscriptionUserSelection = .automatic
    ) -> TranscriptionRoutingContext {
        TranscriptionRoutingContext(
            useCase: useCase,
            language: language,
            hardware: hardware,
            selection: selection
        )
    }

    /// Um segundo de silêncio a 16 kHz — só para os pedidos terem áudio de verdade.
    static func audio(seconds: Double = 1.0) -> TranscriptionAudio {
        TranscriptionAudio(samples: [Float](repeating: 0, count: Int(seconds * 16_000)))
    }
}

// MARK: - Motores falsos

/// Motor em lote que devolve um texto fixo — ou falha, quando o teste pede.
///
/// É `actor` porque `TranscriptionEngine` é `Sendable` e o motor guarda o que foi chamado: o
/// contrato precisa provar que dá para implementá-lo com estado sem `@unchecked Sendable`.
actor FakeBatchEngine: BatchTranscriptionEngine {
    nonisolated let descriptor: TranscriptionEngineDescriptor

    private let transcript: String
    private let prepareFailure: TranscriptionEngineFailure?
    private let transcribeFailure: TranscriptionEngineFailure?

    private(set) var preparedModels: [TranscriptionModelID] = []
    private(set) var unloadCount = 0
    private(set) var transcribedCandidates: [TranscriptionRoutingCandidate] = []

    init(
        descriptor: TranscriptionEngineDescriptor,
        transcript: String = "texto de teste",
        prepareFailure: TranscriptionEngineFailure? = nil,
        transcribeFailure: TranscriptionEngineFailure? = nil
    ) {
        self.descriptor = descriptor
        self.transcript = transcript
        self.prepareFailure = prepareFailure
        self.transcribeFailure = transcribeFailure
    }

    func prepare(model: TranscriptionModelID) async throws {
        if let prepareFailure { throw prepareFailure }
        // Idempotente na prática: registrar duas vezes o mesmo modelo é o que o teste verifica.
        preparedModels.append(model)
    }

    func unload() async {
        unloadCount += 1
    }

    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult {
        if let transcribeFailure { throw transcribeFailure }
        transcribedCandidates.append(candidate)
        return TranscriptionEngineResult(
            text: transcript,
            segments: [
                TranscriptionTextSegment(
                    text: transcript,
                    start: 0,
                    end: request.audio.duration,
                    confidence: 0.9
                )
            ],
            detectedLanguage: request.language ?? .portugueseBrazil,
            provenance: TranscriptionProvenance(candidate: candidate, useCase: request.useCase),
            processingTime: 0.01
        )
    }
}

/// Motor de streaming falso: abre sessões `FakeTranscriptionStream`.
actor FakeStreamingEngine: StreamingTranscriptionEngine {
    nonisolated let descriptor: TranscriptionEngineDescriptor

    private let startFailure: TranscriptionEngineFailure?
    private(set) var preparedModels: [TranscriptionModelID] = []
    private(set) var unloadCount = 0

    init(descriptor: TranscriptionEngineDescriptor, startFailure: TranscriptionEngineFailure? = nil) {
        self.descriptor = descriptor
        self.startFailure = startFailure
    }

    func prepare(model: TranscriptionModelID) async throws {
        preparedModels.append(model)
    }

    func unload() async {
        unloadCount += 1
    }

    func startStream(
        _ request: TranscriptionStreamRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> any TranscriptionStream {
        if let startFailure { throw startFailure }
        return FakeTranscriptionStream(
            provenance: TranscriptionProvenance(candidate: candidate, useCase: request.useCase)
        )
    }
}

/// Sessão de streaming falsa: cada `append` vira um `partial`; `finish` promove o último
/// `partial` a `final` e encerra o stream.
actor FakeTranscriptionStream: TranscriptionStream {
    nonisolated let provenance: TranscriptionProvenance
    nonisolated let events: AsyncThrowingStream<TranscriptionStreamEvent, any Error>

    private let continuation: AsyncThrowingStream<TranscriptionStreamEvent, any Error>.Continuation
    private var elapsed: TimeInterval = 0
    private var lastPartial: TranscriptionTextSegment?

    init(provenance: TranscriptionProvenance) {
        self.provenance = provenance
        let (stream, continuation) = AsyncThrowingStream<TranscriptionStreamEvent, any Error>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    func append(_ audio: TranscriptionAudio) async throws {
        let start = elapsed
        elapsed += audio.duration
        let segment = TranscriptionTextSegment(text: "parcial \(start)", start: start, end: elapsed)
        lastPartial = segment
        continuation.yield(.partial(segment))
    }

    func finish() async {
        if let lastPartial {
            continuation.yield(.final(lastPartial))
        }
        continuation.finish()
    }

    func cancel() async {
        lastPartial = nil
        continuation.finish()
    }
}
