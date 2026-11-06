import Testing
import Foundation

/// A lógica pura do ditado sobre o coordenador (T2.4a): seleção → pedido, aviso de fallback,
/// estado do modelo na tela e classificação de falha.
@Suite("Ditado — migração para o coordenador")
struct DictationTranscriptionTests {

    // MARK: - Idioma do pedido

    @Test("Todo idioma do seletor chega ao Whisper como token de idioma")
    func languageMatchesLegacyRequest() {
        // O caminho legado fazia `language == .auto ? nil : language.rawValue`; sem o `.auto` o
        // código do idioma **sempre** vai no decode. Isso importa: é o token de idioma que impede
        // o Whisper de traduzir o que ouviu — foi sem ele, em automático, que uma reunião inteira
        // em pt-BR saiu em inglês (28/08/2026).
        for language in Language.allCases {
            let code = WhisperKitEngineSupport.whisperLanguageCode(for: language.transcriptionLanguage)
            #expect(code == language.rawValue, "o Whisper fala o código primário, sem região")
            #expect(code?.isEmpty == false)
        }
        #expect(Language.portuguese.transcriptionLanguage.rawValue == "pt")
        #expect(Language.english.transcriptionLanguage.rawValue == "en")
        #expect(Language.chinese.transcriptionLanguage.rawValue == "zh")

        // O `nil` continua existindo no CONTRATO (o probe da guarda o usa), só não sai mais de
        // escolha de usuário.
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: nil) == nil)
    }

    @Test("Idioma genérico não derruba motor nenhum do plano do ditado")
    func genericLanguageStillRoutes() {
        let plan = TranscriptionRouter().plan(
            for: TranscriptionRoutingContext(
                useCase: .dictation,
                language: Language.portuguese.transcriptionLanguage,
                hardware: .appleSiliconLike,
                selection: .automatic
            )
        )

        #expect(plan.primary?.engine == .whisperKit)
    }

    // MARK: - Seleção: settings ainda NÃO migrados (o caso de todo mundo hoje)

    @Test("O default legado Whisper continua automático")
    func unmigratedDefaultIsAutomatic() {
        var settings = AppSettings()
        settings.transcriptionEngine = .whisper
        settings.transcriptionSettingsVersion = 0

        let selection = settings.transcriptionSelection(for: .dictation)

        #expect(selection == .automatic)
        #expect(selection.preferred == nil)
        #expect(selection.strictEngineSelection == false)
    }

    @Test("Sem migração, o modelo escolhido a dedo é preservado — nada de voltar para o small")
    func unmigratedCustomModelIsPreserved() {
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = 0
        settings.transcriptionEngine = .whisper
        settings.modelSize = .largeTurbo

        let selection = settings.transcriptionSelection(for: .dictation)

        #expect(selection.preferred == TranscriptionEngineChoice(engine: .whisperKit, model: .whisperLargeV3Turbo))
        #expect(selection.strictEngineSelection == false)
    }

    @Test("Sem migração, quem escolheu Parakeet continua no Parakeet")
    func unmigratedParakeetIsPreserved() {
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = 0
        settings.transcriptionEngine = .parakeet

        let selection = settings.transcriptionSelection(for: .dictation)

        #expect(selection.preferred == TranscriptionEngineChoice(engine: .parakeet, model: .parakeetTDT06BV3))
    }

    @Test("A resolução em memória não escreve nada nos settings")
    func resolvingSelectionDoesNotMutateSettings() {
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = 0
        settings.modelSize = .medium
        let before = settings

        _ = settings.transcriptionSelection(for: .dictation)

        #expect(settings == before)
        #expect(settings.transcriptionSettingsVersion == 0)
    }

    // MARK: - Seleção: settings já migrados (Onda 6 em diante)

    @Test("Migrado no automático ignora seleção guardada de uma passagem pelo avançado")
    func migratedAutomaticIgnoresStoredChoice() {
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = AppSettings.currentTranscriptionSettingsVersion
        settings.transcriptionSelectionMode = .automatic
        settings.transcriptionSelections[.dictation] = TranscriptionEngineChoice(engine: .parakeet)

        #expect(settings.transcriptionSelection(for: .dictation) == .automatic)
    }

    @Test("Migrado no avançado usa a escolha pinada do caso de uso")
    func migratedAdvancedUsesPinnedChoice() {
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = AppSettings.currentTranscriptionSettingsVersion
        settings.transcriptionSelectionMode = .advanced
        settings.transcriptionSelections[.dictation] = TranscriptionEngineChoice(
            engine: .whisperKit,
            model: .whisperMedium
        )
        settings.transcriptionSelections[.translationChunk] = TranscriptionEngineChoice(engine: .parakeet)

        #expect(settings.transcriptionSelection(for: .dictation).preferred?.model == .whisperMedium)
        #expect(settings.transcriptionSelection(for: .translationChunk).preferred?.engine == .parakeet)
    }

    @Test("Avançado sem escolha para o caso de uso cai no automático, não em erro")
    func advancedWithoutChoiceFallsBackToAutomatic() {
        var settings = AppSettings()
        settings.transcriptionSettingsVersion = AppSettings.currentTranscriptionSettingsVersion
        settings.transcriptionSelectionMode = .advanced

        #expect(settings.transcriptionSelection(for: .dictation) == .automatic)
    }

    @Test("O ditado nunca é strict: fallback continua permitido")
    func dictationIsNeverStrict() {
        // `allCases` e não lista escrita à mão: motor novo no enum entra aqui sozinho. O Apple fica
        // de fora porque exige idioma explícito, e este teste roda no default (automático).
        for engine in AppSettings.TranscriptionEngine.allCases where engine != .apple {
            for size in AppSettings.ModelSize.allCases {
                var settings = AppSettings()
                settings.transcriptionEngine = engine
                settings.modelSize = size
                #expect(settings.transcriptionSelection(for: .dictation).strictEngineSelection == false)
            }
        }
    }

    // MARK: - Comportamento idêntico: o modelo efetivo é o de hoje

    /// O teste que trava a regra 6 do PLANO para o ditado: para **toda** combinação legada de
    /// motor + tamanho, o rank 0 do plano é o mesmo par que o `switch settings.transcriptionEngine`
    /// de antes rodava.
    @Test("O rank 0 do plano é o motor+modelo que o ditado legado usava")
    func plannedModelMatchesLegacyBehaviour() {
        let router = TranscriptionRouter()

        for engine in AppSettings.TranscriptionEngine.allCases {
            for size in AppSettings.ModelSize.allCases {
                var settings = AppSettings()
                settings.transcriptionEngine = engine
                settings.modelSize = size
                // O default do idioma já é português desde 29/08/2026, que é o único idioma do
                // Parakeet depois da troca de pesos da Onda 5. A linha continua explícita para o
                // teste não passar a depender de qual é o default de hoje — ele muda, a
                // equivalência com o ditado legado não.
                settings.selectedLanguage = .portuguese

                let plan = router.plan(
                    for: TranscriptionRoutingContext(
                        useCase: .dictation,
                        language: settings.selectedLanguage.transcriptionLanguage,
                        hardware: .appleSiliconLike,
                        selection: settings.transcriptionSelection(for: .dictation)
                    )
                )

                let expected: TranscriptionEngineChoice
                switch engine {
                case .whisper:
                    expected = TranscriptionEngineChoice(
                        engine: .whisperKit,
                        model: TranscriptionModelID(size.whisperModelName)
                    )
                case .parakeet:
                    expected = TranscriptionEngineChoice(engine: .parakeet, model: .parakeetTDT06BV3)
                case .apple:
                    continue  // coberto por `appleNeedsAnExplicitLanguage`: depende do idioma.
                }

                #expect(plan.primary?.engine == expected.engine)
                #expect(plan.primary?.model == expected.model)
                #expect(plan.primary?.rank == 0)
            }
        }
    }

    /// O SpeechAnalyzer não detecta idioma sozinho (`detectsLanguageAutomatically: false`): o
    /// locale dele é fixo, e é o **modelo** que o carrega.
    ///
    /// Este teste é o que segura os cinco idiomas acrescentados em 29/08/2026: cada um só vale a
    /// pena se o motor bom o atende, e "atende" aqui quer dizer ter um `TranscriptionModelID`
    /// próprio que o roteador saiba escolher. Um idioma novo no `Language` sem modelo no descritor
    /// cai calado no Whisper — que é o motor que a Onda 5 mediu como o pior dos três.
    @Test("Apple é o rank 0 do ditado em todo idioma do seletor, com o modelo do locale certo")
    func appleServesEveryLanguageInThePicker() {
        let router = TranscriptionRouter()

        func primary(language: Language?) -> TranscriptionEngineChoice? {
            var settings = AppSettings()
            settings.transcriptionEngine = .apple
            if let language { settings.selectedLanguage = language }
            let plan = router.plan(
                for: TranscriptionRoutingContext(
                    useCase: .dictation,
                    language: language?.transcriptionLanguage,
                    hardware: .appleSiliconLike,
                    selection: settings.transcriptionSelection(for: .dictation)
                )
            )
            guard let p = plan.primary else { return nil }
            return TranscriptionEngineChoice(engine: p.engine, model: p.model)
        }

        for language in Language.allCases {
            let escolha = primary(language: language)
            #expect(escolha?.engine == .appleSpeechAnalyzer, "\(language.rawValue) não chegou no Apple")
            #expect(
                escolha?.model == language.appleSpeechLocale.model,
                "\(language.rawValue) foi para o modelo de outro locale"
            )
        }

        // O pedido SEM idioma continua barrado — é o contrato, não o seletor: o probe da guarda
        // manda `language: nil` e não pode acordar um motor de locale fixo.
        #expect(primary(language: nil)?.engine != .appleSpeechAnalyzer)
    }

    /// Espelho do `appleServesEveryLanguageInThePicker`, do outro lado.
    ///
    /// Os pesos do Parakeet são um fine-tune pt-BR que esqueceu as outras línguas (medido em
    /// 27/08/2026: áudio em inglês volta como português fonético). Ele não degrada fora do
    /// português — ele transcreve errado com confiança. Com seis idiomas no seletor, escolher
    /// Parakeet e falar qualquer um deles precisa cair noutro motor.
    @Test("Fora do português o plano do ditado não cai no Parakeet")
    func otherLanguagesDoNotRouteToParakeet() {
        func primary(language: Language?) -> TranscriptionEngineID? {
            var settings = AppSettings()
            settings.transcriptionEngine = .parakeet
            if let language { settings.selectedLanguage = language }
            return TranscriptionRouter().plan(
                for: TranscriptionRoutingContext(
                    useCase: .dictation,
                    language: language?.transcriptionLanguage,
                    hardware: .appleSiliconLike,
                    selection: settings.transcriptionSelection(for: .dictation)
                )
            ).primary?.engine
        }

        for language in Language.allCases where language != .portuguese {
            #expect(primary(language: language) != .parakeet, "\(language.rawValue) caiu no Parakeet")
        }
        // Pedido sem idioma (o probe do contrato) também não.
        #expect(primary(language: nil) != .parakeet)
        // E o português continua chegando nele — senão o teste passaria com o motor removido.
        #expect(primary(language: .portuguese) == .parakeet)
    }

    @Test("Instalação nova usa Apple Speech no ditado")
    func defaultPlanIsAppleSpeech() {
        let settings = AppSettings()
        let plan = TranscriptionRouter().plan(
            for: TranscriptionRoutingContext(
                useCase: .dictation,
                language: settings.selectedLanguage.transcriptionLanguage,
                hardware: .appleSiliconLike,
                selection: settings.transcriptionSelection(for: .dictation)
            )
        )

        #expect(plan.primary?.engine == .appleSpeechAnalyzer)
        #expect(plan.primary?.model == settings.selectedLanguage.appleSpeechLocale.model)
        #expect(plan.primary?.origin == .userSelection)
    }

    // MARK: - Aviso de fallback

    @Test("Primeira escolha não avisa nada")
    func noNoticeOnPrimaryCandidate() {
        let provenance = TranscriptionProvenance(
            engine: .whisperKit,
            model: .whisperSmall,
            useCase: .dictation,
            origin: .userSelection,
            candidateRank: 0
        )

        #expect(DictationTranscription.fallbackNotice(for: provenance) == nil)
    }

    @Test("Fallback avisa com o nome de produto de quem transcreveu")
    func noticeNamesTheEngineThatRan() {
        let provenance = TranscriptionProvenance(
            engine: .whisperKit,
            model: .whisperSmall,
            useCase: .dictation,
            origin: .automatic,
            candidateRank: 1
        )

        let notice = DictationTranscription.fallbackNotice(for: provenance)

        #expect(notice?.engineName == "WhisperKit")
        #expect(notice?.modelName == "Whisper small")
    }

    @Test("Motor fora do catálogo ainda avisa, com o id técnico")
    func noticeFallsBackToRawIdentifiers() {
        let provenance = TranscriptionProvenance(
            engine: TranscriptionEngineID("motor-do-futuro"),
            model: TranscriptionModelID("pesos-do-futuro"),
            useCase: .dictation,
            origin: .automatic,
            candidateRank: 2
        )

        let notice = DictationTranscription.fallbackNotice(for: provenance)

        #expect(notice?.engineName == "motor-do-futuro")
        #expect(notice?.modelName == "pesos-do-futuro")
    }

    // MARK: - Proveniência no log

    @Test("O resumo de log tem motor, modelo, origem e posição — e nada de texto")
    func logSummaryCarriesProvenanceOnly() {
        let primary = DictationTranscription.logSummary(
            for: TranscriptionProvenance(
                engine: .whisperKit,
                model: .whisperSmall,
                useCase: .dictation,
                origin: .userSelection,
                candidateRank: 0
            )
        )
        #expect(primary.contains("whisperkit"))
        #expect(primary.contains("openai_whisper-small"))
        #expect(primary.contains("escolha do usuário"))
        #expect(primary.contains("1ª escolha"))

        let fallback = DictationTranscription.logSummary(
            for: TranscriptionProvenance(
                engine: .parakeet,
                model: .parakeetTDT06BV3,
                useCase: .dictation,
                origin: .automatic,
                candidateRank: 3
            )
        )
        #expect(fallback.contains("automático"))
        #expect(fallback.contains("fallback #3"))
    }

    // MARK: - Estado do modelo na tela

    @Test("Cada estágio do motor vira o estágio equivalente da faixa de status")
    func modelStatusMirrorsRuntimeStage() {
        func status(_ stage: TranscriptionRuntimeStage) -> DictationTranscription.ModelStatus {
            DictationTranscription.modelStatus(
                for: stage,
                expecting: .whisperSmall,
                describingFailure: { _ in "boom" }
            )
        }

        #expect(status(.idle) == .idle)
        #expect(status(.downloading(model: .whisperSmall, fraction: 0.42)) == .downloading(0.42))
        #expect(status(.loading(model: .whisperSmall)) == .loading)
        #expect(status(.ready(model: .whisperSmall)) == .ready)
        #expect(
            status(.failed(model: .whisperSmall, failure: .hardwareUnsupported)) == .failed("boom")
        )
    }

    @Test("A mensagem da falha é de quem chama — a tradução não mora na lógica pura")
    func modelStatusDelegatesTheFailureMessage() {
        let status = DictationTranscription.modelStatus(
            for: .failed(model: .whisperMedium, failure: .modelUnavailable(.whisperMedium)),
            expecting: .whisperMedium,
            describingFailure: { failure in
                guard case .modelUnavailable(let model) = failure else { return "?" }
                return "faltou \(model.rawValue)"
            }
        )

        #expect(status == .failed("faltou openai_whisper-medium"))
    }

    /// O MAIOR do Farol na T2.4a: o motor é compartilhado com a tradução e troca de pesos, então
    /// estágio do motor certo com o modelo errado **não** é o ditado pronto.
    @Test("Estágio de OUTRO modelo do mesmo motor não vira 'Modelo pronto'")
    func modelStatusIgnoresAnotherModelOnTheSameEngine() {
        func status(_ stage: TranscriptionRuntimeStage) -> DictationTranscription.ModelStatus {
            DictationTranscription.modelStatus(
                for: stage,
                expecting: .whisperSmall,
                describingFailure: { _ in "boom" }
            )
        }

        // O caso que a faixa mentia: large-v3-turbo pronto, small ausente.
        #expect(status(.ready(model: .whisperLargeV3Turbo)) == .idle)
        #expect(status(.downloading(model: .whisperLargeV3Turbo, fraction: 0.9)) == .idle)
        #expect(status(.loading(model: .whisperLargeV3Turbo)) == .idle)
        // Falha de outro modelo também não é problema do ditado — nem alarme falso na tela dele.
        #expect(status(.failed(model: .whisperMedium, failure: .hardwareUnsupported)) == .idle)
    }

    @Test("Sem candidato no plano, a faixa não fala de modelo nenhum")
    func modelStatusWithoutCandidateIsIdle() {
        let status = DictationTranscription.modelStatus(
            for: .ready(model: .whisperSmall),
            expecting: nil,
            describingFailure: { _ in "boom" }
        )

        #expect(status == .idle)
    }

    // MARK: - Classificação de falha

    @Test("Plano vazio é 'nenhum candidato'")
    func emptyPlanIsNoCandidate() {
        let plan = TranscriptionRoutingPlan(
            useCase: .dictation,
            candidates: [],
            rejections: [],
            isStrict: true
        )

        #expect(DictationTranscription.failure(for: TranscriptionCoordinatorError.noCandidate(plan)) == .noCandidate)
    }

    @Test("Todos os candidatos falharam: vale a falha do último tentado")
    func allCandidatesFailedKeepsTheLastFailure() {
        let attempts = [
            TranscriptionAttempt(
                candidate: TranscriptionRoutingCandidate(
                    engine: .parakeet,
                    model: .parakeetTDT06BV3,
                    rank: 0,
                    origin: .userSelection
                ),
                stage: .preparation,
                failure: .modelUnavailable(.parakeetTDT06BV3)
            ),
            TranscriptionAttempt(
                candidate: TranscriptionRoutingCandidate(
                    engine: .whisperKit,
                    model: .whisperSmall,
                    rank: 1,
                    origin: .automatic
                ),
                stage: .inference,
                failure: .engineInternal("kaboom")
            )
        ]

        let failure = DictationTranscription.failure(
            for: TranscriptionCoordinatorError.allCandidatesFailed(attempts)
        )

        #expect(failure == .enginesFailed(.engineInternal("kaboom")))
    }

    @Test("Lista de tentativas vazia não inventa falha de motor")
    func allCandidatesFailedWithoutAttemptsIsNoCandidate() {
        #expect(
            DictationTranscription.failure(for: TranscriptionCoordinatorError.allCandidatesFailed([]))
                == .noCandidate
        )
    }

    @Test("Cancelamento nunca vira erro de tela — nem do coordenador, nem do motor")
    func cancellationIsNotAnError() {
        #expect(DictationTranscription.failure(for: TranscriptionCoordinatorError.cancelled) == .cancelled)
        #expect(DictationTranscription.failure(for: TranscriptionEngineFailure.cancelled) == .cancelled)
        #expect(DictationTranscription.failure(for: CancellationError()) == .cancelled)
    }

    @Test("Falha de motor solta é classificada como falha de motor")
    func looseEngineFailureIsClassified() {
        #expect(
            DictationTranscription.failure(for: TranscriptionEngineFailure.invalidAudio("áudio vazio"))
                == .enginesFailed(.invalidAudio("áudio vazio"))
        )
    }

    @Test("Erro desconhecido preserva a descrição técnica")
    func unknownErrorKeepsItsDescription() {
        struct Boom: Error {}

        guard case .unexpected(let detail) = DictationTranscription.failure(for: Boom()) else {
            Issue.record("erro desconhecido deveria virar .unexpected")
            return
        }
        #expect(!detail.isEmpty)
    }

    @Test("Erros estruturais do coordenador não viram 'motor falhou'")
    func structuralCoordinatorErrorsAreUnexpected() {
        let mismatch = DictationTranscription.failure(
            for: TranscriptionCoordinatorError.planMismatch(
                planUseCase: .meetingFinal,
                requestUseCase: .dictation
            )
        )
        guard case .unexpected(let detail) = mismatch else {
            Issue.record("planMismatch deveria virar .unexpected")
            return
        }
        #expect(detail.contains("meetingFinal"))
        #expect(detail.contains("dictation"))

        let streaming = DictationTranscription.failure(
            for: TranscriptionCoordinatorError.streamingUnsupported(.meetingPreview)
        )
        guard case .unexpected = streaming else {
            Issue.record("streamingUnsupported deveria virar .unexpected")
            return
        }
    }
}

