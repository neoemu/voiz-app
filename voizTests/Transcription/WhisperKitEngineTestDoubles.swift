import Foundation

// Dublês do seam do motor WhisperKit (`WhisperKitRuntime` / `WhisperKitSession`).
//
// O ponto deles é tornar o CICLO DE VIDA determinístico: `TestGate` deixa o teste parar uma
// carga ou uma inferência exatamente no meio de um `await` — que é onde o ator devolve o
// executor, e portanto onde estavam os três CRÍTICOS da primeira versão desta tarefa. Sem
// portão, um teste de concorrência só testaria o escalonador do dia.

/// Um portão manual: quem chama `wait()` para até alguém chamar `open()`.
///
/// Também conta chegadas, para o teste poder esperar "já tem N tarefas paradas aqui" em vez de
/// dormir e torcer.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0
    private var arrivalWatchers: [(id: Int, target: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWatcherID = 0

    init(open: Bool = false) {
        self.isOpen = open
    }

    /// Registra a chegada e bloqueia enquanto o portão estiver fechado.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrived += 1
            let watchers = arrivalWatchers.filter { $0.target <= arrived }
            arrivalWatchers.removeAll { $0.target <= arrived }
            let passesThrough = isOpen
            if !passesThrough { waiters.append(continuation) }
            lock.unlock()

            for watcher in watchers { watcher.continuation.resume(returning: true) }
            if passesThrough { continuation.resume() }
        }
    }

    /// Fecha o portão de novo. Quem já passou não volta; quem chegar daqui em diante para.
    func close() {
        lock.lock(); defer { lock.unlock() }
        isOpen = false
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    /// Espera até `count` chamadas terem chegado ao portão.
    ///
    /// Devolve `false` se o prazo estourar — um vazamento de vaga não falha sozinho, ele faz a
    /// próxima chegada nunca vir; sem prazo isso pendura a suíte. O watcher sai da lista **sob o
    /// lock** antes de resumir no estouro: senão a chegada tardia resume a mesma continuation.
    /// 30s é cerca de 6× o wall-clock da suíte inteira, não o prazo de 2s que media o escalonador.
    @discardableResult
    func waitForArrivals(_ count: Int, within seconds: Double = 30) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if arrived >= count {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            nextWatcherID += 1
            let id = nextWatcherID
            arrivalWatchers.append((id: id, target: count, continuation: continuation))
            lock.unlock()

            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                lock.lock()
                guard let index = arrivalWatchers.firstIndex(where: { $0.id == id }) else {
                    lock.unlock()
                    return
                }
                let watcher = arrivalWatchers.remove(at: index)
                lock.unlock()
                watcher.continuation.resume(returning: false)
            }
        }
    }

    var arrivals: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrived
    }
}

/// Roda `body` com um prazo. Devolve `nil` se o prazo estourar.
///
/// Existe para transformar "o motor travou" em falha de teste em vez de num teste pendurado: um
/// vazamento de vaga não faz nada falhar, ele faz a próxima operação nunca voltar.
/// Um erro do corpo é propagado (não vira "estouro de prazo"): só `nil` significa que a
/// operação não voltou a tempo.
///
/// Deliberadamente **não** usa `withTaskGroup`: um grupo só devolve depois que todos os filhos
/// terminam, então um corpo de fato travado (uma espera não-cancelável numa vaga vazada, que é
/// justamente o que este helper existe para detectar) penduraria o helper junto. Aqui o corpo
/// roda numa `Task` solta e, se o prazo vencer, ele é abandonado — vazar uma tarefa no processo
/// de teste é o preço de transformar um travamento em falha legível.
func withDeadline<T: Sendable>(
    seconds: Double = 30,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T? {
    let outcome = OneShot<T>()
    let work = Task {
        do {
            let value = try await body()
            await outcome.finish(.success(value))
        } catch {
            await outcome.finish(.failure(error))
        }
    }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await outcome.finish(nil)
    }
    defer { work.cancel(); timer.cancel() }

    switch await outcome.value() {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: return nil
    }
}

