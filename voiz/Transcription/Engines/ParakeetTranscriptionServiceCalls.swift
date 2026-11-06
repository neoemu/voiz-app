import Foundation

// A única parte do adapter da T2.2 que os testes não compilam: aqui moram `Language`,
// `TranscriptionResult` e — por tabela — o FluidAudio que o `ParakeetTranscriptionService`
// importa. Por isso não há decisão nenhuma neste arquivo: encaminhamento de chamada, cópia de
// campo e um `switch` exaustivo. Tudo que classifica erro ou escolhe caminho está em
// `ParakeetServiceRuntime`, que é puro e testado.

/// Encaminha as chamadas cruas do `ParakeetTranscriptionService`.
nonisolated struct ParakeetTranscriptionServiceCalls: ParakeetServiceCalls {
    private let service: ParakeetTranscriptionService

    init(service: ParakeetTranscriptionService) {
        self.service = service
    }

    func ensureLoaded() async {
        await service.ensureInitialized()
    }

    var isLoaded: Bool {
        get async { await service.isInitialized }
    }

    var loadErrorDescription: String? {
        get async { await service.error }
    }

    func run(
        samples: [Float],
        language: ParakeetRequestedLanguage
    ) async throws -> ParakeetRuntimeOutput {
        do {
            let result = try await service.transcribe(
                audioSamples: samples,
                language: Self.appLanguage(language)
            )
            // O serviço devolve sempre um segmento só (uma utterance). Confiança e duração vêm
            // dele; texto final, segmento do contrato e proveniência quem monta é o motor.
            let segment = result.segments.first
            return ParakeetRuntimeOutput(
                text: result.fullText,
                confidence: segment?.confidence ?? 0,
                duration: segment?.duration ?? 0,
                processingTime: result.processingTime
            )
        } catch TranscriptionService.TranscriptionError.notInitialized {
            // Traduzido aqui, e não classificado lá dentro: o erro do singleton do Whisper não
            // entra no vocabulário de falha do Parakeet.
            throw ParakeetServiceCallFailure.notLoaded
        }
    }

    func releaseModels() async {
        await service.release()
    }

    private static func appLanguage(_ language: ParakeetRequestedLanguage) -> Language {
        switch language {
        case .portuguese: return .portuguese
        case .english: return .english
        // O seletor não tem mais automático, e o motor só serve português (descritor da Onda 5):
        // um pedido sem idioma que chegue aqui é rotulado pelo que ele de fato vai transcrever.
        case .automatic: return .portuguese
        }
    }
}

extension ParakeetTranscriptionEngine {
    /// O motor ligado ao serviço de verdade.
    ///
    /// O serviço é parâmetro **obrigatório**: com um default (`= ParakeetTranscriptionService()`)
    /// cada chamada criaria um runtime Parakeet novo enquanto `TranscriptionViewModel` e
    /// `MeetingViewModel` mantêm os deles — e o coordenador não tem como impor residência sobre
    /// instâncias que não são dele.
    ///
    /// Ninguém chama isto ainda: quem monta motores é a T2.3.
    @MainActor
    static func make(
        service: ParakeetTranscriptionService,
        observer: (@Sendable (LoadEvent) -> Void)? = nil
    ) -> ParakeetTranscriptionEngine {
        ParakeetTranscriptionEngine(
            runtime: ParakeetServiceRuntime(calls: ParakeetTranscriptionServiceCalls(service: service)),
            observer: observer
        )
    }
}
