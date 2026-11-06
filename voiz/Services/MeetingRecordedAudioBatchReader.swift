import Accelerate
import AVFoundation
import Foundation

/// Leitor incremental dos arquivos canônicos de reunião (Float32, mono, 16 kHz).
/// Reproduz a política da captura anterior: chunks de 3s, silêncio descartado e fala
/// contínua coalescida até o limite do Whisper, sem carregar a call inteira na memória.
final class MeetingRecordedAudioBatchReader {
    private let source: MeetingCaptureSource
    private let file: AVAudioFile
    private let sampleRate: Double
    private let chunkFrameCount: AVAudioFrameCount
    private let maxBatchSeconds: TimeInterval
    private let gapTolerance: TimeInterval
    private let audibleThreshold: Float

    /// Duração total do arquivo — denominador da barra de progresso do pós-processamento.
    var totalSeconds: TimeInterval { Double(file.length) / sampleRate }
    /// Posição já lida do arquivo. Anda à frente da inferência em no máximo um lote
    /// (mais o chunk adiado), o que é erro aceitável para exibição de progresso.
    var consumedSeconds: TimeInterval { Double(file.framePosition) / sampleRate }

    /// Fila, não slot único: um chunk dividido no corte gera a cauda E pode
    /// precisar adiar a cabeça no mesmo passo.
    private var deferredChunks: [MeetingAudioChunk] = []
    private let cutPlan: MeetingRecordingLifecycle.MeetingBatchCutPlan
    private var reachedEnd = false
    private var batchSamples: [Float] = []
    private var batchStart: TimeInterval?
    private var batchEnd: TimeInterval = 0

    init(
        source: MeetingCaptureSource,
        url: URL,
        chunkSeconds: TimeInterval,
        maxBatchSeconds: TimeInterval,
        gapTolerance: TimeInterval,
        audibleThreshold: Float,
        speakerBoundaries: [TimeInterval] = []
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              abs(format.sampleRate - 16_000) < 1 else {
            throw RecordedAudioError.unsupportedFormat(
                sampleRate: format.sampleRate,
                channels: format.channelCount
            )
        }

        self.source = source
        self.file = file
        self.sampleRate = format.sampleRate
        self.chunkFrameCount = AVAudioFrameCount(max(1, Int(format.sampleRate * chunkSeconds)))
        self.maxBatchSeconds = maxBatchSeconds
        self.gapTolerance = gapTolerance
        self.audibleThreshold = audibleThreshold
        self.cutPlan = MeetingRecordingLifecycle.MeetingBatchCutPlan(boundaries: speakerBoundaries)
        self.batchSamples.reserveCapacity(Int(format.sampleRate * maxBatchSeconds))
    }

    func nextBatch() async throws -> MeetingAudioChunk? {
        guard !reachedEnd || batchStart != nil || !deferredChunks.isEmpty else { return nil }
        var chunksRead = 0

        while true {
            let pending: MeetingAudioChunk?
            if !deferredChunks.isEmpty {
                pending = deferredChunks.removeFirst()
            } else {
                pending = try readChunk()
            }

            guard var chunk = pending else {
                reachedEnd = true
                return takeBatch()
            }

            // Corte da diarização DENTRO do chunk: divide no instante exato e
            // guarda a cauda. Sem isso a troca de falante erraria por até um
            // chunk inteiro de leitura.
            if let cut = cutPlan.cut(strictlyInside: chunk) {
                let parts = MeetingRecordingLifecycle.MeetingBatchCutPlan.split(chunk, at: cut)
                chunk = parts.head
                deferredChunks.insert(parts.tail, at: 0)
            }

            chunksRead += 1
            if chunksRead.isMultiple(of: 20) {
                // Arquivos longos e silenciosos não devem monopolizar a main actor
                // enquanto a tela mostra o progresso do pós-processamento.
                await Task.yield()
            }

            guard !chunk.samples.isEmpty else {
                if batchStart != nil {
                    return takeBatch()
                }
                continue
            }

            if let start = batchStart {
                let hasGap = chunk.startTime - batchEnd > gapTolerance
                let exceedsWindow = chunk.endTime - start > maxBatchSeconds
                // Troca de falante é corte OBRIGATÓRIO, ao lado do silêncio e
                // do teto: é o que faz cada lote nascer de um falante só.
                let crossesSpeaker = cutPlan.crossesBoundary(
                    fromBatchStart: start,
                    toChunkStart: chunk.startTime
                )
                if hasGap || exceedsWindow || crossesSpeaker {
                    deferredChunks.insert(chunk, at: 0)
                    return takeBatch()
                }
            } else {
                batchStart = chunk.startTime
            }

            batchSamples.append(contentsOf: chunk.samples)
            batchEnd = chunk.endTime
        }
    }

    private func readChunk() throws -> MeetingAudioChunk? {
        let startFrame = file.framePosition
        let remaining = file.length - startFrame
        guard remaining > 0 else { return nil }

        let requested = AVAudioFrameCount(min(Int64(chunkFrameCount), remaining))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: requested
        ) else {
            throw RecordedAudioError.bufferAllocationFailed
        }

        try file.read(into: buffer, frameCount: requested)
        let count = Int(buffer.frameLength)
        // Mantém o mesmo piso do flush da captura antiga (~250ms).
        guard count >= 4_000, let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        let start = Double(startFrame) / sampleRate
        let end = start + Double(count) / sampleRate
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(count))
        // Silêncio ainda carrega seus timestamps para fechar o lote anterior, mas não
        // precisa alocar/copiar 3s de samples que nunca serão enviados ao modelo.
        let samples = rms > audibleThreshold
            ? Array(UnsafeBufferPointer(start: channel, count: count))
            : []
        return MeetingAudioChunk(
            source: source,
            samples: samples,
            startTime: start,
            endTime: end
        )
    }

    private func takeBatch() -> MeetingAudioChunk? {
        guard let start = batchStart, !batchSamples.isEmpty else { return nil }
        let chunk = MeetingAudioChunk(
            source: source,
            samples: batchSamples,
            startTime: start,
            endTime: batchEnd
        )
        batchSamples = []
        batchSamples.reserveCapacity(Int(sampleRate * maxBatchSeconds))
        batchStart = nil
        batchEnd = 0
        return chunk
    }

    private enum RecordedAudioError: LocalizedError {
        case unsupportedFormat(sampleRate: Double, channels: AVAudioChannelCount)
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let sampleRate, let channels):
                return "Formato de áudio inesperado: \(Int(sampleRate)) Hz, \(channels) canal(is)."
            case .bufferAllocationFailed:
                return "Não foi possível alocar o buffer de leitura do áudio."
            }
        }
    }
}
