import Testing
import Foundation

// Testes do `ParakeetServiceRuntime` — a implementação de **produção** do `ParakeetRuntime`, a
// mesma que `ParakeetTranscriptionEngine.make(service:)` monta.
//
// Isto é a resposta ao CRITICO do Farol: na primeira rodada o cancelamento era testado injetando
// o erro *depois* da ponte, provando um caminho que a montagem real não percorre. Aqui o dublê
// está no lugar do **serviço** (`ParakeetServiceCalls`), abaixo da ponte, então o `catch` que
// classifica o erro é literalmente o de produção. O que sobra fora do teste é
// `ParakeetTranscriptionServiceCalls`, que só encaminha chamada e copia campo.

/// Serviço Parakeet falso, no lugar exato do `ParakeetTranscriptionService`.
actor FakeParakeetServiceCalls: ParakeetServiceCalls {
    private let loadsSuccessfully: Bool
    private let failure: (any Error)?
    private let output: ParakeetRuntimeOutput

    private(set) var ensureLoadedCount = 0
    private(set) var runCount = 0
    private(set) var releaseCount = 0
    private(set) var requestedLanguages: [ParakeetRequestedLanguage] = []

    private var loaded = false
    private var storedError: String?

    init(
        loadsSuccessfully: Bool = true,
        loadErrorDescription: String? = nil,
        failure: (any Error)? = nil,
        output: ParakeetRuntimeOutput = .init(text: "texto", confidence: 0.5, duration: 1, processingTime: 0.02)
    ) {
        self.loadsSuccessfully = loadsSuccessfully
        self.storedError = loadErrorDescription
        self.failure = failure
        self.output = output
    }

    func ensureLoaded() async {
        ensureLoadedCount += 1
        // Espelha o serviço real: a falha de carga NÃO lança, vira `error` + `isInitialized` falso.
        loaded = loadsSuccessfully
    }

    var isLoaded: Bool { loaded }

    var loadErrorDescription: String? { storedError }

    func run(
        samples: [Float],
        language: ParakeetRequestedLanguage
    ) async throws -> ParakeetRuntimeOutput {
        runCount += 1
        requestedLanguages.append(language)
        if let failure { throw failure }
        return output
    }

    func releaseModels() async {
        releaseCount += 1
        loaded = false
    }
}

