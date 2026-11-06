import Foundation
import FluidAudio

/// Diarização offline (pós-call) do áudio do sistema usando o pipeline do FluidAudio
/// (CoreML/ANE, 100% on-device). Só o `system-audio.caf` é diarizado — o microfone já
/// vem isolado como "Você", então só precisamos separar os outros participantes entre si.
///
/// Lazy load espelhando `ParakeetTranscriptionService`: os modelos baixam na 1ª vez
/// (com recovery automático em caso de download corrompido, via `prepareModels`).
final class MeetingDiarizationService {
    private var manager: OfflineDiarizerManager?
    private var isInitialized = false

    private static let diarizerSampleRate = 16_000
    private static let windowDuration = DiarizationWindowPlanner.defaultWindowDuration
    private static let windowOverlap = DiarizationWindowPlanner.defaultOverlap

    func ensureInitialized() async throws {
        guard !isInitialized else { return }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        self.manager = manager
        isInitialized = true
        print("✅ Diarizer offline carregado")
    }

    /// Diariza um arquivo de áudio e retorna os segmentos "quem falou quando".
    ///
    /// A entrada pública permanece a mesma para o MeetingViewModel. O arquivo é reamostrado uma
    /// vez para a fonte mapeada do FluidAudio; em seguida, o mesmo manager roda janelas de 3 min
    /// com 60 s de sobreposição e o linker reconstrói uma identidade global.
    func diarize(audioFileURL: URL) async throws -> [DiarizedSegment] {
        try await diarizeDetailed(audioFileURL: audioFileURL).segments
    }

    /// A mesma diarização, devolvendo também os agregados. É o que a sonda das
    /// proxies consome — e o que faz a fração minoritária ter denominador RAW.
    func diarizeDetailed(audioFileURL: URL) async throws -> DiarizationLinkResult {
        try await ensureInitialized()
        let start = Date()
        let windowed = try await diarizeWindows(audioFileURL: audioFileURL)
        let linked = DiarizationWindowLinker.linkDetailed(windowed.results)
        let elapsed = Date().timeIntervalSince(start)
        // Só agregados: durações, contagens e similaridades. Nada de texto de
        // fala, nada de ID local — o log é para o veredito das proxies.
        print(
            "🗣️ Diarização: \(linked.segments.count) segmentos em \(windowed.results.count)/\(windowed.windowCount) janelas (\(String(format: "%.2f", elapsed))s) \(linked.stats.logSummary)"
        )
        return linked
    }

    /// Só o diarizador, janela a janela, antes da costura. A sonda grava esta
    /// saída para reavaliar o linker na CPU sem rodar o modelo de novo.
    func diarizeWindows(
        audioFileURL: URL
    ) async throws -> (results: [DiarizationWindowResult], windowCount: Int) {
        try await ensureInitialized()
        guard let manager else { throw DiarizationServiceError.notInitialized }

        let factory = AudioSourceFactory()
        let (source, loadDuration) = try factory.makeDiskBackedSource(
            from: audioFileURL,
            targetSampleRate: Self.diarizerSampleRate
        )
        defer { source.cleanup() }

        let duration = TimeInterval(source.sampleCount) / Double(Self.diarizerSampleRate)
        let windows = DiarizationWindowPlanner.makeWindows(
            duration: duration,
            windowDuration: Self.windowDuration,
            overlap: Self.windowOverlap
        )
        var windowResults: [DiarizationWindowResult] = []
        windowResults.reserveCapacity(windows.count)

        for window in windows {
            let startSample = max(0, Int((window.start * Double(Self.diarizerSampleRate)).rounded()))
            let endSample = min(
                source.sampleCount,
                Int((window.end * Double(Self.diarizerSampleRate)).rounded())
            )
            guard endSample > startSample else { continue }

            let windowSource = WindowedAudioSampleSource(
                base: source,
                startSample: startSample,
                sampleCount: endSample - startSample
            )

            do {
                let result = try await manager.process(
                    audioSource: windowSource,
                    audioLoadingSeconds: window.index == 0 ? loadDuration : 0
                )
                if !result.segments.isEmpty {
                    windowResults.append(
                        DiarizationWindowResult(
                            window: window,
                            segments: result.segments.map {
                                DiarizedSegment(
                                    speakerId: $0.speakerId,
                                    start: TimeInterval($0.startTimeSeconds),
                                    end: TimeInterval($0.endTimeSeconds),
                                    embedding: $0.embedding
                                )
                            }
                        )
                    )
                }
            } catch OfflineDiarizationError.noSpeechDetected {
                // Silence-only windows are expected in a long meeting; another window may still
                // contain speech, so do not make the whole post-call diarization fail.
                continue
            }
        }

        guard !windowResults.isEmpty else {
            throw OfflineDiarizationError.noSpeechDetected
        }
        return (windowResults, windows.count)
    }

    enum DiarizationServiceError: Error, LocalizedError {
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return String(localized: "Diarizer não inicializado")
            }
        }
    }
}

/// A zero-copy view over one interval of FluidAudio's disk-backed, 16 kHz mono source.
private struct WindowedAudioSampleSource<Base: AudioSampleSource>: AudioSampleSource {
    let base: Base
    let startSample: Int
    let sampleCount: Int

    func copySamples(
        into destination: UnsafeMutablePointer<Float>,
        offset: Int,
        count: Int
    ) throws {
        guard count > 0, offset >= 0, offset < sampleCount else { return }
        let available = min(count, sampleCount - offset)
        try base.copySamples(
            into: destination,
            offset: startSample + offset,
            count: available
        )
    }
}
