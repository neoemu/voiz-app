import Testing
import Foundation

/// A lógica pura da transcrição pós-call da reunião (T2.5): o plano congelado, a política de retry
/// dos lotes, o rebaixamento para o próximo candidato e a proveniência por turno.
///
/// Tudo aqui roda sem host app, sem áudio e sem motor — é o que sobra do `MeetingViewModel` depois
/// que as decisões saem dele (mesmo desenho da `DictationTranscriptionTests`, T2.4a).
@Suite("Reunião — plano congelado, retry e proveniência")
struct MeetingTranscriptionTests {

    // MARK: - Fixtures

    private static func candidate(
        _ engine: TranscriptionEngineID,
        _ model: TranscriptionModelID,
        rank: Int,
        origin: TranscriptionSelectionOrigin = .automatic
    ) -> TranscriptionRoutingCandidate {
        TranscriptionRoutingCandidate(engine: engine, model: model, rank: rank, origin: origin)
    }

    /// Um plano com Whisper large-v3-turbo escolhido pelo usuário e Parakeet atrás como fallback.
    private static func planWithFallback() -> TranscriptionRoutingPlan {
        TranscriptionRoutingPlan(
            useCase: .meetingFinal,
            candidates: [
                candidate(.whisperKit, .whisperLargeV3Turbo, rank: 0, origin: .userSelection),
                candidate(.parakeet, .parakeetTDT06BV3, rank: 1)
            ],
            rejections: [
                TranscriptionRoutingRejection(engine: .appleSpeechAnalyzer, reason: .hardwareUnsupported)
            ],
            isStrict: false
        )
    }

    private static func provenance(
        _ engine: TranscriptionEngineID,
        _ model: TranscriptionModelID,
        rank: Int = 0,
        origin: TranscriptionSelectionOrigin = .automatic
    ) -> TranscriptionProvenance {
        TranscriptionProvenance(
            engine: engine,
            model: model,
            useCase: .meetingFinal,
            origin: origin,
            candidateRank: rank
        )
    }

    // MARK: - Política de retry dos lotes

    @Test("Os lotes pedem 2 tentativas por candidato — é o 'retry 1× por lote' do PLANO")
    func theBatchPolicyRetriesOncePerCandidate() {
        #expect(MeetingTranscription.batchRetryPolicy.attemptsPerCandidate == 2)
    }

    @Test("A supressão dura a reunião inteira, e não os 300 s do ditado")
    func theBatchPolicySuppressesForTheWholeMeeting() {
        // Com 300 s, uma reunião de ~7 min ganharia exatamente uma retentativa no meio dela — e o
        // `runLoad` dos motores evicta o residente ANTES de tentar carregar o novo, então o lote que
        // disparasse o retry perderia o fallback que estava servindo (análise da Quilha).
        #expect(MeetingTranscription.batchRetryPolicy.failureCooldown > 60 * 60 * 24)
        #expect(MeetingTranscription.batchRetryPolicy.failureCooldown == .greatestFiniteMagnitude)
    }

    @Test("A falha de um lote é registrada globalmente — os lotes NÃO usam .silentInteractive")
    func theBatchPolicyRecordsFailuresGlobally() {
        // O aviso da Quilha para esta tarefa: consumidor silencioso não escreve `latchedModels`,
        // então `clearingLatch` nunca é acionado e `unload()` — o único caminho contratual para
        // limpar o latch do motor — nunca acontece. Não há vencimento de cooldown para ele, e uma
        // falha transitória de preparação mataria a reunião inteira.
        #expect(MeetingTranscription.batchRetryPolicy.recordsGlobalFailure)
        #expect(MeetingTranscription.batchRetryPolicy != .silentInteractive)
        #expect(MeetingTranscription.batchRetryPolicy == .meetingBatch)
    }

    // MARK: - O snapshot

    @Test("O snapshot preserva candidatos, ordem, idioma e strict")
    func theSnapshotPreservesThePlan() {
        let snapshot = TranscriptionPlanSnapshot(
            plan: Self.planWithFallback(),
            language: .portugueseBrazil
        )

        #expect(snapshot.useCase == .meetingFinal)
        #expect(snapshot.language == .portugueseBrazil)
        #expect(snapshot.isStrict == false)
        #expect(snapshot.candidates.count == 2)
        #expect(snapshot.primary?.engine == .whisperKit)
        #expect(snapshot.primary?.model == .whisperLargeV3Turbo)
        #expect(snapshot.primary?.origin == .userSelection)
        #expect(snapshot.candidates.last?.engine == .parakeet)
        #expect(snapshot.candidates.last?.rank == 1)
    }

    @Test("O plano volta do snapshot na mesma ordem — mesmo com os candidatos fora de ordem")
    func theRoutingPlanComesBackInRankOrder() {
        // Rank é o que define a ordem de tentativa; um JSON editado à mão (ou um encode futuro que
        // não preserve ordem) não pode inverter primeira escolha e fallback.
        let snapshot = TranscriptionPlanSnapshot(
            language: .portuguese,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(
                    engine: .parakeet, model: .parakeetTDT06BV3, rank: 1, origin: .automatic
                ),
                TranscriptionPlanSnapshot.Candidate(
                    engine: .whisperKit, model: .whisperSmall, rank: 0, origin: .userSelection
                )
            ],
            isStrict: false
        )

