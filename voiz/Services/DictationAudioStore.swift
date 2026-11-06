import Foundation
import AVFoundation

/// Lossless local recording, committed before ASR starts. No audio in UserDefaults/logs.
nonisolated struct DictationAudioStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voiz/DictationAudio", isDirectory: true)
    }

    func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".caf") }
    func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }

    func save(_ samples: [Float], id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(id.uuidString + ".tmp.caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw CocoaError(.fileWriteUnknown) }
        // Small writes avoid another recording-sized allocation. Close the CAF before rename.
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            let block = 16_000 * 10
            for start in stride(from: 0, to: samples.count, by: block) {
                let count = min(block, samples.count - start)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let target = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    target.update(from: source.baseAddress!.advanced(by: start), count: count)
                }
                try file.write(from: buffer)
            }
        }
        try FileManager.default.moveItem(at: temporary, to: url(for: id))
    }

    func load(_ id: UUID) throws -> [Float] {
        let file = try AVAudioFile(forReading: url(for: id), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160_000)
        else { throw CocoaError(.fileReadUnknown) }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }

    func remove(_ id: UUID) throws {
        guard exists(id) else { return }
        try FileManager.default.removeItem(at: url(for: id))
    }
}
