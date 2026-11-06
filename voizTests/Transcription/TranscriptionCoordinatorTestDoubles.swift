import Foundation

// Dublês dos motores para os testes do `TranscriptionCoordinator`.
//
// O que estes dublês precisam provar é **ordem** e **quem foi chamado**: o coordenador não
// transcreve nada, ele decide. Por isso tudo aqui registra a sequência de chamadas num log
// compartilhado — "o motor A recebeu `unload` antes de o motor B receber `prepare`" é a asserção
// que interessa, e ela não existe olhando um motor de cada vez.
//
// `TestGate` e `withDeadline` são reaproveitados de `WhisperKitEngineTestDoubles.swift`.

// MARK: - Log compartilhado

/// Uma chamada que um dublê recebeu.
enum EngineCall: Equatable, Sendable {
    case prepare(TranscriptionEngineID, TranscriptionModelID)
    case unload(TranscriptionEngineID)
    /// O caso de uso entra aqui porque é ele que distingue os trabalhos num teste de prioridade:
    /// sem ele, quatro pedidos ao mesmo motor com o mesmo modelo viram quatro entradas idênticas
    /// e a ordem de serviço deixa de ser observável.
    case transcribe(TranscriptionEngineID, TranscriptionModelID, TranscriptionUseCase)

    var engine: TranscriptionEngineID {
        switch self {
        case .prepare(let engine, _), .unload(let engine), .transcribe(let engine, _, _): return engine
        }
    }

    var useCase: TranscriptionUseCase? {
        guard case .transcribe(_, _, let useCase) = self else { return nil }
        return useCase
    }
}

/// Registro thread-safe da ordem das chamadas entre TODOS os motores de um teste.
final class EngineCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [EngineCall] = []

    func record(_ call: EngineCall) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(call)
    }

    var calls: [EngineCall] { lock.lock(); defer { lock.unlock() }; return _calls }

    func calls(of engine: TranscriptionEngineID) -> [EngineCall] {
        calls.filter { $0.engine == engine }
    }

    /// Índice da primeira ocorrência, para asserções de ordem entre motores.
    func firstIndex(of call: EngineCall) -> Int? {
        calls.firstIndex(of: call)
    }

    func count(of call: EngineCall) -> Int {
        calls.filter { $0 == call }.count
    }
}

// MARK: - Motor falso

/// Motor em lote programável: falhas por tentativa, portão na inferência e log de chamadas.
///
/// `actor` como os motores de verdade — o coordenador os usa de tarefas concorrentes, então um
/// dublê com estado solto esconderia justamente o que o teste quer ver.
actor CoordinatorFakeEngine: BatchTranscriptionEngine {
    nonisolated let descriptor: TranscriptionEngineDescriptor
    nonisolated let id: TranscriptionEngineID

    private let log: EngineCallLog
    private let text: String
    /// Portão da inferência: fechado, ele segura o trabalho dentro do motor — que é como o teste
    /// mantém a vaga do coordenador ocupada enquanto enfileira os outros.
    private let transcribeGate: TestGate
    /// Proveniência que o motor devolve, quando o teste quer um motor que mente.
    private let lyingProvenance: TranscriptionProvenance?

    /// Falhas na n-ésima chamada (1-based). Ausente = sucesso.
    private var prepareFailures: [Int: TranscriptionEngineFailure]
    private var transcribeFailures: [Int: TranscriptionEngineFailure]

    private var prepareCount = 0
    private var transcribeCount = 0
    private(set) var unloadCount = 0
    private(set) var residentModel: TranscriptionModelID?

    init(
        id: TranscriptionEngineID,
        descriptor: TranscriptionEngineDescriptor,
        log: EngineCallLog,
        text: String = "texto",
        transcribeGate: TestGate = TestGate(open: true),
        prepareGate: TestGate = TestGate(open: true),
        prepareFailures: [Int: TranscriptionEngineFailure] = [:],
        transcribeFailures: [Int: TranscriptionEngineFailure] = [:],
        lyingProvenance: TranscriptionProvenance? = nil
    ) {
        self.id = id
        self.descriptor = descriptor
        self.log = log
        self.text = text
        self.transcribeGate = transcribeGate
        self.prepareGate = prepareGate
        self.prepareFailures = prepareFailures
        self.transcribeFailures = transcribeFailures
        self.lyingProvenance = lyingProvenance
    }

    /// O latch de falha dos motores de verdade: um modelo cuja carga falhou é re-lançado na hora,
    /// **sem tentar nada**, até troca de modelo ou `unload()` (DECISOES, contrato de ciclo de
    /// vida, item 7; `WhisperKitTranscriptionEngine:194-195`, `ParakeetTranscriptionEngine:241-243`).
    ///
    /// Modelar isto no dublê não é capricho: sem o latch, um coordenador que esquecesse de
    /// descarregar antes de tentar de novo passava nos testes e falhava contra os motores reais —
    /// que foi exatamente o MAIOR do Farol sobre `clearFailures`.
    private var latchedFailure: (model: TranscriptionModelID, failure: TranscriptionEngineFailure)?

    /// Portão da preparação. Fechado, ele segura o `prepare` — e, como `TestGate.wait()` ignora
    /// cancelamento, reproduz fielmente o que os motores fazem: a carga vive numa `Task` não
    /// estruturada e `await task.value` não devolve cedo quando quem espera é cancelado.
    private let prepareGate: TestGate

    func prepare(model: TranscriptionModelID) async throws {
        log.record(.prepare(id, model))
        if let latched = latchedFailure, latched.model == model {
            // Nem conta como tentativa: o motor real devolve antes de tocar em disco ou em rede.
            throw latched.failure
        }
        prepareCount += 1
        let failure = prepareFailures[prepareCount]

        await Task.yield()
        await prepareGate.wait()

        if let failure {
            latchedFailure = (model, failure)
            throw failure
        }
        latchedFailure = nil
        residentModel = model
    }

    func unload() async {
        log.record(.unload(id))
        unloadCount += 1
        residentModel = nil
        // `unload` é o único caminho que limpa o latch — é o que dá sentido ao "descarregue antes
        // de tentar de novo" do coordenador.
        latchedFailure = nil
    }

    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult {
        log.record(.transcribe(id, candidate.model, request.useCase))
        transcribeCount += 1
        let failure = transcribeFailures[transcribeCount]

        // Suspensão garantida antes e depois do portão: sem ela um dublê síncrono passaria em
        // testes de ordenação só porque nunca chegou a se sobrepor a ninguém.
        await Task.yield()
        await transcribeGate.wait()
        await Task.yield()

        if let failure { throw failure }

        // Residência é do coordenador: um motor que não foi preparado recusa, igual aos de
        // verdade. É o que faz o teste de residência falhar se o coordenador esquecer o `prepare`.
        guard residentModel == candidate.model else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }

        return TranscriptionEngineResult(
            text: text,
            segments: [TranscriptionTextSegment(text: text, start: 0, end: request.audio.duration)],
            detectedLanguage: request.language,
            provenance: lyingProvenance ?? TranscriptionProvenance(
                candidate: candidate,
                useCase: request.useCase
            ),
            processingTime: 0.01
        )
    }

    var prepareCalls: Int { prepareCount }
    var transcribeCalls: Int { transcribeCount }
}

