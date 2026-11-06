import Foundation

/// The audio tap and Stop run on different queues. A generation also prevents a late tap
/// from the previous recording from entering the next one.
nonisolated final class RecordingSampleBuffer: @unchecked Sendable {
    enum Retention: Sendable {
        case entireRecording
        case latestSamples(Int)
    }

    private let lock = NSLock()
    private let retention: Retention
    private var generation: UUID?
    private var samples: [Float] = []

    init(retention: Retention) { self.retention = retention }

    func begin() -> UUID {
        lock.withLock {
            let id = UUID()
            generation = id
            samples.removeAll(keepingCapacity: true)
            return id
        }
    }

    @discardableResult
    func append(_ incoming: [Float], generation id: UUID) -> Bool {
        lock.withLock {
            guard generation == id else { return false }
            samples.append(contentsOf: incoming)
            if case .latestSamples(let limit) = retention, samples.count > max(0, limit) {
                samples.removeFirst(samples.count - max(0, limit))
            }
            return true
        }
    }

    func finish() -> [Float] {
        lock.withLock {
            generation = nil
            let result = samples
            samples = []
            return result
        }
    }

    func snapshot() -> [Float] { lock.withLock { samples } }
}