/// Guarda o primeiro resultado que chegar e acorda quem estiver esperando. `nil` = prazo vencido.
private actor OneShot<T: Sendable> {
    private var settled: Result<T, any Error>??
    private var waiter: CheckedContinuation<Result<T, any Error>?, Never>?

    func finish(_ result: Result<T, any Error>?) {
        guard settled == nil else { return }
        settled = .some(result)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        }
    }

    func value() async -> Result<T, any Error>? {
        if let settled { return settled }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

/// Espera `condition` virar verdadeira, com prazo. Falha (devolve `false`) em vez de pendurar a
/// suíte quando a condição nunca chega.
///
/// Irmão do `withDeadline` acima, para as condições que não são o resultado de uma operação e sim
/// um estado que aparece depois (a fila do coordenador encheu, o evento hopou para a main actor).
/// O prazo (30s, ~6× o wall-clock da suíte paralela) só transforma pendura em falha: a
/// sincronização é a condição, não o relógio. 2s media starvation do executor.
func waitUntil(
    seconds: Double = 30,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        // 1 ms, não `yield`: o laço quente de yield era o que starvava a tarefa observada.
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Caixa para uma `Task` que o teste só conhece depois de montar o observador.
///
/// Serve para cancelar uma tarefa de dentro do observador de eventos — que o motor chama
/// **sincronamente, já dentro do ator**. É o único ponto de onde o teste consegue injetar um
/// cancelamento no MESMO turno do ator em que a vaga vai ser devolvida; de fora, o hop do
/// `onCancel` sempre chega antes do `releaseSlot()` e a corrida nunca acontece.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, any Error>?

    func hold(_ task: Task<Void, any Error>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Erro de dublê com descrição controlada — é por ela que a heurística de modelo corrompido
/// decide, então o teste precisa ditar o texto.
struct FakeRuntimeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }

    /// O que o CoreML devolve quando o download deixou um `weight.bin` faltando.
    static let corruptedModel = FakeRuntimeError("could not open weight.bin")
}

/// Sessão de inferência falsa: conta chamadas, mede concorrência real e registra a liberação.
final class FakeWhisperKitSession: WhisperKitSession, @unchecked Sendable {
    let id: Int
    /// Portão da inferência. Aberto por padrão — o teste fecha quando quer parar no meio.
    let gate: TestGate
    /// Salta antes e depois do portão. Ver `transcribe(samples:languageCode:)`.
    let padded: Bool

    private let lock = NSLock()
    private var _calls = 0
    private var _concurrent = 0
    private var _maxConcurrent = 0
    private var _releases = 0
    private var _concurrentAtRelease: Int?
    private var _error: (any Error)?
    private var _languageCodes: [String?] = []
    private var _sampleCounts: [Int] = []
    private var _contexts: [TranscriptionContext] = []

    init(id: Int, gate: TestGate = TestGate(open: true), padded: Bool = true) {
        self.id = id
        self.gate = gate
        self.padded = padded
    }

    func setError(_ error: (any Error)?) {
        lock.lock(); defer { lock.unlock() }
        _error = error
    }

    func transcribe(samples: [Float], languageCode: String?, context: TranscriptionContext) async throws -> WhisperKitSessionOutput {
        lock.lock()
        _contexts.append(context)
        _calls += 1
        _concurrent += 1
        _maxConcurrent = max(_maxConcurrent, _concurrent)
        _languageCodes.append(languageCode)
        _sampleCounts.append(samples.count)
        let error = _error
        lock.unlock()

        defer {
            lock.lock()
            _concurrent -= 1
            lock.unlock()
        }

        // Janela de suspensão garantida: sem ela, um dublê síncrono "passaria" no teste de
        // serialização só porque nunca chegou a se sobrepor.
        //
        // `padded == false` remove os saltos em volta do portão: aí, entre o portão abrir e o
        // motor devolver a vaga, não há nenhum hop — é o que permite ao teste do handoff da
        // vaga fazer o `releaseSlot()` ganhar a corrida contra o hop do `onCancel`.
        if padded { await Task.yield() }
        await gate.wait()
        if padded { await Task.yield() }

        if let error { throw error }
        return WhisperKitSessionOutput(
            text: "[MÚSICA] olá  mundo ",
            language: "pt",
            segments: [WhisperKitSessionSegment(text: "olá mundo", start: 0, end: 1.5, confidence: -0.25)]
        )
    }

    func release() async {
        lock.lock(); defer { lock.unlock() }
        _releases += 1
        // Se isto for > 0, os pesos foram soltos com uma inferência ainda em voo.
        _concurrentAtRelease = _concurrent
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrent }
    var releases: Int { lock.lock(); defer { lock.unlock() }; return _releases }
    var concurrentAtRelease: Int? { lock.lock(); defer { lock.unlock() }; return _concurrentAtRelease }
    var languageCodes: [String?] { lock.lock(); defer { lock.unlock() }; return _languageCodes }
    var sampleCounts: [Int] { lock.lock(); defer { lock.unlock() }; return _sampleCounts }
    var contexts: [TranscriptionContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
}

/// Runtime falso: portões em download e carga, erros programáveis por tentativa, e o registro
/// de tudo que o motor pediu ao disco.
final class FakeWhisperKitRuntime: WhisperKitRuntime, @unchecked Sendable {
    let downloadGate: TestGate
    let loadGate: TestGate

    private let lock = NSLock()
    private var _downloadedVariants: Set<String>
    private var _downloadErrors: [Int: any Error] = [:]
    private var _loadErrors: [Int: any Error] = [:]
    private var _downloadCalls: [String] = []
    private var _loadCalls = 0
    private var _removedVariants: [String] = []
    private var _sessions: [FakeWhisperKitSession] = []
    private var _progressReports: [Double] = []
    /// Portão usado pelas sessões criadas daqui em diante.
    private var _sessionGate = TestGate(open: true)
    private var _sessionPadded = true

    init(
        downloadedVariants: Set<String> = [],
        downloadGate: TestGate = TestGate(open: true),
        loadGate: TestGate = TestGate(open: true)
    ) {
        self._downloadedVariants = downloadedVariants
        self.downloadGate = downloadGate
        self.loadGate = loadGate
    }

    /// Erro a lançar na n-ésima chamada (1-based) de download/carga.
    func failDownload(onAttempt attempt: Int, with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        _downloadErrors[attempt] = error
    }

    func failLoad(onAttempt attempt: Int, with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        _loadErrors[attempt] = error
    }

    func useSessionGate(_ gate: TestGate, padded: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        _sessionGate = gate
        _sessionPadded = padded
    }

    // MARK: - WhisperKitRuntime

    func isModelDownloaded(variant: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _downloadedVariants.contains(variant)
    }

    func removeModelFolder(variant: String) {
        lock.lock()
        _removedVariants.append(variant)
        _downloadedVariants.remove(variant)
        lock.unlock()
    }

    func downloadModel(
        variant: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        lock.lock()
        _downloadCalls.append(variant)
        let attempt = _downloadCalls.count
        let error = _downloadErrors[attempt]
        lock.unlock()

        onProgress(0.5)
        await downloadGate.wait()
        if let error { throw error }

        lock.lock()
        _downloadedVariants.insert(variant)
        lock.unlock()
        return URL(fileURLWithPath: "/tmp/fake-whisperkit/\(variant)", isDirectory: true)
    }

    func loadSession(modelFolder: URL) async throws -> any WhisperKitSession {
        lock.lock()
        _loadCalls += 1
        let attempt = _loadCalls
        let error = _loadErrors[attempt]
        let gate = _sessionGate
        let padded = _sessionPadded
        lock.unlock()

        await loadGate.wait()
        if let error { throw error }

        let session = FakeWhisperKitSession(id: attempt, gate: gate, padded: padded)
        lock.lock()
        _sessions.append(session)
        lock.unlock()
        return session
    }

    // MARK: - Observação

    var downloadCalls: [String] { lock.lock(); defer { lock.unlock() }; return _downloadCalls }
    var loadCalls: Int { lock.lock(); defer { lock.unlock() }; return _loadCalls }
    var removedVariants: [String] { lock.lock(); defer { lock.unlock() }; return _removedVariants }
    var sessions: [FakeWhisperKitSession] { lock.lock(); defer { lock.unlock() }; return _sessions }
}

/// Coletor thread-safe dos eventos de carga — o observador é chamado de dentro do ator e da
/// thread do download, então acumular num array solto seria corrida.
nonisolated final class LoadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WhisperKitLoadEvent] = []

    var record: @Sendable (WhisperKitLoadEvent) -> Void {
        { [self] event in
            lock.lock()
            _events.append(event)
            lock.unlock()
        }
    }

    var events: [WhisperKitLoadEvent] { lock.lock(); defer { lock.unlock() }; return _events }

    var stages: [WhisperKitLoadEvent.Stage] { events.map(\.stage) }

    func generations(matching predicate: (WhisperKitLoadEvent.Stage) -> Bool) -> [Int] {
        events.filter { predicate($0.stage) }.map(\.generation)
    }
}

// MARK: - Atalhos de montagem

extension TranscriptionRoutingCandidate {
    static func test(
        model: TranscriptionModelID = .whisperSmall,
        rank: Int = 0,
        origin: TranscriptionSelectionOrigin = .userSelection
    ) -> TranscriptionRoutingCandidate {
        TranscriptionRoutingCandidate(engine: .whisperKit, model: model, rank: rank, origin: origin)
    }
}

extension TranscriptionRequest {
    static func test(
        useCase: TranscriptionUseCase = .dictation,
        language: TranscriptionLanguage? = .portuguese,
        sampleCount: Int = 16_000,
        sampleRate: Double = TranscriptionAudio.defaultSampleRate
    ) -> TranscriptionRequest {
        TranscriptionRequest(
            useCase: useCase,
            language: language,
            audio: TranscriptionAudio(
                samples: Array(repeating: 0.1, count: sampleCount),
                sampleRate: sampleRate
            )
        )
    }
}
