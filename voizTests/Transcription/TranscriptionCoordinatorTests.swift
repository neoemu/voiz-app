import Testing
import Foundation

/// Testes do `TranscriptionCoordinator` com motores falsos.
///
/// O coordenador não transcreve nada — ele decide. Então tudo aqui é sobre decisão: quem foi
/// chamado, em que ordem, o que foi descarregado antes do quê, e o que o resultado diz sobre a
/// escolha. Um teste que só olhasse o texto devolvido passaria com um coordenador que ignorasse o
/// plano inteiro.
@Suite("Coordenador de transcrição — plano, prioridade e residência")
struct TranscriptionCoordinatorTests {

    // MARK: - Montagem

    private struct Harness {
        var coordinator: TranscriptionCoordinator
        var alpha: CoordinatorFakeEngine
        var bravo: CoordinatorFakeEngine
        var log: EngineCallLog
        var clock: TestClock
    }

    private func makeHarness(
        alphaWeight: TranscriptionModelWeight = .light,
        bravoWeight: TranscriptionModelWeight = .heavy,
        alphaPrepareFailures: [Int: TranscriptionEngineFailure] = [:],
        alphaTranscribeFailures: [Int: TranscriptionEngineFailure] = [:],
        bravoPrepareFailures: [Int: TranscriptionEngineFailure] = [:],
        alphaGate: TestGate = TestGate(open: true),
        alphaPrepareGate: TestGate = TestGate(open: true),
        alphaLyingProvenance: TranscriptionProvenance? = nil,
        retryPolicy: TranscriptionRetryPolicy = .default,
        foreignOwners: [any TranscriptionForeignWeightOwner] = [],
        interactiveGrantsBeforeBatch: Int = 3,
        includeBravoEngine: Bool = true
    ) -> Harness {
        let catalog = CoordinatorFixtures.catalog(alphaWeight: alphaWeight, bravoWeight: bravoWeight)
        let log = EngineCallLog()
        let clock = TestClock()

        let alpha = CoordinatorFakeEngine(
            id: .fakeAlpha,
            descriptor: CoordinatorFixtures.descriptor(.fakeAlpha, in: catalog),
            log: log,
            text: "alfa",
            transcribeGate: alphaGate,
            prepareGate: alphaPrepareGate,
            prepareFailures: alphaPrepareFailures,
            transcribeFailures: alphaTranscribeFailures,
            lyingProvenance: alphaLyingProvenance
        )
        let bravo = CoordinatorFakeEngine(
            id: .fakeBravo,
            descriptor: CoordinatorFixtures.descriptor(.fakeBravo, in: catalog),
            log: log,
            text: "bravo",
            prepareFailures: bravoPrepareFailures
        )

        var engines: [TranscriptionEngineID: any BatchTranscriptionEngine] = [.fakeAlpha: alpha]
        if includeBravoEngine { engines[.fakeBravo] = bravo }

        return Harness(
            coordinator: TranscriptionCoordinator(
                engines: engines,
                router: TranscriptionRouter(catalog: catalog),
                hardware: .appleSilicon16GB,
                retryPolicy: retryPolicy,
                foreignOwners: foreignOwners,
                interactiveGrantsBeforeBatch: interactiveGrantsBeforeBatch,
                now: clock.now
            ),
            alpha: alpha,
            bravo: bravo,
            log: log,
            clock: clock
        )
    }

    private func request(
        useCase: TranscriptionUseCase = .dictation,
        language: TranscriptionLanguage? = .portugueseBrazil
    ) -> TranscriptionRequest {
        TranscriptionRequest(useCase: useCase, language: language, audio: TranscriptionFixtures.audio())
    }

    // MARK: - Caminho feliz e proveniência

