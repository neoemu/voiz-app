import Testing
import Foundation

/// Aquecimento × residência × supersessão (achados MAIORES da review da T2.4a).
///
/// Suíte separada da `TranscriptionCoordinatorTests` de propósito: o que se testa aqui não é o
/// coordenador decidindo sozinho, é o coordenador **na presença de outro consumidor** — dois view
/// models pedindo aquecimento de modelos pesados diferentes, e um view model trocando de plano
/// mais rápido do que o motor carrega.
@Suite("Aquecimento — nunca evicta e é supersedível")
struct CoordinatorWarmUpResidencyTests {

    private struct Harness {
        var coordinator: TranscriptionCoordinator
        var alpha: CoordinatorFakeEngine
        var bravo: CoordinatorFakeEngine
        var log: EngineCallLog
    }

    private func makeHarness(
        alphaWeight: TranscriptionModelWeight = .light,
        bravoWeight: TranscriptionModelWeight = .heavy,
        alphaPrepareGate: TestGate = TestGate(open: true),
        foreignOwners: [any TranscriptionForeignWeightOwner] = []
    ) -> Harness {
        let catalog = CoordinatorFixtures.catalog(alphaWeight: alphaWeight, bravoWeight: bravoWeight)
        let log = EngineCallLog()
        let alpha = CoordinatorFakeEngine(
            id: .fakeAlpha,
            descriptor: CoordinatorFixtures.descriptor(.fakeAlpha, in: catalog),
            log: log,
            text: "alfa",
            prepareGate: alphaPrepareGate
        )
        let bravo = CoordinatorFakeEngine(
            id: .fakeBravo,
            descriptor: CoordinatorFixtures.descriptor(.fakeBravo, in: catalog),
            log: log,
            text: "bravo"
        )
        return Harness(
            coordinator: TranscriptionCoordinator(
                engines: [.fakeAlpha: alpha, .fakeBravo: bravo],
                router: TranscriptionRouter(catalog: catalog),
                hardware: .appleSilicon16GB,
                foreignOwners: foreignOwners
            ),
            alpha: alpha,
            bravo: bravo,
            log: log
        )
    }

    /// O rank 0 do plano automático é o `fakeAlpha` (prioridade 0); para aquecer o `fakeBravo`
    /// basta escolhê-lo à mão, que é o que o outro consumidor faria.
    private let bravoSelection = TranscriptionUserSelection.manual(engine: .fakeBravo)

    // MARK: - Regra 4: aquecimento nunca evicta

    @Test("Aquecer um pesado desiste em vez de descarregar o pesado de outro motor")
    func warmUpNeverEvictsAnotherEnginesHeavyModel() async throws {
        // A configuração real por trás disto: ditado no Parakeet (pesado) e tradução no Whisper
        // large-v3-turbo (pesado) — a T1.4 mantém a tradução no Whisper mesmo com Parakeet global.
        // Antes da regra 4, o segundo aquecimento de boot descarregava o primeiro: o download
        // inteiro do primeiro virava desperdício, e o dono dele ainda pagava a recarga na primeira
        // frase.
        let harness = makeHarness(alphaWeight: .heavy, bravoWeight: .heavy)

        await harness.coordinator.warmUp(for: .dictation, language: .portugueseBrazil)
        #expect(await harness.coordinator.residentModel(of: .fakeAlpha) == .fakeLight)

        await harness.coordinator.warmUp(
            for: .translationChunk,
            language: .portugueseBrazil,
            selection: bravoSelection
        )

        // Quem chegou primeiro fica; o segundo nem toca no motor dele.
        #expect(await harness.coordinator.residentModel(of: .fakeAlpha) == .fakeLight)
        #expect(await harness.coordinator.residentModel(of: .fakeBravo) == nil)
        #expect(harness.log.count(of: .unload(.fakeAlpha)) == 0)
        #expect(harness.log.count(of: .prepare(.fakeBravo, .fakeHeavy)) == 0)
        #expect(await harness.alpha.unloadCount == 0)
    }

    @Test("Sem pesado alheio no caminho, o aquecimento do pesado acontece normalmente")
    func warmUpStillLoadsWhenNothingWouldBeEvicted() async throws {
        // Contraprova do teste acima: a regra 4 é "não evicte", não "não aqueça pesado".
        let harness = makeHarness(alphaWeight: .light, bravoWeight: .heavy)

        await harness.coordinator.warmUp(for: .dictation, language: .portugueseBrazil)
        await harness.coordinator.warmUp(
            for: .translationChunk,
            language: .portugueseBrazil,
            selection: bravoSelection
        )

        #expect(await harness.coordinator.residentModel(of: .fakeBravo) == .fakeHeavy)
        // O leve do outro motor continua onde estava — pesado não evicta leve.
        #expect(await harness.coordinator.residentModel(of: .fakeAlpha) == .fakeLight)
        #expect(harness.log.count(of: .prepare(.fakeBravo, .fakeHeavy)) == 1)
    }

