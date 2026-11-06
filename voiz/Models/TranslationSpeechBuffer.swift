import Foundation

/// Converts arbitrary capture packets into fixed-size VAD frames. The final partial
/// frame is returned once; callers may pad it for inference without adding padding
/// to the original samples passed to the phrase segmenter.
nonisolated struct TranslationAudioFramer {
    let frameSize: Int
    private var pending: [Float] = []
    private var closed = false

    init(frameSize: Int = 4096) {
        precondition(frameSize > 0)
        self.frameSize = frameSize
    }

    var bufferedSampleCount: Int { pending.count }

    mutating func append(_ samples: [Float]) -> [[Float]] {
        guard !closed, !samples.isEmpty else { return [] }
        var frames: [[Float]] = []
        var offset = 0
        while offset < samples.count {
            let count = min(frameSize - pending.count, samples.count - offset)
            pending.append(contentsOf: samples[offset..<(offset + count)])
            offset += count
            if pending.count == frameSize {
                frames.append(pending)
                pending = []
            }
        }
        return frames
    }

    mutating func finish() -> [Float]? {
        guard !closed else { return nil }
        closed = true
        let tail = pending
        pending = []
        return tail.isEmpty ? nil : tail
    }

    mutating func clear() {
        pending = []
        closed = false
    }
}

