import Testing
import Foundation

/// Um formato que o app já gravou em `UserDefaults` (chave `voiz.app.settings`).
///
/// `persistedKeys` é fato histórico, não opinião do teste: são as chaves que o `encode` daquela
/// revisão de fato produzia — os campos armazenados de `AppSettings`, enquanto o encode era
/// sintetizado por inteiro (até `4d1285f`), e o `CodingKeys` manual dali em diante. As duas
/// listas foram extraídas commit a commit de `voiz/Models/TranscriptionModels.swift`.
///
/// `json` é uma amostra **completa** desse formato: o teste `fixturesMatchTheirHistoricalShape`
/// compara as chaves do JSON com `persistedKeys` e quebra se a fixture for parcial. É essa
/// comparação que sustenta a afirmação "estes são os formatos, inteiros" — sem ela o cabeçalho
/// prometeria fidelidade histórica e entregaria amostra representativa (achado MAIOR da review).
struct LegacyFormat: Sendable {
    let id: String
    /// Commit que introduziu **este formato persistido**. Cuidado: nem toda mudança visível no
    /// arquivo muda o que vai para o disco (ver `25cb9a5` na lista abaixo).
    let commit: String
    let summary: String
    let persistedKeys: Set<String>
    let json: String
}

/// Decode de **todos** os formatos que o app já gravou, do original ao imediatamente anterior à
/// T1.4, mais as duas eras em que o mesmo formato tinha default diferente.
///
/// O que se cobra em todos é a mesma coisa: **nada se perde**. Um decode que lança faz
/// `SettingsStore.load()` cair para `AppSettings()` inteiro, e o usuário perde chave de API,
/// endpoint BYO e atalhos de uma vez só.
@Suite("AppSettings — decode dos formatos antigos")
struct AppSettingsLegacyDecodeTests {

    static func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// Atalho gravado antes do `usesFn` existir: ⌘⇧Space, sem a chave nova.
    static let hotKeyWithoutUsesFn = #"{"keyCode":49,"modifiers":768,"keyDisplay":"Space"}"#
    static let fnPushToTalkJSON = #"{"keyCode":65535,"modifiers":0,"keyDisplay":"","usesFn":true}"#
    static let fnSpaceJSON = #"{"keyCode":49,"modifiers":0,"keyDisplay":"Space","usesFn":true}"#

    // MARK: - As chaves de cada era, na ordem em que a história as acrescentou

    static let keysF1: Set<String> = [
        "selectedLanguage", "autoInsertText", "showConfidence", "modelSize", "hotKey"
    ]
    static let keysF2 = keysF1.union(["openAIKey", "translationModel"])
    static let keysF3 = keysF2.union(["showRecordingHUD"])
    static let keysF4 = keysF3.union(["translationProvider", "xaiKey", "xaiModel"])
    static let keysF5 = keysF4.union(["transcriptionEngine"])
    static let keysF6 = keysF5.union(["customBaseURL", "customKey", "customModel"])
    static let keysF7 = keysF6.union(["calendarSuggestionsEnabled"])
    static let keysF8 = keysF7.union([
        "pushToTalkShortcut", "handsFreeShortcut", "dictationHotkeysEnabled"
    ])
    static let keysF9 = keysF8.union(["meetingDetectionEnabled"])
    static let keysF10 = keysF9.union(["meetingLivePreviewEnabled"])
    static let keysF11 = keysF10.union(["geminiKey", "geminiModel"])
    static let keysF12 = keysF11.union(["interfaceLanguage", "notesLanguage"])
    static let keysF13 = keysF12.union(["notchOverlayEnabled"])
    static let keysF14 = keysF13.union(["anthropicKey", "anthropicModel", "reasoningEffort"])

    // MARK: - As fixtures

