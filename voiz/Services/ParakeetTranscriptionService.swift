import Foundation
import FluidAudio
import Combine

/// Spike: engine de transcrição alternativa usando NVIDIA Parakeet TDT v3
/// via FluidAudio (CoreML/ANE). Multilíngue (25 idiomas, inclui PT), batch,
/// com fator real-time muito maior que o Whisper (~100×+ no Apple Silicon).
///
/// Mesma interface pública do `TranscriptionService` para permitir comparação
/// lado a lado (trocável pelo seletor de engine nas Configurações).
class ParakeetTranscriptionService: ObservableObject {
    private var asrManager: AsrManager?
    /// Legível de fora só para o adapter da T2.2 (`ParakeetTranscriptionServiceCalls`, consumido
    /// por `ParakeetServiceRuntime`) conseguir distinguir "carregou" de "falhou ao carregar" —
    /// hoje a falha só existe em `error`. O runtime também usa esta leitura para exigir pesos
    /// carregados antes de transcrever, em vez de deixar o `ensureInitialized()` abaixo recarregar
    /// em silêncio.
    private(set) var isInitialized = false

    @Published var isLoading = false
    @Published var error: String?

    /// Nome deste motor nos logs. Marca de produto, não copy traduzível.
    private static let logName = "Parakeet v3"

    init() {
        print(TranscriptionLogRedaction.engineCreated(Self.logName))
    }

    func ensureInitialized() async {
        guard !isInitialized && !isLoading else { return }
        await initializeParakeet()
    }

    private func initializeParakeet() async {
        print(TranscriptionLogRedaction.engineLoadStarted(Self.logName))
        isLoading = true
        do {
            // version padrão = .v3 (multilíngue). Preferimos o fine-tune pt-BR publicado; o modelo
            // base da NVIDIA é a rede de segurança quando ele não pôde ser buscado.
            let models: AsrModels
            do {
                if ParakeetPTBRWeights.defaultDirectory().map({ !ParakeetPTBRWeights.isInstalled(at: $0) }) ?? false {
                    print(TranscriptionLogRedaction.engineDownloadingLocalWeights(Self.logName))
                }
                let directory = try await ParakeetPTBRWeights.ensureAvailable()
                models = try await AsrModels.load(from: directory)
                print(TranscriptionLogRedaction.engineUsingLocalWeights(Self.logName))
            } catch {
                // Cair no base é aceitável (rede caiu, disco cheio); cair em silêncio não é.
                print(TranscriptionLogRedaction.engineLocalWeightsUnavailable(Self.logName, error: error))
                models = try await AsrModels.downloadAndLoad()
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            isInitialized = true
            isLoading = false
            print(TranscriptionLogRedaction.engineLoadFinished(Self.logName))
        } catch {
            self.error = "Falha ao carregar Parakeet: \(error.localizedDescription)"
            isLoading = false
            print(TranscriptionLogRedaction.engineLoadFailed(Self.logName, error: error))
        }
    }

    /// Libera os pesos residentes (~600 MB) e volta ao estado não inicializado.
    ///
    /// `AsrManager.cleanup()` do FluidAudio 0.15.5 zera `asrModels`, preprocessor, encoder,
    /// decoder e joint. Sem esta descarga o Parakeet ficaria residente até o processo morrer e a
    /// regra de "um modelo pesado residente" da T2.3 seria inexequível para ele.
    ///
    /// Não é chamada por nada no app: quem usa é o `unload()` do `ParakeetTranscriptionEngine`
    /// (T2.2), que garante não haver carga nem inferência em voo quando chega aqui.
    func release() async {
        if let asrManager {
            await asrManager.cleanup()
        }
        asrManager = nil
        isInitialized = false
        error = nil
    }

    func transcribe(audioSamples: [Float], language: Language) async throws -> TranscriptionResult {
        await ensureInitialized()

        guard isInitialized, let asrManager else {
            throw TranscriptionService.TranscriptionError.notInitialized
        }

        let startTime = Date()

        // Parakeet v3 é multilíngue e autodetecta o idioma; cada ditado é uma
        // utterance independente, então usamos um decoder state novo por chamada.
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(audioSamples, decoderState: &decoderState)

        let processingTime = Date().timeIntervalSince(startTime)
        let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sem transcript no log (PLANO, regra 7): esta linha imprimia os primeiros 60 caracteres do
        // texto reconhecido em stdout — e ela roda no caminho REAL do ditado com Parakeet, porque é
        // este serviço que o adapter da T2.2 (`ParakeetServiceRuntime`) executa.
        print(TranscriptionLogRedaction.engineFinishedBatch(
            fullText,
            engine: Self.logName,
            processingTime: processingTime,
            realTimeFactor: Double(result.rtfx)
        ))

        let segment = TranscriptionSegment(
            text: fullText,
            language: language,
            confidence: result.confidence,
            timestamp: Date(),
            duration: result.duration
        )

        return TranscriptionResult(
            segments: [segment],
            fullText: fullText,
            // Parakeet não expõe idioma detectado no resultado; mantém o pedido.
            detectedLanguage: language,
            processingTime: processingTime
        )
    }
}
