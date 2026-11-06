#if DEBUG
import AVFoundation
import Foundation

nonisolated enum BenchmarkAudioLoaderError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case emptyFile(String)
    case conversionFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .openFailed(let p): return "Falha ao abrir áudio: \(URL(fileURLWithPath: p).lastPathComponent)"
        case .emptyFile(let p): return "Áudio vazio: \(URL(fileURLWithPath: p).lastPathComponent)"
        case .conversionFailed(let p): return "Conversão de áudio falhou: \(URL(fileURLWithPath: p).lastPathComponent)"
        }
    }
}

/// Caixa `@unchecked Sendable` só para a closure de `AVAudioConverter` (API síncrona,
/// buffer local não cruza isolamento de verdade — evita warning Swift 6).
///
/// `nonisolated` no tipo e no `init`: o default do target é MainActor, e o loader que
/// instancia a caixa é `nonisolated` — sem isto vira futuro erro Swift 6
/// (`call to main actor-isolated initializer … in a synchronous nonisolated context`).
private nonisolated final class PCMBufferBox: @unchecked Sendable {
    nonisolated let buffer: AVAudioPCMBuffer
    nonisolated init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// WAV → mono float 16 kHz. `nonisolated` para o actor do runner.
nonisolated enum BenchmarkAudioLoader {
    nonisolated static let targetSampleRate: Double = TranscriptionAudio.defaultSampleRate

    nonisolated static func load(url: URL) throws -> TranscriptionAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw BenchmarkAudioLoaderError.openFailed(url.path)
        }

        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            throw BenchmarkAudioLoaderError.emptyFile(url.path)
        }

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let targetFormat else {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }

        if sourceFormat.commonFormat == .pcmFormatFloat32,
           sourceFormat.channelCount == 1,
           abs(sourceFormat.sampleRate - targetSampleRate) < 1,
           let channel = sourceBuffer.floatChannelData?[0]
        {
            let n = Int(sourceBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channel, count: n))
            return TranscriptionAudio(samples: samples, sampleRate: targetSampleRate)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let estimated = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 32
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(estimated, 1)) else {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }

        // Converter exige closure @Sendable; o buffer é local e a chamada é síncrona.
        let sourceBox = PCMBufferBox(sourceBuffer)
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: targetBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBox.buffer
        }

        if status == .error || error != nil {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }
        guard let channel = targetBuffer.floatChannelData?[0] else {
            throw BenchmarkAudioLoaderError.conversionFailed(url.path)
        }
        let n = Int(targetBuffer.frameLength)
        guard n > 0 else {
            throw BenchmarkAudioLoaderError.emptyFile(url.path)
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: n))
        return TranscriptionAudio(samples: samples, sampleRate: targetSampleRate)
    }
}
#endif