        let plan = snapshot.routingPlan
        #expect(plan.candidates.map(\.rank) == [0, 1])
        #expect(plan.primary?.engine == .whisperKit)
        #expect(plan.useCase == .meetingFinal)
        // As rejeições não são persistidas: são diagnóstico do instante em que o roteador decidiu.
        #expect(plan.rejections.isEmpty)
    }

    @Test("Strict sobrevive ao snapshot — uma reunião estrita não ganha fallback na volta")
    func strictSurvivesTheRoundTrip() throws {
        let strict = TranscriptionRoutingPlan(
            useCase: .meetingFinal,
            candidates: [Self.candidate(.parakeet, .parakeetTDT06BV3, rank: 0, origin: .userSelection)],
            rejections: [],
            isStrict: true
        )
        let snapshot = TranscriptionPlanSnapshot(plan: strict, language: nil)
        let decoded = try Self.roundTrip(snapshot)

        #expect(decoded.isStrict)
        #expect(decoded.routingPlan.isStrict)
        #expect(decoded.language == nil)
    }

    @Test("Round-trip JSON: o plano gravado na sessão volta idêntico")
    func theSnapshotRoundTrips() throws {
        let snapshot = TranscriptionPlanSnapshot(
            plan: Self.planWithFallback(),
            language: .portugueseBrazil,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        #expect(try Self.roundTrip(snapshot) == snapshot)
    }

    // MARK: - Decode tolerante

    @Test("Caso de uso desconhecido não derruba o snapshot — a sessão inteira depende disso")
    func anUnknownUseCaseDoesNotThrow() throws {
        // Um `throw` aqui não custa um campo: custa a reunião. O `MeetingSessionStore` decodifica
        // cada sessão com `try?`, então um snapshot ilegível apagaria a reunião da lista — com
        // áudio, transcript e resumo.
        let json = """
        {
          "useCase": "algoQueAindaNaoExiste",
          "candidates": [
            {"engine": "whisperkit", "model": "openai_whisper-small", "rank": 0, "origin": "automatic"}
          ],
          "isStrict": false,
          "createdAt": 760000000
        }
        """
        let decoded = try JSONDecoder().decode(TranscriptionPlanSnapshot.self, from: Data(json.utf8))
        #expect(decoded.useCase == .meetingFinal)
        #expect(decoded.candidates.count == 1)
    }

    @Test("Origem desconhecida vira automático; o candidato sobrevive")
    func anUnknownOriginFallsBackToAutomatic() throws {
        let json = """
        {
          "useCase": "meetingFinal",
          "candidates": [
            {"engine": "parakeet", "model": "parakeet-tdt-0.6b-v3", "rank": 0, "origin": "telepatia"}
          ],
          "isStrict": false,
          "createdAt": 760000000
        }
        """
        let decoded = try JSONDecoder().decode(TranscriptionPlanSnapshot.self, from: Data(json.utf8))
        #expect(decoded.candidates.first?.origin == .automatic)
        #expect(decoded.candidates.first?.engine == .parakeet)
    }

    @Test("Um candidato corrompido some sozinho, sem levar os outros")
    func aBrokenCandidateDoesNotTakeThePlanDown() throws {
        let json = """
        {
          "useCase": "meetingFinal",
          "candidates": [
            {"model": "openai_whisper-small", "rank": 0, "origin": "automatic"},
            {"engine": "parakeet", "model": "parakeet-tdt-0.6b-v3", "rank": 1, "origin": "automatic"}
          ],
          "isStrict": false,
          "createdAt": 760000000
        }
        """
        let decoded = try JSONDecoder().decode(TranscriptionPlanSnapshot.self, from: Data(json.utf8))
        #expect(decoded.candidates.count == 1)
        #expect(decoded.candidates.first?.engine == .parakeet)
    }

    @Test("Forma não-objeto degrada para vazio — é o que impede a sessão inteira de sumir")
    func aNonObjectSnapshotDecodesAsEmpty() throws {
        // O MAIOR das duas reviews: o decode prometia não lançar e lançava na PRIMEIRA linha
        // (`container(keyedBy:)`). Como `MeetingSession` decodifica sintetizado, um `typeMismatch`
        // aqui sobe pela sessão e o `try?` do store apaga a reunião — áudio, turns e resumo.
        for json in ["\"qualquer coisa\"", "42", "[1, 2, 3]", "true"] {
            let decoded = try JSONDecoder().decode(
                TranscriptionPlanSnapshot.self,
                from: Data(json.utf8)
            )
            #expect(decoded.isEmpty, "forma \(json) não degradou para vazio")
            #expect(MeetingTranscription.batchPlan(from: decoded) == nil)
        }
    }

    @Test("Snapshot ilegível não finge ser recente: a data fica no marco zero")
    func anUnreadableSnapshotDoesNotLookFresh() throws {
        let decoded = try JSONDecoder().decode(
            TranscriptionPlanSnapshot.self,
            from: Data("\"qualquer coisa\"".utf8)
        )
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test("Campos ausentes têm default; o snapshot nunca lança por omissão")
    func missingFieldsFallBackInsteadOfThrowing() throws {
        let json = """
        { "candidates": [ {"engine": "whisperkit", "model": "openai_whisper-medium"} ] }
        """
        let decoded = try JSONDecoder().decode(TranscriptionPlanSnapshot.self, from: Data(json.utf8))
        #expect(decoded.useCase == .meetingFinal)
        #expect(decoded.isStrict == false)
        #expect(decoded.language == nil)
        #expect(decoded.candidates.first?.rank == 0)
        #expect(decoded.candidates.first?.origin == .automatic)
    }

    // MARK: - Qual plano os lotes executam

    @Test("Sem snapshot, os lotes não têm plano — é a sessão legada se comportando como antes")
    func aSessionWithoutASnapshotHasNoBatchPlan() {
        #expect(MeetingTranscription.batchPlan(from: nil) == nil)
    }

    @Test("Snapshot vazio (nada sobreviveu ao decode) também cai no caminho legado")
    func anEmptySnapshotHasNoBatchPlan() {
        let empty = TranscriptionPlanSnapshot(language: .portuguese, candidates: [], isStrict: false)
        #expect(MeetingTranscription.batchPlan(from: empty) == nil)
    }

    @Test("Snapshot de outro caso de uso é recusado aqui, e não no coordenador")
    func aSnapshotFromAnotherUseCaseIsRejected() {
        // Deixar passar viraria `planMismatch` lá dentro, que aborta o lote em vez de transcrever.
        let foreign = TranscriptionPlanSnapshot(
            useCase: .dictation,
            language: .portuguese,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(
                    engine: .whisperKit, model: .whisperSmall, rank: 0, origin: .automatic
                )
            ],
            isStrict: false
        )
        #expect(MeetingTranscription.batchPlan(from: foreign) == nil)
    }

    @Test("Com snapshot utilizável, o plano dos lotes é o dele")
    func aUsableSnapshotBecomesTheBatchPlan() throws {
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: .portugueseBrazil)
        let plan = try #require(MeetingTranscription.batchPlan(from: snapshot))
        #expect(plan.candidates.count == 2)
        #expect(plan.primary?.model == .whisperLargeV3Turbo)
    }

    // MARK: - Rebaixamento: o próximo candidato

    @Test("Falhou o rank 0: os lotes seguintes começam no rank 1 do snapshot")
    func theNextBatchStartsAtTheFollowingCandidate() {
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: .portugueseBrazil)
        let attempts = [
            TranscriptionAttempt(
                candidate: Self.candidate(.whisperKit, .whisperLargeV3Turbo, rank: 0, origin: .userSelection),
                stage: .preparation,
                failure: .modelUnavailable(.whisperLargeV3Turbo)
            )
        ]

        let suppressed = MeetingTranscription.suppressedCandidates(from: attempts)
        let next = MeetingTranscription.nextPrimaryCandidate(in: snapshot, suppressing: suppressed)

        #expect(next?.engine == .parakeet)
        #expect(next?.rank == 1)
    }

    @Test("A supressão acumula entre lotes: com os dois caídos, não sobra candidato")
    func suppressionAccumulatesAcrossBatches() {
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: nil)
        var suppressed = MeetingTranscription.suppressedCandidates(from: [
            TranscriptionAttempt(
                candidate: Self.candidate(.whisperKit, .whisperLargeV3Turbo, rank: 0),
                stage: .preparation,
                failure: .modelUnavailable(.whisperLargeV3Turbo)
            )
        ])
        suppressed.formUnion(MeetingTranscription.suppressedCandidates(from: [
            TranscriptionAttempt(
                candidate: Self.candidate(.parakeet, .parakeetTDT06BV3, rank: 1),
                stage: .inference,
                failure: .engineInternal("ANE ocupada")
            )
        ]))

        #expect(MeetingTranscription.nextPrimaryCandidate(in: snapshot, suppressing: suppressed) == nil)
    }

    @Test("Um lote que sucedeu no rank 0 não rebaixa nada")
    func aSuccessfulBatchDoesNotDowngrade() {
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: nil)
        let next = MeetingTranscription.nextPrimaryCandidate(in: snapshot, suppressing: [])
        #expect(next?.engine == .whisperKit)
        #expect(next?.rank == 0)
    }

    @Test("Falhou na 1ª tentativa e passou na 2ª: o vencedor NÃO é suprimido")
    func theWinningCandidateIsNeverMirroredAsSuppressed() {
        // O `attemptsPerCandidate: 2` dos lotes em ação: `failedAttempts` guarda a primeira falha
        // mesmo quando a segunda tentativa do MESMO candidato dá certo — e nesse caso o coordenador
        // apaga o registro dele. Um espelho que não excluísse o vencedor anunciaria um rebaixamento
        // que não houve, e o marcaria para sempre, calando o aviso quando a falha fosse definitiva
        // (MENOR do Farol).
        let winner = Self.candidate(.whisperKit, .whisperLargeV3Turbo, rank: 0, origin: .userSelection)
        let attempts = [
            TranscriptionAttempt(
                candidate: winner,
                stage: .preparation,
                failure: .engineInternal("tropeço transitório")
            )
        ]
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: nil)

        let suppressed = MeetingTranscription.suppressedCandidates(
            from: attempts,
            succeeded: Self.provenance(.whisperKit, .whisperLargeV3Turbo, origin: .userSelection)
        )
        #expect(suppressed.isEmpty)
        #expect(
            MeetingTranscription.nextPrimaryCandidate(in: snapshot, suppressing: suppressed)?.rank == 0
        )
    }

    @Test("Quem falhou ANTES do vencedor continua suprimido — só o vencedor sai da conta")
    func onlyTheWinnerIsExcluded() {
        let alpha = Self.candidate(.whisperKit, .whisperLargeV3Turbo, rank: 0)
        let beta = Self.candidate(.parakeet, .parakeetTDT06BV3, rank: 1)
        let attempts = [
            TranscriptionAttempt(candidate: alpha, stage: .preparation, failure: .modelUnavailable(.whisperLargeV3Turbo)),
            TranscriptionAttempt(candidate: beta, stage: .inference, failure: .engineInternal("tropeço"))
        ]

        let suppressed = MeetingTranscription.suppressedCandidates(
            from: attempts,
            succeeded: Self.provenance(.parakeet, .parakeetTDT06BV3, rank: 1)
        )
        #expect(suppressed == [MeetingTranscription.CandidateKey(alpha)])
    }

    // MARK: - Cancelamento

    @Test("Cancelamento é reconhecido nos três vocabulários; falha de motor não é")
    func cancellationIsClassifiedApartFromFailure() {
        // A distinção decide se o laço do pós-call continua: falha de lote é local, cancelamento
        // vale para a passagem inteira (MENOR da Quilha).
        #expect(MeetingTranscription.isCancellation(TranscriptionCoordinatorError.cancelled))
        #expect(MeetingTranscription.isCancellation(TranscriptionEngineFailure.cancelled))
        #expect(MeetingTranscription.isCancellation(CancellationError()))

        #expect(MeetingTranscription.isCancellation(TranscriptionCoordinatorError.allCandidatesFailed([])) == false)
        #expect(MeetingTranscription.isCancellation(TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) == false)
        #expect(MeetingTranscription.isCancellation(TranscriptionCoordinatorError.streamingUnsupported(.meetingPreview)) == false)
    }

    @Test("A linha de rebaixamento é só id de motor e modelo — nunca texto")
    func theDowngradeLineCarriesOnlyIdentifiers() {
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: nil)
        let from = snapshot.primary
        let to = snapshot.candidates.last

        let line = MeetingTranscription.downgradeLogSummary(from: from, to: to)
        #expect(line.contains("whisperkit/openai_whisper-large-v3_turbo"))
        #expect(line.contains("parakeet/parakeet-tdt-0.6b-v3"))

        let exhausted = MeetingTranscription.downgradeLogSummary(from: to, to: nil)
        #expect(exhausted.contains("esgotado"))
    }

    @Test("O resumo do plano em log descreve a ordem inteira, sem texto")
    func thePlanLogSummaryDescribesTheOrder() {
        let snapshot = TranscriptionPlanSnapshot(plan: Self.planWithFallback(), language: .portugueseBrazil)
        #expect(snapshot.logSummary == "whisperkit/openai_whisper-large-v3_turbo → parakeet/parakeet-tdt-0.6b-v3")

        let strict = TranscriptionPlanSnapshot(
            language: nil,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(
                    engine: .parakeet, model: .parakeetTDT06BV3, rank: 0, origin: .userSelection
                )
            ],
            isStrict: true
        )
        #expect(strict.logSummary.contains("estrito"))

        let empty = TranscriptionPlanSnapshot(language: nil, candidates: [], isStrict: false)
        #expect(empty.logSummary == "plano vazio")
    }

    // MARK: - Proveniência por turno

    @Test("Turno costurado guarda a proveniência do PRIMEIRO lote")
    func aMergedTurnKeepsTheFirstProvenance() {
        // Um turno é identificado pelo começo dele: registrar a última faria a atribuição mudar
        // retroativamente a cada costura.
        let first = Self.provenance(.whisperKit, .whisperLargeV3Turbo)
        let second = Self.provenance(.parakeet, .parakeetTDT06BV3, rank: 1)

        #expect(MeetingTranscription.mergedProvenance(existing: first, incoming: second) == first)
    }

    @Test("Turno legado (sem proveniência) adota a do lote que o continuou")
    func aLegacyTurnAdoptsTheIncomingProvenance() {
        let incoming = Self.provenance(.parakeet, .parakeetTDT06BV3, rank: 1)
        #expect(MeetingTranscription.mergedProvenance(existing: nil, incoming: incoming) == incoming)
        #expect(MeetingTranscription.mergedProvenance(existing: nil, incoming: nil) == nil)
    }

    // MARK: - Utilidades

    private static func roundTrip(_ snapshot: TranscriptionPlanSnapshot) throws -> TranscriptionPlanSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionPlanSnapshot.self, from: encoder.encode(snapshot))
    }
}

