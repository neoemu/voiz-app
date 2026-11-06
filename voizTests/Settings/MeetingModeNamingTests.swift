import Foundation
import Testing

@Suite("Meeting modes — public names and legacy persistence")
struct MeetingModeNamingTests {
    @Test("Live mode is named Ao vivo in every selector, while old saved values still decode")
    func liveLabelKeepsLegacyStorage() throws {
        let restored = try JSONDecoder().decode(AppSettings.MeetingMode.self, from: Data("\"granola\"".utf8))
        #expect(restored == .granola)
        #expect(restored.menuLabel == String(localized: "Ao vivo"))
        #expect(restored.displayName == String(localized: "Ao vivo"))
        #expect(!restored.menuLabel.localizedCaseInsensitiveContains("granola"))
        #expect(String(data: try JSONEncoder().encode(restored), encoding: .utf8) == "\"granola\"")
        #expect(AppSettings.MeetingMode.allCases.map(\.rawValue) == ["quality", "granola"])
    }

    @Test("Live locale admission normalizes identifiers and rejects unsupported languages")
    func localeAdmission() {
        #expect(AppleSpeechLocale.supports(Locale(identifier: "EN_us")))
        #expect(AppleSpeechLocale.supports(Locale(identifier: "pt_BR")))
        #expect(!AppleSpeechLocale.supports(Locale(identifier: "it-IT")))
    }
}
