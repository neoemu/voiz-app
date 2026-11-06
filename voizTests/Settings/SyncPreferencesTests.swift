import Foundation
import Testing

@Suite("Sync — preferências portáveis sem credenciais")
struct SyncPreferencesTests {
    private func source() -> AppSettings {
        var settings = AppSettings.fullyCustomizedForTests
        settings.interfaceLanguage = .french
        settings.appearance = .light
        settings.selectedLanguage = .japanese
        settings.notesLanguage = .english
        settings.showConfidence = false
        return settings
    }

    private func object() throws -> [String: Any] {
        let data = try JSONEncoder().encode(SyncPreferences(snapshot: source()))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Snapshot exporta exatamente cinco preferências e versão, sem dados locais")
    func exactPortableJSON() throws {
        let original = source()
        let snapshot = SyncPreferences(snapshot: original)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == """
        {"appearance":"light","interfaceLanguage":"fr","notesLanguage":"en","schemaVersion":1,"selectedLanguage":"ja","showConfidence":false}
        """)
        for secret in [original.openAIKey, original.anthropicKey, original.xaiKey,
                       original.geminiKey, original.customKey, original.customBaseURL, original.customModel] {
            #expect(!secret.isEmpty)
            #expect(!json.contains(secret))
        }
        #expect(try JSONDecoder().decode(SyncPreferences.self, from: data) == snapshot)
    }

    @Test("Aplicar altera somente a allowlist e preserva todos os outros campos do destino")
    func applyingPreservesDestinationIncludingSecretsAndMachineChoices() throws {
        var destination = AppSettings.fullyCustomizedForTests
        destination.interfaceLanguage = .system
        destination.appearance = .dark
        destination.selectedLanguage = .portuguese
        destination.notesLanguage = .spoken
        destination.showConfidence = true
        destination.openAIKey = "SYNTHETIC_DESTINATION_OPENAI"
        destination.anthropicKey = "SYNTHETIC_DESTINATION_ANTHROPIC"
        destination.xaiKey = "SYNTHETIC_DESTINATION_XAI"
        destination.geminiKey = "SYNTHETIC_DESTINATION_GEMINI"
        destination.customKey = "SYNTHETIC_DESTINATION_CUSTOM"
        destination.customBaseURL = "http://localhost:9123/private-endpoint"
        destination.customModel = "destination-model"
        destination.dictationVocabulary = "PRIVATE_LOCAL_VOCABULARY"
        destination.calendarSelection.disabledAccountIDs = ["PRIVATE_LOCAL_ACCOUNT"]
        let original = destination
        let snapshot = SyncPreferences(snapshot: source())
        try snapshot.apply(to: &destination)

        #expect(destination.interfaceLanguage == .french)
        #expect(destination.appearance == .light)
        #expect(destination.selectedLanguage == .japanese)
        #expect(destination.notesLanguage == .english)
        #expect(destination.showConfidence == false)
        #expect(destination.openAIKey == original.openAIKey)
        #expect(destination.anthropicKey == original.anthropicKey)
        #expect(destination.xaiKey == original.xaiKey)
        #expect(destination.geminiKey == original.geminiKey)
        #expect(destination.customKey == original.customKey)
        #expect(destination.customBaseURL == original.customBaseURL)
        #expect(destination.customModel == original.customModel)
        #expect(destination.calendarSelection == original.calendarSelection)
        #expect(destination.pushToTalkShortcut == original.pushToTalkShortcut)
        #expect(destination.transcriptionSelections == original.transcriptionSelections)
        // Restore the five allowed differences to detect changes to ANY other stored field,
        // including new local fields added to AppSettings in a later release.
        var restored = destination
        restored.interfaceLanguage = original.interfaceLanguage
        restored.appearance = original.appearance
        restored.selectedLanguage = original.selectedLanguage
        restored.notesLanguage = original.notesLanguage
        restored.showConfidence = original.showConfidence
        #expect(restored == original)
        let applied = destination
        try snapshot.apply(to: &destination)
        #expect(destination == applied)
    }

    @Test("Versões não suportadas falham antes dos campos e antes de qualquer aplicação", arguments: [-1, 0, 2, 99])
    func unsupportedVersionIsAtomic(version: Int) throws {
        let data = Data("{\"schemaVersion\":\(version),\"interfaceLanguage\":false}".utf8)
        #expect(throws: SyncPreferences.ValidationError.unsupportedVersion(version)) {
            try JSONDecoder().decode(SyncPreferences.self, from: data)
        }
        var snapshot = SyncPreferences(snapshot: source())
        snapshot.schemaVersion = version
        var destination = AppSettings.fullyCustomizedForTests
        let original = destination
        #expect(throws: SyncPreferences.ValidationError.unsupportedVersion(version)) {
            try snapshot.apply(to: &destination)
        }
        #expect(destination == original)
        #expect(throws: SyncPreferences.ValidationError.unsupportedVersion(version)) {
            try JSONEncoder().encode(snapshot)
        }
    }

    @Test("Payload incompleto ou valores inválidos não viram defaults locais")
    func malformedPreferencesAreRejected() throws {
        let valid = try object()
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SyncPreferences.self, from: data)
            }
        }
        let invalidValues: [(String, Any)] = [
            ("schemaVersion", true), ("schemaVersion", "1"),
            ("interfaceLanguage", "unknown-language"), ("appearance", "unknown-appearance"),
            ("selectedLanguage", "auto"), ("notesLanguage", "unknown-language"),
            ("showConfidence", "false"), ("showConfidence", 0), ("showConfidence", NSNull())
        ]
        for (key, value) in invalidValues {
            var malformed = valid
            malformed[key] = value
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SyncPreferences.self, from: data)
            }
        }
    }

    @Test("Campos fora da allowlist são recusados, inclusive segredos e identidade")
    func unapprovedFieldsAreRejected() throws {
        for key in ["openAIKey", "anthropicKey", "xaiKey", "geminiKey", "customKey", "customBaseURL",
                    "customModel", "profile", "licenseKey", "recordingsPath", "hotKey",
                    "calendarSelection", "transcriptionEngine", "futurePreference"] {
            var extended = try object()
            extended[key] = "SYNTHETIC_LOCAL_ONLY"
            let data = try JSONSerialization.data(withJSONObject: extended)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(SyncPreferences.self, from: data)
            }
        }
    }
}
