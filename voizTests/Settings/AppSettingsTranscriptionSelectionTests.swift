import Testing
import Foundation

/// Campos novos do bloco de transcrição (T1.4) e a migração do par legado
/// `transcriptionEngine` + `modelSize` para o formato por caso de uso.
@Suite("AppSettings — seleção de transcrição")
struct AppSettingsTranscriptionSelectionTests {

    // MARK: - Defaults

    @Test("Instalação nova começa no automático, sem seleção e não migrada")
    func defaultsAreAutomaticAndUnmigrated() {
        let settings = AppSettings()

        #expect(settings.transcriptionSelectionMode == .automatic)
        #expect(settings.transcriptionSelections.isEmpty)
        // Zero e não `currentTranscriptionSettingsVersion`: `init(from:)` parte destes defaults,
        // então um valor "já migrado" aqui faria o JSON antigo pular a migração.
        #expect(settings.transcriptionSettingsVersion == 0)
        #expect(AppSettings.currentTranscriptionSettingsVersion == 1)
    }

    @Test("Instalação nova usa Apple Speech e mantém o modelo Whisper guardado")
    func freshInstallUsesAppleSpeech() {
        let settings = AppSettings()

        #expect(settings.transcriptionEngine == .apple)
        #expect(settings.modelSize == .small)
    }

    // MARK: - Mapa por caso de uso

    @Test("O mapa de escolhas guarda e devolve por caso de uso")
    func choicesMapStoresPerUseCase() {
        var choices = TranscriptionUseCaseChoices()
        #expect(choices.isEmpty)

        choices[.dictation] = TranscriptionEngineChoice(engine: .whisperKit, model: .whisperMedium)

        #expect(choices[.dictation]?.engine == .whisperKit)
        #expect(choices[.dictation]?.model == .whisperMedium)
        #expect(choices[.meetingFinal] == nil)
        #expect(choices.pinnedUseCases == [.dictation])

        choices[.dictation] = nil
        #expect(choices.isEmpty)
    }

    @Test("`perUseCase` cobre todos os casos de uso, um a um")
    func perUseCaseCoversEveryUseCase() {
        let choices = TranscriptionUseCaseChoices.perUseCase { useCase in
            TranscriptionEngineChoice(engine: TranscriptionEngineID(useCase.rawValue))
        }

        #expect(choices.pinnedUseCases == TranscriptionUseCase.allCases)
        for useCase in TranscriptionUseCase.allCases {
            #expect(choices[useCase]?.engine == TranscriptionEngineID(useCase.rawValue))
        }
    }