    @Test("Prepara e transcreve no primeiro candidato, com proveniência de primeira escolha")
    func happyPath() async throws {
        let harness = makeHarness()

        let outcome = try await harness.coordinator.transcribe(request())

        #expect(outcome.text == "alfa")
        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(outcome.provenance.model == .fakeLight)
        #expect(outcome.provenance.candidateRank == 0)
        #expect(outcome.provenance.useCase == .dictation)
        #expect(outcome.usedFallback == false)
        #expect(outcome.failedAttempts.isEmpty)
        // `prepare` antes de `transcribe`: o motor não auto-prepara, então esquecer isso seria
        // `modelUnavailable` em todo pedido.
        #expect(harness.log.calls == [
            .prepare(.fakeAlpha, .fakeLight),
            .transcribe(.fakeAlpha, .fakeLight, .dictation)
        ])
    }

    @Test("A proveniência é do plano, não do motor: um motor que mente é corrigido")
    func provenanceComesFromThePlan() async throws {
        // Um motor com bug (ou de terceiro) não pode dizer que foi primeira escolha quando foi
        // fallback: a proveniência alimenta o histórico e o benchmark da Onda 3.
        let lie = TranscriptionProvenance(
            engine: .fakeCharlie,
            model: .fakePtOnly,
            useCase: .meetingFinal,
            origin: .userSelection,
            candidateRank: 99
        )
        let harness = makeHarness(alphaLyingProvenance: lie)

        let outcome = try await harness.coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(outcome.provenance.candidateRank == 0)
        #expect(outcome.provenance.useCase == .dictation)
        // O texto continua sendo o do motor — só a atribuição é do coordenador.
        #expect(outcome.text == "alfa")
    }

    // MARK: - Fallback

    @Test("Falha de preparação cai para o próximo candidato, com o motivo registrado")
    func fallbackAfterPrepareFailure() async throws {
        let harness = makeHarness(
            alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)]
        )

        let outcome = try await harness.coordinator.transcribe(request())

        #expect(outcome.text == "bravo")
        #expect(outcome.provenance.engine == .fakeBravo)
        #expect(outcome.provenance.candidateRank == 1)
        #expect(outcome.usedFallback)
        // Proveniência fiel quer dizer também: por que o primeiro não deu.
        #expect(outcome.failedAttempts.count == 1)
        #expect(outcome.failedAttempts.first?.candidate.engine == .fakeAlpha)
        #expect(outcome.failedAttempts.first?.stage == .preparation)
        #expect(outcome.failedAttempts.first?.failure == .modelUnavailable(.fakeLight))
    }

    @Test("Falha de inferência também cai para o próximo candidato")
    func fallbackAfterInferenceFailure() async throws {
        let harness = makeHarness(
            alphaTranscribeFailures: [1: .engineInternal("decoder explodiu")]
        )

        let outcome = try await harness.coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeBravo)
        #expect(outcome.failedAttempts.first?.stage == .inference)
        #expect(outcome.failedAttempts.first?.failure == .engineInternal("decoder explodiu"))
    }

    @Test("Falha que não permite fallback para o plano na hora")
    func nonFallbackFailureStopsThePlan() async throws {
        // `invalidAudio` seguiria inválido no próximo motor: reprocessar custa bateria à toa.
        let harness = makeHarness(
            alphaTranscribeFailures: [1: .invalidAudio("áudio curto demais")]
        )

        await #expect(throws: TranscriptionCoordinatorError.self) {
            try await harness.coordinator.transcribe(self.request())
        }
        // O segundo motor nem foi tocado.
        #expect(await harness.bravo.prepareCalls == 0)
        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
    }

    @Test("Cancelamento no motor vira cancelamento do coordenador, sem tentar outro motor")
    func cancellationNeverFallsBack() async throws {
        let harness = makeHarness(alphaTranscribeFailures: [1: .cancelled])

        do {
            _ = try await harness.coordinator.transcribe(request())
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionCoordinatorError {
            #expect(error == .cancelled)
        }

        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
        // Cancelamento não é defeito do modelo: não pode entrar no registro de falhas, senão a
        // próxima tentativa do usuário nasceria de molho.
        #expect(await harness.coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) == nil)
    }

    @Test("Motor citado no plano mas ausente do coordenador é um candidato que falha, não um crash")
    func missingEngineFallsThrough() async throws {
        // O catálogo tem o Apple SpeechAnalyzer desde a T1.2, mas o adapter dele só nasce na
        // Onda 3: o plano cita um motor que o coordenador não tem montado. Isso é um candidato
        // que falha, não um crash — e o próximo tem que tentar.
        let catalog = CoordinatorFixtures.catalog()
        let log = EngineCallLog()
        let bravo = CoordinatorFakeEngine(
            id: .fakeBravo,
            descriptor: CoordinatorFixtures.descriptor(.fakeBravo, in: catalog),
            log: log,
            text: "bravo"
        )
        let coordinator = TranscriptionCoordinator(
            engines: [.fakeBravo: bravo],
            router: TranscriptionRouter(catalog: catalog),
            hardware: .appleSilicon16GB
        )

        let outcome = try await coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeBravo)
        #expect(outcome.failedAttempts.count == 1)
        #expect(outcome.failedAttempts.first?.stage == TranscriptionAttempt.Stage.engineMissing)
        #expect(outcome.failedAttempts.first?.candidate.engine == .fakeAlpha)
    }

    // MARK: - Strict

    @Test("strictEngineSelection nunca usa fallback, mesmo com outro motor viável")
    func strictNeverFallsBack() async throws {
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let selection = TranscriptionUserSelection.manual(engine: .fakeAlpha, strict: true)

        do {
            _ = try await harness.coordinator.transcribe(request(), selection: selection)
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionCoordinatorError {
            guard case .allCandidatesFailed(let attempts) = error else {
                Issue.record("erro inesperado: \(error)")
                return
            }
            #expect(attempts.count == 1)
            #expect(attempts.first?.candidate.engine == .fakeAlpha)
        }

        // O ponto do strict: o outro motor não foi nem preparado.
        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
        #expect(await harness.bravo.prepareCalls == 0)
    }

    @Test("strict com escolha inviável dá plano vazio, e o coordenador não inventa candidato")
    func strictWithUnviableChoiceHasNoCandidate() async throws {
        let harness = makeHarness()
        // `fakeCharlie` não está no catálogo: sob strict, o plano fica vazio.
        let selection = TranscriptionUserSelection.manual(engine: .fakeCharlie, strict: true)

        do {
            _ = try await harness.coordinator.transcribe(request(), selection: selection)
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionCoordinatorError {
            guard case .noCandidate(let plan) = error else {
                Issue.record("erro inesperado: \(error)")
                return
            }
            #expect(plan.isEmpty)
            #expect(plan.rejectionReason(for: .fakeCharlie) == .unknownEngine)
        }
        #expect(harness.log.calls.isEmpty)
    }

    @Test("Plano strict com DOIS candidatos: o segundo nunca é tentado")
    func strictPlanNeverTriesASecondCandidate() async throws {
        // O roteador nunca devolve dois candidatos sob strict — mas o plano é um valor que a T2.5
        // **persiste na sessão** e reusa depois, inclusive vindo de outra versão do app. A
        // promessa "strict não cai para outro motor" é do coordenador, e tem que valer para
        // qualquer plano que chegue, não só para os que ele mesmo montou.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let strictPlan = TranscriptionRoutingPlan(
            useCase: .dictation,
            candidates: [
                TranscriptionRoutingCandidate(
                    engine: .fakeAlpha, model: .fakeLight, rank: 0, origin: .userSelection
                ),
                TranscriptionRoutingCandidate(
                    engine: .fakeBravo, model: .fakeHeavy, rank: 1, origin: .automatic
                )
            ],
            rejections: [],
            isStrict: true
        )

        await #expect(throws: TranscriptionCoordinatorError.self) {
            try await harness.coordinator.transcribe(self.request(), using: strictPlan)
        }

        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
        #expect(await harness.bravo.prepareCalls == 0)
    }

    @Test("Plano strict com motor ausente também não cai para o próximo")
    func strictPlanWithMissingEngineDoesNotFallBack() async throws {
        let catalog = CoordinatorFixtures.catalog()
        let log = EngineCallLog()
        let bravo = CoordinatorFakeEngine(
            id: .fakeBravo,
            descriptor: CoordinatorFixtures.descriptor(.fakeBravo, in: catalog),
            log: log
        )
        let coordinator = TranscriptionCoordinator(
            engines: [.fakeBravo: bravo],
            router: TranscriptionRouter(catalog: catalog),
            hardware: .appleSilicon16GB
        )
        let strictPlan = TranscriptionRoutingPlan(
            useCase: .dictation,
            candidates: [
                TranscriptionRoutingCandidate(
                    engine: .fakeAlpha, model: .fakeLight, rank: 0, origin: .userSelection
                ),
                TranscriptionRoutingCandidate(
                    engine: .fakeBravo, model: .fakeHeavy, rank: 1, origin: .automatic
                )
            ],
            rejections: [],
            isStrict: true
        )

        await #expect(throws: TranscriptionCoordinatorError.self) {
            try await coordinator.transcribe(self.request(), using: strictPlan)
        }
        #expect(log.calls.isEmpty)
    }

    @Test("Plano strict com o candidato de molho não tenta o segundo")
    func strictPlanWithSuppressedCandidateDoesNotFallBack() async throws {
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator
        let strictPlan = TranscriptionRoutingPlan(
            useCase: .dictation,
            candidates: [
                TranscriptionRoutingCandidate(
                    engine: .fakeAlpha, model: .fakeLight, rank: 0, origin: .userSelection
                ),
                TranscriptionRoutingCandidate(
                    engine: .fakeBravo, model: .fakeHeavy, rank: 1, origin: .automatic
                )
            ],
            rejections: [],
            isStrict: true
        )

        // A primeira chamada registra a falha; a segunda encontra o candidato de molho.
        _ = try? await coordinator.transcribe(request(), using: strictPlan)
        do {
            _ = try await coordinator.transcribe(request(), using: strictPlan)
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionCoordinatorError {
            guard case .allCandidatesFailed(let attempts) = error else {
                Issue.record("erro inesperado: \(error)")
                return
            }
            #expect(attempts.count == 1)
            #expect(attempts.first?.stage == TranscriptionAttempt.Stage.suppressed)
        }
        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
    }

    @Test("strict pula o candidato de molho sem tentar o próximo motor")
    func strictWithSuppressedCandidateDoesNotFallBack() async throws {
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let selection = TranscriptionUserSelection.manual(engine: .fakeAlpha, strict: true)

        _ = try? await harness.coordinator.transcribe(request(), selection: selection)
        _ = try? await harness.coordinator.transcribe(request(), selection: selection)

        #expect(await harness.alpha.prepareCalls == 1)
        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
    }

    // MARK: - Prioridade

    @Test("Interativo passa à frente do batch que está esperando")
    func interactiveWorkJumpsAheadOfQueuedBatches() async throws {
        // A vaga do motor é FIFO pura; a ordenação por prioridade é do coordenador. Sem ela, um
        // ditado que chega no meio de uma reunião esperaria todos os lotes enfileirados.
        let gate = TestGate()
        let harness = makeHarness(alphaGate: gate)
        let coordinator = harness.coordinator

        let first = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        // O primeiro lote já está DENTRO da inferência, segurando a vaga.
        await gate.waitForArrivals(1)

        let secondBatch = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        let thirdBatch = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        #expect(await waitUntil { await coordinator.queuedWork.batch == 2 })

        let dictation = Task { try await coordinator.transcribe(self.request(useCase: .dictation)) }
        #expect(await waitUntil { await coordinator.queuedWork.interactive == 1 })

        gate.open()
        _ = try await first.value
        _ = try await dictation.value
        _ = try await secondBatch.value
        _ = try await thirdBatch.value

        // A ordem de ENTRADA na inferência é a ordem em que a fila serviu cada trabalho: o
        // primeiro lote já estava rodando, e o ditado — que chegou por ÚLTIMO — foi servido antes
        // dos dois lotes que já esperavam.
        let served = harness.log.calls.compactMap(\.useCase)
        #expect(served == [.meetingFinal, .dictation, .meetingFinal, .meetingFinal])
        #expect(await coordinator.queuedWork.total == 0)
    }

    @Test("Entre dois interativos vale a ordem de chegada — prioridade não é fura-fila infinita")
    func interactiveWorkKeepsArrivalOrderAmongItself() async throws {
        let gate = TestGate()
        let harness = makeHarness(alphaGate: gate)
        let coordinator = harness.coordinator

        let running = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        await gate.waitForArrivals(1)

        let firstInteractive = Task { try await coordinator.transcribe(self.request(useCase: .dictation)) }
        #expect(await waitUntil { await coordinator.queuedWork.interactive == 1 })
        let secondInteractive = Task {
            try await coordinator.transcribe(self.request(useCase: .translationChunk))
        }
        #expect(await waitUntil { await coordinator.queuedWork.interactive == 2 })

        gate.open()
        _ = try await running.value
        _ = try await firstInteractive.value
        _ = try await secondInteractive.value

        #expect(harness.log.calls.compactMap(\.useCase) == [.meetingFinal, .dictation, .translationChunk])
    }

    @Test("Lote cancelado sai da fila em vez de segurar a vez de quem vem depois")
    func cancelledBatchLeavesTheQueue() async throws {
        let gate = TestGate()
        let harness = makeHarness(alphaGate: gate)
        let coordinator = harness.coordinator

        let running = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        await gate.waitForArrivals(1)

        let doomed = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        #expect(await waitUntil { await coordinator.queuedWork.batch == 1 })

        doomed.cancel()
        #expect(await waitUntil { await coordinator.queuedWork.batch == 0 })

        gate.open()
        _ = try await running.value

        // O cancelado devolve cancelamento, e a vaga volta: o pedido seguinte roda.
        await #expect(throws: TranscriptionCoordinatorError.cancelled) { try await doomed.value }
        let after = try await withDeadline(seconds: 30) {
            try await coordinator.transcribe(
                TranscriptionRequest(useCase: .dictation, language: .portugueseBrazil, audio: TranscriptionFixtures.audio())
            )
        }
        #expect(after?.text == "alfa")
    }

    // MARK: - Residência

    @Test("Um modelo pesado residente: preparar o pesado do outro motor descarrega o primeiro")
    func onlyOneHeavyModelStaysResident() async throws {
        let harness = makeHarness(alphaWeight: .heavy, bravoWeight: .heavy)
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        #expect(await coordinator.residentModel(of: .fakeAlpha) == .fakeLight)

        // Força o segundo motor: escolha manual não-strict do `fakeBravo`.
        _ = try await coordinator.transcribe(
            request(),
            selection: .manual(engine: .fakeBravo)
        )

        #expect(await coordinator.residentModel(of: .fakeBravo) == .fakeHeavy)
        #expect(await coordinator.residentModel(of: .fakeAlpha) == nil)
        #expect(await harness.alpha.unloadCount == 1)
        // Ordem: o pesado antigo sai ANTES de o novo entrar — senão os dois ficam residentes ao
        // mesmo tempo, que é exatamente o que a regra existe para impedir.
        let unloadIndex = try #require(harness.log.firstIndex(of: .unload(.fakeAlpha)))
        let prepareIndex = try #require(harness.log.firstIndex(of: .prepare(.fakeBravo, .fakeHeavy)))
        #expect(unloadIndex < prepareIndex)
    }

    @Test("Modelo leve não desaloja o pesado do outro motor (Whisper small não conta)")
    func lightModelDoesNotEvictHeavyOne() async throws {
        // `fakeAlpha` carrega um modelo LEVE — a regra do plano é sobre pesados, e tratar tudo
        // como pesado faria o ditado descarregar o Parakeet da reunião a cada frase.
        let harness = makeHarness(alphaWeight: .light, bravoWeight: .heavy)
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request(), selection: .manual(engine: .fakeBravo))
        #expect(await coordinator.residentModel(of: .fakeBravo) == .fakeHeavy)

        _ = try await coordinator.transcribe(request())

        #expect(await coordinator.residentModel(of: .fakeAlpha) == .fakeLight)
        #expect(await coordinator.residentModel(of: .fakeBravo) == .fakeHeavy)
        #expect(await harness.bravo.unloadCount == 0)
    }

    @Test("unloadAll descarrega todos e a residência é reconfirmada por prepare, não pelo unload")
    func residencyIsReconfirmedByPrepare() async throws {
        // `unload()` devolve `Void` — ele não é prova de nada. O coordenador registra "não sei
        // mais o que este motor tem" e restabelece a verdade preparando de novo.
        let harness = makeHarness()
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        #expect(await coordinator.residentModel(of: .fakeAlpha) == .fakeLight)

        await coordinator.unloadAll()
        #expect(await coordinator.residentModel(of: .fakeAlpha) == nil)

        _ = try await coordinator.transcribe(request())

        #expect(await harness.alpha.prepareCalls == 2)
        #expect(await coordinator.residentModel(of: .fakeAlpha) == .fakeLight)
    }

    @Test("modelUnavailable durante a inferência esquece a residência que achávamos ter")
    func residencyIsForgottenWhenInferenceSaysUnavailable() async throws {
        let harness = makeHarness(
            alphaTranscribeFailures: [1: .modelUnavailable(.fakeLight)]
        )
        let coordinator = harness.coordinator

        // Cai para o `fakeBravo` nesta chamada…
        _ = try await coordinator.transcribe(request())
        #expect(await coordinator.residentModel(of: .fakeAlpha) == nil)

        // …e a chamada seguinte prepara o alfa de novo, em vez de transcrever sobre pesos que o
        // coordenador não sabe se existem.
        harness.clock.advance(TranscriptionRetryPolicy.default.failureCooldown)
        _ = try await coordinator.transcribe(request())
        #expect(await harness.alpha.prepareCalls == 2)
    }

    // MARK: - Retry e limpeza do latch

    @Test("Falha recente fica de molho: o candidato é pulado sem tocar no motor")
    func recentFailureIsSuppressed() async throws {
        // Sem isto, uma reunião de 40 lotes tentaria 40 downloads do mesmo modelo quebrado.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        let first = try await coordinator.transcribe(request())
        #expect(first.provenance.engine == .fakeBravo)
        #expect(first.failedAttempts.first?.stage == .preparation)

        let second = try await coordinator.transcribe(request())
        #expect(second.provenance.engine == .fakeBravo)
        #expect(second.failedAttempts.first?.stage == .suppressed)
        #expect(second.failedAttempts.first?.failure == .modelUnavailable(.fakeLight))

        // O motor que falhou não foi tocado de novo: nem `unload`, nem `prepare`, nem rede.
        #expect(await harness.alpha.prepareCalls == 1)
        #expect(await harness.alpha.unloadCount == 0)
    }

    @Test("Vencido o cooldown, a nova tentativa limpa o latch do motor com unload antes do prepare")
    func expiredCooldownClearsTheEngineLatch() async throws {
        // O motor latcha o modelo que falhou até troca de modelo ou `unload` (DECISOES, item 7):
        // tentar de novo sem limpar o latch só re-lança a falha antiga sem tentar nada.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        harness.clock.advance(TranscriptionRetryPolicy.default.failureCooldown + 1)

        let outcome = try await coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(await harness.alpha.prepareCalls == 2)
        #expect(await harness.alpha.unloadCount == 1)
        let unloadIndex = try #require(harness.log.firstIndex(of: .unload(.fakeAlpha)))
        let calls = harness.log.calls
        let secondPrepare = calls.enumerated().filter { $0.element == .prepare(.fakeAlpha, .fakeLight) }
        #expect(secondPrepare.count == 2)
        #expect(unloadIndex > secondPrepare[0].offset)
        #expect(unloadIndex < secondPrepare[1].offset)
    }

    @Test("attemptsPerCandidate = 2 tenta o MESMO candidato de novo, limpando o latch no meio")
    func retryWithinTheSameCallClearsTheLatch() async throws {
        // É o que a T2.5 pede: "retry 1× por lote, depois o próximo fallback".
        let harness = makeHarness(
            alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)],
            retryPolicy: TranscriptionRetryPolicy(attemptsPerCandidate: 2)
        )

        let outcome = try await harness.coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(outcome.provenance.candidateRank == 0)
        #expect(await harness.alpha.prepareCalls == 2)
        #expect(await harness.alpha.unloadCount == 1)
        #expect(harness.log.calls == [
            .prepare(.fakeAlpha, .fakeLight),
            .unload(.fakeAlpha),
            .prepare(.fakeAlpha, .fakeLight),
            .transcribe(.fakeAlpha, .fakeLight, .dictation)
        ])
        // O motor `fakeBravo` nem entrou: o retry resolveu antes do fallback.
        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
    }

    @Test("clearFailures devolve o candidato ao jogo — e descarrega, porque o motor ainda latcha")
    func clearFailuresReopensTheCandidate() async throws {
        // O MAIOR do Farol: `clearFailures` apagava também a informação de que a falha anterior
        // fora de preparação, então o pedido seguinte chamava `prepare` sem descarregar — e os
        // motores reais re-lançam `failedModel` na hora, sem tentar nada. Com o dublê latchando (o
        // que os motores de verdade fazem), este teste reprova sem a marca de latch preservada.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        #expect(await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) != nil)
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight))

        await coordinator.clearFailures(engine: .fakeAlpha)
        // A supressão sai…
        #expect(await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) == nil)
        // …mas a marca de latch fica: ela descreve o estado do MOTOR, que ninguém desfez.
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight))

        let outcome = try await coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(outcome.provenance.candidateRank == 0)
        #expect(await harness.alpha.unloadCount == 1)
        let unloadIndex = try #require(harness.log.firstIndex(of: .unload(.fakeAlpha)))
        let transcribeIndex = try #require(
            harness.log.firstIndex(of: .transcribe(.fakeAlpha, .fakeLight, .dictation))
        )
        #expect(unloadIndex < transcribeIndex)
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight) == false)
    }

    @Test("Sem clearFailures nem cooldown vencido, o motor latchado nem é tocado")
    func latchedEngineIsNotTouchedWhileSuppressed() async throws {
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        _ = try await coordinator.transcribe(request())

        #expect(await harness.alpha.prepareCalls == 1)
        #expect(await harness.alpha.unloadCount == 0)
    }

    // MARK: - Política de retry por pedido

    @Test("A política entra por PEDIDO: a mesma instância serve ditado e lote da reunião")
    func retryPolicyArrivesPerRequest() async throws {
        // O MAIOR da Quilha: a política só existia no `init`, então a T2.5 não tinha por onde
        // pedir o "retry 1× por lote" sem subir a repetição também no ditado — ou sem um segundo
        // coordenador, o que derrubaria a regra de dono único dos motores.
        // Duas falhas seguidas de preparação: com uma tentativa por candidato o alfa cai para o
        // fallback; com duas, ele se recupera na segunda. É o que separa as duas políticas.
        let harness = makeHarness(
            alphaPrepareFailures: [
                1: .modelUnavailable(.fakeLight),
                2: .modelUnavailable(.fakeLight)
            ]
        )
        let coordinator = harness.coordinator

        // Ditado: política default, sem repetição → cai para o fallback.
        let dictation = try await coordinator.transcribe(request())
        #expect(dictation.provenance.engine == .fakeBravo)
        #expect(await harness.alpha.prepareCalls == 1)

        await coordinator.clearFailures()

        // Lote da reunião: `.meetingBatch` repete o mesmo candidato antes de cair.
        let batch = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        #expect(batch.provenance.engine == .fakeAlpha)
        #expect(batch.provenance.candidateRank == 0)
        // Duas tentativas, cada uma precedida do `unload` que limpa o latch.
        #expect(await harness.alpha.prepareCalls == 3)
        #expect(await harness.alpha.unloadCount == 2)
    }

    @Test("O cooldown da política do pedido é o que decide a supressão")
    func requestPolicyDecidesTheCooldown() async throws {
        // Duas falhas de preparação seguidas do MESMO caso de uso: a primeira registra a supressão,
        // e é a segunda leitura — feita com políticas diferentes — que este teste compara.
        let harness = makeHarness(
            alphaPrepareFailures: [
                1: .modelUnavailable(.fakeLight),
                2: .modelUnavailable(.fakeLight)
            ]
        )
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request(useCase: .meetingFinal), retryPolicy: .meetingBatch)
        harness.clock.advance(600)

        // Com o cooldown do lote da reunião (que dura a passagem inteira), o candidato continua de
        // molho mesmo depois de 10 minutos — é o que impede o lote de perder o modelo de fallback
        // que está servindo para uma retentativa no meio da reunião.
        let suppressed = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        #expect(suppressed.failedAttempts.first?.stage == TranscriptionAttempt.Stage.suppressed)

        // Com a política default (300 s), o mesmo registro já venceu — e a leitura é do mesmo caso
        // de uso, senão o que este teste mostraria seria a partição, não o cooldown.
        let retried = try await coordinator.transcribe(request(useCase: .meetingFinal))
        #expect(retried.provenance.engine == .fakeAlpha)
    }

    // MARK: - Escopo da supressão: por caso de uso, e por passagem

    @Test("Falha do ditado NÃO suprime o lote da reunião — a supressão é por caso de uso")
    func aDictationFailureDoesNotSuppressAMeetingBatch() async throws {
        // O MAIOR do Farol na T2.5. Com a chave global, o registro que o ditado deixava (300 s) era
        // relido pelo lote da reunião com a política DELE — cooldown infinito —, e o rank 0 da
        // reunião ficava suprimido para sempre sem nunca ter sido tentado nela.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        #expect(
            await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) != nil
        )
        // A reunião não sabe de nada: o livro dela sobre este par está limpo.
        #expect(
            await coordinator.recordedFailure(useCase: .meetingFinal, engine: .fakeAlpha, model: .fakeLight) == nil
        )

        let batch = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        // Tentou de verdade (não foi pulado) e conseguiu — a segunda carga do alfa já passa.
        #expect(batch.provenance.engine == .fakeAlpha)
        #expect(batch.failedAttempts.contains { $0.stage == .suppressed } == false)
    }

    @Test("O latch do motor CONTINUA global: quem tenta depois descarrega antes de preparar")
    func theEngineLatchIsNotPartitioned() async throws {
        // A contrapartida da partição: a supressão é opinião de um consumidor, o latch é fato sobre
        // o motor. Fingir que o latch é por caso de uso faria dois consumidores acreditarem em
        // estados diferentes do mesmo WhisperKit — e o `prepare` re-lançaria a falha antiga na hora,
        // sem tentar nada.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight))

        _ = try await coordinator.transcribe(request(useCase: .meetingFinal), retryPolicy: .meetingBatch)
        // O lote da reunião não foi suprimido, mas também não preparou às cegas: descarregou antes,
        // que é o único caminho contratual para limpar o latch do motor.
        #expect(await harness.alpha.unloadCount == 1)
    }

    @Test("clearFailures(useCase:) reabre só aquele caso de uso — é a fronteira da passagem")
    func clearFailuresByUseCaseIsThePassBoundary() async throws {
        // O alfa falha nas três primeiras cargas: duas gastas pelas duas tentativas do lote da
        // reunião, a terceira pela tentativa única do ditado. Cada um sai com o registro dele.
        let harness = makeHarness(
            alphaPrepareFailures: [
                1: .modelUnavailable(.fakeLight),
                2: .modelUnavailable(.fakeLight),
                3: .modelUnavailable(.fakeLight)
            ]
        )
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request(useCase: .meetingFinal), retryPolicy: .meetingBatch)
        _ = try await coordinator.transcribe(request())

        #expect(
            await coordinator.recordedFailure(useCase: .meetingFinal, engine: .fakeAlpha, model: .fakeLight) != nil
        )
        #expect(
            await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) != nil
        )

        // A nova passagem da reunião reabre o que a REUNIÃO aprendeu, e só isso.
        await coordinator.clearFailures(useCase: .meetingFinal)
        #expect(
            await coordinator.recordedFailure(useCase: .meetingFinal, engine: .fakeAlpha, model: .fakeLight) == nil
        )
        #expect(
            await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) != nil
        )
    }

    @Test("Sem reabrir, o cooldown infinito duraria o PROCESSO inteiro — com reabertura, a passagem")
    func theInfiniteCooldownNeedsAnExplicitReopen() async throws {
        // O alfa falha para sempre; a reunião cai no bravo. A pergunta é o que acontece na
        // passagem SEGUINTE — que é a reunião de amanhã, ou o botão "Reprocessar transcript".
        let harness = makeHarness(
            alphaPrepareFailures: Dictionary(uniqueKeysWithValues: (1...8).map { ($0, TranscriptionEngineFailure.modelUnavailable(.fakeLight)) })
        )
        let coordinator = harness.coordinator

        let first = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        #expect(first.provenance.engine == .fakeBravo)
        let attemptsOnAlpha = await harness.alpha.prepareCalls

        // Segunda passagem SEM reabrir: o alfa é pulado sem tocar no motor, para sempre.
        let withoutReopen = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        #expect(withoutReopen.failedAttempts.first?.stage == TranscriptionAttempt.Stage.suppressed)
        #expect(await harness.alpha.prepareCalls == attemptsOnAlpha)

        // Terceira passagem, agora com a reabertura que o `MeetingViewModel` faz no começo de cada
        // pós-processamento: o rank 0 volta a ser tentado — é o "retry 1× por lote" valendo na
        // primeira tentativa de uma passagem nova.
        await coordinator.clearFailures(useCase: .meetingFinal)
        let withReopen = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        #expect(withReopen.failedAttempts.first?.stage == TranscriptionAttempt.Stage.preparation)
        #expect(await harness.alpha.prepareCalls > attemptsOnAlpha)
    }

    // MARK: - Cancelamento durante a preparação

    @Test("Cancelar durante o prepare devolve na hora e a vaga volta — sem esperar o download")
    func cancellingDuringPrepareReleasesThePermit() async throws {
        // O MAIOR da Quilha: os motores delegam a carga a uma `Task` não estruturada, então
        // `await task.value` não devolve cedo quando quem espera é cancelado. Com a vaga do
        // coordenador na mão, um ditado desistido no meio do download trancava TODA a transcrição
        // do app até o download acabar. O portão do dublê ignora cancelamento de propósito: é
        // exatamente o que o motor real faz.
        let prepareGate = TestGate()
        defer { prepareGate.open() }
        let harness = makeHarness(alphaPrepareGate: prepareGate)
        let coordinator = harness.coordinator

        let doomed = Task { try await coordinator.transcribe(self.request()) }
        // Evento, não relógio de 2s: o prazo de 30s só transforma pendura em falha legível.
        try #require(await prepareGate.waitForArrivals(1))

        doomed.cancel()

        // A vaga voltou: o pedido seguinte entra no `prepare` COM o portão ainda fechado. Se a
        // vaga continuasse com o cancelado — prepare síncrono ou release só no caminho feliz —
        // esta segunda chegada nunca viria; `queuedWork` só conta espera, não posse. A espera
        // das 2 chegadas vem ANTES de `doomed.value`: senão o prepare não-cancelável pendura aí
        // e o prazo do portão nunca entra em cena.
        #expect(prepareGate.arrivals == 1)
        let next = Task { try await coordinator.transcribe(self.request()) }
        try #require(await prepareGate.waitForArrivals(2, within: 30))
        #expect(await coordinator.queuedWork.total == 0)

        await #expect(throws: TranscriptionCoordinatorError.cancelled) { try await doomed.value }
        // A residência é marcada de forma pessimista: a carga abandonada pode terminar depois, e
        // dois pesados residentes seria pior que um `unload` inútil.
        #expect(await coordinator.residentModel(of: .fakeAlpha) == .fakeLight)

        prepareGate.open()
        let outcome = try await next.value
        #expect(outcome.text == "alfa")
    }

    // MARK: - Justiça da fila

    @Test("Depois da cota de interativos, o lote mais antigo é servido")
    func batchIsNotStarvedByContinuousInteractiveWork() async throws {
        // O MAIOR da Quilha: inserir todo interativo à frente de todo lote É a definição de
        // inanição. `.translationChunk` chega continuamente durante a tradução ao vivo e, na Onda
        // 4, `.meetingPreview` também — os lotes da reunião ficariam sem ser servidos.
        let gate = TestGate()
        let harness = makeHarness(alphaGate: gate, interactiveGrantsBeforeBatch: 2)
        let coordinator = harness.coordinator

        let running = Task { try await coordinator.transcribe(self.request(useCase: .dictation)) }
        await gate.waitForArrivals(1)

        // Um lote entra na fila e fica para trás…
        let batch = Task { try await coordinator.transcribe(self.request(useCase: .meetingFinal)) }
        #expect(await waitUntil { await coordinator.queuedWork.batch == 1 })

        // …enquanto três interativos chegam.
        var interactive: [Task<TranscriptionOutcome, any Error>] = []
        for _ in 0..<3 {
            interactive.append(Task { try await coordinator.transcribe(self.request(useCase: .translationChunk)) })
        }
        #expect(await waitUntil { await coordinator.queuedWork.interactive == 3 })

        gate.open()
        _ = try await running.value
        _ = try await batch.value
        for task in interactive { _ = try await task.value }

        // Com a cota em 2: dois interativos furam a fila, e o terceiro cede a vez ao lote.
        let served = harness.log.calls.compactMap(\.useCase)
        #expect(served == [.dictation, .translationChunk, .translationChunk, .meetingFinal, .translationChunk])
    }

    // MARK: - Donos de peso fora do coordenador

    @Test("Antes de carregar um pesado, os donos externos são mandados liberar")
    func foreignOwnersAreAskedToReleaseBeforeAHeavyLoad() async throws {
        // A ponte para a janela de dois donos de memória (T2.4a → T2.5): sem ela, "um modelo
        // pesado residente" seria promessa só sobre a metade do app que já migrou.
        let legacy = FakeForeignWeightOwner(description: "TranscriptionService.shared")
        let harness = makeHarness(bravoWeight: .heavy, foreignOwners: [legacy])
        let coordinator = harness.coordinator
        await legacy.attach(harness.log)

        _ = try await coordinator.transcribe(request(), selection: .manual(engine: .fakeBravo))

        #expect(await legacy.releaseCount == 1)
        #expect(await legacy.releasedBeforeFirstPrepare)
    }

    @Test("Modelo leve não manda ninguém liberar nada")
    func lightModelDoesNotDisturbForeignOwners() async throws {
        let legacy = FakeForeignWeightOwner(description: "TranscriptionService.shared")
        let harness = makeHarness(alphaWeight: .light, foreignOwners: [legacy])

        _ = try await harness.coordinator.transcribe(request())

        #expect(await legacy.releaseCount == 0)
    }

    @Test("unloadAll também libera os donos externos")
    func unloadAllReleasesForeignOwners() async throws {
        let legacy = FakeForeignWeightOwner(description: "MeetingLivePreviewService")
        let harness = makeHarness(foreignOwners: [legacy])

        await harness.coordinator.unloadAll()

        #expect(await legacy.releaseCount == 1)
    }

    @Test("unloadAll toma a vaga: não descarrega por baixo de trabalho em voo")
    func unloadAllWaitsForInFlightWork() async throws {
        // Antes ele rodava fora da vaga: o `unload` cancelava a carga em voo do motor e o pedido
        // morria com `.cancelled` — que não permite fallback — sem ninguém ter cancelado nada.
        let gate = TestGate()
        let harness = makeHarness(alphaGate: gate)
        let coordinator = harness.coordinator

        let running = Task { try await coordinator.transcribe(self.request()) }
        await gate.waitForArrivals(1)

        let unloading = Task { await coordinator.unloadAll() }
        #expect(await waitUntil { await coordinator.queuedWork.batch == 1 })

        gate.open()
        let outcome = try await running.value
        await unloading.value

        // O pedido terminou normalmente, e o unload só rodou depois dele.
        #expect(outcome.text == "alfa")
        let transcribeIndex = try #require(
            harness.log.firstIndex(of: .transcribe(.fakeAlpha, .fakeLight, .dictation))
        )
        let unloadIndex = try #require(harness.log.firstIndex(of: .unload(.fakeAlpha)))
        #expect(transcribeIndex < unloadIndex)
        #expect(await coordinator.residentModel(of: .fakeAlpha) == nil)
    }

    @Test("Sucesso apaga a falha registrada daquele par motor+modelo")
    func successForgetsThePreviousFailure() async throws {
        let harness = makeHarness(
            alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)],
            retryPolicy: TranscriptionRetryPolicy(attemptsPerCandidate: 2)
        )
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request())

        #expect(await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) == nil)
    }

    @Test("Motor que lança fora do vocabulário do contrato vira engineInternal, não erro cru")
    func foreignErrorsAreClassified() async throws {
        // Quem chama o coordenador só precisa entender `TranscriptionCoordinatorError`; um erro
        // desconhecido subindo cru quebraria isso — e, na T2.4a, viraria uma mensagem de erro
        // do sistema na tela do ditado.
        struct ErroEstranho: Error {}
        let catalog = CoordinatorFixtures.catalog()
        let log = EngineCallLog()
        let alpha = ThrowingPrepareEngine(
            id: .fakeAlpha,
            descriptor: CoordinatorFixtures.descriptor(.fakeAlpha, in: catalog),
            log: log,
            error: ErroEstranho()
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

        let outcome = try await coordinator.transcribe(request())

        #expect(outcome.provenance.engine == .fakeBravo)
        #expect(outcome.failedAttempts.count == 1)
        #expect(outcome.failedAttempts.first?.stage == TranscriptionAttempt.Stage.preparation)
        let failure = try #require(outcome.failedAttempts.first?.failure)
        if case .engineInternal = failure {} else {
            Issue.record("esperava engineInternal, veio \(failure)")
        }
    }

    // MARK: - Bordas do pedido

    @Test("A prévia da reunião não entra no caminho em lote")
    func streamingUseCaseIsRejected() async throws {
        let harness = makeHarness()

        await #expect(throws: TranscriptionCoordinatorError.streamingUnsupported(.meetingPreview)) {
            try await harness.coordinator.transcribe(self.request(useCase: .meetingPreview))
        }
        #expect(harness.log.calls.isEmpty)
    }

    @Test("Plano de outro caso de uso é recusado em vez de trocar o motor por baixo do snapshot")
    func planFromAnotherUseCaseIsRejected() async throws {
        let harness = makeHarness()
        let plan = await harness.coordinator.plan(for: .meetingFinal, language: .portugueseBrazil)

        await #expect(
            throws: TranscriptionCoordinatorError.planMismatch(
                planUseCase: .meetingFinal,
                requestUseCase: .dictation
            )
        ) {
            try await harness.coordinator.transcribe(self.request(useCase: .dictation), using: plan)
        }
        #expect(harness.log.calls.isEmpty)
    }

    @Test("O plano guardado é reusado tal e qual pelos lotes seguintes")
    func aStoredPlanIsReusedVerbatim() async throws {
        // É o que a T2.5 precisa: uma mudança nas Configurações no meio da reunião não pode
        // trocar o motor entre dois lotes do mesmo transcript.
        let harness = makeHarness()
        let coordinator = harness.coordinator
        let plan = await coordinator.plan(
            for: .meetingFinal,
            language: .portugueseBrazil,
            selection: .manual(engine: .fakeBravo)
        )

        let first = try await coordinator.transcribe(request(useCase: .meetingFinal), using: plan)
        let second = try await coordinator.transcribe(request(useCase: .meetingFinal), using: plan)

        #expect(first.provenance.engine == .fakeBravo)
        #expect(second.provenance.engine == .fakeBravo)
        #expect(first.provenance.origin == .userSelection)
        #expect(second.plan == plan)
    }

    @Test("Pedido já cancelado não toca em motor nenhum")
    func cancelledRequestNeverTouchesAnEngine() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        let task = Task {
            // Garante que o cancelamento chegue antes do trabalho começar.
            await Task.yield()
            return try await coordinator.transcribe(self.request())
        }
        task.cancel()

        await #expect(throws: TranscriptionCoordinatorError.cancelled) { try await task.value }
        #expect(harness.log.calls.isEmpty)
    }

    // MARK: - Aquecimento

    @Test("O aquecimento deixa o rank-0 residente, sem tocar no fallback nem transcrever")
    func warmUpMakesThePrimaryCandidateResident() async throws {
        // O que a migração dos view models (T2.4a/T2.4b) precisa: quando o usuário aperta gravar,
        // o modelo já está na Neural Engine — como estava com o `ensureInitialized()` legado.
        let harness = makeHarness()
        let coordinator = harness.coordinator

        await coordinator.warmUp(for: .translationChunk, language: .portugueseBrazil)

        // Só o primeiro candidato: aquecer o fallback carregaria pesos que ninguém pediu.
        #expect(harness.log.calls == [.prepare(.fakeAlpha, .fakeLight)])
        #expect(await coordinator.residentModel(of: .fakeAlpha) == .fakeLight)
        #expect(await harness.alpha.residentModel == .fakeLight)

        let outcome = try await coordinator.transcribe(request(useCase: .translationChunk))

        // O pedido encontrou o modelo pronto: nada foi descarregado nem trocado no meio — que é o
        // que "não recarrega" quer dizer aqui, já que o `prepare` idempotente do motor real não
        // deixa rastro observável quando o modelo pedido já é o residente.
        #expect(outcome.provenance.engine == .fakeAlpha)
        #expect(outcome.provenance.candidateRank == 0)
        #expect(harness.log.count(of: .unload(.fakeAlpha)) == 0)
        #expect(harness.log.calls(of: .fakeBravo).isEmpty)
    }

    @Test("Aquecimento que falha não gera cooldown, não marca latch e não impede o pedido seguinte")
    func aFailedWarmUpNeitherRecordsFailureNorBlocksTheRequest() async throws {
        // Regra 2 do `warmUp`: aquecer é cortesia. Gastar a política de retry de um pedido que
        // ainda nem existe faria o aquecimento decidir o desfecho do primeiro pedido de verdade.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        await coordinator.warmUp(for: .translationChunk, language: .portugueseBrazil)

        #expect(harness.log.calls == [.prepare(.fakeAlpha, .fakeLight)])
        #expect(
            await coordinator.recordedFailure(useCase: .translationChunk, engine: .fakeAlpha, model: .fakeLight) == nil
        )
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight) == false)

        // E o pedido seguinte acontece como se o aquecimento nunca tivesse existido: tenta o
        // rank 0 (que o motor re-lança na hora, pelo latch INTERNO dele — o mesmo comportamento do
        // `initializationFailed` do serviço legado) e cai para o fallback.
        let outcome = try await coordinator.transcribe(request(useCase: .translationChunk))

        #expect(outcome.provenance.engine == .fakeBravo)
        #expect(outcome.usedFallback)
        // Sem `unload` antes da segunda tentativa: o coordenador não herdou marca de latch do
        // aquecimento, então não gastou um ciclo de recuperação que ninguém pediu.
        #expect(harness.log.count(of: .unload(.fakeAlpha)) == 0)
        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == 2)
        #expect(
            await coordinator.recordedFailure(useCase: .translationChunk, engine: .fakeAlpha, model: .fakeLight) != nil
        )
    }

    @Test("O aquecimento não fura a supressão de um candidato em cooldown")
    func warmUpRespectsTheFailureCooldown() async throws {
        // Sem isto o aquecimento seria a porta dos fundos que dispara justamente o download que a
        // supressão existe para evitar.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request(useCase: .translationChunk))
        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == 1)

        await coordinator.warmUp(for: .translationChunk, language: .portugueseBrazil)
        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == 1)

        // Vencido o cooldown, o aquecimento volta a valer.
        harness.clock.advance(TranscriptionRetryPolicy.default.failureCooldown + 1)
        await coordinator.warmUp(for: .translationChunk, language: .portugueseBrazil)
        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == 2)
    }

    @Test("O aquecimento lê a supressão com a política do pedido, não com a do coordenador")
    func warmUpReadsTheSuppressionWithTheGivenPolicy() async throws {
        // A regra 3 do `warmUp` ("não fura a supressão") depende de quem lê o registro ler com a
        // MESMA política de quem o escreveu. Hoje não diverge, porque `.silentInteractive` herda os
        // 300 s do default; na T2.5 diverge, e é o cenário que a Quilha desenhou: `.meetingBatch`
        // suprime o candidato falho pela reunião inteira, e um aquecimento que relesse com 300 s
        // dispararia justamente o download que a supressão existe para evitar.
        // `.meetingBatch` tenta o mesmo candidato duas vezes antes do fallback, então as duas
        // tentativas falham para o alfa ser de fato suprimido.
        let harness = makeHarness(
            alphaPrepareFailures: [
                1: .modelUnavailable(.fakeLight),
                2: .modelUnavailable(.fakeLight)
            ]
        )
        let coordinator = harness.coordinator

        let outcome = try await coordinator.transcribe(
            request(useCase: .meetingFinal),
            retryPolicy: .meetingBatch
        )
        #expect(outcome.provenance.engine == .fakeBravo)
        #expect(
            await coordinator.recordedFailure(useCase: .meetingFinal, engine: .fakeAlpha, model: .fakeLight) != nil
        )

        let preparesAfterTheFailure = harness.log.count(of: .prepare(.fakeAlpha, .fakeLight))
        let unloadsAfterTheFailure = harness.log.count(of: .unload(.fakeAlpha))

        // Muito além do cooldown do ditado: com a política do coordenador (300 s) a supressão já
        // teria vencido, então o teste distingue as duas leituras em vez de só confirmar uma.
        harness.clock.advance(TranscriptionRetryPolicy.default.failureCooldown * 10)

        await coordinator.warmUp(
            for: .meetingFinal,
            language: .portugueseBrazil,
            retryPolicy: .meetingBatch
        )
        #expect(
            harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == preparesAfterTheFailure,
            "o aquecimento furou a supressão da reunião"
        )
        // O `unload` é a parte cara do furo: ele evicta o residente para limpar o latch, e é o que
        // faria o lote seguinte pagar uma recarga inteira.
        #expect(harness.log.count(of: .unload(.fakeAlpha)) == unloadsAfterTheFailure)

        // E sem a política do pedido o aquecimento volta a valer, com os 300 s do coordenador já
        // vencidos: prova que a supressão acima veio do parâmetro, e não de o aquecimento ter
        // desistido por outro motivo.
        await coordinator.warmUp(for: .meetingFinal, language: .portugueseBrazil)
        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == preparesAfterTheFailure + 1)
    }

    @Test("Aquecer sob strict nunca aquece um motor que o plano não escolheria")
    func warmUpUnderStrictNeverWarmsAnotherEngine() async throws {
        // Respeitado por construção: o plano do aquecimento sai do mesmo roteador do pedido.
        let harness = makeHarness()
        let coordinator = harness.coordinator

        await coordinator.warmUp(
            for: .translationChunk,
            language: .portugueseBrazil,
            selection: .manual(engine: .fakeBravo, strict: true)
        )

        #expect(harness.log.calls == [.prepare(.fakeBravo, .fakeHeavy)])
    }

    // MARK: - Descrição da falha (LocalizedError)

    @Test("Plano vazio sob strict explica o motivo em vez de virar 'erro 2'")
    func noCandidateDescribesWhyTheStrictPlanIsEmpty() async throws {
        // O modo mais silencioso de a tradução quebrar: um id de modelo que o catálogo não conhece
        // não vira fallback sob strict — vira plano VAZIO. Se a mensagem for genérica, ninguém
        // descobre por quê.
        let harness = makeHarness()
        let unknown = TranscriptionModelID("modelo-que-nao-existe")

        do {
            _ = try await harness.coordinator.transcribe(
                request(useCase: .translationChunk),
                selection: .manual(engine: .fakeAlpha, model: unknown, strict: true)
            )
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionCoordinatorError {
            let described = error.localizedDescription
            // O que o console precisa para ser acionável: caso de uso, que foi seleção estrita, o
            // motor recusado e o motivo — nada de "erro 2".
            #expect(described.contains("translationChunk"))
            #expect(described.contains("seleção estrita"))
            #expect(described.contains(TranscriptionEngineID.fakeAlpha.rawValue))
            #expect(described.contains("selectedModelUnavailable"))
            #expect(described.contains("erro 2") == false)
        }

        // E nenhum motor foi tocado: plano vazio não prepara nada.
        #expect(harness.log.calls.isEmpty)
    }

    @Test("Todas as falhas do coordenador têm descrição própria, e nenhuma é a genérica do enum")
    func everyCoordinatorErrorHasItsOwnDescription() {
        let plan = TranscriptionRoutingPlan(
            useCase: .dictation,
            candidates: [],
            rejections: [TranscriptionRoutingRejection(engine: .fakeAlpha, reason: .unknownEngine)],
            isStrict: false
        )
        let attempt = TranscriptionAttempt(
            candidate: TranscriptionRoutingCandidate(
                engine: .fakeAlpha,
                model: .fakeLight,
                rank: 0,
                origin: .automatic
            ),
            stage: .preparation,
            failure: .modelUnavailable(.fakeLight)
        )
        let errors: [TranscriptionCoordinatorError] = [
            .noCandidate(plan),
            .allCandidatesFailed([attempt]),
            .allCandidatesFailed([]),
            .planMismatch(planUseCase: .meetingFinal, requestUseCase: .dictation),
            .streamingUnsupported(.meetingPreview),
            .cancelled
        ]

        for error in errors {
            let described = error.localizedDescription
            #expect(described.isEmpty == false)
            // A descrição default de um enum sem `LocalizedError` cita o nome do tipo.
            #expect(described.contains("TranscriptionCoordinatorError") == false, "\(error)")
        }
    }

    // MARK: - Falha que não sai da tela (recordsGlobalFailure)

    @Test("Falha de pedido silencioso não vira supressão para os outros casos de uso")
    func aSilentRequestLeavesNoGlobalFailureBehind() async throws {
        // O vazamento que a Quilha achou: a tradução é strict e falha em silêncio, mas gravava
        // `failures[key]` com 300 s — e o ditado, que NÃO é strict, leria isso com a política dele,
        // pularia o Whisper e carregaria o Parakeet por causa de uma falha em outra tela.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        // A tradução falha (strict: sem fallback).
        await #expect(throws: (any Error).self) {
            try await coordinator.transcribe(
                self.request(useCase: .translationChunk),
                selection: .manual(engine: .fakeAlpha, model: .fakeLight, strict: true),
                retryPolicy: .silentInteractive
            )
        }

        // Nada nos livros do coordenador: nem supressão, nem marca de latch.
        #expect(await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) == nil)
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight) == false)

        // O ditado seguinte não é pulado: ele TENTA o alfa (e só cai para o bravo porque o latch
        // interno do motor — que é compartilhado por contrato, como o `initializationFailed`
        // legado era — re-lança na hora).
        let outcome = try await coordinator.transcribe(request(useCase: .dictation))

        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == 2)
        #expect(outcome.provenance.engine == .fakeBravo)
    }

    @Test("Sem registro global, o pedido silencioso seguinte falha barato — sem unload nem recarga")
    func aSilentRequestFailsCheaplyOnRepeat() async throws {
        // O outro lado: se a marca de latch fosse mantida sem a supressão, cada trecho de 1,2 s
        // descarregaria e tentaria baixar de novo. Pular as duas escritas é o que dá a falha barata.
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator
        let selection = TranscriptionUserSelection.manual(engine: .fakeAlpha, model: .fakeLight, strict: true)

        for _ in 0..<3 {
            await #expect(throws: (any Error).self) {
                try await coordinator.transcribe(
                    self.request(useCase: .translationChunk),
                    selection: selection,
                    retryPolicy: .silentInteractive
                )
            }
        }

        // Três prepares (o latch do motor re-lança na hora, sem disco nem rede) e ZERO unloads —
        // nenhuma recarga foi tentada.
        #expect(harness.log.count(of: .prepare(.fakeAlpha, .fakeLight)) == 3)
        #expect(harness.log.count(of: .unload(.fakeAlpha)) == 0)
    }

    @Test("A política default continua registrando — o silêncio é opt-in")
    func theDefaultPolicyStillRecordsFailures() async throws {
        let harness = makeHarness(alphaPrepareFailures: [1: .modelUnavailable(.fakeLight)])
        let coordinator = harness.coordinator

        _ = try await coordinator.transcribe(request(useCase: .dictation))

        #expect(await coordinator.recordedFailure(useCase: .dictation, engine: .fakeAlpha, model: .fakeLight) != nil)
        #expect(await coordinator.knowsLatch(engine: .fakeAlpha, model: .fakeLight))
    }

    // MARK: - Apple SpeechAnalyzer integração no Coordenador (Q1)

    @Test("Plano com Apple SpeechAnalyzer no rank 0 produz proveniência apple-speech-analyzer quando o motor está presente")
    func appleEnginePresentProducesAppleProvenance() async throws {
        let appleEngine = FakeBatchEngine(descriptor: TranscriptionEngineDescriptor.appleSpeechAnalyzer, transcript: "transcrição apple")
        let whisperEngine = FakeBatchEngine(descriptor: TranscriptionEngineDescriptor.whisperKit, transcript: "transcrição whisper")

        let coordinator = TranscriptionCoordinator(
            engines: [
                .appleSpeechAnalyzer: appleEngine,
                .whisperKit: whisperEngine
            ],
            router: TranscriptionRouter(catalog: .shipping),
            hardware: .appleSilicon16GB
        )

        let req = self.request(useCase: .meetingFinal, language: .portugueseBrazil)
        let outcome = try await coordinator.transcribe(
            req,
            selection: .manual(engine: .appleSpeechAnalyzer)
        )

        #expect(outcome.provenance.engine == .appleSpeechAnalyzer)
        #expect(outcome.provenance.model == .appleSystemSpeechPTBR)
        #expect(outcome.text == "transcrição apple")
        #expect(outcome.failedAttempts.isEmpty)
    }

    @Test("Sem o motor Apple no dicionário do coordenador, falha em .engineMissing e cai no fallback WhisperKit small")
    func appleEngineMissingFallsBackToWhisperSmall() async throws {
        let whisperEngine = FakeBatchEngine(descriptor: TranscriptionEngineDescriptor.whisperKit, transcript: "transcrição whisper small")

        // Coordenador montado sem .appleSpeechAnalyzer no dicionário de engines
        let coordinator = TranscriptionCoordinator(
            engines: [
                .whisperKit: whisperEngine
            ],
            router: TranscriptionRouter(catalog: .shipping),
            hardware: .appleSilicon16GB
        )

        let req = self.request(useCase: .meetingFinal, language: .portugueseBrazil)
        // Seleção manual sem strict permite fallback para os candidatos seguintes
        let outcome = try await coordinator.transcribe(
            req,
            selection: .manual(engine: .appleSpeechAnalyzer, strict: false)
        )

        #expect(outcome.provenance.engine == .whisperKit)
        #expect(outcome.provenance.model == .whisperSmall)
        #expect(outcome.text == "transcrição whisper small")
        #expect(outcome.failedAttempts.count == 1)
        #expect(outcome.failedAttempts.first?.stage == TranscriptionAttempt.Stage.engineMissing)
        #expect(outcome.failedAttempts.first?.candidate.engine == .appleSpeechAnalyzer)
    }
}
