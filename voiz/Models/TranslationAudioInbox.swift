import Foundation

/// A recording owns this inbox. Capture yields synchronously while holding its tap
/// lock; stopping capture then finishing this stream is an ordered end-of-audio fence.
nonisolated final class TranslationAudioInbox: @unchecked Sendable {
    enum Failure: Error, Equatable { case overloaded }
    let stream: AsyncThrowingStream<[Float], Error>
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private let lock = NSLock()
    private let maximumQueuedSamples: Int
    private let onOverflow: @Sendable () -> Void
    private var queuedSamples = 0
    private var accepting = true

    init(maximumQueuedSamples: Int = 16_000 * 60, onOverflow: @escaping @Sendable () -> Void = {}) {
        precondition(maximumQueuedSamples > 0)
        self.maximumQueuedSamples = maximumQueuedSamples
        self.onOverflow = onOverflow
        let pair = AsyncThrowingStream<[Float], Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    /// Fast/nonblocking: never run VAD, ASR or UI work on the audio tap.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let overflow = lock.withLock { () -> Bool in
            guard accepting else { return false }
            guard samples.count <= maximumQueuedSamples - queuedSamples else {
                accepting = false
                continuation.finish(throwing: Failure.overloaded)
                return true
            }
            queuedSamples += samples.count
            continuation.yield(samples)
            return false
        }
        if overflow { onOverflow() }
    }

    func consumed(_ count: Int) {
        lock.withLock { queuedSamples = max(0, queuedSamples - count) }
    }

    func finish() {
        lock.withLock {
            guard accepting else { return }
            accepting = false
            continuation.finish()
        }
    }
}
