import Foundation

// O seam do motor WhisperKit: o que o adapter precisa da biblioteca, e nada mais.
//
// Este arquivo — e o `WhisperKitTranscriptionEngine` que fala com ele — depende **só de
// Foundation**, igual a `Transcription/Contracts/`. É isso que permite compilar o motor inteiro
// no alvo `voizTests` e exercitar o ciclo de vida dele com um dublê: sem CoreML, sem rede e sem
// os ~480 MB de pesos. A implementação de verdade mora em `LiveWhisperKitRuntime.swift`, que é
// só do alvo do app.
//
// A review de arquitetura foi explícita: os três CRÍTICOS da primeira versão estavam todos
// dentro do trecho que não tinha teste porque o motor falava direto com `WhisperKit.download` e
// `WhisperKit(modelFolder:)`. O seam existe para que isso não se repita.

/// O runtime do WhisperKit visto pelo motor: baixar pesos, carregá-los, e o pouco de disco que
/// a decisão de baixar depende.
///
/// Disco entra aqui (em vez de o motor chamar `WhisperKitEngineSupport` direto) porque o teste
/// precisa dizer "este modelo já está baixado" sem criar 480 MB de arquivos.
nonisolated protocol WhisperKitRuntime: Sendable {
    /// Os pesos da variante já estão íntegros no disco? Decide só se o primeiro evento de carga
    /// é `.downloading` ou `.loading` — o download em si é idempotente.
    func isModelDownloaded(variant: String) -> Bool

    /// Apaga a pasta da variante. Usado só na recuperação de modelo corrompido.
    func removeModelFolder(variant: String)

    /// Baixa (ou apenas verifica, se já presente) a variante e devolve a pasta local.
    ///
    /// `onProgress` recebe a fração de 0 a 1 e pode ser chamado de qualquer thread — é o
    /// `progressCallback` do `HubApi` por baixo.
    func downloadModel(
        variant: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    /// Carrega os pesos da pasta e devolve a sessão de inferência.
    func loadSession(modelFolder: URL) async throws -> any WhisperKitSession
}

/// Um conjunto de pesos carregado e pronto para inferir.
///
/// Separado do runtime porque é o objeto que o `unload()` precisa soltar de verdade — a regra
/// de **um** modelo pesado residente do PLANO depende de `release()` liberar mesmo, e não de o
/// motor apenas esquecer a referência.
nonisolated protocol WhisperKitSession: Sendable {
    /// Uma inferência. O motor garante que nunca há duas em voo na mesma sessão.
    ///
    /// `languageCode` é o código primário do Whisper (`pt`, `en`); `nil` = detecção automática.
    func transcribe(
        samples: [Float],
        languageCode: String?,
        context: TranscriptionContext
    ) async throws -> WhisperKitSessionOutput

    /// Libera os pesos. Chamado uma vez, depois que o motor drenou a fila de inferência.
    func release() async
}

/// O resultado cru de uma inferência, sem os tipos do WhisperKit nem os do app.
nonisolated struct WhisperKitSessionOutput: Sendable, Equatable {
    /// Texto como o modelo devolveu — a sanitização é do motor, não do runtime.
    var text: String
    /// Idioma que o modelo diz ter ouvido (`pt`, `english`…), como veio. `nil` = não reportou.
    var language: String?
    var segments: [WhisperKitSessionSegment]
    var vocabularyTermsUsed: Int?

    init(text: String, language: String? = nil, segments: [WhisperKitSessionSegment] = [], vocabularyTermsUsed: Int? = nil) {
        self.text = text
        self.language = language
        self.segments = segments
        self.vocabularyTermsUsed = vocabularyTermsUsed
    }
}

/// Um segmento cru, com os tempos relativos ao início do áudio pedido.
nonisolated struct WhisperKitSessionSegment: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// `avgLogprob` do Whisper. Escala própria dele.
    var confidence: Float?

    init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
