import Foundation
import WhisperKit
import Combine

@MainActor
class TranscriptionService: ObservableObject {
    /// Instância única compartilhada pelas 3 telas (Ditado/Tradução/Reunião).
    /// O modelo Whisper é um recurso único na Neural Engine — compartilhar evita
    /// baixar/carregar o mesmo modelo 3× em paralelo (3× rede + 3× RAM).
    static let shared = TranscriptionService()

    /// Modelo padrão: `small` é leve (~480MB) e confiável como ponto de partida.
    /// `large-v3_turbo` tem qualidade maior, mas baixa ~1.5GB no primeiro uso —
    /// fica como opção que o usuário escolhe nas Configurações.
    static let defaultModelName = "openai_whisper-small"

    private var whisperKit: WhisperKit?
    private var isInitialized = false
    private var modelName: String
    /// Evita re-baixar em loop: só tentamos apagar+re-baixar uma vez por modelo.
    private var didAttemptRecovery = false
    /// Falha definitiva (modelo segue inválido após recuperação) — para de
    /// retentar a cada chamada e expõe a mensagem para a UI.
    private var initializationFailed = false

    @Published var isLoading = false
    @Published var loadingProgress: Double = 0.0
    @Published var error: String?
    /// Estado do modelo para a UI (mostra gauge de download, "carregando", "pronto").
    @Published var loadState: ModelLoadState = .idle

    /// Estágios do ciclo de vida do modelo de transcrição.
    enum ModelLoadState: Equatable {
        case idle                  // nada acontecendo ainda
        case downloading(Double)   // baixando (0...1)
        case loading               // já baixado, carregando na ANE
        case ready                 // pronto para transcrever
        case failed(String)        // falhou (mensagem)
    }

    private var cancellables = Set<AnyCancellable>()

    /// `private` para garantir a instância única — use `TranscriptionService.shared`.
    /// `nonisolated` para permitir a inicialização do `static let shared` (só
    /// atribui propriedades armazenadas, sem tocar em estado isolado).
    nonisolated private init(modelName: String = TranscriptionService.defaultModelName) {
        self.modelName = modelName
        print("🤖 TranscriptionService init started (model: \(modelName))")
        // Initialization will happen lazily on first transcription
        print("✅ TranscriptionService init completed (lazy mode)")
    }

    /// Troca o modelo do WhisperKit. Se um modelo diferente já estiver carregado,
    /// descarta-o para que a próxima transcrição recarregue com o novo modelo.
    func configure(modelName: String) {
        guard modelName != self.modelName else { return }
        print("🔄 Transcription model changed: \(self.modelName) → \(modelName)")
        self.modelName = modelName
        whisperKit = nil
        isInitialized = false
        // Novo modelo → permite uma nova tentativa de recuperação e limpa o erro.
        didAttemptRecovery = false
        initializationFailed = false
        error = nil
        loadState = .idle
    }

    /// O modelo que este serviço legado está configurado para usar.
    ///
    /// Legível de fora só para o `TranscriptionForeignWeightOwner` da T2.4b conseguir perguntar ao
    /// catálogo se o que está aqui é pesado — sem isso, "libere os pesos pesados" viraria "libere
    /// sempre", e o ditado recarregaria 480 MB toda vez que a tradução aquecesse um modelo grande.
    var configuredModelName: String { modelName }

