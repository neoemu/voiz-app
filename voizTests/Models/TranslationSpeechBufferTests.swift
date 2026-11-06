import Foundation
import Testing

@Suite("Translation speech frames and phrase boundaries")
struct TranslationSpeechBufferTests {
    @Test func arbitraryPacketsPreserveEverySampleAndFinishThePartialFrameOnce() {
        var framer = TranslationAudioFramer()
        let samples = (0..<10_007).map(Float.init)
        var frames: [[Float]] = []
        for range in [0..<17, 17..<4_700, 4_700..<4_701, 4_701..<10_007] {
            frames += framer.append(Array(samples[range]))
            #expect(framer.bufferedSampleCount < 4096)
        }
        #expect(frames.map(\.count) == [4096, 4096])
        let tail = framer.finish()
        #expect(tail?.count == 1815)
        #expect(frames.flatMap { $0 } + (tail ?? []) == samples)
        let secondFinish = framer.finish()
        let late = framer.append([123])
        #expect(secondFinish == nil)
        #expect(late.isEmpty)
        #expect(framer.bufferedSampleCount == 0)
    }

    @Test func framerClearStartsAnIndependentRecording() {
        var framer = TranslationAudioFramer(frameSize: 4)
        _ = framer.append([1, 2, 3])
        framer.clear()
        let frames = framer.append([4, 5, 6, 7, 8])
        let tail = framer.finish()
        #expect(frames == [[4, 5, 6, 7]])
        #expect(tail == [8])
        framer.clear()
        let next = framer.append([9])
        let nextTail = framer.finish()
        #expect(next.isEmpty)
        #expect(nextTail == [9])
    }

    @Test func silenceAndLoudNonSpeechRemainBoundedWithoutASRRequests() {
        var segmenter = TranslationSpeechSegmenter()
        for index in 0..<100 {
            let packet = [Float](repeating: index.isMultiple(of: 2) ? 0 : 0.8, count: 4096)
            let chunks = segmenter.append(packet, probability: 0.1)
            #expect(chunks.isEmpty)
            #expect(segmenter.bufferedSampleCount <= 4096)
        }
        let finished = segmenter.finish()
        #expect(finished.isEmpty)
        #expect(segmenter.bufferedSampleCount == 0)
    }

    @Test func evenVeryShortQuietPositiveSpeechIsKept() {
        var segmenter = TranslationSpeechSegmenter(preRollSeconds: 0)
        let speech: [Float] = [0.000_001, -0.000_001]
        let live = segmenter.append(speech, probability: 0.9)
        let final = segmenter.finish()
        #expect(live.isEmpty)
        #expect(final == [speech])
    }

