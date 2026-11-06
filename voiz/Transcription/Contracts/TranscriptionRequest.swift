import Foundation

/// Um bloco de áudio mono em ponto flutuante — o formato que todos os motores do app já falam
/// (`[Float]` 16 kHz, produzido pelo `AudioCaptureService`).
///
/// A taxa anda junto das amostras porque `duration` sem ela é chute, e a duração decide
/// coisas reais (lote curto demais para o Parakeet, janela do preview).
nonisolated struct TranscriptionAudio: Sendable, Equatable {
    /// Amostras mono, normalizadas em -1…1.
    var samples: [Float]
    /// Amostras por segundo. 16 kHz é o que o pipeline usa hoje ponta a ponta.
    var sampleRate: Double

    init(samples: [Float], sampleRate: Double = TranscriptionAudio.defaultSampleRate) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    static let defaultSampleRate: Double = 16_000

    var duration: TimeInterval {
        sampleRate > 0 ? TimeInterval(Double(samples.count) / sampleRate) : 0
    }

    var isEmpty: Bool { samples.isEmpty }
}

/// Um pedido de transcrição em lote: o áudio inteiro já está na mão.
///
/// `language == nil` significa **detecção automática** — é o `Language.auto` que o app já
/// oferece. Deixar isso como `nil` em vez de um caso `.auto` no enum de idioma evita que
/// "auto" vaze para lugares onde ele não faz sentido (a lista de idiomas que um motor suporta,
/// a proveniência de um resultado já produzido).
nonisolated struct TranscriptionRequest: Sendable, Equatable {
    var useCase: TranscriptionUseCase
    /// Idioma falado esperado; `nil` = detectar.
    var language: TranscriptionLanguage?
    var audio: TranscriptionAudio
    var context: TranscriptionContext

    init(useCase: TranscriptionUseCase, language: TranscriptionLanguage?, audio: TranscriptionAudio,
         context: TranscriptionContext = TranscriptionContext()) {
        self.useCase = useCase
        self.language = language
        self.audio = audio
        self.context = context
        self.context.isDictation = useCase == .dictation
    }
}

/// A abertura de uma sessão de streaming. Não carrega áudio: as amostras chegam depois, por
/// `TranscriptionStream.append(_:)`, enquanto o usuário fala.
nonisolated struct TranscriptionStreamRequest: Sendable, Equatable {
    var useCase: TranscriptionUseCase
    var language: TranscriptionLanguage?
    /// Taxa das amostras que serão entregues à sessão. Fixada na abertura porque trocar de
    /// taxa no meio de uma sessão de streaming não é recuperável.
    var sampleRate: Double

    init(
        useCase: TranscriptionUseCase,
        language: TranscriptionLanguage?,
        sampleRate: Double = TranscriptionAudio.defaultSampleRate
    ) {
        self.useCase = useCase
        self.language = language
        self.sampleRate = sampleRate
    }
}