    /// Libera os pesos residentes e volta ao estado não inicializado.
    ///
    /// É o efeito que o `configure(modelName:)` já tinha ao trocar de modelo, isolado para poder
    /// ser chamado sem trocar nada — é o que a ponte `TranscriptionForeignWeightOwner` (T2.3)
    /// precisa para que a regra de "um modelo pesado residente" também valha sobre a metade do app
    /// que ainda não migrou. Simétrica ao `release()` que o `ParakeetTranscriptionService` ganhou
    /// na T2.2, e pelo mesmo motivo.
    ///
    /// Seguro durante uma transcrição em voo: `transcribe` captura o `whisperKit` numa `let` local
    /// antes do `await`, então a chamada em curso mantém a referência viva e termina normalmente —
    /// quem paga é a chamada seguinte, que recarrega. Quem chama isto está justamente escolhendo
    /// pagar isso para não estourar memória.
    ///
    /// Não mexe em `didAttemptRecovery`: a cota de uma recuperação por modelo é sobre o modelo
    /// estar corrompido no disco, e liberar RAM não conserta nem estraga disco.
    func release() {
        guard whisperKit != nil || isInitialized || isLoading else { return }
        print("🧹 TranscriptionService: liberando pesos residentes (\(modelName))")
        whisperKit = nil
        isInitialized = false
        isLoading = false
        loadState = .idle
    }

    /// `true` se os pesos dos submodelos críticos já estão no disco — usado
    /// para a UI dizer "baixado" vs "baixando", e detecta partial corrompido.
    func isModelDownloaded(_ modelName: String) -> Bool {
        WhisperKitEngineSupport.isModelDownloaded(modelName)
    }

    func ensureInitialized() async {
        // Se já falhou em definitivo, não fica re-tentando a cada chunk (evita
        // loop de erro/re-download). Recupera só ao trocar de modelo (configure).
        guard !initializationFailed else { return }
        guard !isInitialized && !isLoading else {
            print("⏸️ Skipping initialization (isInitialized: \(isInitialized), isLoading: \(isLoading))")
            return
        }
        await initializeWhisper()
    }

    private func initializeWhisper() async {
        let modelName = self.modelName
        print("⏳ Starting WhisperKit initialization (model: \(modelName), downloading if needed...)")
        isLoading = true
        error = nil
        // Já no disco → vai direto pro "carregando"; senão, mostra o gauge de download.
        loadState = isModelDownloaded(modelName) ? .loading : .downloading(0)

        do {
            // Baixa (ou apenas verifica, se já presente) reportando progresso real.
            let folder = try await WhisperKit.download(
                variant: modelName,
                progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self?.loadingProgress = fraction
                        self?.loadState = .downloading(fraction)
                    }
                }
            )

            // Carrega da pasta local (não re-baixa).
            loadState = .loading
            whisperKit = try await WhisperKit(
                modelFolder: folder.path,
                verbose: true
            )