    @Test("Com dono externo registrado, o aquecimento pesado desiste em vez de fazê-lo soltar")
    func warmUpDoesNotAskForeignOwnersToRelease() async throws {
        // `ensureResident` manda os donos externos (as instâncias legadas até a T2.5) liberarem
        // antes de um pesado. Uma cortesia de cadência não pode ser o que faz outra tela soltar o
        // modelo dela.
        let owner = FakeForeignWeightOwner(description: "serviço legado")
        let harness = makeHarness(foreignOwners: [owner])

        await harness.coordinator.warmUp(
            for: .translationChunk,
            language: .portugueseBrazil,
            selection: bravoSelection
        )

        #expect(await owner.releaseCount == 0)
        #expect(harness.log.count(of: .prepare(.fakeBravo, .fakeHeavy)) == 0)
    }

    @Test("O pedido de verdade continua evictando — a regra 4 é só do aquecimento")
    func realRequestsStillEvict() async throws {
        let harness = makeHarness(alphaWeight: .heavy, bravoWeight: .heavy)

        await harness.coordinator.warmUp(for: .dictation, language: .portugueseBrazil)
        let outcome = try await harness.coordinator.transcribe(
            TranscriptionRequest(
                useCase: .translationChunk,
                language: .portugueseBrazil,
                audio: TranscriptionFixtures.audio()
            ),
            selection: bravoSelection
        )

        #expect(outcome.provenance.engine == .fakeBravo)
        // Um pesado residente por vez: o pedido descarrega o alfa, o aquecimento não descarregaria.
        #expect(harness.log.count(of: .unload(.fakeAlpha)) == 1)
        #expect(await harness.coordinator.residentModel(of: .fakeAlpha) == nil)
    }

    // MARK: - Supersessão: só o último aquecimento chega ao motor

    @Test("Aquecimentos superados somem da fila em vez de carregarem em série")
    func supersededWarmUpsNeverReachTheEngine() async throws {
        // Reproduz o que o view model faz ao arrastar o seletor de modelo: cada troca cancela o
        // aquecimento anterior antes de abrir o próximo. Sem o cancelamento, as quatro cargas
        // rodavam inteiras, em série, na frente do primeiro ditado.
        let gate = TestGate()
        let harness = makeHarness(alphaPrepareGate: gate)
        let coordinator = harness.coordinator

        // Segura a vaga do coordenador: o aquecimento do alfa fica parado dentro do `prepare`.
        let blocking = Task { await coordinator.warmUp(for: .dictation, language: .portugueseBrazil) }
        await gate.waitForArrivals(1)

        // Quatro roteamentos em sequência, cada um cancelando o anterior — só o último vale.
        var warmUp: Task<Void, Never>?
        for _ in 0..<4 {
            warmUp?.cancel()
            let selection = bravoSelection
            warmUp = Task { await coordinator.warmUp(for: .dictation, language: .portugueseBrazil, selection: selection) }
            // Dá ao cancelado a chance de chegar à fila e sair dela.
            await Task.yield()
        }

        gate.open()
        _ = try await withDeadline(seconds: 30) {
            await blocking.value
            await warmUp?.value
        }

        // Um `prepare` no bravo, não quatro: os três superados saíram sem tocar no motor.
        #expect(harness.log.count(of: .prepare(.fakeBravo, .fakeHeavy)) == 1)
        #expect(await harness.bravo.prepareCalls == 1)
    }

    @Test("Um aquecimento cancelado não deixa a vaga presa")
    func cancelledWarmUpReleasesThePermit() async throws {
        let gate = TestGate()
        let harness = makeHarness(alphaPrepareGate: gate)
        let coordinator = harness.coordinator

        let blocking = Task { await coordinator.warmUp(for: .dictation, language: .portugueseBrazil) }
        await gate.waitForArrivals(1)

        let superseded = Task {
            await coordinator.warmUp(for: .dictation, language: .portugueseBrazil, selection: bravoSelection)
        }
        await Task.yield()
        superseded.cancel()
        await superseded.value

        gate.open()
        _ = try await withDeadline(seconds: 30) { await blocking.value }

        // A prova de que a vaga voltou: um pedido normal ainda é servido.
        let outcome = try #require(
            await withDeadline(seconds: 30) {
                try await coordinator.transcribe(
                    TranscriptionRequest(
                        useCase: .dictation,
                        language: .portugueseBrazil,
                        audio: TranscriptionFixtures.audio()
                    )
                )
            }
        )
        #expect(outcome.provenance.engine == .fakeAlpha)
    }
}
