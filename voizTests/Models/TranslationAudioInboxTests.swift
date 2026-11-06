import Foundation
import Testing

@Suite("Translation capture delivery")
struct TranslationAudioInboxTests {
    @Test func endFencePreservesEveryAdmittedFrameInOrder() async throws {
        let inbox = TranslationAudioInbox()
        let producer = Task.detached {
            for index in 0..<100 { inbox.append([Float(index)]) }
            inbox.finish()
            inbox.append([999])
            inbox.finish()
        }
        var received: [Float] = []
        for try await frame in inbox.stream {
            inbox.consumed(frame.count)
            received += frame
        }
        await producer.value
        #expect(received == (0..<100).map(Float.init))
    }

    @Test func overloadIsExplicitAndKeepsAlreadyQueuedAudio() async {
        let inbox = TranslationAudioInbox(maximumQueuedSamples: 3)
        inbox.append([1, 2])
        inbox.append([3, 4])
        var received: [Float] = []
        var failed = false
        do {
            for try await frame in inbox.stream { received += frame }
        } catch TranslationAudioInbox.Failure.overloaded { failed = true }
        catch { Issue.record("Unexpected inbox error") }
        #expect(received == [1, 2])
        #expect(failed)
    }

    @Test func consumedFramesReleaseTheQueueBudget() async throws {
        let inbox = TranslationAudioInbox(maximumQueuedSamples: 2)
        var iterator = inbox.stream.makeAsyncIterator()
        inbox.append([1, 2])
        let first = try await iterator.next()
        #expect(first == [1, 2])
        inbox.consumed(2)
        inbox.append([3, 4])
        inbox.finish()
        let last = try await iterator.next()
        let end = try await iterator.next()
        #expect(last == [3, 4])
        #expect(end == nil)
    }

    @Test func oldCaptureCannotWriteIntoTheNextRecording() async throws {
        let old = TranslationAudioInbox()
        old.append([1])
        old.finish()
        let next = TranslationAudioInbox()
        old.append([99])
        next.append([2])
        next.finish()
        var first: [Float] = [], second: [Float] = []
        for try await frame in old.stream { first += frame }
        for try await frame in next.stream { second += frame }
        #expect(first == [1])
        #expect(second == [2])
    }
}
