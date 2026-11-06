import Foundation

/// Portable presentation/language preferences only. This DTO neither starts Sync nor
/// serializes AppSettings: credentials, endpoints, profiles and machine choices stay local.
struct SyncPreferences: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var interfaceLanguage: AppSettings.InterfaceLanguage
    var appearance: AppSettings.InterfaceAppearance
    var selectedLanguage: Language
    var notesLanguage: AppSettings.NotesLanguage
    var showConfidence: Bool

    enum ValidationError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    init(snapshot settings: AppSettings) {
        schemaVersion = Self.currentSchemaVersion
        interfaceLanguage = settings.interfaceLanguage
        appearance = settings.appearance
        selectedLanguage = settings.selectedLanguage
        notesLanguage = settings.notesLanguage
        showConfidence = settings.showConfidence
    }

    /// Applying is explicit and changes only the allowlist, never resets the destination.
    /// Language choices do not select providers/models, enable features or grant permissions.
    func apply(to settings: inout AppSettings) throws {
        try validateVersion()
        settings.interfaceLanguage = interfaceLanguage
        settings.appearance = appearance
        settings.selectedLanguage = selectedLanguage
        settings.notesLanguage = notesLanguage
        settings.showConfidence = showConfidence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, interfaceLanguage, appearance, selectedLanguage, notesLanguage, showConfidence
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unexpected portable preference fields"))
        }
        schemaVersion = version
        interfaceLanguage = try container.decode(AppSettings.InterfaceLanguage.self, forKey: .interfaceLanguage)
        appearance = try container.decode(AppSettings.InterfaceAppearance.self, forKey: .appearance)
        selectedLanguage = try container.decode(Language.self, forKey: .selectedLanguage)
        notesLanguage = try container.decode(AppSettings.NotesLanguage.self, forKey: .notesLanguage)
        showConfidence = try container.decode(Bool.self, forKey: .showConfidence)
    }

    func encode(to encoder: Encoder) throws {
        try validateVersion()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(interfaceLanguage, forKey: .interfaceLanguage)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(selectedLanguage, forKey: .selectedLanguage)
        try container.encode(notesLanguage, forKey: .notesLanguage)
        try container.encode(showConfidence, forKey: .showConfidence)
    }

    private func validateVersion() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedVersion(schemaVersion)
        }
    }
}
