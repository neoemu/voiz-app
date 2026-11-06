import Foundation
import Testing

@Suite("Transcription defaults and saved preferences")
struct TranscriptionSettingsPersistenceTests {
    @Test("Fresh install defaults to Apple Speech for dictation and Quality meetings")
    func freshInstall() throws {
        let suite = "voiz-tests-transcription-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, credentials: MockSettingsCredentialsStore()).load()
        #expect(settings.transcriptionEngine == .apple)
        for useCase in [TranscriptionUseCase.dictation, .meetingFinal] {
            let plan = TranscriptionRouter().plan(for: TranscriptionRoutingContext(
                useCase: useCase, language: settings.selectedLanguage.transcriptionLanguage,
                hardware: TranscriptionHardwareProfile(architecture: .appleSilicon, hasNeuralEngine: true,
                    physicalMemoryBytes: 32 * 1024 * 1024 * 1024), selection: settings.transcriptionSelection(for: useCase)
            ))
            #expect(plan.primary?.engine == .appleSpeechAnalyzer)
            #expect(plan.primary?.model == settings.selectedLanguage.appleSpeechLocale.model)
        }
    }

    @Test("Every saved engine survives reopening settings", arguments: AppSettings.TranscriptionEngine.allCases)
    func savedChoice(engine: AppSettings.TranscriptionEngine) throws {
        let suite = "voiz-tests-transcription-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = SettingsStore(defaults: defaults, credentials: MockSettingsCredentialsStore()).load()
        settings.transcriptionEngine = engine
        settings.modelSize = .medium
        SettingsStore(defaults: defaults, credentials: MockSettingsCredentialsStore()).save(settings)
        let restored = SettingsStore(defaults: defaults, credentials: MockSettingsCredentialsStore()).load()
        #expect(restored.transcriptionEngine == engine)
        #expect(restored.modelSize == .medium)
        #expect(restored == settings)
    }
}