    @Test("O mapa vira objeto JSON com o caso de uso como chave")
    func choicesEncodeAsJSONObject() throws {
        let choices = TranscriptionUseCaseChoices([
            .dictation: TranscriptionEngineChoice(engine: .whisperKit, model: .whisperSmall)
        ])

        let data = try JSONEncoder().encode(choices)
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])

        #expect(Set(object.keys) == ["dictation"])
        #expect(try JSONDecoder().decode(TranscriptionUseCaseChoices.self, from: data) == choices)
    }

    @Test("Caso de uso desconhecido no JSON é ignorado, não derruba o mapa")
    func unknownUseCaseKeysAreDropped() throws {
        // Settings escritos por uma versão futura, com um caso de uso que esta não conhece.
        let json = """
        {"dictation": {"engine": "whisperkit"}, "podcastImport": {"engine": "whisperkit"}}
        """
        let choices = try JSONDecoder().decode(TranscriptionUseCaseChoices.self, from: Data(json.utf8))

        #expect(choices.pinnedUseCases == [.dictation])
        #expect(choices[.dictation] == TranscriptionEngineChoice(engine: .whisperKit))
    }

    // MARK: - Leitura da escolha

    @Test("A escolha pinada só vale no modo avançado")
    func pinnedChoiceOnlyCountsInAdvancedMode() {
        var settings = AppSettings()
        settings.transcriptionSelections = .perUseCase { _ in
            TranscriptionEngineChoice(engine: .parakeet)
        }

        settings.transcriptionSelectionMode = .automatic
        #expect(settings.transcriptionChoice(for: .dictation) == nil)

        // Voltar para o avançado reencontra a escolha guardada — ela não é apagada ao sair.
        settings.transcriptionSelectionMode = .advanced
        #expect(settings.transcriptionChoice(for: .dictation)?.engine == .parakeet)
    }

    // MARK: - Migração

    @Test("Quem estava no default vai para o automático, sem seleção")
    func defaultLegacyChoiceMigratesToAutomatic() {
        var settings = AppSettings()
        settings.transcriptionEngine = .whisper
        let migrated = settings.migratingTranscriptionSettings()

        #expect(migrated.transcriptionSelectionMode == .automatic)
        #expect(migrated.transcriptionSelections.isEmpty)
        #expect(migrated.transcriptionSettingsVersion == AppSettings.currentTranscriptionSettingsVersion)
    }

    /// Os casos de uso cujo consumidor legado faz `switch` em `transcriptionEngine` — só estes
    /// seguem o motor escolhido nas Configurações.
    ///
    /// Tradução e prévia ficam de fora e têm testes próprios: a prévia é fixa em Whisper small
    /// (`MeetingLivePreviewService:50`) e a tradução usa sempre o WhisperKit compartilhado com o
    /// tamanho configurado (`TranslationViewModel:22,107,214` nunca lê `transcriptionEngine`).
    static let useCasesThatFollowTheEngine: [TranscriptionUseCase] = [.dictation, .meetingFinal]

    /// Todos os casos que seguem o **tamanho** configurado, no Whisper, quando o motor é Whisper.
    static let useCasesFedByTheConfiguredWhisperModel: [TranscriptionUseCase] = [
        .dictation, .translationChunk, .meetingFinal
    ]

    @Test("Modelo Whisper escolhido a dedo vira avançado preservando a escolha", arguments: [
        (AppSettings.ModelSize.base, TranscriptionModelID.whisperBase),
        (.medium, .whisperMedium),
        (.largeTurbo, .whisperLargeV3Turbo)
    ])
    func customWhisperModelMigratesToAdvanced(
        modelSize: AppSettings.ModelSize,
        expected: TranscriptionModelID
    ) {
        var settings = AppSettings()
        settings.transcriptionEngine = .whisper
        settings.modelSize = modelSize

        let migrated = settings.migratingTranscriptionSettings()

        #expect(migrated.transcriptionSelectionMode == .advanced)
        #expect(migrated.transcriptionSettingsVersion == AppSettings.currentTranscriptionSettingsVersion)
        // Com motor Whisper, ditado, tradução e transcript final rodam o tamanho configurado.
        for useCase in Self.useCasesFedByTheConfiguredWhisperModel {
            #expect(migrated.transcriptionChoice(for: useCase)?.engine == .whisperKit)
            #expect(migrated.transcriptionChoice(for: useCase)?.model == expected)
        }
        // A prévia não: ela roda Whisper small hardcoded e continua nele.
        #expect(migrated.transcriptionChoice(for: .meetingPreview)?.model == .whisperSmall)
        // O par legado continua onde estava: quem lê o comportamento hoje não vê diferença.
        #expect(migrated.modelSize == modelSize)
        #expect(migrated.transcriptionEngine == .whisper)
    }

    @Test("Parakeet migra só quem despacha por motor; tradução e prévia ficam no Whisper", arguments: [
        AppSettings.ModelSize.base, .small, .medium, .largeTurbo
    ])
    func parakeetMigratesToItsOwnCheckpoint(modelSize: AppSettings.ModelSize) {
        var settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        // Mesmo com o `modelSize` no default, é escolha do usuário: o motor não é o padrão.
        settings.modelSize = modelSize

        let migrated = settings.migratingTranscriptionSettings()

        #expect(migrated.transcriptionSelectionMode == .advanced)
        // Ditado e transcript final fazem switch no motor: vão para o checkpoint do Parakeet, e
        // o tamanho é ignorado (ele nomeia variantes do Whisper).
        for useCase in Self.useCasesThatFollowTheEngine {
            #expect(migrated.transcriptionChoice(for: useCase)?.engine == .parakeet)
            #expect(migrated.transcriptionChoice(for: useCase)?.model == .parakeetTDT06BV3)
        }
        // A tradução NUNCA rodou Parakeet: o `TranslationViewModel` fala direto com o
        // `TranscriptionService.shared` (WhisperKit) e só aplica o tamanho configurado.
        #expect(migrated.transcriptionChoice(for: .translationChunk)?.engine == .whisperKit)
        #expect(
            migrated.transcriptionChoice(for: .translationChunk)?.model
                == TranscriptionModelID(modelSize.whisperModelName)
        )
        // A prévia também não: o `MeetingLivePreviewService` instancia WhisperKit small direto.
        #expect(migrated.transcriptionChoice(for: .meetingPreview)?.engine == .whisperKit)
        #expect(migrated.transcriptionChoice(for: .meetingPreview)?.model == .whisperSmall)
    }

    // MARK: - A matriz inteira contra os consumidores legados

    /// A tabela que a migração tem que reproduzir, escrita **à mão a partir da leitura de cada
    /// consumidor legado** — de propósito não chama `legacyTranscriptionChoice(for:)`, senão o
    /// teste concordaria com o código em vez de conferi-lo.
    ///
    /// | caso de uso        | consumidor                              | motor            | modelo            |
    /// |--------------------|-----------------------------------------|------------------|-------------------|
    /// | `.dictation`       | `TranscriptionViewModel:280-291`        | segue o escolhido| configurado       |
    /// | `.meetingFinal`    | `MeetingViewModel:508-515,1125`         | segue o escolhido| configurado       |
    /// | `.translationChunk`| `TranslationViewModel:22,107,214`       | **sempre Whisper**| configurado      |
    /// | `.meetingPreview`  | `MeetingLivePreviewService:50`          | **sempre Whisper**| **sempre small** |
    static func expectedLegacyChoices(
        engine: AppSettings.TranscriptionEngine,
        modelSize: AppSettings.ModelSize
    ) -> [TranscriptionUseCase: TranscriptionEngineChoice] {
        let configuredWhisper = TranscriptionEngineChoice(
            engine: .whisperKit,
            model: TranscriptionModelID(modelSize.whisperModelName)
        )
        let followsEngine = engine == .parakeet
            ? TranscriptionEngineChoice(engine: .parakeet, model: .parakeetTDT06BV3)
            : configuredWhisper

        return [
            .dictation: followsEngine,
            .meetingFinal: followsEngine,
            .translationChunk: configuredWhisper,
            .meetingPreview: TranscriptionEngineChoice(engine: .whisperKit, model: .whisperSmall)
        ]
    }

    @Test(
        "Matriz motor × tamanho: cada caso de uso migra para o que seu consumidor legado roda hoje",
        arguments: [AppSettings.TranscriptionEngine.whisper, .parakeet],
                   [AppSettings.ModelSize.base, .small, .medium, .largeTurbo]
    )
    func migrationMirrorsEveryLegacyConsumer(
        engine: AppSettings.TranscriptionEngine,
        modelSize: AppSettings.ModelSize
    ) {
        var settings = AppSettings()
        settings.transcriptionEngine = engine
        settings.modelSize = modelSize

        let expected = Self.expectedLegacyChoices(engine: engine, modelSize: modelSize)
        let migrated = settings.migratingTranscriptionSettings()

        for useCase in TranscriptionUseCase.allCases {
            // A leitura do legado bate com a tabela, em qualquer modo.
            #expect(
                settings.legacyTranscriptionChoice(for: useCase) == expected[useCase],
                "legado \(engine.rawValue)/\(modelSize.rawValue) em \(useCase.rawValue)"
            )
        }

        if settings.usesLegacyDefaultTranscriptionChoice {
            // Único caso automático (whisper + small): sem seleção pinada. A tabela acima já
            // provou que, aí, os quatro consumidores rodam o mesmo Whisper small.
            #expect(migrated.transcriptionSelectionMode == .automatic)
            #expect(migrated.transcriptionSelections.isEmpty)
        } else {
            #expect(migrated.transcriptionSelectionMode == .advanced)
            for useCase in TranscriptionUseCase.allCases {
                #expect(
                    migrated.transcriptionChoice(for: useCase) == expected[useCase],
                    "migrado \(engine.rawValue)/\(modelSize.rawValue) em \(useCase.rawValue)"
                )
            }
        }
    }

    @Test("REGRESSÃO — Parakeet nunca vaza para a tradução, em nenhum tamanho", arguments: [
        AppSettings.ModelSize.base, .small, .medium, .largeTurbo
    ])
    func parakeetNeverLeaksIntoTranslation(modelSize: AppSettings.ModelSize) {
        var settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        settings.modelSize = modelSize

        let choice = settings.migratingTranscriptionSettings()
            .transcriptionChoice(for: .translationChunk)

        #expect(choice?.engine == .whisperKit)
        #expect(choice?.model == TranscriptionModelID(modelSize.whisperModelName))
    }

    // MARK: - Regressão: a prévia ao vivo nunca muda de modelo

    /// Crítico da review do Farol: a primeira versão desta migração usava a escolha global para
    /// os quatro casos de uso, partindo da premissa (falsa) de que ela valia para todos. A prévia
    /// é fixa em `MeetingLivePreviewService.previewModelName = "openai_whisper-small"` e nunca
    /// leu `AppSettings.modelSize` — migrá-la junto mudaria o comportamento dela na virada.
    @Test(
        "REGRESSÃO — .meetingPreview migra sempre para Whisper small, qualquer que seja o legado",
        arguments: [
            (AppSettings.TranscriptionEngine.whisper, AppSettings.ModelSize.base),
            (.whisper, .small),
            (.whisper, .medium),
            (.whisper, .largeTurbo),
            (.parakeet, .base),
            (.parakeet, .small),
            (.parakeet, .medium),
            (.parakeet, .largeTurbo)
        ]
    )
    func meetingPreviewAlwaysMigratesToWhisperSmall(
        engine: AppSettings.TranscriptionEngine,
        modelSize: AppSettings.ModelSize
    ) {
        var settings = AppSettings()
        settings.transcriptionEngine = engine
        settings.modelSize = modelSize

        let migrated = settings.migratingTranscriptionSettings()

        if migrated.transcriptionSelectionMode == .advanced {
            #expect(migrated.transcriptionChoice(for: .meetingPreview) == TranscriptionEngineChoice(
                engine: .whisperKit,
                model: .whisperSmall
            ))
        } else {
            // Único caso automático (whisper+small): sem seleção, a prévia segue o padrão —
            // que já é o small.
            #expect(migrated.transcriptionSelections.isEmpty)
            #expect(settings.legacyTranscriptionChoice(for: .meetingPreview).model == .whisperSmall)
        }
    }

    /// O id que a migração grava para a prévia tem que ser byte a byte o nome que o
    /// `MeetingLivePreviewService` passa ao `WhisperKit`. Se alguém mudar um dos dois, este teste
    /// é o lugar onde a divergência aparece.
    @Test("O modelo da prévia é exatamente o `openai_whisper-small` do serviço")
    func previewModelIDMatchesTheServiceConstant() {
        #expect(AppSettings.legacyMeetingPreviewChoice.model?.rawValue == "openai_whisper-small")
        #expect(TranscriptionModelID.whisperSmall.rawValue == "openai_whisper-small")
    }

    @Test("Migrar duas vezes dá o mesmo resultado")
    func migrationIsIdempotent() {
        var custom = AppSettings()
        custom.modelSize = .largeTurbo

        for settings in [AppSettings(), custom] {
            let once = settings.migratingTranscriptionSettings()
            let twice = once.migratingTranscriptionSettings()
            let thrice = twice.migratingTranscriptionSettings()

            #expect(once == twice)
            #expect(twice == thrice)
        }
    }

    @Test("Migração não reescreve quem já está na versão corrente")
    func migrationSkipsAlreadyMigratedSettings() {
        // Alguém já migrado que voltou ao automático e depois trocou o modelo pela UI legada:
        // a migração não pode arrastá-lo de volta para o avançado.
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = AppSettings.currentTranscriptionSettingsVersion
        settings.transcriptionSelectionMode = .automatic
        settings.modelSize = .largeTurbo

        #expect(settings.migratingTranscriptionSettings() == settings)
    }

    @Test("Migração não mexe em nenhum outro campo dos settings")
    func migrationTouchesOnlyTheTranscriptionBlock() {
        var settings = AppSettings.fullyCustomizedForTests
        settings.transcriptionSettingsVersion = 0

        var migrated = settings.migratingTranscriptionSettings()
        // Desfeitos os três campos do bloco, o resto tem que ser byte a byte o mesmo.
        migrated.transcriptionSelectionMode = settings.transcriptionSelectionMode
        migrated.transcriptionSelections = settings.transcriptionSelections
        migrated.transcriptionSettingsVersion = settings.transcriptionSettingsVersion

        #expect(migrated == settings)
    }

    @Test("A escolha migrada sobrevive a um roundtrip de disco")
    func migratedChoiceSurvivesPersistence() throws {
        var settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        let migrated = settings.migratingTranscriptionSettings()

        let data = try JSONEncoder().encode(migrated)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded == migrated)
        #expect(decoded.transcriptionChoice(for: .meetingFinal)?.engine == .parakeet)
        // E migrar de novo depois de reler não muda nada.
        #expect(decoded.migratingTranscriptionSettings() == decoded)
    }
}
