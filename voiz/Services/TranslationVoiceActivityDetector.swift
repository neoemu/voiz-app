import Foundation
import FluidAudio

/// A recording owns its recurrent state; only the loaded model is shared. The caller
/// supplies consecutive 16 kHz mono frames and owns speech segmentation thresholds.
actor TranslationVoiceActivityDetector {
    nonisolated static let frameSize = 4_096

    nonisolated enum Failure: Error, Sendable {
        case emptyFrame
        case oversizedFrame
        case nonFiniteSamples
        case overlappingFrames
        case invalidProbability
    }

    private let manager: VadManager
    private var state = VadStreamState.initial()
    private var processingFrame = false

    private init(manager: VadManager) {
        self.manager = manager
    }

    /// Prepare before starting capture. A missing model may be downloaded by the
    /// existing FluidAudio loader; failures propagate without an energy-only fallback.
    nonisolated static func make() async throws -> TranslationVoiceActivityDetector {
        try Task.checkCancellation()
        let manager = try await ModelCache.shared.load()
        try Task.checkCancellation()
        return TranslationVoiceActivityDetector(manager: manager)
    }

    /// Full frames contain 4096 samples; only the final frame may be shorter.
    /// Oversized input must never reach FluidAudio, which would silently truncate it.
    func probability(for samples: [Float]) async throws -> Float {
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw Failure.emptyFrame }
        guard samples.count <= Self.frameSize else { throw Failure.oversizedFrame }
        guard samples.allSatisfy(\.isFinite) else { throw Failure.nonFiniteSamples }
        // Actor methods are reentrant across the model await. Reject concurrent use
        // rather than running two frames from the same stale recurrent state.
        guard !processingFrame else { throw Failure.overlappingFrames }
        processingFrame = true
        defer { processingFrame = false }

        let result = try await manager.processStreamingChunk(samples, state: state)
        try Task.checkCancellation()
        guard result.probability.isFinite, (0...1).contains(result.probability) else {
            throw Failure.invalidProbability
        }
        state = result.state
        return result.probability
    }

    /// Coalesces initial loads without retaining any recording's VadStreamState.
    /// Cancellation of a caller does not cancel another recording's shared load.
    private actor ModelCache {
        static let shared = ModelCache()
        private var manager: VadManager?
        private var loading: Task<VadManager, Error>?

        func load() async throws -> VadManager {
            if let manager { return manager }
            if let loading { return try await loading.value }
            let task = Task { try await VadManager(config: VadConfig(debugMode: false)) }
            loading = task
            do {
                let loaded = try await task.value
                manager = loaded
                loading = nil
                return loaded
            } catch {
                loading = nil
                throw error
            }
        }
    }
}
