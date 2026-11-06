import Foundation
import Testing

@Suite("Internacionalização — catálogos e idiomas suportados")
struct LocalizationCatalogTests {
    private static let targetLocales = ["de", "en", "es", "fr", "ja", "zh-Hans"]

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: Variations?

        var translatedValues: [String] {
            if let stringUnit, stringUnit.state == "translated", !stringUnit.value.isEmpty {
                return [stringUnit.value]
            }
            return variations?.plural.values.compactMap { variation in
                let unit = variation.stringUnit
                return unit.state == "translated" && !unit.value.isEmpty ? unit.value : nil
            } ?? []
        }
    }

    private struct Variations: Decodable {
        let plural: [String: Variation]
    }

    private struct Variation: Decodable {
        let stringUnit: StringUnit
    }

    private struct StringUnit: Decodable {
        let state: String
        let value: String
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // voizTests
            .deletingLastPathComponent() // raiz do repositório
    }

    private static func loadCatalog(named name: String) throws -> Catalog {
        let url = repositoryRoot.appending(path: "voiz/\(name)")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private static func formatPlaceholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|llu|ld|lu|d|u|@|f|s)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        return matches.compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range])
                .replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression)
        }.sorted()
    }

    @Test("o seletor da interface oferece todos os idiomas falados")
    func interfaceLanguagesMatchTranscriptionLanguages() {
        let interfaceCodes = AppSettings.InterfaceLanguage.allCases.compactMap(\.localeCode)
        #expect(interfaceCodes == ["pt-BR", "en", "es", "fr", "de", "ja", "zh-Hans"])
        #expect(interfaceCodes.count == Language.allCases.count)
    }

    @Test("seguir a interface instrui as notas nos sete idiomas")
    func notesFollowEveryInterfaceLanguage() {
        let expected: [(AppSettings.InterfaceLanguage, String)] = [
            (.portuguese, "Escreva em português do Brasil."),
            (.english, "Write in English."),
            (.spanish, "Escribe en español."),
            (.french, "Écris en français."),
            (.german, "Schreibe auf Deutsch."),
            (.japanese, "日本語で書いてください。"),
            (.chinese, "请用简体中文写。"),
        ]

        for (language, instruction) in expected {
            var settings = AppSettings()
            settings.interfaceLanguage = language
            settings.notesLanguage = .interface
            #expect(settings.notesLanguageInstruction == instruction)
        }
    }

    @Test("toda string de interface tem tradução em todos os idiomas")
    func localizableCatalogIsComplete() throws {
        let catalog = try Self.loadCatalog(named: "Localizable.xcstrings")
        #expect(catalog.sourceLanguage == "pt-BR")

        var missing: [String] = []
        for (key, entry) in catalog.strings {
            for locale in Self.targetLocales {
                let values = entry.localizations?[locale]?.translatedValues ?? []
                if values.isEmpty {
                    missing.append("\(locale): \(key)")
                }
            }
        }
        #expect(missing.isEmpty, "Traduções ausentes: \(missing.sorted().joined(separator: " | "))")
    }

    @Test("avisos de privacidade têm tradução em todos os idiomas")
    func infoPlistCatalogIsComplete() throws {
        let catalog = try Self.loadCatalog(named: "InfoPlist.xcstrings")
        #expect(catalog.sourceLanguage == "pt-BR")

        var missing: [String] = []
        for (key, entry) in catalog.strings {
            for locale in Self.targetLocales {
                if entry.localizations?[locale]?.translatedValues.isEmpty != false {
                    missing.append("\(locale): \(key)")
                }
            }
        }
        #expect(missing.isEmpty, "Avisos sem tradução: \(missing.sorted().joined(separator: " | "))")
    }

    @Test("traduções preservam placeholders e nomes técnicos")
    func catalogPreservesRuntimeTokens() throws {
        let catalog = try Self.loadCatalog(named: "Localizable.xcstrings")
        let protectedNames = [
            "Voiz", "Notion", "WhisperKit", "Parakeet", "FluidAudio", "SpeechAnalyzer",
            "Granola", "ChatGPT", "Codex", "Claude Code", "OpenAI", "xAI", "Gemini",
            "Grok", "MCP", "ASR", "Keychain", "Finder", "Teams", "Meet", "Zoom",
        ]
        var problems: [String] = []

        for (key, entry) in catalog.strings {
            let expectedPlaceholders = Self.formatPlaceholders(in: key)
            let namesInSource = protectedNames.filter(key.contains)
            for locale in Self.targetLocales {
                let values = entry.localizations?[locale]?.translatedValues ?? []
                for value in values {
                    if Self.formatPlaceholders(in: value) != expectedPlaceholders {
                        problems.append("\(locale) alterou placeholders de: \(key)")
                    }
                    for name in namesInSource where !value.contains(name) {
                        problems.append("\(locale) removeu \(name) de: \(key)")
                    }
                }
            }
        }

        #expect(problems.isEmpty, "Tokens alterados: \(problems.sorted().joined(separator: " | "))")
    }
}
