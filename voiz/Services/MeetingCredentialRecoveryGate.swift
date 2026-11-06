import Foundation

/// The queue and unfinished session stay untouched until credential access succeeds.
/// Kept independent of recording services so startup races can be tested without audio or files.
@MainActor
enum MeetingCredentialRecoveryGate {
    static func settingsForAI(preferences: AppSettings? = nil,
                              load: () async throws -> AppSettings) async throws -> AppSettings {
        try Task.checkCancellation()
        let verified = try await load()
        try Task.checkCancellation()
        guard var settings = preferences else { return verified }
        settings.openAIKey = verified.openAIKey
        settings.anthropicKey = verified.anthropicKey
        settings.xaiKey = verified.xaiKey
        settings.geminiKey = verified.geminiKey
        settings.customKey = verified.customKey
        return settings
    }

    static func releaseQueuedClaims(_ queuedIDs: [UUID], current: UUID?, inFlight: inout Set<UUID>) {
        // Each queue contains only claims acquired by its owner. Never release active
        // processing or another view model's reservations during owner destruction.
        for identifier in queuedIDs where identifier != current { inFlight.remove(identifier) }
    }

    static func hasActiveWork(processingIDs: Set<UUID>, queuedIDs: [UUID], waitingForCredentials: Bool) -> Bool {
        // Paused recovery remains queued but must not indefinitely prevent quitting or updates.
        // Other manual work not in that queue still protects the app from interruption.
        !(waitingForCredentials ? processingIDs.subtracting(queuedIDs) : processingIDs).isEmpty
    }

    static func runNext(
        loadCredentials: () async -> Bool,
        takeNext: () -> UUID?,
        process: (UUID) async -> Void
    ) async -> Bool {
        guard await loadCredentials(), !Task.isCancelled, let identifier = takeNext() else { return false }
        await process(identifier)
        return true
    }
}