/// Builds phrases from VAD-classified frames, keeping context around speech instead
/// of sending every timer tick to ASR. Memory retained here is bounded by one phrase
/// or the pre-roll ring; emitted arrays belong to the caller's work queue.
///
/// A positive VAD frame is never rejected for being short or quiet. At a forced
/// duration split, samples are partitioned without overlap so that no recognized
/// word needs an unsafe text-based deduplication heuristic.
nonisolated struct TranslationSpeechSegmenter {
    let sampleRate: Double
    let entryThreshold: Float
    let continuationThreshold: Float
    let preRollSamples: Int
    let endpointSilenceSamples: Int
    let postRollSamples: Int
    let maximumPhraseSamples: Int

    private var preRoll: [Float] = []
    private var phrase: [Float] = []
    private var inUtterance = false
    private var firstSpeechStart: Int?
    private var lastSpeechEnd = 0
    private var quietSamples = 0
    private var closed = false

    init(sampleRate: Double = 16_000,
         entryThreshold: Float = 0.5,
         continuationThreshold: Float = 0.35,
         preRollSeconds: Double = 0.256,
         endpointSilenceSeconds: Double = 0.6,
         postRollSeconds: Double = 0.256,
         maximumPhraseSeconds: Double = 12) {
        precondition(sampleRate.isFinite && sampleRate > 0)
        precondition(entryThreshold.isFinite && (0...1).contains(entryThreshold))
        precondition(continuationThreshold.isFinite && (0...entryThreshold).contains(continuationThreshold))
        precondition(preRollSeconds.isFinite && preRollSeconds >= 0)
        precondition(postRollSeconds.isFinite && postRollSeconds >= 0)
        precondition(endpointSilenceSeconds.isFinite && endpointSilenceSeconds > 0)
        precondition(maximumPhraseSeconds.isFinite && maximumPhraseSeconds > 0)
        precondition(preRollSeconds < maximumPhraseSeconds)
        precondition(postRollSeconds <= endpointSilenceSeconds && endpointSilenceSeconds <= maximumPhraseSeconds)
        self.sampleRate = sampleRate
        self.entryThreshold = entryThreshold
        self.continuationThreshold = continuationThreshold
        preRollSamples = max(0, Int((sampleRate * preRollSeconds).rounded()))
        endpointSilenceSamples = max(1, Int((sampleRate * endpointSilenceSeconds).rounded()))
        postRollSamples = max(0, Int((sampleRate * postRollSeconds).rounded()))
        maximumPhraseSamples = max(1, Int((sampleRate * maximumPhraseSeconds).rounded()))
        precondition(preRollSamples < maximumPhraseSamples)
    }

    var bufferedSampleCount: Int { preRoll.count + phrase.count }

    mutating func append(_ samples: [Float], probability: Float) -> [[Float]] {
        guard !closed, !samples.isEmpty else { return [] }
        var emitted: [[Float]] = []
        var offset = 0

        while offset < samples.count {
            let threshold = inUtterance ? continuationThreshold : entryThreshold
            let speech = probability.isFinite && probability >= threshold
            if !inUtterance {
                guard speech else {
                    retainPreRoll(samples[offset...])
                    break
                }
                phrase = preRoll
                preRoll = []
                inUtterance = true
                firstSpeechStart = nil
                lastSpeechEnd = 0
                quietSamples = 0
            }

            // Process large input arrays incrementally: a single append cannot grow
            // the retained phrase past the configured limit.
            let capacity = maximumPhraseSamples - phrase.count
            let untilEndpoint = speech ? samples.count - offset : endpointSilenceSamples - quietSamples
            let count = min(samples.count - offset, capacity, untilEndpoint)
            if count > 0 {
                if speech && firstSpeechStart == nil { firstSpeechStart = phrase.count }
                phrase.append(contentsOf: samples[offset..<(offset + count)])
                offset += count
                if speech {
                    lastSpeechEnd = phrase.count
                    quietSamples = 0
                } else {
                    quietSamples += count
                }
            }

            if !speech && quietSamples >= endpointSilenceSamples {
                endUtterance(into: &emitted)
            } else if phrase.count == maximumPhraseSamples {
                splitAtCapacity(into: &emitted)
            }
        }
        return emitted
    }

    mutating func finish() -> [[Float]] {
        guard !closed else { return [] }
        var emitted: [[Float]] = []
        if inUtterance { endUtterance(into: &emitted) }
        preRoll = []
        closed = true
        return emitted
    }

    mutating func clear() {
        preRoll = []
        phrase = []
        inUtterance = false
        firstSpeechStart = nil
        lastSpeechEnd = 0
        quietSamples = 0
        closed = false
    }

    private mutating func retainPreRoll(_ samples: ArraySlice<Float>) {
        guard preRollSamples > 0 else { preRoll = []; return }
        if samples.count >= preRollSamples {
            preRoll = Array(samples.suffix(preRollSamples))
        } else {
            preRoll.append(contentsOf: samples)
            if preRoll.count > preRollSamples { preRoll.removeFirst(preRoll.count - preRollSamples) }
        }
    }

    private mutating func endUtterance(into emitted: inout [[Float]]) {
        // After an exact capacity split there may only be quiet samples left. Do
        // not manufacture a silence-only ASR request for that trailing context.
        let end = lastSpeechEnd > 0 ? min(phrase.count, lastSpeechEnd + postRollSamples) : 0
        if end > 0 { emitted.append(Array(phrase[..<end])) }
        retainPreRoll(phrase[end...])
        phrase = []
        inUtterance = false
        firstSpeechStart = nil
        lastSpeechEnd = 0
        quietSamples = 0
    }

    private mutating func splitAtCapacity(into emitted: inout [[Float]]) {
        let cut = quietBoundary() ?? phrase.count
        if lastSpeechEnd > 0 { emitted.append(Array(phrase[..<cut])) }
        phrase = Array(phrase[cut...])
        lastSpeechEnd = max(0, lastSpeechEnd - cut)
        firstSpeechStart = lastSpeechEnd > 0 ? firstSpeechStart.map { max(0, $0 - cut) } : nil
        // Keep the ongoing utterance's hysteresis and quiet timer. Requiring a new
        // onset at a duration boundary would discard soft speech in the next frame.
    }

    /// Prefer the middle of the latest quiet 80ms window within the final 2s
    /// (or final third for short configured limits). This is a cut-point heuristic,
    /// never a gate that rejects low-amplitude speech admitted by VAD.
    private func quietBoundary() -> Int? {
        let window = max(1, min(phrase.count / 4, Int((sampleRate * 0.08).rounded())))
        let step = max(1, Int((sampleRate * 0.02).rounded()))
        let lookBack = max(window, min(phrase.count / 3, Int((sampleRate * 2).rounded())))
        let referenceStart = phrase.count - lookBack
        var referenceEnergy: Double = 0
        for sample in phrase[referenceStart...] { referenceEnergy += Double(sample) * Double(sample) }
        referenceEnergy /= Double(lookBack)
        // A uniformly quiet voice is not a pause. Require a valley relative to
        // nearby audio as well as low absolute energy before moving the cut.
        guard referenceEnergy > 0 else { return nil }
        let minimumEnd = max(window, phrase.count - lookBack + window)
        for end in stride(from: phrase.count, through: minimumEnd, by: -step) {
            let start = end - window
            var energy: Double = 0
            for sample in phrase[start..<end] { energy += Double(sample) * Double(sample) }
            let meanEnergy = energy / Double(window)
            if meanEnergy <= 0.004 * 0.004 && meanEnergy <= referenceEnergy * 0.25 {
                let cut = start + max(1, window / 2)
                // With unusually long pre-roll, the quiet window may precede
                // speech onset. Never emit that context as a silence-only phrase.
                if cut > (firstSpeechStart ?? phrase.count) { return cut }
            }
        }
        return nil
    }
}
