import Foundation
import WhisperKit

// A implementação de verdade do seam do motor. É o único arquivo do motor que importa
// WhisperKit — e por isso o único que o alvo `voizTests` não compila.
//
// Aqui não há decisão nenhuma: só a tradução entre o vocabulário do `WhisperKitRuntime` e o da
// biblioteca. Tudo que decide algo (o que é modelo corrompido, o que sanitizar, quando
// re-baixar, quando descarregar) mora no motor ou no `WhisperKitEngineSupport`, que são
// testáveis. As `DecodingOptions` são a exceção de propósito: elas são a configuração da
// biblioteca, e estão preservadas byte a byte do `TranscriptionService`.

nonisolated extension WhisperKitTranscriptionEngine {
    /// O motor com o runtime de produção. Simétrica à `ParakeetTranscriptionEngine.make(service:)`
    /// da T2.2 — o coordenador da T2.3 monta os dois motores da mesma forma, em vez de instanciar
    /// o runtime de um na mão e usar a fábrica do outro.
    ///
    /// Continua não havendo construtor default: quem chama esta fábrica está pedindo, de
    /// propósito, um runtime WhisperKit novo.
    static func make(
        observer: (@Sendable (WhisperKitLoadEvent) -> Void)? = nil
    ) -> WhisperKitTranscriptionEngine {
        WhisperKitTranscriptionEngine(runtime: LiveWhisperKitRuntime(), observer: observer)
    }
}

/// O runtime WhisperKit de produção.
nonisolated struct LiveWhisperKitRuntime: WhisperKitRuntime {

    init() {}

    func isModelDownloaded(variant: String) -> Bool {
        WhisperKitEngineSupport.isModelDownloaded(variant)
    }

    func removeModelFolder(variant: String) {
        WhisperKitEngineSupport.removeModelFolder(variant)
    }

    func downloadModel(
        variant: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        print("⏳ Starting WhisperKit download (model: \(variant), skipped if already present…)")
        return try await WhisperKit.download(
            variant: variant,
            progressCallback: { progress in onProgress(progress.fractionCompleted) }
        )
    }

    /// `verbose` DESLIGADO. Não é preferência de ruído: com ele ligado, a fala
    /// da reunião vai para o log do sistema.
    ///
    /// A cadeia é toda verificável no WhisperKit 1.0.0:
    /// `WhisperKit.swift:72` faz `Logging.updateLogLevel(config.verbose ? … : .none)`;
    /// `TranscribeTask.swift:69` faz `options.verbose = Logging.isLoggingEnabled`;
    /// com isso as linhas 225-232 logam CADA PALAVRA decodificada e 251-257
    /// logam os segmentos formatados; e `ArgmaxCore/Logging.swift:123` emite
    /// tudo com `privacy: .public`, ou seja, sem redação no OSLog.
    ///
    /// Resultado: qualquer transcrição bem-sucedida escrevia o que foi dito no
    /// log do sistema, onde fica retido e legível por fora do app. Isto é
    /// exatamente o oposto da regra do projeto — logs sem texto de fala.
    ///
    /// Para diagnóstico local existe a porta explícita `VOIZ_WHISPERKIT_VERBOSE`,
    /// e só em build de DEBUG: quem a liga está escolhendo, naquela execução,
    /// mandar transcrição para o log.
    func loadSession(modelFolder: URL) async throws -> any WhisperKitSession {
        let kit = try await WhisperKit(
            modelFolder: modelFolder.path,
            verbose: Self.verboseDiagnosticsEnabled
        )
        print("✅ WhisperKit initialized successfully")
        return LiveWhisperKitSession(kit: kit)
    }

    /// `true` só em DEBUG e só com a variável de ambiente explícita.
    static var verboseDiagnosticsEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["VOIZ_WHISPERKIT_VERBOSE"] == "1"
        #else
        false
        #endif
    }
}

/// Um `WhisperKit` carregado.
///
/// `@unchecked Sendable` com justificativa: `WhisperKit` é `open class` com estado mutável
/// (`currentTimings`, `progress`, o tokenizer do decoder) e nada nele é sincronizado. O que
/// torna o compartilhamento seguro é o `WhisperKitTranscriptionEngine`, que enfileira as
/// inferências — no máximo uma em voo por sessão — e só chama `release()` depois de drenar essa
/// fila. Fora do motor, esta classe não deve ser compartilhada.
nonisolated final class LiveWhisperKitSession: WhisperKitSession, @unchecked Sendable {
    private let kit: WhisperKit

    init(kit: WhisperKit) {
        self.kit = kit
    }

    func transcribe(samples: [Float], languageCode: String?, context: TranscriptionContext) async throws -> WhisperKitSessionOutput {
        guard let tokenizer = kit.tokenizer else {
            throw TranscriptionEngineFailure.engineInternal("Tokenizer do WhisperKit indisponível")
        }
        let budget = TranscriptionContext.whisperBudget(cacheTokens: kit.textDecoder.kvCacheMaxSequenceLength)
        let prompt = context.whisperPrompt(tokenize: { tokenizer.encode(text: $0) }, budget: budget.promptTokens)
        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                language: languageCode,
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                // 1 fallback no máximo: cada fallback é um decode inteiro extra; com 5, um
                // trecho ruidoso podia custar 6 passes e travar o pipeline ao vivo.
                temperatureFallbackCount: 1,
                // Context and recognized speech share the exported CoreML cache.
                sampleLength: context.isDictation ? budget.sampleLength : min(224, budget.sampleLength),
                topK: 5,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                // Timestamps let long dictation advance by recognized segments. Meeting chunks
                // retain their cheaper decoding; their turn times come from capture instead.
                withoutTimestamps: !context.isDictation,
                // WhisperKit otherwise skips clips <= 1s and the last <= 1s window.
                // A short "A", "não" or "agreed" is a complete answer in dictation.
                windowClipTime: context.isDictation ? 0 : 1,
                promptTokens: prompt.tokens.isEmpty ? nil : prompt.tokens
            )
        )

        guard !results.isEmpty else {
            throw TranscriptionEngineFailure.engineInternal("WhisperKit não devolveu nenhum resultado")
        }

        return WhisperKitSessionOutput(
            text: results.map(\.text).joined(separator: " "),
            language: results.first?.language,
            segments: results.flatMap(\.segments).map {
                WhisperKitSessionSegment(
                    text: $0.text,
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    confidence: Float($0.avgLogprob)
                )
            },
            vocabularyTermsUsed: prompt.used
        )
    }

    /// Libera os pesos de verdade. `unloadModels()` zera encoder, decoder e tokenizer do
    /// `WhisperKit` — sem ele, "descarregar" seria só esquecer a referência e torcer para o ARC
    /// coletar, o que não dá ao coordenador a garantia que a regra de um modelo pesado exige.
    func release() async {
        await kit.unloadModels()
    }
}
