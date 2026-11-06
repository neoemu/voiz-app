import Testing
import Foundation

// Testes da metade (b) da guarda de idioma da Q2 (evidência), do retargeting do plano e da
// passagem que junta as duas metades.

@Suite("Guarda de idioma — plano e evidência (Q2)")
struct TranscriptionLanguageGuardTests {

    // MARK: - Retargeting

    @Test("Reapontar o plano troca o modelo do motor de locale fixo e preserva os multilíngues")
    func retargetingSwapsTheLocaleBoundModel() {
        let snapshot = LanguageProbeFixtures.snapshot(language: .portuguese)

        let corrected = TranscriptionLanguageGuard.retargeting(snapshot, to: .english)

        #expect(corrected.language == .english)
        #expect(corrected.candidates.map(\.engine) == [.appleSpeechAnalyzer, .whisperKit, .parakeet])
        // O modelo do Apple **é** o locale: sem esta troca o rank 0 pediria pt-BR num pedido em
        // inglês, que é o vazio que a guarda existe para evitar.
        #expect(corrected.candidates[0].model == .appleSystemSpeechENUS)
        #expect(corrected.candidates[1].model == .whisperSmall)
        #expect(corrected.candidates[2].model == .parakeetTDT06BV3)
        #expect(corrected.candidates.map(\.rank) == [0, 1, 2])
    }

    @Test("Reapontar preserva a decisão congelada: caso de uso, strict e o instante do congelamento")
    func retargetingPreservesTheFrozenDecision() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = LanguageProbeFixtures.snapshot(
            language: .english,
            isStrict: true,
            createdAt: createdAt
        )

        let corrected = TranscriptionLanguageGuard.retargeting(snapshot, to: .portuguese)