/// Motor cujo `prepare` lança um erro que **não** é `TranscriptionEngineFailure`.
///
/// Serve a um caso só: provar que o coordenador classifica o que sobe de um motor mal-comportado
/// em vez de deixar o erro cru chegar à tela.
actor ThrowingPrepareEngine: BatchTranscriptionEngine {
    nonisolated let descriptor: TranscriptionEngineDescriptor
    nonisolated let id: TranscriptionEngineID

    private let log: EngineCallLog
    private let error: any Error

    init(
        id: TranscriptionEngineID,
        descriptor: TranscriptionEngineDescriptor,
        log: EngineCallLog,
        error: any Error
    ) {
        self.id = id
        self.descriptor = descriptor
        self.log = log
        self.error = error
    }

    func prepare(model: TranscriptionModelID) async throws {
        log.record(.prepare(id, model))
        throw error
    }

    func unload() async {
        log.record(.unload(id))
    }

    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult {
        log.record(.transcribe(id, candidate.model, request.useCase))
        throw error
    }
}

/// Um dono de pesos fora do coordenador — o dublê das instâncias legadas que sobrevivem até a
/// T2.5 (`TranscriptionService.shared`, os `ParakeetTranscriptionService` dos view models, o
/// WhisperKit do preview).
actor FakeForeignWeightOwner: TranscriptionForeignWeightOwner {
    nonisolated let ownerDescription: String

    private(set) var releaseCount = 0
    /// A liberação aconteceu antes de o coordenador preparar qualquer motor? É a ordem que
    /// interessa: liberar depois de já ter carregado não protege memória nenhuma.
    private(set) var releasedBeforeFirstPrepare = false

    private var log: EngineCallLog?

    init(description: String) {
        self.ownerDescription = description
    }

    /// O log do harness só existe depois do harness, e o dono precisa existir antes dele — daí a
    /// ligação em dois tempos. Basta acontecer antes do primeiro pedido.
    func attach(_ log: EngineCallLog) {
        self.log = log
    }

    func releaseHeavyWeights() async {
        releaseCount += 1
        if releaseCount == 1, let log {
            releasedBeforeFirstPrepare = !log.calls.contains { call in
                if case .prepare = call { return true }
                return false
            }
        }
    }
}

// MARK: - Catálogo de motores falsos

nonisolated enum CoordinatorFixtures {
    /// Um catálogo com dois motores: `fakeAlpha` (prioridade 0, modelo leve) e `fakeBravo`
    /// (prioridade 10, modelo pesado). É o formato mínimo para exercitar fallback e residência.
    static func catalog(
        alphaWeight: TranscriptionModelWeight = .light,
        bravoWeight: TranscriptionModelWeight = .heavy
    ) -> TranscriptionCatalog {
        TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(
                .fakeAlpha,
                useCases: [.dictation, .translationChunk, .meetingFinal],
                streaming: false,
                models: [TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha, weight: alphaWeight)],
                priority: 0
            ),
            TranscriptionFixtures.engine(
                .fakeBravo,
                useCases: [.dictation, .translationChunk, .meetingFinal],
                streaming: false,
                models: [TranscriptionFixtures.model(.fakeHeavy, engine: .fakeBravo, weight: bravoWeight)],
                priority: 10
            )
        ])
    }

    static func descriptor(
        _ engine: TranscriptionEngineID,
        in catalog: TranscriptionCatalog
    ) -> TranscriptionEngineDescriptor {
        catalog.descriptor(for: engine)!
    }
}

/// Relógio de teste: o cooldown de falha precisa ser observável sem dormir cinco minutos.
///
/// `nonisolated` porque o alvo compila com isolamento default na main actor, e o coordenador lê o
/// relógio de dentro do ator dele — sem a anotação, a closure devolvida por `now` nasce isolada e
/// deixa de ser `@Sendable`.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self._now = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return _now
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}
