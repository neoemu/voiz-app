import Foundation

/// Shared by microphone capture and the synthetic file probe. It owns all recurrent
/// state for one recording and never sends audio without detected speech to ASR.
actor TranslationSpeechPipeline {
    enum Failure: Error { case closed, overlappingInput }
    private let detector: TranslationVoiceActivityDetector
    private var framer = TranslationAudioFramer()
    private var segmenter = TranslationSpeechSegmenter()
    private var closed = false
    private var processing = false

    private init(detector: TranslationVoiceActivityDetector) { self.detector = detector }

    nonisolated static func make() async throws -> TranslationSpeechPipeline {
        let detector = try await TranslationVoiceActivityDetector.make()
        return TranslationSpeechPipeline(detector: detector)
    }

    func append(_ samples: [Float]) async throws -> [[Float]] {
        guard !closed else { throw Failure.closed }
        guard !processing else { throw Failure.overlappingInput }
        processing = true
        defer { processing = false }
        var phrases: [[Float]] = []
        for frame in framer.append(samples) {
            let probability = try await detector.probability(for: frame)
            phrases += segmenter.append(frame, probability: probability)
        }
        return phrases
    }

    func finish() async throws -> [[Float]] {
        guard !closed else { return [] }
        guard !processing else { throw Failure.overlappingInput }
        closed = true
        var phrases: [[Float]] = []
        if let frame = framer.finish() {
            let probability = try await detector.probability(for: frame)
            phrases += segmenter.append(frame, probability: probability)
        }
        return phrases + segmenter.finish()
    }
}
