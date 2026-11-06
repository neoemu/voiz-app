import Foundation

// A implementação de produção do `ParakeetRuntime`, sobre o `ParakeetTranscriptionService`.
//
// Este arquivo também depende **só de Foundation** — e é de propósito. O CRITICO do Farol na
// primeira rodada foi que a semântica de cancelamento testada não era a da ponte de produção: o
// teste injetava o cancelamento *depois* dela. A correção não é só arrumar o `catch`, é fazer o
// `catch` de produção ser testável. Por isso a fronteira "precisa de FluidAudio" desceu um nível:
// `ParakeetServiceCalls` descreve as chamadas cruas do serviço, e a única coisa que sobra fora
// dos testes é `ParakeetTranscriptionServiceCalls`, sem decisão nenhuma dentro.

/// As chamadas do `ParakeetTranscriptionService` de que o runtime precisa, sem os tipos de UI do
/// app (`Language`, `TranscriptionResult`) e sem FluidAudio.
nonisolated protocol ParakeetServiceCalls: Sendable {
    /// `ensureInitialized()`: baixa e carrega. Não lança — o serviço engole a falha em `error`.
    func ensureLoaded() async
    /// `isInitialized`.
    var isLoaded: Bool { get async }
    /// `error`, a descrição técnica da última falha de carga.
    var loadErrorDescription: String? { get async }
    /// `transcribe(audioSamples:language:)`.
    func run(
        samples: [Float],
        language: ParakeetRequestedLanguage
    ) async throws -> ParakeetRuntimeOutput
    /// Descarga real dos pesos (`AsrManager.cleanup()`).
    func releaseModels() async
}

/// Falhas que a camada de chamadas reporta sem precisar do vocabulário de outro motor.
///
/// Existe para o `TranscriptionService.TranscriptionError` — que é o erro do singleton do
/// Whisper — não vazar para a classificação de falha do Parakeet.
nonisolated enum ParakeetServiceCallFailure: Error, Sendable, Equatable {
    /// O serviço recusou porque os pesos não estão carregados.
    case notLoaded
}

/// O idioma pedido, reduzido ao que o serviço entende.
///
/// Enum de três casos em vez de um `String`: o mapeamento para o `Language` do app vira um
/// `switch` exaustivo lá fora, sem `default` e sem decisão — é o que deixa a camada de produção
/// que não pode ser testada literalmente sem lógica.
nonisolated enum ParakeetRequestedLanguage: String, Sendable, Equatable, CaseIterable {
    case portuguese
    case english
    /// Detecção automática: o `Language.auto` que o serviço já entende.
    case automatic

    init(_ language: TranscriptionLanguage?) {
        guard let language else {
            self = .automatic
            return
        }
        switch language.primaryCode {
        case "pt": self = .portuguese
        case "en": self = .english
        // Inalcançável pelo motor (o descritor barra antes), mas cair em automático é a resposta
        // certa para um multilíngue: melhor deixar ele detectar do que rotular errado.
        default: self = .automatic
        }
    }
}

/// O `ParakeetRuntime` de produção.
///
/// Faz três coisas e só: recusa modelo que não sabe carregar, transforma o "erro em `@Published`"
/// do serviço em erro de runtime, e preserva cancelamento.
nonisolated struct ParakeetServiceRuntime: ParakeetRuntime {
    private let calls: any ParakeetServiceCalls
    /// O único id que este runtime sabe carregar hoje. Vira lista quando o TAGARELA CoreML
    /// entrar (Onda 5) — até lá, pedir outro id é `unsupportedModel`, nunca "carrega o v3 e
    /// registra o outro na proveniência".
    private let supportedModel: TranscriptionModelID

    init(
        calls: any ParakeetServiceCalls,
        supportedModel: TranscriptionModelID = .parakeetTDT06BV3
    ) {
        self.calls = calls
        self.supportedModel = supportedModel
    }

    func load(model: TranscriptionModelID) async throws {
        try check(model)
        try checkCancellation()

        await calls.ensureLoaded()

        // `ensureInitialized()` nunca lança: um cancelamento durante a carga só aparece aqui.
        try checkCancellation()

        guard await calls.isLoaded else {
            // O serviço engole a falha de carga em `@Published var error` e só a chamada
            // seguinte de `transcribe` levantaria `.notInitialized`. Aqui ela vira falha do
            // `prepare`, que é onde o coordenador consegue escolher outro motor antes de gastar
            // áudio.
            throw ParakeetRuntimeError.modelsUnavailable(
                await calls.loadErrorDescription ?? "Parakeet não carregado"
            )
        }
    }

    func transcribe(
        samples: [Float],
        language: TranscriptionLanguage?,
        model: TranscriptionModelID
    ) async throws -> ParakeetRuntimeOutput {
        try check(model)

        // O runtime EXIGE os pesos já carregados — o item 3 do contrato ("transcribe não
        // auto-prepara") tem de valer em TODAS as camadas, não só na do motor.
        //
        // Uma camada abaixo, `ParakeetTranscriptionService.transcribe` ainda começa com
        // `ensureInitialized()`. Sem esta guarda, uma violação de residência — transcrever com o
        // que o coordenador acha que já descarregou — viraria recarga silenciosa de 600 MB, fora
        // dos livros dele e sem evento nenhum. Aqui vira erro visível.
        guard await calls.isLoaded else {
            throw ParakeetRuntimeError.modelsUnavailable("Parakeet não carregado")
        }

        do {
            return try await calls.run(samples: samples, language: ParakeetRequestedLanguage(language))
        } catch {
            throw Self.failure(from: error)
        }
    }

    func release() async {
        await calls.releaseModels()
    }

    private func check(_ model: TranscriptionModelID) throws {
        guard model == supportedModel else {
            throw ParakeetRuntimeError.unsupportedModel(model)
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ParakeetRuntimeError.cancelled }
    }

    /// Classifica o erro cru que veio do serviço.
    ///
    /// **Cancelamento vem primeiro, antes do ramo genérico.** Era o CRITICO do Farol: um
    /// `CancellationError` real vindo do `AsrManager` caía no `catch` genérico e virava
    /// `runtimeFailure` → `.engineInternal`, cujo `allowsFallback` é verdadeiro — ou seja, o
    /// coordenador transcreveria de novo, noutro motor, um trabalho que alguém acabou de mandar
    /// parar. `Task.isCancelled` entra junto porque o erro que sai de uma inferência abortada nem
    /// sempre é um `CancellationError`: é a consequência dele.
    static func failure(from error: any Error) -> ParakeetRuntimeError {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let runtime = error as? ParakeetRuntimeError { return runtime }
        if let call = error as? ParakeetServiceCallFailure {
            switch call {
            case .notLoaded: return .modelsUnavailable("Parakeet não carregado")
            }
        }
        return .runtimeFailure(error.localizedDescription)
    }
}