        #expect(corrected.useCase == .meetingFinal)
        #expect(corrected.isStrict)
        // A data é "quando esta decisão foi tomada": o retarget corrige o locale, não retoma a
        // decisão. Carimbar agora faria um plano antigo parecer recém-criado.
        #expect(corrected.createdAt == createdAt)
    }

    @Test("Motor sem modelo para o idioma novo sai do plano, e os ranks são renumerados")
    func retargetingDropsEnginesWithoutAModel() {
        // Catálogo falso: um motor só-pt na frente de um multilíngue.
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(
                .fakeAlpha,
                languages: [.portugueseBrazil],
                detectsLanguage: false,
                models: [TranscriptionFixtures.model(.fakePtOnly, engine: .fakeAlpha, languages: [.portugueseBrazil])]
            ),
            TranscriptionFixtures.engine(.fakeBravo)
        ])
        let snapshot = TranscriptionPlanSnapshot(
            language: .portuguese,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(engine: .fakeAlpha, model: .fakePtOnly, rank: 0, origin: .automatic),
                TranscriptionPlanSnapshot.Candidate(engine: .fakeBravo, model: .fakeLight, rank: 1, origin: .automatic)
            ],
            isStrict: false
        )

        let corrected = TranscriptionLanguageGuard.retargeting(snapshot, to: .english, in: catalog)

        #expect(corrected.candidates.map(\.engine) == [.fakeBravo])
        // Renumerado: um plano cujo rank 0 desapareceu não pode continuar começando no rank 1 — o
        // `nextPrimaryCandidate` da reunião ordena por rank.
        #expect(corrected.candidates.map(\.rank) == [0])
    }

    @Test("Trocar o modelo rebaixa a origem para automática; manter o modelo preserva a escolha")
    func retargetingDowngradesOriginOnlyWhenTheModelChanges() {
        let snapshot = TranscriptionPlanSnapshot(
            language: .portuguese,
            candidates: [
                // Pin do usuário num motor de locale fixo: o modelo TEM que mudar.
                TranscriptionPlanSnapshot.Candidate(
                    engine: .appleSpeechAnalyzer,
                    model: .appleSystemSpeechPTBR,
                    rank: 0,
                    origin: .userSelection
                ),
                // Pin num motor multilíngue: o modelo sobrevive, então a escolha sobrevive.
                TranscriptionPlanSnapshot.Candidate(
                    engine: .whisperKit,
                    model: .whisperLargeV3Turbo,
                    rank: 1,
                    origin: .userSelection
                )
            ],
            isStrict: false
        )

        let corrected = TranscriptionLanguageGuard.retargeting(snapshot, to: .english)

        // Regra 3 do roteador aplicada aqui: o que vai rodar já não é o que o usuário pediu, então a
        // proveniência não pode dizer `userSelection`.
        #expect(corrected.candidates[0].model == .appleSystemSpeechENUS)
        #expect(corrected.candidates[0].origin == .automatic)
        #expect(corrected.candidates[1].model == .whisperLargeV3Turbo)
        #expect(corrected.candidates[1].origin == .userSelection)
    }

    @Test("Motor desconhecido neste app fica intacto em vez de sumir por ignorância")
    func retargetingKeepsUnknownEngines() {
        let future = TranscriptionEngineID("tagarela")
        let snapshot = TranscriptionPlanSnapshot(
            language: .portuguese,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(
                    engine: future,
                    model: TranscriptionModelID("tagarela-v9"),
                    rank: 0,
                    origin: .automatic
                )
            ],
            isStrict: false
        )

        let corrected = TranscriptionLanguageGuard.retargeting(snapshot, to: .english)

        #expect(corrected.candidates.map(\.engine) == [future])
        #expect(corrected.candidates[0].model == TranscriptionModelID("tagarela-v9"))
    }

    // MARK: - Idiomas do catálogo

    @Test("Os idiomas serviveis saem do catálogo, canônicos e na ordem de declaração")
    func servableLanguagesComeFromTheCatalog() {
        // Os sete do seletor, na ordem em que o catálogo os declara. A ordem importa de verdade:
        // é ela que decide quais alternativos o orçamento de 2 tentativas chega a experimentar,
        // e por isso português e inglês vêm primeiro.
        #expect(
            TranscriptionLanguageGuard.servableLanguages()
                == [.portuguese, .english, .spanish, .french, .german, .japanese, .chinese]
        )
        #expect(
            TranscriptionLanguageGuard.alternates(to: .portuguese)
                == [.english, .spanish, .french, .german, .japanese, .chinese]
        )
        // Regional entra e sai canônico: `pt-BR` não pode reaparecer como alternativo de `pt`.
        #expect(
            TranscriptionLanguageGuard.alternates(to: .portugueseBrazil)
                == TranscriptionLanguageGuard.alternates(to: .portuguese)
        )
        #expect(TranscriptionLanguageGuard.alternates(to: .englishUS).contains(.english) == false)
        #expect(TranscriptionLanguageGuard.correctionTarget(for: .portugueseBrazil) == .portuguese)
        #expect(TranscriptionLanguageGuard.correctionTarget(for: .japaneseJapan) == .japanese)
        // Italiano: o `SpeechTranscriber` tem it_IT, mas o app não oferece — e o que o app não
        // oferece não é alvo de correção.
        #expect(TranscriptionLanguageGuard.correctionTarget(for: TranscriptionLanguage("it")) == nil)
    }

    // MARK: - Medida de fala

    @Test("A fala é contada por frame: 3 s de voz num lote de 26 s não desaparecem no RMS global")
    func speechIsCountedPerFrame() {
        let batch = LanguageProbeFixtures.silence(seconds: 11)
            + LanguageProbeFixtures.speech(seconds: 3)
            + LanguageProbeFixtures.silence(seconds: 12)

        let measured = TranscriptionLanguageGuard.speechSeconds(in: batch)

        #expect(measured > 2.5)
        #expect(measured < 3.5)
        #expect(TranscriptionLanguageGuard.speechSeconds(in: LanguageProbeFixtures.silence(seconds: 26)) == 0)
        #expect(TranscriptionLanguageGuard.speechSeconds(in: []) == 0)
    }

    // MARK: - Evidência

    @Test("Lote com fala e texto vazio tenta o outro locale antes de aceitar o vazio")
    func speechWithoutTextTriesTheOtherLocale() {
        var guardState = TranscriptionLanguageEvidenceGuard()

        let verdict = guardState.verdict(
            forEmptyBatch: LanguageProbeFixtures.speech(seconds: 6),
            planned: .english
        )

        #expect(verdict == .tryAlternate(.portuguese))
        #expect(guardState.spentAttempts == 1)
    }

    @Test("Lote sem fala aceita o vazio direto — vazio é a resposta certa para silêncio")
    func silentBatchAcceptsEmptyWithoutSpendingAnything() {
        var guardState = TranscriptionLanguageEvidenceGuard()

        let verdict = guardState.verdict(
            forEmptyBatch: LanguageProbeFixtures.silence(seconds: 26),
            planned: .english
        )

        #expect(verdict == .acceptEmpty(.noSpeechEvidence(0)))
        // Um veredito que não virou tentativa não pode gastar o que a próxima vai precisar.
        #expect(guardState.spentAttempts == 0)
    }

    @Test("Plano sem idioma não tem locale para trocar")
    func automaticLanguageHasNothingToSwap() {
        var guardState = TranscriptionLanguageEvidenceGuard()

        #expect(
            guardState.verdict(
                forEmptyBatch: LanguageProbeFixtures.speech(seconds: 6),
                planned: nil
            ) == .acceptEmpty(.planHasNoLanguage)
        )
    }

    @Test("Tentativa que produz texto adota o idioma novo e fecha o caminho de volta")
    func successfulAlternateIsAdoptedAndTheOldOneIsRuledOut() {
        var guardState = TranscriptionLanguageEvidenceGuard()
        let speech = LanguageProbeFixtures.speech(seconds: 6)

        #expect(guardState.verdict(forEmptyBatch: speech, planned: .english) == .tryAlternate(.portuguese))
        #expect(
            guardState.note(alternate: .portuguese, result: .producedText, replacing: .english)
                == .adopts(.portuguese)
        )

        // Agora o plano está em pt. Um lote vazio com fala em pt não pode voltar para en: ele já se
        // provou silencioso neste material. Sem isso, a guarda oscilaria a cada lote vazio.
        #expect(guardState.ruledOut == [.english])
        let depois = guardState.verdict(forEmptyBatch: speech, planned: .portuguese)
        #expect(depois != .tryAlternate(.english), "não existe caminho de volta")

        // Com sete idiomas a lista não se esgota numa tentativa — quem para a busca é o orçamento.
        #expect(depois == .tryAlternate(.spanish))
        #expect(
            guardState.verdict(forEmptyBatch: speech, planned: .portuguese)
                == .acceptEmpty(.budgetSpent(2))
        )
    }

    @Test("Tentativa que também volta vazia descarta o alternativo e para de insistir")
    func failedAlternateIsRuledOut() {
        var guardState = TranscriptionLanguageEvidenceGuard()
        let speech = LanguageProbeFixtures.speech(seconds: 6)

        #expect(guardState.verdict(forEmptyBatch: speech, planned: .portuguese) == .tryAlternate(.english))
        #expect(
            guardState.note(alternate: .english, result: .empty, replacing: .portuguese)
                == .keepsPlan
        )
        #expect(guardState.ruledOut == [.english])

        // O locale que voltou vazio não é tentado de novo: a próxima pergunta é outra.
        #expect(
            guardState.verdict(forEmptyBatch: speech, planned: .portuguese)
                == .tryAlternate(.spanish)
        )
        #expect(guardState.spentAttempts == 2)

        // E aí acaba. O material simplesmente não rende texto — pode ser música, ruído ou um
        // idioma que o app não oferece. O vazio dos lotes seguintes é para valer, e sai de graça:
        // é o orçamento que impede a passagem de varrer os sete, uma inferência de lote por vez.
        #expect(
            guardState.verdict(forEmptyBatch: speech, planned: .portuguese)
                == .acceptEmpty(.budgetSpent(2))
        )
        #expect(guardState.spentAttempts == 2)
    }

    @Test("O orçamento é o cinto: com três idiomas, ele para antes de gastar todos")
    func budgetStopsTheSearchEvenWithMoreLanguagesAvailable() {
        // Com dois idiomas o `ruledOut` já basta; o orçamento só é observável quando há mais de um
        // alternativo. É este teste que impede alguém de "simplificar" removendo o contador.
        let french = TranscriptionLanguage("fr")
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(
                .fakeAlpha,
                languages: [.portuguese, .english, french],
                detectsLanguage: false
            )
        ])
        var guardState = TranscriptionLanguageEvidenceGuard(alternateAttemptBudget: 1)
        let speech = LanguageProbeFixtures.speech(seconds: 6)

        #expect(
            guardState.verdict(forEmptyBatch: speech, planned: .portuguese, catalog: catalog)
                == .tryAlternate(.english)
        )
        _ = guardState.note(alternate: .english, result: .empty, replacing: .portuguese)

        // `fr` ainda estava disponível; o orçamento é o que impede a passagem de gastar uma
        // inferência inteira por idioma do catálogo.
        #expect(
            guardState.verdict(forEmptyBatch: speech, planned: .portuguese, catalog: catalog)
                == .acceptEmpty(.budgetSpent(1))
        )
    }

    @Test("Tentativa que FALHA não é evidência sobre idioma: a porta do locale continua aberta")
    func failedTrialIsNotEvidenceAboutLanguage() {
        // O caso real: o asset en-US não está instalado e a tentativa lança. Se isso contasse como
        // "en não rende neste material", a guarda fecharia pelo resto da passagem a porta do idioma
        // que pode ser justamente o certo — por um motivo que nada tem a ver com idioma.
        var guardState = TranscriptionLanguageEvidenceGuard(alternateAttemptBudget: 2)
        let speech = LanguageProbeFixtures.speech(seconds: 6)

        #expect(guardState.verdict(forEmptyBatch: speech, planned: .portuguese) == .tryAlternate(.english))
        #expect(
            guardState.note(alternate: .english, result: .failed, replacing: .portuguese)
                == .keepsPlan
        )
        #expect(guardState.ruledOut.isEmpty)

        // A porta continua aberta — o que limita a repetição é o orçamento, que já foi gasto uma vez.
        #expect(guardState.verdict(forEmptyBatch: speech, planned: .portuguese) == .tryAlternate(.english))
        #expect(guardState.spentAttempts == 2)
        #expect(
            guardState.verdict(forEmptyBatch: speech, planned: .portuguese)
                == .acceptEmpty(.budgetSpent(2))
        )
    }

    @Test("A tentativa é uma pergunta: uma vez, e sem escrever nos livros da reunião")
    func trialRetryPolicyNeverWritesInTheMeetingBooks() {
        let policy = TranscriptionLanguageGuard.trialRetryPolicy

        // Uma tentativa: a experiência não é o transcript.
        #expect(policy.attemptsPerCandidate == 1)
        // E NÃO registra. A versão anterior registrava, sob a premissa de que o candidato da
        // tentativa é sempre outro modelo — falsa, porque o retarget preserva o modelo dos motores
        // multilíngues. O contraexemplo está travado em
        // `trialFailureDoesNotSuppressTheNormalPlan`, que é quem prova o efeito; esta linha é o valor.
        #expect(policy.recordsGlobalFailure == false)
        // E não é a política dos lotes, que tem duas tentativas por candidato e supressão de reunião.
        #expect(policy != MeetingTranscription.batchRetryPolicy)
    }

    @Test("Falha da tentativa não condena o plano normal num motor multilíngue")
    func trialFailureDoesNotSuppressTheNormalPlan() async throws {
        // O contraexemplo do Farol, travado com o coordenador de verdade e motores falsos — nenhuma
        // asserção aqui é sobre o valor da política, e sim sobre o que o próximo lote sofre.
        //
        // Por que ele existe: `retargeting` PRESERVA o modelo dos motores multilíngues (só o Apple,
        // cujo modelo é o locale, troca) e a `FailureKey` do coordenador é (caso de uso, motor,
        // modelo), SEM idioma. Então uma tentativa em inglês que falhe no mesmo par motor+modelo do
        // plano marcava esse par pelo cooldown infinito da passagem, e o lote normal em português o
        // pulava como `.suppressed` sem tocar no motor.
        let catalog = CoordinatorFixtures.catalog()
        let log = EngineCallLog()
        let alpha = CoordinatorFakeEngine(
            id: .fakeAlpha,
            descriptor: CoordinatorFixtures.descriptor(.fakeAlpha, in: catalog),
            log: log,
            text: "alfa",
            // A tentativa alternativa é a PRIMEIRA inferência deste motor, e ela falha.
            transcribeFailures: [1: .engineInternal("a tentativa no outro locale falhou")]
        )
        let bravo = CoordinatorFakeEngine(
            id: .fakeBravo,
            descriptor: CoordinatorFixtures.descriptor(.fakeBravo, in: catalog),
            log: log,
            text: "bravo"
        )
        let coordinator = TranscriptionCoordinator(
            engines: [.fakeAlpha: alpha, .fakeBravo: bravo],
            router: TranscriptionRouter(catalog: catalog),
            hardware: .appleSilicon16GB
        )

        // O plano da passagem: o mesmo par motor+modelo serve os dois idiomas, que é exatamente o
        // caso do Whisper small e do Parakeet no plano real.
        let plan = await coordinator.plan(for: .meetingFinal, language: .portuguese)
        #expect(plan.candidates.map(\.engine) == [.fakeAlpha, .fakeBravo])

        // 1. A tentativa em outro locale falha no rank 0 (e o próprio trial cai para o rank 1).
        _ = try? await coordinator.transcribe(
            TranscriptionRequest(
                useCase: .meetingFinal,
                language: .english,
                audio: TranscriptionFixtures.audio()
            ),
            using: plan,
            retryPolicy: TranscriptionLanguageGuard.trialRetryPolicy
        )
        #expect(
            await coordinator.recordedFailure(
                useCase: .meetingFinal,
                engine: .fakeAlpha,
                model: .fakeLight
            ) == nil,
            "a tentativa escreveu supressão nos livros da reunião"
        )

        // 2. O lote NORMAL seguinte tem que tentar o rank 0 de novo, e vencer com ele.
        let outcome = try await coordinator.transcribe(
            TranscriptionRequest(
                useCase: .meetingFinal,
                language: .portuguese,
                audio: TranscriptionFixtures.audio()
            ),
            using: plan,
            retryPolicy: MeetingTranscription.batchRetryPolicy
        )

        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(outcome.provenance.candidateRank == 0)
        #expect(outcome.text == "alfa")
        // A prova que o `.suppressed` esconderia: o motor foi de fato chamado a segunda vez.
        #expect(await alpha.transcribeCalls == 2)
    }

    // MARK: - A passagem

    @Test("O probe é consumido uma vez por passagem, mesmo quando não conclui nada")
    func theProbeIsSpentOncePerPass() {
        var pass = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(language: .english))

        #expect(pass.probePlan != nil)
        #expect(pass.applyProbe(detected: nil, reportedBy: .whisperKit) == .keepsPlan(.noDetection))
        #expect(pass.hasProbed)
        // Sem isto, um probe inconclusivo seria repetido a cada lote — uma inferência extra por lote
        // numa reunião inteira.
        #expect(pass.probePlan == nil)
        #expect(!pass.isCorrected)

        var skipped = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot())
        skipped.skipProbe()
        #expect(skipped.probePlan == nil)
        #expect(!skipped.isCorrected)
    }

    @Test("Idioma explícito: probe detectando outro idioma não reescreve o plano da passagem")
    func explicitProbeDoesNotRewriteThePassPlan() {
        var pt = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(language: .portuguese))
        #expect(pt.applyProbe(detected: .english, reportedBy: .whisperKit)
            == .keepsPlan(.explicitLanguageIsSovereign(detected: .english)))
        #expect(pt.language == .portuguese)
        #expect(!pt.isCorrected)
        #expect(pt.languageIsExplicit)
        #expect(pt.snapshot.candidates.first?.model == .appleSystemSpeechPTBR)

        var en = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(
            language: .english,
            candidates: [
                (.appleSpeechAnalyzer, .appleSystemSpeechENUS),
                (.whisperKit, .whisperSmall),
                (.parakeet, .parakeetTDT06BV3)
            ]
        ))
        #expect(en.applyProbe(detected: .portuguese, reportedBy: .whisperKit)
            == .keepsPlan(.explicitLanguageIsSovereign(detected: .portuguese)))
        #expect(en.language == .english)
        #expect(!en.isCorrected)
        #expect(en.languageIsExplicit)
        #expect(en.snapshot.candidates.first?.model == .appleSystemSpeechENUS)
    }

    @Test("autoAdopted: probe discordante ainda corrige o plano da passagem")
    func autoAdoptedProbeRewritesThePassPlan() {
        var pass = TranscriptionLanguagePass(
            snapshot: LanguageProbeFixtures.autoAdopted(language: .english)
        )

        let decision = pass.applyProbe(detected: .portuguese, reportedBy: .whisperKit)

        #expect(decision == .corrects(to: .portuguese))
        #expect(pass.language == .portuguese)
        #expect(pass.isCorrected)
        #expect(!pass.languageIsExplicit)
        #expect(pass.snapshot.languageOrigin == .autoAdopted)
        #expect(pass.snapshot.candidates.map(\.engine) == [.whisperKit, .parakeet])
        #expect(pass.snapshot.candidates.contains { $0.engine == .appleSpeechAnalyzer } == false)
    }

    @Test("O plano de experimento não adota nada: quem decide é o resultado")
    func trialPlanDoesNotMutateThePass() {
        var pass = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(language: .portuguese))

        let trial = pass.trialPlan(for: .english)

        #expect(trial?.candidates.first?.model == .appleSystemSpeechENUS)
        // Nada mudou na passagem — adotar antes de ver o resultado seria trocar o plano por palpite.
        #expect(pass.language == .portuguese)
        #expect(!pass.isCorrected)
        #expect(pass.snapshot.candidates.first?.model == .appleSystemSpeechPTBR)
    }

    @Test("Idioma explícito: evidência não tenta nem adota o outro locale")
    func explicitPassDoesNotAdoptAlternateFromEvidence() {
        var pt = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(language: .portuguese))
        let speech = LanguageProbeFixtures.speech(seconds: 6)
        #expect(pt.verdictForEmptyBatch(samples: speech) == .acceptEmpty(.explicitLanguageIsSovereign))
        #expect(pt.note(alternate: .english, result: .producedText) == .keepsPlan)
        #expect(pt.language == .portuguese)
        #expect(!pt.isCorrected)

        var en = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(
            language: .english,
            candidates: [
                (.appleSpeechAnalyzer, .appleSystemSpeechENUS),
                (.whisperKit, .whisperSmall)
            ]
        ))
        #expect(en.verdictForEmptyBatch(samples: speech) == .acceptEmpty(.explicitLanguageIsSovereign))
        #expect(en.note(alternate: .portuguese, result: .producedText) == .keepsPlan)
        #expect(en.language == .english)
        #expect(!en.isCorrected)
    }

    @Test("autoAdopted: lote vazio com fala ainda pode adotar o outro locale")
    func autoAdoptedEvidenceCanStillAdopt() {
        var pass = TranscriptionLanguagePass(
            snapshot: LanguageProbeFixtures.autoAdopted(language: .english)
        )
        let speech = LanguageProbeFixtures.speech(seconds: 6)

        #expect(!pass.languageIsExplicit)
        #expect(pass.verdictForEmptyBatch(samples: speech) == .tryAlternate(.portuguese))
        #expect(pass.note(alternate: .portuguese, result: .producedText) == .adopts(.portuguese))
        #expect(pass.language == .portuguese)
        #expect(pass.isCorrected)
        #expect(pass.snapshot.languageOrigin == .autoAdopted)
        #expect(pass.snapshot.candidates.contains { $0.engine == .appleSpeechAnalyzer } == false)
    }

    @Test("Persist → decode → nova Pass: autoAdopted continua corrigível; explicit continua soberano")
    func originSurvivesRoundTripIntoANewPass() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let speech = LanguageProbeFixtures.speech(seconds: 6)

        let adoptedData = try encoder.encode(
            LanguageProbeFixtures.autoAdopted(language: .english)
        )
        let adopted = try decoder.decode(TranscriptionPlanSnapshot.self, from: adoptedData)
        #expect(adopted.languageOrigin == .autoAdopted)
        var adoptedPass = TranscriptionLanguagePass(snapshot: adopted)
        #expect(!adoptedPass.languageIsExplicit)
        #expect(adoptedPass.verdictForEmptyBatch(samples: speech) == .tryAlternate(.portuguese))

        let explicitData = try encoder.encode(LanguageProbeFixtures.snapshot(language: .portuguese))
        let explicit = try decoder.decode(TranscriptionPlanSnapshot.self, from: explicitData)
        #expect(explicit.languageOrigin == .explicit)
        var explicitPass = TranscriptionLanguagePass(snapshot: explicit)
        #expect(explicitPass.languageIsExplicit)
        #expect(explicitPass.verdictForEmptyBatch(samples: speech) == .acceptEmpty(.explicitLanguageIsSovereign))

        let legacy = try decoder.decode(
            TranscriptionPlanSnapshot.self,
            from: Data(#"""
            {"language":"en","candidates":[{"engine":"whisperkit","model":"openai_whisper-small","rank":0,"origin":"automatic"}],"isStrict":false,"createdAt":"2026-08-01T00:00:00Z","useCase":"meetingFinal"}
            """#.utf8)
        )
        #expect(legacy.languageOrigin == .unresolved)

        let unknown = try decoder.decode(
            TranscriptionPlanSnapshot.self,
            from: Data(#"""
            {"language":"pt","languageOrigin":"origem-do-futuro","candidates":[{"engine":"whisperkit","model":"openai_whisper-small","rank":0,"origin":"automatic"}],"isStrict":false,"createdAt":"2026-08-01T00:00:00Z","useCase":"meetingFinal"}
            """#.utf8)
        )
        #expect(unknown.languageOrigin == .unresolved)
    }

    @Test("Legado sem origin: igual ao explícito atual mantém; QUALQUER mismatch reconstrói (com ou sem Apple); auto é corrigível")
    func unresolvedOriginResolvesAgainstCurrentSettings() {
        let enWithApple = LanguageProbeFixtures.snapshot(language: .english, languageOrigin: .unresolved)
        let ptWithApple = LanguageProbeFixtures.snapshot(language: .portuguese, languageOrigin: .unresolved)
        let enNoApple = LanguageProbeFixtures.snapshot(
            language: .english,
            languageOrigin: .unresolved,
            candidates: [
                (.whisperKit, .whisperSmall),
                (.parakeet, .parakeetTDT06BV3)
            ]
        )

        switch MeetingTranscription.preparingStoredPlan(ptWithApple, selectedLanguage: .portuguese) {
        case .usable(let prepared, persistResolvedOrigin: true):
            #expect(prepared.languageOrigin == .explicit)
            #expect(TranscriptionLanguagePass(snapshot: prepared).languageIsExplicit)
        case .usable(_, persistResolvedOrigin: false):
            Issue.record("unresolved resolvido tem que pedir persist one-shot")
        case .unusable:
            Issue.record("pt explícito igual ao snapshot tinha que manter")
        }

        switch MeetingTranscription.preparingStoredPlan(enWithApple, selectedLanguage: .portuguese) {
        case .unusable:
            break
        case .usable:
            Issue.record("en no disco + Apple + pt nos Ajustes é ambíguo — Ajustes vencem")
        }

        // A heurística removida (r5): "sem candidato Apple = auto congelado" é
        // falsificável — um Mac Intel não tem Apple em plano NENHUM
        // (SpeechAnalyzer exige Apple Silicon; ver TranscriptionCatalogTests) e
        // um decode parcial dá a mesma assinatura. Nos dois casos um plano
        // legitimamente explícito era relido como auto. Reintroduzir o
        // `if !candidates.contains(appleSpeechAnalyzer) { .autoAdopted }`
        // quebra este ramo.
        #expect(enNoApple.candidates.contains(where: { $0.engine == .appleSpeechAnalyzer }) == false)
        switch MeetingTranscription.preparingStoredPlan(enNoApple, selectedLanguage: .portuguese) {
        case .unusable:
            break
        case .usable:
            Issue.record("mismatch com o explícito atual reconstrói mesmo sem Apple no plano")
        }

        // Idem para o plano sem idioma gravado: não casa com o explícito de hoje.
        let noLanguageNoApple = LanguageProbeFixtures.snapshot(
            language: nil,
            languageOrigin: .unresolved,
            candidates: [
                (.whisperKit, .whisperSmall),
                (.parakeet, .parakeetTDT06BV3)
            ]
        )
        switch MeetingTranscription.preparingStoredPlan(noLanguageNoApple, selectedLanguage: .english) {
        case .unusable:
            break
        case .usable:
            Issue.record("plano sem idioma não pode passar por explícito igual ao dos Ajustes")
        }

        // O `.auto` dos Ajustes deixou de existir em 29/08/2026, e com ele o único caminho que
        // fazia um unresolved legado virar `autoAdopted`. O que sobra é binário: casa com o
        // idioma explícito de hoje (vira `explicit`, one-shot) ou é reconstruído.
        //
        // A consequência que este ramo trava: uma sessão incompleta gravada no automático antigo
        // NÃO volta a ser tratada como automática. Ela é lida contra a escolha atual do humano —
        // que é a informação mais confiável que existe sobre o idioma daquele áudio.
        switch MeetingTranscription.preparingStoredPlan(enWithApple, selectedLanguage: .english) {
        case .usable(let prepared, persistResolvedOrigin: true):
            #expect(prepared.languageOrigin == .explicit)
            var pass = TranscriptionLanguagePass(snapshot: prepared)
            #expect(pass.languageIsExplicit)
            // E sendo explícito, o probe não corrige mais nada: o idioma do humano é soberano.
            #expect(
                pass.applyProbe(detected: .portuguese, reportedBy: .whisperKit)
                    == .keepsPlan(.explicitLanguageIsSovereign(detected: .portuguese))
            )
        case .usable(_, persistResolvedOrigin: false):
            Issue.record("unresolved resolvido tem que pedir persist one-shot")
        case .unusable:
            Issue.record("en no disco + en nos Ajustes tinha que casar")
        }

        let recorded = LanguageProbeFixtures.snapshot(language: .english, languageOrigin: .explicit)
        switch MeetingTranscription.preparingStoredPlan(recorded, selectedLanguage: .portuguese) {
        case .usable(let prepared, persistResolvedOrigin: false):
            #expect(prepared.languageOrigin == .explicit)
        case .usable(_, persistResolvedOrigin: true):
            Issue.record("origem já gravada não se reinterpreta nem se re-persiste")
        case .unusable:
            Issue.record("origem já gravada não se reinterpreta")
        }
    }

    @Test("Tentativa vazia ou falha não mexe no plano da passagem")
    func failedTrialLeavesThePassAlone() {
        // Auto: a evidência ainda registra o trial. Explícito nem chega aqui (note é no-op).
        var empty = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(language: nil))
        #expect(empty.note(alternate: .english, result: .empty) == .keepsPlan)
        #expect(empty.language == nil)
        #expect(!empty.isCorrected)

        var failed = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(language: nil))
        #expect(failed.note(alternate: .english, result: .failed) == .keepsPlan)
        #expect(failed.language == nil)
        #expect(!failed.isCorrected)
        // E a diferença que importa: o vazio fecha o locale, a falha não.
        #expect(empty.evidence.ruledOut == [.english])
        #expect(failed.evidence.ruledOut.isEmpty)
    }

    @Test("A passagem usa a MESMA definição de plano utilizável que a reunião")
    func passUsesTheMeetingDefinitionOfUsablePlan() {
        // Sessão legada (sem candidato) tem que se comportar como antes da T2.5: sem plano.
        let empty = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot(candidates: []))
        #expect(empty.batchPlan == nil)
        #expect(empty.trialPlan(for: .english) == nil)

        let usable = TranscriptionLanguagePass(snapshot: LanguageProbeFixtures.snapshot())
        #expect(usable.batchPlan?.candidates.count == 3)
    }

    @Test("A linha de log da evidência traz idioma, motivo e números — nunca texto")
    func evidenceLogSummaryIsRedactedByConstruction() {
        let trying = TranscriptionLanguageEvidenceGuard.logSummary(
            .tryAlternate(.portuguese),
            planned: .english
        )
        #expect(trying.contains("pt"))
        #expect(trying.contains("en"))

        let accepted = TranscriptionLanguageEvidenceGuard.logSummary(
            .acceptEmpty(.budgetSpent(2)),
            planned: .portuguese
        )
        #expect(accepted.contains("orçamento"))
        #expect(accepted.contains("2"))
    }
}