@Suite("Reunião — ciclo de vida Granola/stop (r4)")
struct MeetingRecordingLifecycleTests {
    @Test("Granola com zero turns NÃO completa só com resumo — exige batch")
    func granolaWithZeroTurnsCannotSkipBatch() {
        #expect(
            MeetingRecordingLifecycle.granolaCompletesWithLiveTranscriptOnly(
                mode: .granola,
                turnCount: 0
            ) == false
        )
        #expect(
            MeetingRecordingLifecycle.granolaCompletesWithLiveTranscriptOnly(
                mode: .granola,
                turnCount: 2
            ) == true
        )
        #expect(
            MeetingRecordingLifecycle.granolaCompletesWithLiveTranscriptOnly(
                mode: .quality,
                turnCount: 5
            ) == false
        )
    }

    @Test("Granola com turns: pós-call é SÓ resumo — sem eco")
    func granolaWithTurnsIsSummaryOnly() {
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(mode: .granola, turnCount: 2)
                == .liveTranscriptThenSummary
        )
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(mode: .granola, turnCount: 0)
                == .fullBatchPipeline,
            "zero turns cai no pipeline Qualidade (batch)"
        )
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(mode: .quality, turnCount: 5)
                == .fullBatchPipeline
        )
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(
                mode: .granola,
                turnCount: 2,
                isManualReprocess: true
            ) == .fullBatchPipeline,
            "Reprocessar manual é re-criação — WYSIWYG não governa o clique"
        )
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(
                mode: .granola,
                turnCount: 2,
                isManualReprocess: false
            ) == .liveTranscriptThenSummary,
            "o hangup automático do Granola continua só-resumo"
        )
        // O defeito GRANOLA-ECO: liveTranscriptEchoThenSummary. WYSIWYG = só resumo.
        #expect(
            MeetingRecordingLifecycle.GranolaPostCallWork.liveTranscriptThenSummary
                != MeetingRecordingLifecycle.GranolaPostCallWork.fullBatchPipeline
        )
    }

    @Test("draftFromLiveFinal traz source e janela do relógio da captura — o eco precisa disso")
    func liveFinalDraftHasSourceAndCaptureClock() {
        let draft = MeetingRecordingLifecycle.draftFromLiveFinal(
            text: "fala",
            channel: .microphone,
            window: MeetingLiveCaptureWindow(startTime: 12.5, endTime: 14.0),
            speakerName: "Você"
        )
        #expect(draft?.source == .microphone)
        #expect(draft?.startTime == 12.5)
        #expect(draft?.endTime == 14.0)
        let other = MeetingRecordingLifecycle.draftFromLiveFinal(
            text: "eles",
            channel: .systemAudio,
            window: MeetingLiveCaptureWindow(startTime: 1, endTime: 2),
            speakerName: "Eles"
        )
        #expect(other?.source == .systemAudio)
    }

    @Test("Provider nil ou start-fail promove Granola a Qualidade")
    func liveUnavailableFallsBackToQuality() {
        #expect(
            MeetingRecordingLifecycle.modeAfterLiveStart(
                requested: .granola,
                liveTranscriberStarted: false
            ) == .quality
        )
        #expect(
            MeetingRecordingLifecycle.modeAfterLiveStart(
                requested: .quality,
                liveTranscriberStarted: false
            ) == .quality
        )
    }

    @Test("Provider real ligado: Granola permanece ao vivo (não cai no fallback)")
    func wiredProviderKeepsGranolaLive() {
        #expect(
            MeetingRecordingLifecycle.modeAfterLiveStart(
                requested: .granola,
                liveTranscriberStarted: true
            ) == .granola
        )
    }

    @Test("wireProvider não invoca a factory ao construir o root")
    func wiringTheRootDoesNotInvokeTheFactory() {
        final class RootHarness: @unchecked Sendable {
            var liveTranscriberProvider: (@Sendable () -> any MeetingLiveTranscriber)?
            init(factory: @escaping @Sendable () -> any MeetingLiveTranscriber) {
                liveTranscriberProvider = MeetingRecordingLifecycle.wireProvider(factory: factory)
            }
        }
        let box = InvocationBox()
        _ = RootHarness {
            box.count += 1
            return StartingLiveTranscriber()
        }
        #expect(box.count == 0)
        // Invocar o provider (como o start Granola faz) é a primeira chamada.
        _ = RootHarness {
            box.count += 1
            return StartingLiveTranscriber()
        }.liveTranscriberProvider?()
        #expect(box.count == 1)
    }

    @Test("start() que lança persiste a sessão em Qualidade e decide batch")
    func throwingStartPersistsQualityAndChoosesBatch() async {
        var session = MeetingSession(
            title: "Call",
            sessionType: .meeting,
            startedAt: Date()
        )
        session.meetingMode = .granola
        let attempt = await MeetingRecordingLifecycle.attemptLiveStart(
            requested: .granola,
            provider: { ThrowingStartTranscriber() },
            locale: MeetingRecordingLifecycle.liveLocale(forPlanLanguage: .english)
        )
        let spy = PersistSpy()
        session = MeetingRecordingLifecycle.persistLiveStart(
            to: session,
            attempt: attempt,
            save: spy.save
        )
        #expect(session.meetingMode == .quality)
        #expect(spy.saved.count == 1)
        #expect(spy.saved[0].id == session.id)
        #expect(spy.saved[0].meetingMode == .quality)
        #expect(attempt.transcriber == nil)
        #expect(
            MeetingRecordingLifecycle.granolaCompletesWithLiveTranscriptOnly(
                mode: session.meetingMode,
                turnCount: 0
            ) == false
        )
        #expect(
            MeetingRecordingLifecycle.granolaCompletesWithLiveTranscriptOnly(
                mode: spy.saved[0].meetingMode,
                turnCount: 0
            ) == false
        )
    }

    @Test("start() que sobe mantém Granola e devolve transcritor")
    func successfulStartKeepsGranola() async {
        var session = MeetingSession(
            title: "Call",
            sessionType: .meeting,
            startedAt: Date()
        )
        session.meetingMode = .granola
        let attempt = await MeetingRecordingLifecycle.attemptLiveStart(
            requested: .granola,
            provider: { StartingLiveTranscriber() },
            locale: MeetingRecordingLifecycle.liveLocale(forPlanLanguage: .portuguese)
        )
        let spy = PersistSpy()
        session = MeetingRecordingLifecycle.persistLiveStart(
            to: session,
            attempt: attempt,
            save: spy.save
        )
        #expect(attempt.mode == .granola)
        #expect(attempt.transcriber != nil)
        #expect(attempt.stream != nil)
        #expect(session.meetingMode == .granola)
        #expect(spy.saved.count == 1)
        #expect(spy.saved[0].meetingMode == .granola)
    }

    @Test("Locale do plano cobre os sete idiomas do app; plano legado sem idioma usa pt-BR")
    func liveLocaleFollowsPlanLanguage() {
        func tag(_ language: TranscriptionLanguage?) -> String {
            MeetingRecordingLifecycle.liveLocale(forPlanLanguage: language)
                .identifier
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
        }
        #expect(tag(.portugueseBrazil) == "pt-br")
        #expect(tag(.portuguese) == "pt-br")
        #expect(tag(.englishUS) == "en-us")
        #expect(tag(.english) == "en-us")
        #expect(tag(.spanish) == "es-es")
        #expect(tag(.french) == "fr-fr")
        #expect(tag(.german) == "de-de")
        #expect(tag(.japanese) == "ja-jp")
        #expect(tag(.chinese) == "zh-cn")
        #expect(tag(nil) == "pt-br")
    }

    @Test("Assistente aparece apenas com transcritor oficial Ao vivo ativo")
    func liveAssistantRequiresActiveLiveMode() {
        #expect(MeetingRecordingLifecycle.liveAssistantIsAvailable(
            mode: .granola,
            liveTranscriberActive: true
        ))
        #expect(MeetingRecordingLifecycle.liveAssistantIsAvailable(
            mode: .granola,
            liveTranscriberActive: false
        ) == false)
        #expect(MeetingRecordingLifecycle.liveAssistantIsAvailable(
            mode: .quality,
            liveTranscriberActive: true
        ) == false)
        #expect(MeetingRecordingLifecycle.liveAssistantIsAvailable(
            mode: nil,
            liveTranscriberActive: true
        ) == false)
    }

    @Test("Factory de produção devolve instância nova por chamada, sem start()")
    func productionFactoryMakesANewInstanceEachCall() {
        let first = AppleSpeechMeetingTranscriber.make()
        let second = AppleSpeechMeetingTranscriber.make()
        #expect(first !== second)
    }

    @Test("Final publicado sem activeSession vira turn persistível (teardown por ID)")
    func liveFinalBecomesTurnEvenWithoutActiveSession() throws {
        var session = MeetingSession(
            title: "A",
            sessionType: .meeting,
            startedAt: Date().addingTimeInterval(-60),
            turns: []
        )
        session.meetingMode = .granola
        let window = MeetingLiveCaptureWindow(startTime: 50, endTime: 52)
        let draft = MeetingRecordingLifecycle.draftFromLiveFinal(
            text: "rabo da fala",
            channel: .microphone,
            window: window,
            speakerName: session.speakerName(for: .microphone)
        )
        let empty = MeetingRecordingLifecycle.draftFromLiveFinal(
            text: "   ",
            channel: .microphone,
            window: window,
            speakerName: "Você"
        )
        #expect(empty == nil)
        let saved = try #require(draft)
        #expect(saved.text == "rabo da fala")
        #expect(saved.startTime == 50)
        session.turns.append(
            MeetingTurn(
                source: saved.source,
                speakerName: saved.speakerName,
                text: saved.text,
                startTime: saved.startTime,
                endTime: saved.endTime,
                confidence: 1.0,
                provenance: nil
            )
        )
        #expect(session.turns.count == 1)
    }

    @Test("Nota <0,6s e pausa sobre releitura stale não se perdem e não dobram")
    func stopDeltasApplyOnFreshReadWithoutDoubleCounting() {
        var stale = MeetingSession(
            title: "N",
            sessionType: .meeting,
            startedAt: Date().addingTimeInterval(-120)
        )
        stale.notes = "antes"
        stale.pausedDuration = 10

        let afterFirstSave = MeetingRecordingLifecycle.mergeStopDeltas(
            onto: stale,
            notes: "antes + rabo",
            pausedDurationFloor: 15
        )
        #expect(afterFirstSave.notes == "antes + rabo")
        #expect(afterFirstSave.pausedDuration == 15)

        var wiped = stale
        wiped.notes = "antes"
        wiped.pausedDuration = 10
        let restored = MeetingRecordingLifecycle.mergeStopDeltas(
            onto: wiped,
            notes: "antes + rabo",
            pausedDurationFloor: 15
        )
        #expect(restored.notes == "antes + rabo")
        #expect(restored.pausedDuration == 15)

        let idempotent = MeetingRecordingLifecycle.mergeStopDeltas(
            onto: restored,
            notes: "antes + rabo",
            pausedDurationFloor: 15
        )
        #expect(idempotent.pausedDuration == 15)
    }

    @Test("Título da IA só entra se o atual é default — calendário/app não é default")
    func generatedTitleOnlyReplacesDefault() {
        let defaults: Set<String> = ["Reunião", "Nova reunião"]
        #expect(
            MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                current: "Planejamento Q3",
                generated: "Título da IA",
                defaultTitles: defaults
            ) == false
        )
        #expect(
            MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                current: "Reunião de Alinhamento",
                generated: "Título da IA",
                defaultTitles: defaults
            ) == false
        )
        #expect(
            MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                current: "Nova reunião",
                generated: "Título da IA",
                defaultTitles: defaults
            ) == true
        )
        #expect(
            MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                current: "Nova reunião",
                generated: "",
                defaultTitles: defaults
            ) == false
        )
    }

    @Test("Título padrão com data e hora é substituído pelo da IA; título escrito por alguém não")
    func generatedTitleReplacesDatedDefault() {
        // Reintroduzir o defeito (comparar só por igualdade exata com "Reunião") faz os três
        // primeiros `true` virarem `false`: era por isso que a lista ficava só com datas.
        let defaults: Set<String> = ["Reunião", "Nova reunião"]
        for dated in ["Reunião 17/09/2026, 17:01", "Meeting 9/17/26, 5:01 PM", "Entrevista 18.06.26, 07:22"] {
            #expect(
                MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                    current: dated,
                    generated: "Daily — MCG e observabilidade",
                    defaultTitles: defaults
                ) == true,
                "\(dated)"
            )
        }
        for custom in ["Reunião de alinhamento", "Planejamento Q3 2026", "Daily 17/09 com o Matheus", "2026 retrospectiva"] {
            #expect(
                MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                    current: custom,
                    generated: "Daily — MCG e observabilidade",
                    defaultTitles: defaults
                ) == false,
                "\(custom)"
            )
        }
        // A IA devolvendo o próprio título padrão (fallback) não conta como sugestão.
        #expect(
            MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                current: "Reunião 17/09/2026, 17:01",
                generated: "Reunião 17/09/2026, 17:01",
                defaultTitles: defaults
            ) == false
        )
    }

    @Test("Órfã Granola com turns mantém o transcript e só gera o resumo")
    func interruptedGranolaWithTurnsKeepsLiveTranscript() {
        // Reintroduzir o defeito (sempre virar Qualidade sem olhar turnCount)
        // quebra este teste e apaga o preview no crash do hangup.
        #expect(
            MeetingRecordingLifecycle.modeAfterInterruptedRecording(
                stored: .granola,
                hadEndedAt: false,
                turnCount: 3
            ) == .granola
        )
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(mode: .granola, turnCount: 3)
                == .liveTranscriptThenSummary
        )
        #expect(
            MeetingRecordingLifecycle.modeAfterInterruptedRecording(
                stored: .granola,
                hadEndedAt: true,
                turnCount: 3
            ) == .granola
        )
    }

    @Test("Órfã Granola sem turns continua virando Qualidade")
    func interruptedGranolaWithoutTurnsFallsBackToQuality() {
        #expect(
            MeetingRecordingLifecycle.modeAfterInterruptedRecording(
                stored: .granola,
                hadEndedAt: false,
                turnCount: 0
            ) == .quality
        )
        #expect(
            MeetingRecordingLifecycle.granolaCompletesWithLiveTranscriptOnly(
                mode: .quality,
                turnCount: 0
            ) == false
        )
    }

    @Test("Remover eco some no Granola com turns e fica no Qualidade")
    func removeEchoVisibilityFollowsMode() {
        #expect(
            MeetingRecordingLifecycle.showsRemoveEchoAction(mode: .granola, turnCount: 4) == false
        )
        #expect(
            MeetingRecordingLifecycle.showsRemoveEchoAction(mode: .granola, turnCount: 0)
        )
        #expect(
            MeetingRecordingLifecycle.showsRemoveEchoAction(mode: .quality, turnCount: 4)
        )
        #expect(
            MeetingRecordingLifecycle.showsRemoveEchoAction(mode: nil, turnCount: 2)
        )
    }

    @Test("Lotes rápidos: persistência de produção guarda B na memória e só A no disco")
    func fastBatchesKeepTurnsOnlyInTheAccumulator() {
        func turn(_ text: String, start: TimeInterval, name: String = "Eles") -> MeetingTurn {
            MeetingTurn(
                source: .systemAudio,
                speakerName: name,
                text: text,
                startTime: start,
                endTime: start + 20
            )
        }
        let speakers = [MeetingSpeaker(source: .systemAudio, name: "Eles")]
        var pass = MeetingRecordingLifecycle.BatchTurnPersistence(writeInterval: 10)
        var disk: [MeetingTurn] = []
        var now: TimeInterval = 0

        // O mesmo caminho do VM: accept → flush (nomes) → shouldWriteToDisk.
        func persist(_ incoming: MeetingTurn) {
            pass.accept(incoming)
            let overlay = pass.flush(speakers: speakers)
            if pass.shouldWriteToDisk(at: now) {
                disk = overlay
            }
        }

        persist(turn("A", start: 0))
        now += 1
        persist(turn("B", start: 30))
        now += 1
        persist(turn("C", start: 60))

        #expect(pass.turns.map(\.text) == ["A", "B", "C"])
        #expect(disk.map(\.text) == ["A"])

        var assembledFromDisk = MeetingRecordingLifecycle.BatchTurnAccumulator(
            existing: disk,
            hasReplacement: true
        )
        assembledFromDisk.accept(turn("C", start: 60))
        #expect(
            assembledFromDisk.turns.map(\.text) == ["A", "C"],
            "reintroduzir montagem via store+throttle reaparece o buraco A/C sem B"
        )

        disk = pass.flush(speakers: speakers)
        #expect(disk.map(\.text) == ["A", "B", "C"])
    }

    @Test("Rename no meio da passagem: o flush sai 100% com o nome novo")
    func renameDuringPassRemapsAccumulatorOnFlush() {
        var pass = MeetingRecordingLifecycle.BatchTurnPersistence()
        pass.accept(
            MeetingTurn(
                source: .microphone,
                speakerName: "Você",
                text: "primeira",
                startTime: 0,
                endTime: 2
            )
        )
        pass.accept(
            MeetingTurn(
                source: .microphone,
                speakerName: "Você",
                text: "segunda",
                startTime: 10,
                endTime: 12
            )
        )
        let renamed = [MeetingSpeaker(source: .microphone, name: "Rafa")]
        let flushed = pass.flush(speakers: renamed)
        #expect(flushed.map(\.speakerName) == ["Rafa", "Rafa"])
        #expect(pass.turns.map(\.speakerName) == ["Você", "Você"])

        let ambiguous = [
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Ana"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Bruno")
        ]
        let kept = MeetingRecordingLifecycle.applyingFreshSpeakerNames(
            to: [
                MeetingTurn(
                    source: .systemAudio,
                    speakerName: "Participantes",
                    text: "fala",
                    startTime: 0,
                    endTime: 1
                )
            ],
            speakers: ambiguous
        )
        #expect(kept[0].speakerName == "Participantes")
    }

    @Test("Rename durante o await do pipeline sobrevive ao delta da diarização")
    func renameDuringPipelineAwaitSurvives() {
        // Antes do passo: mic "Você" + um participante já diarizado.
        let before = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1")
        ]
        // Durante o await a UI renomeou os dois.
        let fresh = [
            MeetingSpeaker(source: .microphone, name: "Rafa"),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Ana")
        ]
        // O passo volta com a cópia velha + um participante novo que só ele conhece.
        let stepSpeakers = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Participante 2")
        ]
        let merged = MeetingRecordingLifecycle.mergingPipelineSpeakers(
            stepSpeakers: stepSpeakers,
            before: before,
            fresh: fresh
        )
        #expect(merged.map(\.name) == ["Rafa", "Ana", "Participante 2"])

        let stepTurns = [
            MeetingTurn(
                source: .microphone,
                speakerId: MeetingCaptureSource.microphone.rawValue,
                speakerName: "Você",
                text: "um",
                startTime: 0,
                endTime: 1
            ),
            MeetingTurn(
                source: .systemAudio,
                speakerId: "S1",
                speakerName: "Participante 1",
                text: "dois",
                startTime: 1,
                endTime: 2
            ),
            MeetingTurn(
                source: .systemAudio,
                speakerId: "S2",
                speakerName: "Participante 2",
                text: "tres",
                startTime: 2,
                endTime: 3
            )
        ]
        let turns = MeetingRecordingLifecycle.applyingFreshSpeakerNames(
            to: stepTurns,
            speakers: merged
        )
        #expect(
            turns.map(\.speakerName) == ["Rafa", "Ana", "Participante 2"],
            "escrever speakers/turns da cópia capturada antes do await revertia o rename"
        )
        #expect(Set(turns.map(\.speakerName)).isSubset(of: Set(merged.map(\.name))))
    }

    @Test("Falante removido pelo passo NÃO ressuscita; só o criado durante o await volta")
    func removedSpeakerIsNotResurrectedByTheMerge() {
        // Antes do passo: o "Eles" genérico do Granola, que a diarização
        // substitui por S1/S2. Preservar qualquer ausente devolvia esse "Eles"
        // como fantasma sem turns no card e no export.
        let them = MeetingSpeaker(id: "systemAudio", source: .systemAudio, name: "Eles")
        let before = [MeetingSpeaker(source: .microphone), them]

        // Durante o await a UI renomeou o mic e criou um falante novo.
        let bornDuringAwait = MeetingSpeaker(id: "manual-1", source: .systemAudio, name: "Convidado")
        let fresh = [
            MeetingSpeaker(source: .microphone, name: "Rafa"),
            them,
            bornDuringAwait
        ]

        // O passo devolve os clusters diarizados e NÃO devolve o "Eles".
        let stepSpeakers = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Participante 2")
        ]

        let merged = MeetingRecordingLifecycle.mergingPipelineSpeakers(
            stepSpeakers: stepSpeakers,
            before: before,
            fresh: fresh
        )
        #expect(merged.map(\.id) == ["microphone", "S1", "S2", "manual-1"])
        #expect(merged.map(\.name) == ["Rafa", "Participante 1", "Participante 2", "Convidado"])
        #expect(
            merged.contains(where: { $0.id == them.id }) == false,
            "o falante que o passo removeu tem que ficar removido"
        )

        // Re-diarização: os clusters da rodada anterior também não voltam.
        let oldClusters = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Ana"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Bruno"),
            MeetingSpeaker(id: "S3", source: .systemAudio, name: "Carlos")
        ]
        let reDiarized = MeetingRecordingLifecycle.mergingPipelineSpeakers(
            stepSpeakers: [
                MeetingSpeaker(source: .microphone),
                MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1")
            ],
            before: oldClusters,
            fresh: oldClusters
        )
        #expect(
            reDiarized.map(\.id) == ["microphone", "S1"],
            "S2/S3 da rodada anterior não podem ser arrastados"
        )
    }

    @Test("Sem rename, o passo do pipeline manda nos nomes")
    func pipelineStepKeepsItsOwnNamesWithoutRename() {
        let before = [MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1")]
        let fresh = before
        // Camada 2 (LLM) renomeou o participante dentro do próprio passo.
        let stepSpeakers = [MeetingSpeaker(id: "S1", source: .systemAudio, name: "Ana")]
        let merged = MeetingRecordingLifecycle.mergingPipelineSpeakers(
            stepSpeakers: stepSpeakers,
            before: before,
            fresh: fresh
        )
        #expect(merged.map(\.name) == ["Ana"])
    }

    // MARK: - O2 — cortes de lote na troca de falante

    @Test("Fronteiras saem das bordas dos segmentos, sem repetição e sem corte curto demais")
    func batchBoundariesFromDiarization() {
        let segments = [
            DiarizedSegment(speakerId: "S1", start: 0, end: 12, embedding: [1, 0]),
            // Encostado: o fim de S1 e o começo de S2 são a MESMA fronteira.
            DiarizedSegment(speakerId: "S2", start: 12, end: 20, embedding: [0, 1]),
            // Trecho curto: a borda a 20,4 fica a 0,4s da anterior e é descartada.
            DiarizedSegment(speakerId: "S1", start: 20.4, end: 30, embedding: [1, 0])
        ]
        let boundaries = DiarizationBatchCuts.batchBoundaries(from: segments)
        #expect(boundaries == [12, 20, 30])
        #expect(
            DiarizationBatchCuts.batchBoundaries(from: []).isEmpty
        )
        // O sentinela também é fala: entrar e sair dele é troca de falante.
        let withSentinel = [
            DiarizedSegment(speakerId: "S1", start: 0, end: 10, embedding: [1, 0]),
            DiarizedSegment(
                speakerId: DiarizedSegment.unassignedSpeakerId,
                start: 15,
                end: 18,
                embedding: [1, 0]
            )
        ]
        #expect(
            DiarizationBatchCuts.batchBoundaries(from: withSentinel)
                == [10, 15, 18]
        )
    }

    @Test("O corte cai no instante EXATO, dividindo o chunk de leitura")
    func cutPlanSplitsTheChunkAtTheExactInstant() {
        let plan = MeetingRecordingLifecycle.MeetingBatchCutPlan(boundaries: [13.5])
        let chunk = MeetingAudioChunk(
            source: .systemAudio,
            samples: Array(repeating: 0.5, count: 48_000),  // 3s a 16 kHz
            startTime: 12,
            endTime: 15
        )
        let cut = try? #require(plan.cut(strictlyInside: chunk))
        #expect(cut == 13.5)

        let parts = MeetingRecordingLifecycle.MeetingBatchCutPlan.split(chunk, at: 13.5)
        #expect(parts.head.startTime == 12)
        #expect(parts.head.endTime == 13.5)
        #expect(parts.tail.startTime == 13.5)
        #expect(parts.tail.endTime == 15)
        #expect(
            parts.head.samples.count == 24_000,
            "metade das amostras — cortar na borda de 3s erraria a troca por até um chunk"
        )
        #expect(parts.tail.samples.count == 24_000)

        // Fronteira exatamente na borda do chunk não divide nada.
        let onEdge = MeetingRecordingLifecycle.MeetingBatchCutPlan(boundaries: [12, 15])
        #expect(onEdge.cut(strictlyInside: chunk) == nil)
    }

    @Test("Lote aberto fecha quando um corte fica entre ele e o próximo chunk")
    func cutPlanClosesTheOpenBatch() {
        let plan = MeetingRecordingLifecycle.MeetingBatchCutPlan(boundaries: [15])
        #expect(plan.crossesBoundary(fromBatchStart: 12, toChunkStart: 15))
        #expect(plan.crossesBoundary(fromBatchStart: 12, toChunkStart: 18))
        #expect(plan.crossesBoundary(fromBatchStart: 15, toChunkStart: 18) == false)
        #expect(plan.crossesBoundary(fromBatchStart: 16, toChunkStart: 18) == false)
        #expect(MeetingRecordingLifecycle.MeetingBatchCutPlan().isEmpty)
    }

    @Test("A costura de 3s NÃO atravessa corte de falante — sem isso o O2 é inerte")
    func stitchingDoesNotCrossASpeakerCut() {
        func turn(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> MeetingTurn {
            MeetingTurn(
                source: .systemAudio,
                speakerName: "Eles",
                text: text,
                startTime: start,
                endTime: end
            )
        }

        // Sem fronteira: os dois lotes encostados viram um turno só (comportamento
        // histórico, e o que faria o corte não valer de nada).
        var stitched: [MeetingTurn] = [turn("pergunta", 0, 12)]
        MeetingRecordingLifecycle.merge(turn: turn("resposta", 12, 26), into: &stitched)
        #expect(stitched.count == 1)
        #expect(stitched[0].text == "pergunta resposta")

        // Com a troca de falante em 12, ficam dois turnos — que é o ponto do O2.
        var cut: [MeetingTurn] = [turn("pergunta", 0, 12)]
        MeetingRecordingLifecycle.merge(
            turn: turn("resposta", 12, 26),
            into: &cut,
            speakerBoundaries: [12]
        )
        #expect(cut.count == 2)
        #expect(cut.map(\.text) == ["pergunta", "resposta"])

        // Uma fronteira LONGE não impede a costura de dois lotes do mesmo falante.
        var far: [MeetingTurn] = [turn("primeira", 0, 12)]
        MeetingRecordingLifecycle.merge(
            turn: turn("segunda", 12, 26),
            into: &far,
            speakerBoundaries: [40]
        )
        #expect(far.count == 1)
    }

    @Test("O acumulador de lotes carrega as fronteiras até a costura")
    func accumulatorCarriesTheBoundaries() {
        var pass = MeetingRecordingLifecycle.BatchTurnPersistence(speakerBoundaries: [12])
        pass.accept(
            MeetingTurn(source: .systemAudio, speakerName: "Eles", text: "pergunta", startTime: 0, endTime: 12)
        )
        pass.accept(
            MeetingTurn(source: .systemAudio, speakerName: "Eles", text: "resposta", startTime: 12, endTime: 26)
        )
        #expect(
            pass.turns.count == 2,
            "o acumulador é quem monta o transcript — se ele costurar, o corte morre aqui"
        )

        var stitching = MeetingRecordingLifecycle.BatchTurnPersistence()
        stitching.accept(
            MeetingTurn(source: .systemAudio, speakerName: "Eles", text: "pergunta", startTime: 0, endTime: 12)
        )
        stitching.accept(
            MeetingTurn(source: .systemAudio, speakerName: "Eles", text: "resposta", startTime: 12, endTime: 26)
        )
        #expect(stitching.turns.count == 1)
    }

    @Test("Reprocessar marca a sessão incompleta antes da fila")
    func reprocessMarksSessionIncomplete() {
        var session = MeetingSession(
            title: "Daily",
            sessionType: .meeting,
            startedAt: Date()
        )
        session.isProcessingCompleted = true
        let marked = MeetingRecordingLifecycle.markingReprocessStarted(session)
        #expect(marked.isProcessingCompleted == false)
        #expect(marked.pendingManualReprocess == true)
        #expect(session.isProcessingCompleted == true)
        #expect(session.pendingManualReprocess != true)
        let finished = MeetingRecordingLifecycle.markingProcessingFinished(marked)
        #expect(finished.isProcessingCompleted == true)
        #expect(finished.pendingManualReprocess == false)
    }

    @Test("Resolução do unresolved é one-shot: persist+decode+nova passagem não reinterpreta")
    func unresolvedResolutionIsOneShotAcrossPersistAndNewPass() throws {
        // O cenário do Codex: 1º recovery resolve o unresolved e grava a origem; crash; boot com
        // OUTRO idioma nos Ajustes. Sem o persist, a 2ª passagem reinterpretaria o plano — e o
        // transcript trocaria de motor no meio.
        //
        // A 1ª passagem roda em inglês porque o snapshot está em inglês: desde 29/08/2026 o
        // seletor não tem `.auto`, então resolver um unresolved é comparar com a escolha do
        // humano, não adotar um palpite.
        let unresolved = LanguageProbeFixtures.snapshot(
            language: .english,
            languageOrigin: .unresolved
        )
        #expect(unresolved.candidates.contains(where: { $0.engine == .appleSpeechAnalyzer }))

        let first = MeetingTranscription.preparingStoredPlan(unresolved, selectedLanguage: .english)
        guard case .usable(_, persistResolvedOrigin: true) = first else {
            Issue.record("1ª passagem com idioma igual tinha que resolver e pedir persist")
            return
        }
        if case .usable(let prepared, _) = first {
            #expect(prepared.languageOrigin == .explicit)
        }

        var session = MeetingSession(
            title: "Daily",
            sessionType: .meeting,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        session.isProcessingCompleted = false
        session.transcriptionPlan = unresolved
        session = try #require(MeetingTranscription.persistingResolvedOrigin(first, on: session))
        #expect(session.transcriptionPlan?.languageOrigin == .explicit)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingSession.self, from: try encoder.encode(session))
        let stored = try #require(decoded.transcriptionPlan)
        #expect(stored.languageOrigin == .explicit)

        let second = MeetingTranscription.preparingStoredPlan(stored, selectedLanguage: .portuguese)
        guard case .usable(let kept, persistResolvedOrigin: false) = second else {
            Issue.record("2ª passagem não pode reconstruir nem re-persistir origem gravada")
            return
        }
        #expect(kept.languageOrigin == .explicit)
        #expect(kept.language == stored.language)
        #expect(MeetingTranscription.persistingResolvedOrigin(second, on: decoded) == nil)
    }

    /// Sessão gravada ANTES de 29/08/2026, quando o seletor tinha automático.
    ///
    /// `.autoAdopted` sumiu do que o app escreve, não do que já está no disco. Ela continua sendo
    /// origem gravada — e origem gravada não se reinterpreta, mesmo agora que nenhuma escolha de
    /// usuário produz essa origem. Reinterpretar trocaria o motor de um transcript pela metade.
    @Test("Sessão legada em autoAdopted continua valendo e não é reinterpretada")
    func legacyAutoAdoptedPlanIsNotReinterpreted() {
        let legada = LanguageProbeFixtures.snapshot(
            language: .english,
            languageOrigin: .autoAdopted
        )

        let use = MeetingTranscription.preparingStoredPlan(legada, selectedLanguage: .portuguese)

        guard case .usable(let kept, persistResolvedOrigin: false) = use else {
            Issue.record("origem gravada não se reinterpreta nem com outro idioma nos Ajustes")
            return
        }
        #expect(kept.languageOrigin == .autoAdopted)
        #expect(kept.language == .english)
    }

    @Test("Consumir Reprocessar tira o UUID do Set; re-enqueue automático não é manual")
    func consumeManualReprocessAlwaysRemovesInMemoryID() {
        var session = MeetingSession(
            title: "Daily",
            sessionType: .meeting,
            startedAt: Date()
        )
        session.pendingManualReprocess = true
        var ids: Set<UUID> = [session.id]

        #expect(MeetingRecordingLifecycle.consumeManualReprocessIntent(session: session, inMemoryIDs: &ids))
        #expect(ids.isEmpty, "pending no disco não pode pular o remove")

        let finished = MeetingRecordingLifecycle.markingProcessingFinished(session)
        #expect(finished.pendingManualReprocess == false)
        #expect(
            MeetingRecordingLifecycle.consumeManualReprocessIntent(session: finished, inMemoryIDs: &ids) == false,
            "re-enqueue automático depois do término não pode sair como manual"
        )
        #expect(ids.isEmpty)
    }

    @Test("Términos da flag manual: os três desfechos REAIS limpam; crash preserva e o boot re-enfileira uma vez pela fila")
    func manualReprocessFlagEndsOnPassAndSurvivesCrashOnce() throws {
        var session = MeetingSession(
            title: "Daily",
            sessionType: .meeting,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        session.meetingMode = .granola
        session.turns = [
            MeetingTurn(
                source: .microphone,
                speakerName: "Você",
                text: "fala",
                startTime: 0,
                endTime: 1
            )
        ]
        session = MeetingRecordingLifecycle.markingReprocessStarted(session)
        #expect(session.pendingManualReprocess == true)

        // Os desfechos saem das CONDIÇÕES reais da passagem, não de uma
        // constante escolhida pelo teste: plano utilizável + loop completo,
        // plano utilizável + loop abortado, plano vazio.
        let succeeded = MeetingRecordingLifecycle.postCallOutcome(hasUsablePlan: true, cancelled: false)
        let batchFailed = MeetingRecordingLifecycle.postCallOutcome(hasUsablePlan: true, cancelled: true)
        let emptyPlan = MeetingRecordingLifecycle.postCallOutcome(hasUsablePlan: false, cancelled: false)
        #expect(succeeded == .succeeded)
        #expect(batchFailed == .batchFailed)
        #expect(emptyPlan == .emptyPlan)
        #expect(
            MeetingRecordingLifecycle.postCallOutcome(hasUsablePlan: false, cancelled: true) == .emptyPlan,
            "sem motor nenhum o loop de lotes nem roda — o plano vazio manda"
        )

        // Os três são TÉRMINOS: a flag manual sai pelo caminho de verdade
        // (`finishing`), que é o que o passo 5 do runPostProcessing chama.
        for outcome in [succeeded, batchFailed, emptyPlan] {
            let ended = MeetingRecordingLifecycle.finishing(session, after: outcome)
            #expect(ended.pendingManualReprocess == false, "desfecho \(outcome) tem que limpar a flag")
            #expect(ended.isProcessingCompleted == true)
        }

        // Crash no meio: nada chama `finishing`, e o disco preserva a intenção.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recovered = try decoder.decode(MeetingSession.self, from: try encoder.encode(session))
        #expect(recovered.pendingManualReprocess == true)
        #expect(MeetingRecordingLifecycle.isManualReprocess(recovered))
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(
                mode: recovered.meetingMode,
                turnCount: recovered.turns.count,
                isManualReprocess: MeetingRecordingLifecycle.isManualReprocess(recovered)
            ) == .fullBatchPipeline
        )

        // O boot enfileira pela FILA de verdade — a mesma `admittingToPostProcessing`
        // que o `enqueuePostProcessing` usa. Uma vez, e só uma.
        var queue: [UUID] = []
        var current: UUID?
        #expect(
            MeetingRecordingLifecycle.admittingToPostProcessing(
                recovered.id, queue: &queue, current: current
            )
        )
        #expect(queue == [recovered.id])
        #expect(
            MeetingRecordingLifecycle.admittingToPostProcessing(
                recovered.id, queue: &queue, current: current
            ) == false,
            "o boot que reencontra a mesma sessão incompleta não pode duplicar a entrada"
        )
        #expect(queue == [recovered.id])

        // O worker tira da fila e passa a ser o corrente: ainda assim não reentra.
        current = queue.removeFirst()
        #expect(
            MeetingRecordingLifecycle.admittingToPostProcessing(
                recovered.id, queue: &queue, current: current
            ) == false,
            "sessão já rodando não volta para o fim da fila"
        )
        #expect(queue.isEmpty)

        // A passagem consome a intenção no começo (o Set em memória some junto)
        // e o término é que limpa o disco.
        var ids: Set<UUID> = []
        #expect(MeetingRecordingLifecycle.consumeManualReprocessIntent(session: recovered, inMemoryIDs: &ids))
        #expect(ids.isEmpty)
        let afterBoot = MeetingRecordingLifecycle.finishing(recovered, after: succeeded)
        #expect(
            MeetingRecordingLifecycle.consumeManualReprocessIntent(session: afterBoot, inMemoryIDs: &ids) == false,
            "depois do término o boot não re-enfileira como manual de novo"
        )
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(
                mode: afterBoot.meetingMode,
                turnCount: afterBoot.turns.count,
                isManualReprocess: MeetingRecordingLifecycle.isManualReprocess(afterBoot)
            ) == .liveTranscriptThenSummary,
            "sem a intenção o Granola volta ao só-resumo — não refaz lotes sozinho"
        )
    }

    @Test("Duas instâncias do view model não pós-processam a mesma sessão: a reserva é por processo")
    func postProcessingClaimIsSharedAcrossViewModelInstances() {
        // 2026-09-03: a SwiftUI construiu `MeetingViewModel` dezenas de vezes; cada `init`
        // reencontrou a mesma sessão incompleta no disco e, como a fila de 1 é por instância,
        // cada uma admitiu a sessão e rodou o pipeline inteiro — nomes e resumo na API paga,
        // ~60 vezes. A fila continua admitindo (é o contrato dela); é a reserva compartilhada
        // que tem de barrar a segunda instância.
        let sessionId = UUID()
        var inFlight: Set<UUID> = []

        var queueA: [UUID] = []
        #expect(MeetingRecordingLifecycle.admittingToPostProcessing(sessionId, queue: &queueA, current: nil))
        #expect(MeetingRecordingLifecycle.claimingPostProcessing(sessionId, inFlight: &inFlight))

        var queueB: [UUID] = []
        #expect(
            MeetingRecordingLifecycle.admittingToPostProcessing(sessionId, queue: &queueB, current: nil),
            "a fila da instância B não sabe da A — por isso ela sozinha não bastava"
        )
        #expect(
            MeetingRecordingLifecycle.claimingPostProcessing(sessionId, inFlight: &inFlight) == false,
            "a segunda instância encontra a reserva da primeira e desiste"
        )

        // Outra sessão não é bloqueada pela reserva desta.
        #expect(MeetingRecordingLifecycle.claimingPostProcessing(UUID(), inFlight: &inFlight))

        // Término da passagem devolve a sessão: um Reprocessar manual depois volta a entrar.
        MeetingRecordingLifecycle.releasingPostProcessing(sessionId, inFlight: &inFlight)
        #expect(MeetingRecordingLifecycle.claimingPostProcessing(sessionId, inFlight: &inFlight))
    }

    @Test("Intenção persistida re-enfileira Reprocessar como pipeline completo")
    func persistedManualReprocessSurvivesRestart() {
        var session = MeetingSession(
            title: "Daily",
            sessionType: .meeting,
            startedAt: Date()
        )
        session.meetingMode = .granola
        session.turns = [
            MeetingTurn(
                source: .microphone,
                speakerName: "Você",
                text: "fala ao vivo",
                startTime: 0,
                endTime: 2
            )
        ]
        session.pendingManualReprocess = true
        #expect(MeetingRecordingLifecycle.isManualReprocess(session))
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(
                mode: session.meetingMode,
                turnCount: session.turns.count,
                isManualReprocess: MeetingRecordingLifecycle.isManualReprocess(session)
            ) == .fullBatchPipeline,
            "sem a intenção persistida o boot cairia no só-resumo do Granola"
        )
        session.pendingManualReprocess = false
        #expect(
            MeetingRecordingLifecycle.granolaPostCallWork(
                mode: session.meetingMode,
                turnCount: session.turns.count,
                isManualReprocess: MeetingRecordingLifecycle.isManualReprocess(session)
            ) == .liveTranscriptThenSummary
        )
    }

    @Test("Auto puro não coleta áudio de probe")
    func pureAutoSkipsProbeCollection() {
        let auto = LanguageProbeFixtures.snapshot(language: nil, languageOrigin: .autoAdopted)
        #expect(MeetingTranscription.shouldCollectProbeAudio(from: auto) == false)
        let explicit = LanguageProbeFixtures.snapshot(language: .portuguese)
        #expect(MeetingTranscription.shouldCollectProbeAudio(from: explicit))
        let adopted = LanguageProbeFixtures.autoAdopted(language: .english)
        #expect(MeetingTranscription.shouldCollectProbeAudio(from: adopted))
    }

    @Test("Batch só zera turns quando já há substituto")
    func failedBatchDoesNotClearExistingTurns() {
        let existing = [
            MeetingTurn(
                source: .microphone,
                speakerName: "Você",
                text: "fala ao vivo",
                startTime: 1,
                endTime: 2
            )
        ]
        let beforeFirst = MeetingRecordingLifecycle.replacingTurnsIfNeeded(
            existing,
            alreadyReplaced: false
        )
        #expect(beforeFirst.turns.isEmpty)
        #expect(beforeFirst.replaced)

        let afterSuccess = MeetingRecordingLifecycle.replacingTurnsIfNeeded(
            existing,
            alreadyReplaced: true
        )
        #expect(afterSuccess.turns == existing)
        #expect(afterSuccess.replaced)

        // Sem lote bem-sucedido o chamador nem chama replacingTurnsIfNeeded —
        // os turns existentes ficam. Este teste trava a política; o VM só chama
        // no persistRecognizedTurn com texto.
        #expect(existing.isEmpty == false)
    }

    @Test("Notch e Live Assist usam o volátil do mic já gateado")
    func liveOpenPreviewPiecesUseGatedMic() {
        let pieces = MeetingRecordingLifecycle.liveOpenPreviewPieces(
            currentParagraph: "",
            displayedMicrophoneVolatile: "",
            systemVolatile: "eles"
        )
        #expect(pieces == ["eles"])
        let withGatedMic = MeetingRecordingLifecycle.liveOpenPreviewPieces(
            currentParagraph: "",
            displayedMicrophoneVolatile: "você gateado",
            systemVolatile: "eles"
        )
        #expect(withGatedMic == ["você gateado", "eles"])
    }

    @Test("Captura falhou depois do transcritor subir: teardown do ciclo é obrigatório")
    func captureFailureAfterLiveStartRequiresTeardown() {
        #expect(
            MeetingRecordingLifecycle.mustTeardownLiveCycleAfterCaptureFailure(
                liveTranscriberStarted: true
            )
        )
        #expect(
            MeetingRecordingLifecycle.mustTeardownLiveCycleAfterCaptureFailure(
                liveTranscriberStarted: false
            ) == false
        )
    }

    @Test("Sonda Farol: yield(final)+finish+cancel deixa snapshot vazio até await consumer.value")
    func publishedFinalIsInvisibleUntilConsumerIsAwaited() async {
        let event = MeetingLiveTranscriptionEvent.final(
            text: "rabo",
            channel: .microphone,
            window: MeetingLiveCaptureWindow(startTime: 1, endTime: 2)
        )
        let (stream, continuation) = AsyncStream<MeetingLiveTranscriptionEvent>.makeStream()
        var snapshot: [MeetingLiveTranscriptionEvent] = []
        let consumer = Task {
            for await item in stream {
                try? await Task.sleep(for: .milliseconds(30))
                snapshot.append(item)
            }
        }
        continuation.yield(event)
        continuation.finish()
        consumer.cancel()
        #expect(snapshot.isEmpty, "sem await consumer o final publicado ainda não está no snapshot")
        _ = await consumer.value
        #expect(snapshot.count == 1)
        if case .final(let text, _, _) = snapshot[0] {
            #expect(text == "rabo")
        } else {
            Issue.record("esperava o final depois do await consumer.value")
        }
    }

    @Test("Mesmo objeto reutilizado: stop de A não dispara se B já subiu a geração")
    func reusedTranscriberStopIsGenerationGuarded() {
        let generationAfterA = 1
        let generationAfterB = 2
        #expect(
            MeetingRecordingLifecycle.shouldStopLiveTranscriber(
                stoppingGeneration: generationAfterA,
                currentGeneration: generationAfterA
            )
        )
        #expect(
            MeetingRecordingLifecycle.shouldStopLiveTranscriber(
                stoppingGeneration: generationAfterA,
                currentGeneration: generationAfterB
            ) == false
        )
    }
}

private final class InvocationBox: @unchecked Sendable {
    var count = 0
}

private final class PersistSpy: @unchecked Sendable {
    var saved: [MeetingSession] = []
    func save(_ session: MeetingSession) {
        saved.append(session)
    }
}

private actor StartingLiveTranscriber: MeetingLiveTranscriber {
    func start(
        config: MeetingLiveTranscriberConfiguration
    ) async throws -> AsyncStream<MeetingLiveTranscriptionEvent> {
        AsyncStream { $0.finish() }
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async {}

    func stop() async -> [MeetingLiveTranscriptionEvent] { [] }
}

private actor ThrowingStartTranscriber: MeetingLiveTranscriber {
    func start(
        config: MeetingLiveTranscriberConfiguration
    ) async throws -> AsyncStream<MeetingLiveTranscriptionEvent> {
        throw AppleSpeechMeetingTranscriberError.unsupportedLocale
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async {}

    func stop() async -> [MeetingLiveTranscriptionEvent] { [] }
}
