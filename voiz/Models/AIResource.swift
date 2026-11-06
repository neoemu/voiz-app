import Foundation

nonisolated enum AIResource: String, Sendable {
    case chat, translation, summary, chapters, speakerNames, briefing, assistant, dictationCleanup
}

extension SettingsStore {
    /// Every request uses the user-selected provider and verified provider credentials.
    func settingsForAIUse(resource: AIResource = .chat, explicitModelChoice: Bool = false) async throws -> AppSettings {
        try await settingsForCredentialUse()
    }
}