private extension TranscriptionHardwareProfile {
    /// Um Mac Apple Silicon com memória de sobra — o hardware em que o ditado roda hoje. Fixo, e
    /// não `.detected()`, para o plano do teste não mudar conforme a máquina do CI.
    static let appleSiliconLike = TranscriptionHardwareProfile(
        architecture: .appleSilicon,
        hasNeuralEngine: true,
        physicalMemoryBytes: 32 * 1024 * 1024 * 1024
    )
}

/// O que a tela oferece tem que ser o que o roteador aceita.
@Suite("Motores oferecidos nos Ajustes")
struct SelectableEnginesTests {

    @Test("Em inglês o Parakeet não é oferecido")
    func englishHidesParakeet() {
        let disponiveis = AppSettings.TranscriptionEngine.selectable(for: .english)

        #expect(disponiveis.contains(.parakeet) == false)
        #expect(disponiveis.contains(.whisper))
        #expect(disponiveis.contains(.apple))
    }

    @Test("Em português os três aparecem")
    func portugueseOffersAll() {
        let disponiveis = AppSettings.TranscriptionEngine.selectable(for: .portuguese)

        #expect(Set(disponiveis) == Set(AppSettings.TranscriptionEngine.allCases))
    }

    @Test("Fora do português o Parakeet some da lista de engines")
    func otherLanguagesDropParakeetFromThePicker() {
        for language in Language.allCases where language != .portuguese {
            let disponiveis = AppSettings.TranscriptionEngine.selectable(for: language)

            #expect(
                disponiveis.contains(.parakeet) == false,
                "\(language.rawValue) oferecia o Parakeet, que só sabe português"
            )
            // Os outros dois atendem todos os idiomas do seletor — é o que torna a lista útil em
            // vez de um dropdown de um item só.
            #expect(Set(disponiveis) == [.whisper, .apple])
        }
    }

    @Test("Trocar para inglês tira o Parakeet de baixo do usuário em vez de deixar mentira salva")
    func switchingToEnglishMovesTheSelection() {
        var settings = AppSettings()
        settings.selectedLanguage = .portuguese
        settings.transcriptionEngine = .parakeet

        settings.selectedLanguage = .english
        let anterior = settings.realignTranscriptionEngineWithLanguage()

        #expect(anterior == .parakeet)
        #expect(settings.transcriptionEngine != .parakeet)
        #expect(AppSettings.TranscriptionEngine.selectable(for: .english).contains(settings.transcriptionEngine))
    }

    @Test("Motor que continua válido não é mexido")
    func validSelectionIsLeftAlone() {
        var settings = AppSettings()
        settings.selectedLanguage = .portuguese
        settings.transcriptionEngine = .apple

        settings.selectedLanguage = .english
        let anterior = settings.realignTranscriptionEngineWithLanguage()

        #expect(anterior == nil)
        #expect(settings.transcriptionEngine == .apple)
    }
}