/// `failure` guardado como `any Error` exigiria Sendable; estas fábricas evitam isso mantendo o
/// erro concreto na construção.
nonisolated enum ParakeetCallFailures {
    static func cancellation() -> any Error { CancellationError() }
    static func notLoaded() -> any Error { ParakeetServiceCallFailure.notLoaded }
    static func foreign(_ message: String) -> any Error {
        NSError(domain: "fake.fluidaudio", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@Suite("Ponte de produção do Parakeet (ParakeetServiceRuntime)")
struct ParakeetServiceRuntimeTests {

    // MARK: - Cancelamento (CRITICO da review do Farol)

    @Test("CancellationError do serviço vira cancelled, não runtimeFailure")
    func cancellationErrorIsNotSwallowedByTheGenericCatch() async throws {
        let calls = FakeParakeetServiceCalls(failure: ParakeetCallFailures.cancellation())
        let runtime = ParakeetServiceRuntime(calls: calls)
        try await runtime.load(model: .parakeetTDT06BV3)

        await #expect(throws: ParakeetRuntimeError.cancelled) {
            _ = try await runtime.transcribe(
                samples: [0, 0, 0],
                language: .portugueseBrazil,
                model: .parakeetTDT06BV3
            )
        }
    }

    @Test("Cancelamento não permite fallback depois de traduzido pelo motor")
    func cancellationFromTheRealBridgeDoesNotFallBack() async throws {
        // Ponte de produção montada por baixo do motor de produção: nada injetado no meio.
        let calls = FakeParakeetServiceCalls(failure: ParakeetCallFailures.cancellation())
        let engine = ParakeetTranscriptionEngine(runtime: ParakeetServiceRuntime(calls: calls))
        try await engine.prepare(model: .parakeetTDT06BV3)

        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await engine.transcribe(
                ParakeetFixtures.request(),
                candidate: ParakeetFixtures.candidate()
            )
        }
        // O que o achado do Farol dizia: se virar engineInternal, `allowsFallback` é verdadeiro e
        // o coordenador refaz noutro motor um trabalho que alguém mandou parar.
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)
    }

    @Test("Erro qualquer dentro de uma tarefa cancelada também conta como cancelamento")
    func errorInsideCancelledTaskCountsAsCancellation() async throws {
        let calls = FakeParakeetServiceCalls(failure: ParakeetCallFailures.foreign("ANE ocupada"))
        let runtime = ParakeetServiceRuntime(calls: calls)
        try await runtime.load(model: .parakeetTDT06BV3)

        // O erro que sai de uma inferência abortada nem sempre é `CancellationError`: é a
        // consequência dele. Se a tarefa está cancelada, a leitura correta é cancelamento.
        let task = Task { () -> ParakeetRuntimeError? in
            do {
                _ = try await runtime.transcribe(
                    samples: [0, 0, 0],
                    language: nil,
                    model: .parakeetTDT06BV3
                )
                return nil
            } catch let error as ParakeetRuntimeError {
                return error
            }
        }
        task.cancel()

        #expect(await task.value == .cancelled)
    }

    @Test("Cancelamento durante a carga é detectado, mesmo com o serviço engolindo erros")
    func cancellationDuringLoadIsDetected() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)

        let task = Task { () -> ParakeetRuntimeError? in
            do {
                try await runtime.load(model: .parakeetTDT06BV3)
                return nil
            } catch let error as ParakeetRuntimeError {
                return error
            }
        }
        task.cancel()

        #expect(await task.value == .cancelled)
    }

    // MARK: - Carga

    @Test("Falha de carga do serviço vira modelsUnavailable com a descrição técnica")
    func swallowedLoadErrorBecomesModelsUnavailable() async throws {
        let calls = FakeParakeetServiceCalls(
            loadsSuccessfully: false,
            loadErrorDescription: "Falha ao carregar Parakeet: sem espaço"
        )
        let runtime = ParakeetServiceRuntime(calls: calls)

        await #expect(throws: ParakeetRuntimeError.modelsUnavailable("Falha ao carregar Parakeet: sem espaço")) {
            try await runtime.load(model: .parakeetTDT06BV3)
        }
        #expect(await calls.ensureLoadedCount == 1)
    }

    @Test("Carga bem-sucedida não lança e pede a inicialização uma vez")
    func successfulLoad() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)

        try await runtime.load(model: .parakeetTDT06BV3)

        #expect(await calls.ensureLoadedCount == 1)
    }

    @Test("Modelo que o runtime não sabe carregar é recusado antes de tocar no serviço")
    func unknownModelIsRefused() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)
        // O TAGARELA CoreML entra neste mesmo runtime na Onda 5. Enquanto ele não for carregável,
        // pedir por ele não pode carregar o v3 em silêncio — a proveniência gravada mentiria
        // sobre qual modelo produziu o texto, que é o dado do gate de benchmark.
        let tagarela = TranscriptionModelID("parakeet-tdt-0.6b-v3-ptBR-tagarela")

        await #expect(throws: ParakeetRuntimeError.unsupportedModel(tagarela)) {
            try await runtime.load(model: tagarela)
        }
        await #expect(throws: ParakeetRuntimeError.unsupportedModel(tagarela)) {
            _ = try await runtime.transcribe(samples: [0], language: nil, model: tagarela)
        }
        #expect(await calls.ensureLoadedCount == 0)
        #expect(await calls.runCount == 0)
    }

    @Test("O id suportado é configurável — é assim que a Onda 5 acrescenta o TAGARELA")
    func supportedModelIsConfigurable() async throws {
        let tagarela = TranscriptionModelID("parakeet-tdt-0.6b-v3-ptBR-tagarela")
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls, supportedModel: tagarela)

        try await runtime.load(model: tagarela)
        await #expect(throws: ParakeetRuntimeError.unsupportedModel(.parakeetTDT06BV3)) {
            try await runtime.load(model: .parakeetTDT06BV3)
        }
    }

    // MARK: - Inferência

    @Test("O resultado do serviço chega inteiro ao motor")
    func outputIsForwarded() async throws {
        let calls = FakeParakeetServiceCalls(
            output: ParakeetRuntimeOutput(text: "bom dia", confidence: 0.77, duration: 2, processingTime: 0.3)
        )
        let runtime = ParakeetServiceRuntime(calls: calls)
        try await runtime.load(model: .parakeetTDT06BV3)

        let output = try await runtime.transcribe(
            samples: [0, 0],
            language: .portugueseBrazil,
            model: .parakeetTDT06BV3
        )

        #expect(output == ParakeetRuntimeOutput(text: "bom dia", confidence: 0.77, duration: 2, processingTime: 0.3))
    }

    @Test("Sem pesos carregados, o runtime recusa em vez de deixar o serviço recarregar sozinho")
    func transcribeRequiresLoadedWeights() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)

        // Nunca carregado: o item 3 do contrato ("transcribe não auto-prepara") tem de valer aqui
        // também, senão o `ensureInitialized()` do serviço legado recarrega 600 MB em silêncio.
        await #expect(throws: ParakeetRuntimeError.modelsUnavailable("Parakeet não carregado")) {
            _ = try await runtime.transcribe(samples: [0], language: nil, model: .parakeetTDT06BV3)
        }
        #expect(await calls.runCount == 0)
        #expect(await calls.ensureLoadedCount == 0)
    }

    @Test("Depois de release, transcrever volta a ser erro visível — não recarga silenciosa")
    func transcribeAfterReleaseIsAVisibleError() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)

        try await runtime.load(model: .parakeetTDT06BV3)
        _ = try await runtime.transcribe(samples: [0], language: nil, model: .parakeetTDT06BV3)
        await runtime.release()

        await #expect(throws: ParakeetRuntimeError.modelsUnavailable("Parakeet não carregado")) {
            _ = try await runtime.transcribe(samples: [0], language: nil, model: .parakeetTDT06BV3)
        }
        #expect(await calls.runCount == 1)
    }

    @Test("O serviço recusando por não estar carregado vira modelsUnavailable")
    func notLoadedBecomesModelsUnavailable() async throws {
        let calls = FakeParakeetServiceCalls(failure: ParakeetCallFailures.notLoaded())
        let runtime = ParakeetServiceRuntime(calls: calls)
        try await runtime.load(model: .parakeetTDT06BV3)

        await #expect(throws: ParakeetRuntimeError.modelsUnavailable("Parakeet não carregado")) {
            _ = try await runtime.transcribe(samples: [0], language: nil, model: .parakeetTDT06BV3)
        }
    }

    @Test("Erro de terceiro vira runtimeFailure com a descrição técnica")
    func foreignErrorBecomesRuntimeFailure() async throws {
        let calls = FakeParakeetServiceCalls(failure: ParakeetCallFailures.foreign("encoder falhou"))
        let runtime = ParakeetServiceRuntime(calls: calls)
        try await runtime.load(model: .parakeetTDT06BV3)

        await #expect(throws: ParakeetRuntimeError.runtimeFailure("encoder falhou")) {
            _ = try await runtime.transcribe(samples: [0], language: nil, model: .parakeetTDT06BV3)
        }
    }

    @Test("release delega a descarga real ao serviço")
    func releaseDelegates() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)

        await runtime.release()

        #expect(await calls.releaseCount == 1)
    }

    // MARK: - Idioma

    @Test("O idioma pedido vira o que o serviço entende, e nil vira automático")
    func languageMapping() {
        #expect(ParakeetRequestedLanguage(nil) == .automatic)
        #expect(ParakeetRequestedLanguage(.portugueseBrazil) == .portuguese)
        #expect(ParakeetRequestedLanguage(.portuguese) == .portuguese)
        #expect(ParakeetRequestedLanguage(.englishUS) == .english)
        #expect(ParakeetRequestedLanguage(.english) == .english)
        // Inalcançável pelo motor (o descritor barra antes); num multilíngue, deixar detectar é
        // melhor do que rotular errado.
        #expect(ParakeetRequestedLanguage(TranscriptionLanguage("fr-FR")) == .automatic)
    }

    @Test("O idioma chega ao serviço traduzido")
    func languageReachesTheService() async throws {
        let calls = FakeParakeetServiceCalls()
        let runtime = ParakeetServiceRuntime(calls: calls)
        try await runtime.load(model: .parakeetTDT06BV3)

        _ = try await runtime.transcribe(samples: [0], language: .englishUS, model: .parakeetTDT06BV3)
        _ = try await runtime.transcribe(samples: [0], language: nil, model: .parakeetTDT06BV3)

        #expect(await calls.requestedLanguages == [.english, .automatic])
    }
}