            isInitialized = true
            isLoading = false
            loadState = .ready
            print("✅ WhisperKit initialized successfully")
        } catch {
            isLoading = false

            // Modelo incompleto/corrompido (ex.: download interrompido deixou um
            // weight.bin faltando). Apaga a pasta e re-baixa limpo — uma vez só.
            if isIncompleteModelError(error), !didAttemptRecovery {
                didAttemptRecovery = true
                print("⚠️ Modelo '\(modelName)' incompleto/corrompido — apagando e re-baixando…")
                removeModelFolder(modelName)
                await initializeWhisper()
                return
            }

            initializationFailed = true
            let friendly = friendlyErrorMessage(for: error)
            self.error = friendly
            loadState = .failed(friendly)
            print("❌ WhisperKit initialization failed (\(modelName)): \(error)")
        }
    }

    /// Heurística: o erro indica arquivos do modelo ausentes/corrompidos
    /// (vs. um erro transitório de rede), sinalizando que vale re-baixar.
    private func isIncompleteModelError(_ error: Error) -> Bool {
        WhisperKitEngineSupport.isIncompleteModelError(error)
    }

    private func removeModelFolder(_ modelName: String) {
        WhisperKitEngineSupport.removeModelFolder(modelName)
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        if isIncompleteModelError(error) {
            return String(localized: "Modelo de transcrição incompleto ou corrompido mesmo após re-baixar. Verifique sua conexão e tente novamente, ou escolha outro modelo nas Configurações.")
        }
        return String(localized: "Falha ao carregar o modelo de transcrição: \(error.localizedDescription)")
    }
    
    func transcribe(audioSamples: [Float], language: Language) async throws -> TranscriptionResult {
        print("📝 Transcribe called, ensuring WhisperKit is initialized...")
        await ensureInitialized()
        
        guard isInitialized, let whisperKit = whisperKit else {
            print("❌ WhisperKit not initialized after ensureInitialized()")
            // Propaga o motivo real (modelo ausente/corrompido) em vez de um
            // genérico, pra UI mostrar algo acionável em vez de repetir "erro 0".
            if let error { throw TranscriptionError.modelUnavailable(error) }
            throw TranscriptionError.notInitialized
        }
        
        print("🚀 Starting actual transcription with WhisperKit...")
        print("📊 Audio info: \(audioSamples.count) samples, min: \(audioSamples.min() ?? 0), max: \(audioSamples.max() ?? 0)")
        
        let startTime = Date()
        
        // Sem `nil` desde que o seletor perdeu o automático: o idioma pedido sempre vai no
        // decode. É o token de idioma que impede o Whisper de "traduzir" o que ouviu.
        let languageCode = language.rawValue
        
        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: DecodingOptions(
                language: languageCode,
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                // 1 fallback no máximo: cada fallback é um decode inteiro extra; com 5, um
                // trecho ruidoso podia custar 6 passes e travar o pipeline ao vivo.
                temperatureFallbackCount: 1,
                sampleLength: 224,
                topK: 5,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                // Os tempos dos turns vêm do relógio da captura, não do Whisper — sem
                // tokens de timestamp o decode fica mais curto e barato.
                withoutTimestamps: true
            )
        )
        
        let processingTime = Date().timeIntervalSince(startTime)
        print("⏱️ WhisperKit processing took \(processingTime)s")
        
        guard let result = results.first else {
            print("❌ No results returned from WhisperKit")
            throw TranscriptionError.audioProcessingFailed
        }
        
        print("📊 Got \(result.segments.count) segments from WhisperKit")
        
        let segments = result.segments.map { segment in
            TranscriptionSegment(
                text: segment.text,
                language: language,
                confidence: Float(segment.avgLogprob),
                timestamp: Date(),
                duration: TimeInterval(segment.end - segment.start)
            )
        }
        
        let fullText = sanitizeTranscription(result.text)
        let detectedLang = detectLanguage(from: languageCode ?? result.language)
        
        return TranscriptionResult(
            segments: segments,
            fullText: fullText,
            detectedLanguage: detectedLang,
            processingTime: processingTime
        )
    }
    
    func transcribeStream(audioSamples: [Float], language: Language) async throws -> AsyncThrowingStream<String, Error> {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.transcribe(audioSamples: audioSamples, language: language)
                    continuation.yield(result.fullText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Remove anotações de evento não-fala que o Whisper emite em trechos de
    /// música/silêncio (ex.: [MÚSICA], [Music], (aplausos), ♪) para não
    /// "narrar" tudo que ouve.
    private func sanitizeTranscription(_ text: String) -> String {
        WhisperKitEngineSupport.sanitize(text)
    }

    private func detectLanguage(from code: String) -> Language {
        switch code.lowercased() {
        case "pt", "portuguese":
            return .portuguese
        case "en", "english":
            return .english
        case "es", "spanish":
            return .spanish
        case "fr", "french":
            return .french
        case "de", "german":
            return .german
        case "ja", "japanese":
            return .japanese
        case "zh", "chinese":
            return .chinese
        default:
            return .english
        }
    }
    
    enum TranscriptionError: LocalizedError {
        case notInitialized
        case audioProcessingFailed
        case modelNotLoaded
        case modelUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return String(localized: "Modelo de transcrição ainda não carregado.")
            case .audioProcessingFailed:
                return String(localized: "Falha ao processar o áudio.")
            case .modelNotLoaded:
                return String(localized: "Modelo de transcrição não carregado.")
            case .modelUnavailable(let message):
                return message
            }
        }
    }
}
