import Testing
import Foundation

/// Guarda do `Codable` manual de `AppSettings`.
///
/// `AppSettings` tem `CodingKeys` escrito à mão e um `init(from:)` que sobrescreve campo a
/// campo. É uma armadilha silenciosa em duas direções, e nenhuma delas dá erro de compilação:
///
/// 1. Campo novo fora do `CodingKeys` → o `encode` sintetizado usa o `CodingKeys` declarado,
///    então o campo **nunca é gravado**. O usuário mexe na opção, fecha o app e ela volta.
/// 2. Campo no `CodingKeys` mas sem linha no `init(from:)` → é gravado e **nunca é lido**.
///    Mesmo sintoma, outro lugar.
///
/// Os dois testes abaixo quebram nesses casos: o primeiro compara as propriedades armazenadas
/// (via `Mirror`) com as chaves declaradas; o segundo faz roundtrip de uma instância em que
/// *todo* campo está diferente do default — e prova, também por `Mirror`, que ela realmente
/// está toda diferente, para o teste não passar por acidente ao surgir um campo novo.
@Suite("AppSettings — guarda do Codable manual")
struct AppSettingsCodingGuardTests {

    /// Nomes das propriedades armazenadas. `Mirror` só enxerga armazenadas — computadas e
    /// funções ficam de fora, que é exatamente o conjunto que precisa ser persistido.
    static func storedPropertyNames(of settings: AppSettings) -> Set<String> {
        Set(Mirror(reflecting: settings).children.compactMap(\.label))
    }

    @Test("Toda propriedade armazenada tem chave em CodingKeys — e vice-versa")
    func everyStoredPropertyHasACodingKey() {
        let properties = Self.storedPropertyNames(of: AppSettings())
        let keys = Set(AppSettings.persistedCodingKeyNames)

        // Mensagens separadas: dizem qual dos dois erros aconteceu sem obrigar a ler o diff.
        #expect(
            properties.subtracting(keys).isEmpty,
            "Campo(s) sem CodingKey (não serão gravados): \(properties.subtracting(keys).sorted())"
        )
        #expect(
            keys.subtracting(properties).isEmpty,
            "CodingKey(s) sem propriedade correspondente: \(keys.subtracting(properties).sorted())"
        )
        #expect(AppSettings.persistedCodingKeyNames.count == keys.count, "CodingKeys duplicado")
    }

    @Test("Roundtrip do formato novo preserva todos os campos")
    func roundtripPreservesEveryField() throws {
        let original = AppSettings.fullyCustomizedForTests

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded == original)
    }

    /// Sem isto o roundtrip acima seria um teste de mentira: um campo novo que ninguém alterou
    /// na fixture volta igual ao default mesmo quando o `init(from:)` esqueceu de lê-lo.
    @Test("A fixture do roundtrip tem todo campo diferente do default")
    func roundtripFixtureDiffersInEveryField() {
        let defaults = Mirror(reflecting: AppSettings()).children
        let customized = Mirror(reflecting: AppSettings.fullyCustomizedForTests).children

        for (base, custom) in zip(defaults, customized) {
            #expect(
                String(describing: base.value) != String(describing: custom.value),
                """
                `AppSettings.fullyCustomizedForTests` não muda `\(base.label ?? "?")`. \
                Dê a ele um valor diferente do default, senão o teste de roundtrip não cobre o campo.
                """
            )
        }
    }

    @Test("JSON gravado contém exatamente as chaves declaradas")
    func encodedJSONMatchesDeclaredKeys() throws {
        let data = try JSONEncoder().encode(AppSettings.fullyCustomizedForTests)
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])

        #expect(Set(object.keys) == Set(AppSettings.persistedCodingKeyNames))
    }

    @Test("Chave desconhecida no JSON não derruba o decode")
    func unknownKeysAreIgnored() throws {
        // Cenário real: settings gravados por uma versão mais nova do app, abertos numa antiga.
        let json = """
        {"autoInsertText": false, "campoDoFuturo": {"a": 1}, "outro": [1, 2, 3]}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(decoded.autoInsertText == false)
        #expect(decoded.modelSize == AppSettings().modelSize)
    }
}

extension AppSettings {
    /// Instância com **todo** campo armazenado diferente do default. Serve ao roundtrip: só uma
    /// instância assim prova que cada campo sobrevive ao ir e voltar do disco.
    ///
    /// Ao adicionar um campo em `AppSettings`, dê a ele um valor aqui — o teste
    /// `roundtripFixtureDiffersInEveryField` quebra até isso ser feito.
    static var fullyCustomizedForTests: AppSettings {
        var settings = AppSettings()
        settings.interfaceLanguage = .english
        settings.appearance = .light
        // Japonês porque a fixture precisa diferir do DEFAULT, e o default virou português em
        // 29/08/2026 (quando `.auto` saiu do seletor).
        settings.selectedLanguage = .japanese
        settings.autoInsertText = false
        settings.showConfidence = false
        settings.modelSize = .largeTurbo
        settings.transcriptionEngine = .parakeet
        settings.hotKey = KeyboardShortcut(keyCode: 12, modifiers: 256, keyDisplay: "Q")
        settings.showRecordingHUD = false
        settings.pushToTalkShortcut = KeyboardShortcut(keyCode: 13, modifiers: 512, keyDisplay: "W")
        settings.handsFreeShortcut = KeyboardShortcut(keyCode: 14, modifiers: 4096, keyDisplay: "E", usesFn: true)
        settings.dictationHotkeysEnabled = false
        settings.dictationVocabulary = "auth\nVoiz"
        settings.dictationCorrectionsEnabled = true
        settings.dictationCorrectionMarkers = "corrigindo"
        settings.translationProvider = .custom
        settings.openAIKey = "sk-openai-teste"
        settings.anthropicKey = "sk-ant-teste"
        settings.xaiKey = "xai-teste"
        settings.geminiKey = "gemini-teste"
        settings.translationModel = .gpt56Sol
        settings.anthropicModel = .opus5
        settings.xaiModel = .grok45
        settings.geminiModel = .gemini25Flash
        settings.reasoningEffort = .high
        settings.customBaseURL = "http://localhost:4000/v1"
        settings.customKey = "chave-custom"
        settings.customModel = "meu-modelo"
        settings.calendarSuggestionsEnabled = true
        settings.calendarSelection = MeetingCalendarSelection(disabledAccountIDs: ["work"], disabledCalendarIDs: ["holidays"], meetingsOnly: true)
        settings.meetingDetectionEnabled = false
        settings.meetingMode = .granola
        settings.notesLanguage = .english
        settings.meetingLivePreviewEnabled = true
        settings.notchOverlayEnabled = true
        settings.transcriptionSelectionMode = .advanced
        settings.transcriptionSelections = TranscriptionUseCaseChoices([
            .dictation: TranscriptionEngineChoice(engine: .whisperKit, model: .whisperMedium),
            .meetingFinal: TranscriptionEngineChoice(engine: .parakeet)
        ])
        settings.transcriptionSettingsVersion = 42
        return settings
    }
}