    static let allFormats: [LegacyFormat] = [
        LegacyFormat(
            id: "F1", commit: "221dcf7",
            summary: "o original: idioma, inserção, confiança, modelo e atalho único",
            persistedKeys: keysF1,
            json: """
            {
              "selectedLanguage": "pt",
              "autoInsertText": false,
              "showConfidence": false,
              "modelSize": "base",
              "hotKey": \(hotKeyWithoutUsesFn)
            }
            """
        ),
        LegacyFormat(
            id: "F2", commit: "8c38499",
            summary: "tradução OpenAI; `gpt-4o-mini` é raw value que não existe mais",
            persistedKeys: keysF2,
            json: """
            {
              "selectedLanguage": "auto", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "hotKey": \(hotKeyWithoutUsesFn),
              "openAIKey": "sk-antiga", "translationModel": "gpt-4o-mini"
            }
            """
        ),
        LegacyFormat(
            id: "F3", commit: "b47fe0d",
            summary: "HUD de gravação",
            persistedKeys: keysF3,
            json: """
            {
              "selectedLanguage": "en", "autoInsertText": true, "showConfidence": true,
              "modelSize": "medium", "hotKey": \(hotKeyWithoutUsesFn),
              "openAIKey": "sk-antiga", "translationModel": "gpt-4o",
              "showRecordingHUD": false
            }
            """
        ),
        LegacyFormat(
            id: "F4", commit: "b53d522",
            summary: "provider + xAI, com os slugs antigos do Grok",
            persistedKeys: keysF4,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "hotKey": \(hotKeyWithoutUsesFn),
              "showRecordingHUD": true, "translationProvider": "xai",
              "openAIKey": "", "xaiKey": "xai-antiga",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-4-1-fast-non-reasoning"
            }
            """
        ),
        // ATENÇÃO: `b5fb41d` introduziu `large-v3-turbo` E fez dele o default persistível. O
        // formato (as chaves) é o mesmo do F4 — o que muda é o default gravado, e é essa era que
        // cria a ambiguidade tratada em `ambiguousLargeTurboEraIsPreservedAsAdvanced`.
        // `25cb9a5` NÃO aparece nesta lista: ele só corrigiu o `whisperModelName` computado de
        // `openai_whisper-large-v3-turbo` para `..._turbo`, que não é campo persistido.
        LegacyFormat(
            id: "F5", commit: "1a723cc",
            summary: "spike do Parakeet: `transcriptionEngine` (default de modelo ainda largeTurbo)",
            persistedKeys: keysF5,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "large-v3-turbo", "transcriptionEngine": "parakeet",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3"
            }
            """
        ),
        LegacyFormat(
            id: "F6", commit: "4d1285f",
            summary: "provider custom (BYO endpoint)",
            persistedKeys: keysF6,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "translationProvider": "custom", "openAIKey": "", "xaiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "customBaseURL": "http://localhost:4000", "customKey": "sk-litellm",
              "customModel": "meu-modelo"
            }
            """
        ),
        LegacyFormat(
            id: "F7", commit: "68f8050",
            summary: "sugestões de calendário; nasce aqui o `CodingKeys` manual",
            persistedKeys: keysF7,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": true
            }
            """
        ),
        LegacyFormat(
            id: "F8", commit: "204556f",
            summary: "atalhos de ditado estilo Wispr, com `usesFn`",
            persistedKeys: keysF8,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": false,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": false
            }
            """
        ),
        LegacyFormat(
            id: "F9", commit: "929fbf8",
            summary: "detecção de reunião em curso",
            persistedKeys: keysF9,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": true,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": false, "meetingDetectionEnabled": false
            }
            """
        ),
        LegacyFormat(
            id: "F10", commit: "e8b6497",
            summary: "prévia ao vivo da reunião (opt-in)",
            persistedKeys: keysF10,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": true,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": false, "meetingDetectionEnabled": true,
              "meetingLivePreviewEnabled": true
            }
            """
        ),
        LegacyFormat(
            id: "F11", commit: "87fe664",
            summary: "Gemini como provider",
            persistedKeys: keysF11,
            json: """
            {
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": true,
              "translationProvider": "gemini", "openAIKey": "", "xaiKey": "",
              "geminiKey": "AIza-antiga",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "geminiModel": "gemini-2.5-flash",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": false, "meetingDetectionEnabled": true,
              "meetingLivePreviewEnabled": false
            }
            """
        ),
        LegacyFormat(
            id: "F12", commit: "e1e3252",
            summary: "i18n: idioma da interface e idioma das notas",
            persistedKeys: keysF12,
            json: """
            {
              "interfaceLanguage": "en", "notesLanguage": "pt-BR",
              "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": true,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "", "geminiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-4-1-fast-reasoning",
              "geminiModel": "gemini-3.6-flash",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": false, "meetingDetectionEnabled": true,
              "meetingLivePreviewEnabled": false
            }
            """
        ),
        LegacyFormat(
            id: "F13", commit: "5fcaad8",
            summary: "overlay do notch",
            persistedKeys: keysF13,
            json: """
            {
              "interfaceLanguage": "system", "notesLanguage": "spoken",
              "selectedLanguage": "auto", "autoInsertText": true, "showConfidence": true,
              "modelSize": "small", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": true,
              "translationProvider": "openai", "openAIKey": "", "xaiKey": "", "geminiKey": "",
              "translationModel": "gpt-4o-mini", "xaiModel": "grok-3",
              "geminiModel": "gemini-3.6-flash",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": false, "meetingDetectionEnabled": true,
              "meetingLivePreviewEnabled": false, "notchOverlayEnabled": true
            }
            """
        ),
        LegacyFormat(
            id: "F14", commit: "d908009",
            summary: "Anthropic + esforço de raciocínio — formato imediatamente anterior à T1.4",
            persistedKeys: keysF14,
            json: """
            {
              "interfaceLanguage": "system", "notesLanguage": "spoken",
              "selectedLanguage": "auto", "autoInsertText": true, "showConfidence": true,
              "modelSize": "medium", "transcriptionEngine": "whisper",
              "hotKey": \(hotKeyWithoutUsesFn), "showRecordingHUD": true,
              "pushToTalkShortcut": \(fnPushToTalkJSON), "handsFreeShortcut": \(fnSpaceJSON),
              "dictationHotkeysEnabled": true,
              "translationProvider": "anthropic",
              "openAIKey": "sk-o", "anthropicKey": "sk-ant", "xaiKey": "xai", "geminiKey": "AIza",
              "translationModel": "gpt-5.6-luna", "anthropicModel": "claude-sonnet-5",
              "xaiModel": "grok-4.5", "geminiModel": "gemini-3.6-flash",
              "reasoningEffort": "high",
              "customBaseURL": "", "customKey": "", "customModel": "",
              "calendarSuggestionsEnabled": true, "meetingDetectionEnabled": true,
              "meetingLivePreviewEnabled": true, "notchOverlayEnabled": true
            }
            """
        )
    ]

    // MARK: - O que vale para todos os formatos

    @Test("Cada fixture tem exatamente as chaves que aquele encode gravava")
    func fixturesMatchTheirHistoricalShape() throws {
        for format in Self.allFormats {
            let raw = try JSONSerialization.jsonObject(with: Data(format.json.utf8))
            let object = try #require(raw as? [String: Any])

            #expect(
                Set(object.keys) == format.persistedKeys,
                """
                \(format.id) (\(format.commit)) não é o formato inteiro daquela revisão. \
                Faltando: \(format.persistedKeys.subtracting(object.keys).sorted()); \
                a mais: \(Set(object.keys).subtracting(format.persistedKeys).sorted()).
                """
            )
        }
    }

    @Test("A última era histórica mais os campos da T1.4 dão o formato de hoje")
    func historyConnectsToTheCurrentFormat() {
        let current = Set(AppSettings.persistedCodingKeyNames)
        let newFields: Set<String> = [
            "transcriptionSelectionMode", "transcriptionSelections", "transcriptionSettingsVersion", "meetingMode",
            "appearance", "calendarSelection", "dictationVocabulary", "dictationCorrectionsEnabled", "dictationCorrectionMarkers"
        ]

        #expect(Self.keysF14.union(newFields) == current)
        // Nenhuma chave sumiu pelo caminho: o decode tolerante nunca aposentou uma.
        #expect(Self.keysF1.isSubset(of: current))
    }

    @Test("Todo formato antigo decodifica sem lançar e sem virar defaults")
    func everyFormatDecodes() throws {
        for format in Self.allFormats {
            let settings = try Self.decode(format.json)
            // Os campos da T1.4 não existiam em nenhum deles: todos entram como "não migrado".
            #expect(settings.transcriptionSettingsVersion == 0, "\(format.id)")
            #expect(settings.transcriptionSelectionMode == .automatic, "\(format.id)")
            #expect(settings.transcriptionSelections.isEmpty, "\(format.id)")
            #expect(settings.meetingMode == .quality, "\(format.id)")
            #expect(settings.appearance == .dark, "\(format.id)")
        }
    }

    @Test("Todo formato antigo migra de forma determinística e idempotente")
    func everyFormatMigratesDeterministically() throws {
        for format in Self.allFormats {
            let settings = try Self.decode(format.json)
            let migrated = settings.migratingTranscriptionSettings()

            #expect(migrated == settings.migratingTranscriptionSettings(), "\(format.id)")
            #expect(migrated.migratingTranscriptionSettings() == migrated, "\(format.id)")
            #expect(
                migrated.transcriptionSettingsVersion == AppSettings.currentTranscriptionSettingsVersion,
                "\(format.id)"
            )

            let isLegacyDefault = settings.transcriptionEngine == .whisper && settings.modelSize == .small
            #expect(migrated.transcriptionSelectionMode == (isLegacyDefault ? .automatic : .advanced), "\(format.id)")
            if !isLegacyDefault {
                // A prévia sai igual de todo formato, custom ou não.
                #expect(migrated.transcriptionChoice(for: .meetingPreview)?.model == .whisperSmall, "\(format.id)")
                // A tradução nunca sai do WhisperKit — nem do F5, que tem Parakeet gravado.
                #expect(migrated.transcriptionChoice(for: .translationChunk)?.engine == .whisperKit, "\(format.id)")
                #expect(
                    migrated.transcriptionChoice(for: .translationChunk)?.model
                        == TranscriptionModelID(settings.modelSize.whisperModelName),
                    "\(format.id)"
                )
            }
        }
    }

    @Test("Todo formato antigo sobrevive a um roundtrip depois de migrado")
    func everyFormatSurvivesRewrite() throws {
        for format in Self.allFormats {
            let migrated = try Self.decode(format.json).migratingTranscriptionSettings()
            let data = try JSONEncoder().encode(migrated)
            #expect(try JSONDecoder().decode(AppSettings.self, from: data) == migrated, "\(format.id)")
        }
    }

    // MARK: - A era ambígua do large-v3-turbo (b5fb41d → 178ab42)

    /// Segundo crítico da review do Farol. Entre `b5fb41d` e `178ab42` o default persistível era
    /// `large-v3-turbo` — logo um JSON daquela era com `whisper + large-v3-turbo` **pode** ser
    /// tanto "nunca mexi" quanto escolha manual, e o JSON não guarda a diferença.
    ///
    /// Decisão do Maestro (DECISOES, 2026-08-07): classificar como **avançado**, preservando o
    /// `large-v3-turbo`. É o modelo que o app usaria hoje ao abrir esses settings; trocá-lo por
    /// small seria mudança silenciosa de comportamento, que a regra 6 do PLANO proíbe. O preço é
    /// conhecido e aceito: quem vem daquela era e nunca escolheu nada fica em Avançado até mexer
    /// na UI da Onda 6. "Default → Automático" vale só para o default `small`.
    @Test("Era ambígua: whisper + large-v3-turbo vira AVANÇADO preservando o modelo")
    func ambiguousLargeTurboEraIsPreservedAsAdvanced() throws {
        // Formato da era sem `transcriptionEngine` (b5fb41d/25cb9a5) e com ele (1a723cc):
        // os dois são o mesmo caso e têm que dar o mesmo resultado.
        let beforeEngineKey = try Self.decode("""
        {
          "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
          "modelSize": "large-v3-turbo", "hotKey": \(Self.hotKeyWithoutUsesFn),
          "showRecordingHUD": true, "translationProvider": "openai",
          "openAIKey": "sk-da-era", "xaiKey": "",
          "translationModel": "gpt-4o-mini", "xaiModel": "grok-3"
        }
        """)
        let afterEngineKey = try Self.decode("""
        {
          "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
          "modelSize": "large-v3-turbo", "transcriptionEngine": "whisper",
          "hotKey": \(Self.hotKeyWithoutUsesFn), "showRecordingHUD": true,
          "translationProvider": "openai", "openAIKey": "sk-da-era", "xaiKey": "",
          "translationModel": "gpt-4o-mini", "xaiModel": "grok-3"
        }
        """)

        for settings in [beforeEngineKey, afterEngineKey] {
            #expect(settings.modelSize == .largeTurbo)
            #expect(settings.usesLegacyDefaultTranscriptionChoice == false)

            let migrated = settings.migratingTranscriptionSettings()

            #expect(migrated.transcriptionSelectionMode == .advanced)
            // Preservado, não trocado: é o que o app roda hoje com esses settings.
            #expect(migrated.transcriptionChoice(for: .dictation)?.model == .whisperLargeV3Turbo)
            #expect(migrated.transcriptionChoice(for: .meetingFinal)?.model == .whisperLargeV3Turbo)
            #expect(migrated.transcriptionChoice(for: .translationChunk)?.model == .whisperLargeV3Turbo)
            // E a prévia continua no small, como sempre esteve.
            #expect(migrated.transcriptionChoice(for: .meetingPreview)?.model == .whisperSmall)
            #expect(migrated.openAIKey == "sk-da-era")
        }

        // O outro lado da era: depois de `178ab42` o default voltou a ser `small`, e um JSON
        // idêntico exceto pelo modelo é, esse sim, "nunca mexi" → automático.
        let afterRevert = try Self.decode("""
        {
          "selectedLanguage": "pt", "autoInsertText": true, "showConfidence": true,
          "modelSize": "small", "transcriptionEngine": "whisper",
          "hotKey": \(Self.hotKeyWithoutUsesFn), "showRecordingHUD": true,
          "translationProvider": "openai", "openAIKey": "sk-da-era", "xaiKey": "",
          "translationModel": "gpt-4o-mini", "xaiModel": "grok-3"
        }
        """)
        #expect(afterRevert.migratingTranscriptionSettings().transcriptionSelectionMode == .automatic)
    }

    // MARK: - Semântica específica de cada formato

    @Test("F1 — o atalho gravado sem `usesFn` não ganha Fn no decode")
    func originalHotKeyHasNoFn() throws {
        let settings = try Self.decode(Self.allFormats[0].json)

        #expect(settings.selectedLanguage == .portuguese)
        #expect(settings.autoInsertText == false)
        #expect(settings.showConfidence == false)
        #expect(settings.modelSize == .base)
        #expect(settings.hotKey == .default)
        #expect(settings.hotKey.usesFn == false)
        // Tudo que veio depois cai no default, e não em lixo.
        #expect(settings.transcriptionEngine == .whisper)
        #expect(settings.translationProvider == .openai)
        #expect(settings.showRecordingHUD == true)
        #expect(settings.dictationHotkeysEnabled == true)
        #expect(settings.notchOverlayEnabled == false)
    }

    /// O `"auto"` gravado por toda versão anterior a 29/08/2026 — inclusive a que está na máquina
    /// do usuário agora.
    ///
    /// `Language.auto` deixou de existir, e `Language(rawValue: "auto")` passou a ser `nil`. Com
    /// `try` no lugar de `try?` no `init(from:)`, esse `nil` não cairia no default do campo: ele
    /// **lançaria**, o `SettingsStore.load()` devolveria `AppSettings()` inteiro e o usuário
    /// perderia chave de API, endpoint BYO e atalhos de uma vez — no primeiro boot depois de
    /// atualizar, sem mensagem nenhuma.
    @Test("O `auto` gravado no disco vira português sem derrubar o resto dos settings")
    func retiredAutoLanguageFallsBackWithoutLosingKeys() throws {
        let comAuto = try Self.decode(Self.allFormats[1].json)

        #expect(comAuto.selectedLanguage == .portuguese, "`auto` tem que cair no default do campo")
        // O que precisa sobreviver junto: é este o prejuízo que um `throw` aqui causaria.
        #expect(comAuto.openAIKey == "sk-antiga")
        #expect(comAuto.modelSize == .small)
        #expect(comAuto.autoInsertText == true)

        // Um idioma que esta versão não conhece se comporta igual — não é caso especial do "auto".
        let comIdiomaFuturo = try Self.decode("""
        {
          "selectedLanguage": "tlh", "autoInsertText": true, "showConfidence": true,
          "modelSize": "small", "hotKey": \(Self.hotKeyWithoutUsesFn),
          "openAIKey": "sk-antiga", "translationModel": "gpt-4o-mini"
        }
        """)
        #expect(comIdiomaFuturo.selectedLanguage == .portuguese)
        #expect(comIdiomaFuturo.openAIKey == "sk-antiga")

        // E um idioma NOVO e válido continua sendo lido — senão o teste acima passaria com um
        // decode que ignora o campo inteiro.
        let comJapones = try Self.decode("""
        {
          "selectedLanguage": "ja", "openAIKey": "sk-antiga"
        }
        """)
        #expect(comJapones.selectedLanguage == .japanese)
    }

    @Test("F2/F4 — raw value de modelo aposentado cai no default sem levar a chave junto")
    func retiredModelRawValuesFallBackWithoutLosingKeys() throws {
        let openAI = try Self.decode(Self.allFormats[1].json)
        // `gpt-4o-mini` sumiu do enum: o campo cai no default...
        #expect(openAI.translationModel == AppSettings().translationModel)
        // ...mas a chave de API, que é o que dói perder, continua lá.
        #expect(openAI.openAIKey == "sk-antiga")

        let xai = try Self.decode(Self.allFormats[3].json)
        #expect(xai.xaiModel == AppSettings().xaiModel)
        #expect(xai.translationProvider == .xai)
        #expect(xai.xaiKey == "xai-antiga")
    }

    @Test("F5 — `transcriptionEngine` e o `modelSize` large-v3-turbo")
    func parakeetSpikeFormat() throws {
        let settings = try Self.decode(Self.allFormats[4].json)

        #expect(settings.transcriptionEngine == .parakeet)
        #expect(settings.modelSize == .largeTurbo)
        // O id computado hoje usa underscore — a correção de `25cb9a5`, que nunca tocou no JSON.
        #expect(settings.modelSize.whisperModelName == "openai_whisper-large-v3_turbo")
    }

    @Test("F6 — endpoint BYO normalizado")
    func customProviderFormat() throws {
        let settings = try Self.decode(Self.allFormats[5].json)

        #expect(settings.translationProvider == .custom)
        #expect(settings.customBaseURL == "http://localhost:4000")
        #expect(settings.customKey == "sk-litellm")
        #expect(settings.customModel == "meu-modelo")
        #expect(settings.currentBaseURL == "http://localhost:4000/v1/chat/completions")
    }

    @Test("F8 — atalhos de ditado com `usesFn` viram os padrões Wispr")
    func wisprShortcutsFormat() throws {
        let settings = try Self.decode(Self.allFormats[7].json)

        #expect(settings.pushToTalkShortcut == .fnPushToTalk)
        #expect(settings.handsFreeShortcut == .fnSpaceHandsFree)
        #expect(settings.dictationHotkeysEnabled == false)
    }

    @Test("F11/F12 — Gemini, idioma da interface e idioma das notas")
    func geminiAndI18nFormats() throws {
        let gemini = try Self.decode(Self.allFormats[10].json)
        #expect(gemini.translationProvider == .gemini)
        #expect(gemini.geminiKey == "AIza-antiga")
        #expect(gemini.geminiModel == .gemini25Flash)

        let i18n = try Self.decode(Self.allFormats[11].json)
        #expect(i18n.interfaceLanguage == .english)
        #expect(i18n.notesLanguage == .portuguese)
        // Sem `reasoningEffort` nem Anthropic no JSON: os campos mais novos assumem o default.
        #expect(i18n.reasoningEffort == .auto)
        #expect(i18n.anthropicKey.isEmpty)
    }

    @Test("F14 — formato completo pré-T1.4")
    func preT14Format() throws {
        let settings = try Self.decode(Self.allFormats[13].json)

        #expect(settings.translationProvider == .anthropic)
        #expect(settings.anthropicKey == "sk-ant")
        #expect(settings.anthropicModel == .sonnet5)
        #expect(settings.reasoningEffort == .high)
        #expect(settings.modelSize == .medium)
        #expect(settings.notchOverlayEnabled == true)
    }

    // MARK: - Transversais

    @Test("JSON antigo sem motor mantém Whisper e usa os defaults nos demais campos")
    func emptyObjectPreservesImplicitLegacyEngine() throws {
        var expected = AppSettings()
        expected.transcriptionEngine = .whisper
        #expect(try Self.decode("{}") == expected)
    }

    @Test("Formato antigo relido e regravado ganha as chaves novas sem perder as velhas")
    func legacyFormatUpgradesOnRewrite() throws {
        let legacy = try Self.decode(Self.allFormats[0].json)  // modelSize "base"

        let data = try JSONEncoder().encode(legacy.migratingTranscriptionSettings())
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(reloaded.modelSize == .base)
        #expect(reloaded.hotKey == .default)
        #expect(reloaded.transcriptionSelectionMode == .advanced)
        #expect(reloaded.transcriptionSettingsVersion == AppSettings.currentTranscriptionSettingsVersion)
        #expect(reloaded.transcriptionChoice(for: .translationChunk)?.model == .whisperBase)
        #expect(reloaded.transcriptionChoice(for: .meetingPreview)?.model == .whisperSmall)
    }
}