    @Test func onsetKeepsOnlyPrerollAndEndpointKeepsPostrollWithoutOverlap() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0.2,
            endpointSilenceSeconds: 0.6, postRollSeconds: 0.2)
        _ = segmenter.append((0..<100).map(Float.init), probability: 0.1)
        _ = segmenter.append((100..<110).map(Float.init), probability: 0.9)
        let first = segmenter.append((110..<170).map(Float.init), probability: 0.1)
        #expect(first == [(80..<130).map(Float.init)])
        #expect(segmenter.bufferedSampleCount == 20)
        _ = segmenter.append((170..<180).map(Float.init), probability: 0.9)
        let second = segmenter.finish()
        #expect(second == [(150..<180).map(Float.init)])
        #expect(Set(first.flatMap { $0 }).isDisjoint(with: Set(second.flatMap { $0 })))
    }

    @Test func briefPauseAndSoftContinuationRemainInOnePhrase() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0,
            endpointSilenceSeconds: 0.6, postRollSeconds: 0.2)
        let first = [Float](repeating: 1, count: 30)
        let pause = [Float](repeating: 2, count: 40)
        let continuation = [Float](repeating: 3, count: 30)
        _ = segmenter.append(first, probability: 0.8)
        let noEndpoint = segmenter.append(pause, probability: 0.1)
        let stillOpen = segmenter.append(continuation, probability: 0.4)
        let closed = segmenter.append([Float](repeating: 4, count: 60), probability: 0.1)
        #expect(noEndpoint.isEmpty)
        #expect(stillOpen.isEmpty)
        #expect(closed == [first + pause + continuation + [Float](repeating: 4, count: 20)])
        let weakerNewOnset = segmenter.append([Float](repeating: 5, count: 30), probability: 0.4)
        let final = segmenter.finish()
        #expect(weakerNewOnset.isEmpty)
        #expect(final.isEmpty)
    }

    @Test func continuousSpeechIsPartitionedExactlyAndMemoryStaysBounded() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0,
            endpointSilenceSeconds: 0.3, postRollSeconds: 0.1, maximumPhraseSeconds: 1)
        let speech = (0..<1000).map { Float($0 + 1) }
        let chunks = segmenter.append(speech, probability: 0.9)
        let final = segmenter.finish()
        #expect(chunks.count == 10)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks.flatMap { $0 } + final.flatMap { $0 } == speech)
        #expect(final.isEmpty)
        #expect(segmenter.bufferedSampleCount == 0)
    }

    @Test func maximumLengthPrefersAQuietBoundaryAndPreservesTheRemainder() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0,
            endpointSilenceSeconds: 0.6, postRollSeconds: 0.2, maximumPhraseSeconds: 3)
        var speech = (0..<550).map { Float($0 + 1) }
        for index in 260..<280 { speech[index] = 0 }
        let chunks = segmenter.append(speech, probability: 0.9)
        #expect(chunks.first?.count == 276)
        #expect(segmenter.bufferedSampleCount <= 300)
        let final = segmenter.finish()
        #expect(chunks.flatMap { $0 } + final.flatMap { $0 } == speech)
        #expect((chunks + final).allSatisfy { !$0.isEmpty && $0.count <= 300 })
    }

    @Test func uniformlyQuietSpeechDoesNotCreateAnArtificialTinyTail() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0,
            endpointSilenceSeconds: 0.3, postRollSeconds: 0.1, maximumPhraseSeconds: 1)
        let speech = [Float](repeating: 0.000_001, count: 100)
        let chunks = segmenter.append(speech, probability: 0.9)
        let final = segmenter.finish()
        #expect(chunks == [speech])
        #expect(final.isEmpty)
    }

    @Test func capacitySplitKeepsHysteresisAndDoesNotEmitASilenceOnlyTail() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0,
            endpointSilenceSeconds: 0.3, postRollSeconds: 0.1, maximumPhraseSeconds: 1)
        let first = segmenter.append([Float](repeating: 1, count: 100), probability: 0.9)
        let soft = segmenter.append([Float](repeating: 2, count: 20), probability: 0.4)
        let tail = segmenter.append([Float](repeating: 0, count: 30), probability: 0.1)
        let done = segmenter.finish()
        #expect(first == [[Float](repeating: 1, count: 100)])
        #expect(soft.isEmpty)
        #expect(tail == [[Float](repeating: 2, count: 20) + [Float](repeating: 0, count: 10)])
        #expect(done.isEmpty)

        segmenter.clear()
        _ = segmenter.append([Float](repeating: 1, count: 100), probability: 0.9)
        let silent = segmenter.append([Float](repeating: 0, count: 30), probability: 0.1)
        let silentFinish = segmenter.finish()
        #expect(silent.isEmpty)
        #expect(silentFinish.isEmpty)
    }

    @Test func longPrerollDoesNotBecomeASilenceOnlyCapacityChunk() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0.9,
            endpointSilenceSeconds: 0.3, postRollSeconds: 0.1, maximumPhraseSeconds: 1)
        _ = segmenter.append([Float](repeating: 0, count: 90), probability: 0.1)
        let result = segmenter.append([Float](repeating: 1, count: 10), probability: 0.9)
        #expect(result == [[Float](repeating: 0, count: 90) + [Float](repeating: 1, count: 10)])
        let final = segmenter.finish()
        #expect(final.isEmpty)
    }

    @Test func finishFlushesOnlyPendingSpeechAndIsIdempotentAcrossRecordings() {
        var segmenter = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0,
            endpointSilenceSeconds: 0.6, postRollSeconds: 0.1)
        _ = segmenter.append([1, 2, 3], probability: 0.9)
        _ = segmenter.append([Float](repeating: 0, count: 15), probability: 0.1)
        let first = segmenter.finish()
        let duplicate = segmenter.finish()
        let late = segmenter.append([99], probability: 1)
        #expect(first == [[1, 2, 3] + [Float](repeating: 0, count: 10)])
        #expect(duplicate.isEmpty)
        #expect(late.isEmpty)

        segmenter.clear()
        _ = segmenter.append([8, 9], probability: 0.9)
        let next = segmenter.finish()
        var fresh = TranslationSpeechSegmenter(sampleRate: 100, preRollSeconds: 0)
        _ = fresh.append([8, 9], probability: 0.9)
        let freshResult = fresh.finish()
        #expect(next == [[8, 9]])
        #expect(next == freshResult)
    }
}
