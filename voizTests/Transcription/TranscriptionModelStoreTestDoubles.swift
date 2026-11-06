import Foundation

// Dublês do `TranscriptionModelStore`: um sistema de arquivos em memória e um downloader que
// escreve o que o teste mandar.
//
// O que estes dublês precisam provar é ORDEM — conferir espaço antes de baixar, validar antes de
// instalar, instalar antes de apagar. Por isso o disco falso registra cada operação numa lista:
// contra o disco de verdade, provar "não apagou a revisão antiga antes de validar a nova" exigiria
// encher um volume e matar o processo no instante certo.

// MARK: - Disco e rede falsos para o TranscriptionModelStore
/// Uma operação que o store pediu ao disco. A ordem delas **é** o que a T2.3 promete: validar
/// antes de instalar, instalar antes de apagar.
enum StorageOperation: Equatable, Sendable {
    case createDirectory(String)
    case removeItem(String)
    case moveItem(from: String, to: String)
    case write(String)
    case sha256(String)
    case availableCapacity
}

/// Um sistema de arquivos em memória, com log de operações.
final class FakeModelStorage: TranscriptionModelStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var _operations: [StorageOperation] = []
    private var _availableCapacity: Int64
    private var capacityError: (any Error)?
    private var moveError: (any Error)?

    init(availableCapacity: Int64 = 100 * 1024 * 1024 * 1024) {
        self._availableCapacity = availableCapacity
    }

    // MARK: Programação do teste

    func setAvailableCapacity(_ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        _availableCapacity = bytes
    }

    func failCapacity(with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        capacityError = error
    }

    func failMove(with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        moveError = error
    }

    /// Escreve direto, sem passar pelo log — para montar o estado inicial de um teste.
    func seed(file path: String, contents: Data) {
        lock.lock(); defer { lock.unlock() }
        files[path] = contents
        var directory = (path as NSString).deletingLastPathComponent
        while !directory.isEmpty && directory != "/" {
            directories.insert(directory)
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    var operations: [StorageOperation] { lock.lock(); defer { lock.unlock() }; return _operations }
    var allPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted()
    }

    func contents(at path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    // MARK: TranscriptionModelStorage

    func fileExists(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[url.path] != nil || directories.contains(url.path)
    }

    func createDirectory(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        _operations.append(.createDirectory(url.path))
        var directory = url.path
        while !directory.isEmpty && directory != "/" {
            directories.insert(directory)
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    func removeItem(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        _operations.append(.removeItem(url.path))
        let prefix = url.path + "/"
        guard files[url.path] != nil || directories.contains(url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files = files.filter { !$0.key.hasPrefix(prefix) && $0.key != url.path }
        directories = directories.filter { !$0.hasPrefix(prefix) && $0 != url.path }
    }

    func moveItem(from source: URL, to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        _operations.append(.moveItem(from: source.path, to: destination.path))
        if let moveError { throw moveError }
        let prefix = source.path + "/"
        for (path, data) in files where path.hasPrefix(prefix) || path == source.path {
            let suffix = String(path.dropFirst(source.path.count))
            files[destination.path + suffix] = data
            files[path] = nil
        }
        for path in directories where path.hasPrefix(prefix) || path == source.path {
            let suffix = String(path.dropFirst(source.path.count))
            directories.insert(destination.path + suffix)
            directories.remove(path)
        }
        directories.insert(destination.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        guard directories.contains(url.path) else { throw CocoaError(.fileNoSuchFile) }
        let prefix = url.path + "/"
        let children = Set(
            (Array(files.keys) + Array(directories)).compactMap { path -> String? in
                guard path.hasPrefix(prefix) else { return nil }
                return String(path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
            }
        )
        return children.sorted().map { url.appendingPathComponent($0) }
    }

    func read(at url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url.path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        _operations.append(.write(url.path))
        files[url.path] = data
        directories.insert((url.path as NSString).deletingLastPathComponent)
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        _operations.append(.availableCapacity)
        if let capacityError { throw capacityError }
        // **Falha se `url` não existe**, como o `FileManager` de verdade. Esta fidelidade não é
        // decorativa: a primeira versão do dublê devolvia capacidade para qualquer caminho, e foi
        // isso que mascarou o CRÍTICO do Farol — numa máquina limpa a raiz do depósito não existe,
        // `resourceValues` devolve Cocoa 260, e a primeira instalação da vida do app morria aí,
        // antes de qualquer rede.
        guard directories.contains(url.path) || files[url.path] != nil else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return _availableCapacity
    }

    func sha256(at url: URL) throws -> String {
        lock.lock()
        _operations.append(.sha256(url.path))
        let data = files[url.path]
        lock.unlock()
        guard let data else { throw CocoaError(.fileNoSuchFile) }
        return Self.digest(of: data)
    }

    /// Digest determinístico e falso — o SHA-256 **de verdade** é coberto por um teste próprio
    /// sobre `LiveTranscriptionModelStorage`. O que se testa aqui é a decisão do store diante de
    /// um digest que bate ou não bate, e para isso o algoritmo é irrelevante desde que seja
    /// estável e dependa dos bytes.
    static func digest(of data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let half = String(format: "%016llx", hash)
        return String(repeating: half, count: 4)
    }
}

/// Downloader falso: escreve um conteúdo combinado no destino, ou falha.
final class FakeModelDownloader: TranscriptionModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private let storage: FakeModelStorage
    private var payloads: [Data]
    /// Conteúdo por SHA declarado. Quando presente, o payload deixa de depender da ORDEM das
    /// chamadas — que é o que tornava flaky qualquer teste com duas instalações concorrentes: a
    /// que rodasse primeiro levava o payload da outra e o SHA não batia.
    private let payloadsByChecksum: [String: Data]
    private var error: (any Error)?
    private var _downloads: [URL] = []
    /// Portão do download: fechado, ele segura a instalação exatamente no `await` do meio —
    /// que é onde o ator devolve o executor e onde a ausência de single-flight aparecia.
    let gate: TestGate

    /// - Parameter payloads: um conteúdo por chamada, na ordem. A última se repete.
    init(
        storage: FakeModelStorage,
        payloads: [Data],
        payloadsByChecksum: [String: Data] = [:],
        error: (any Error)? = nil,
        gate: TestGate = TestGate(open: true)
    ) {
        self.storage = storage
        self.payloads = payloads
        self.payloadsByChecksum = payloadsByChecksum
        self.error = error
        self.gate = gate
    }

    /// Downloader honesto: entrega, para cada artefato, o conteúdo cujo digest ele declara.
    convenience init(storage: FakeModelStorage, honestFor payloads: [Data]) {
        self.init(
            storage: storage,
            payloads: payloads,
            payloadsByChecksum: Dictionary(
                uniqueKeysWithValues: payloads.map { (FakeModelStorage.digest(of: $0), $0) }
            )
        )
    }

    convenience init(
        storage: FakeModelStorage,
        payload: Data = Data("pesos".utf8),
        gate: TestGate = TestGate(open: true)
    ) {
        self.init(storage: storage, payloads: [payload], gate: gate)
    }

    func failNext(with error: any Error) {
        lock.lock(); defer { lock.unlock() }
        self.error = error
    }

    var downloads: [URL] { lock.lock(); defer { lock.unlock() }; return _downloads }

    func download(
        _ artifact: TranscriptionModelArtifact,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        lock.lock()
        _downloads.append(artifact.source)
        let index = min(_downloads.count - 1, payloads.count - 1)
        let payload = payloadsByChecksum[artifact.sha256] ?? payloads[index]
        let error = self.error
        lock.unlock()

        onProgress(0.5)
        // Suspensão garantida: sem ela um dublê síncrono nunca exporia a janela em que duas
        // instalações concorrentes se atropelam.
        await Task.yield()
        await gate.wait()
        if let error { throw error }
        // O downloader de produção também escreve pelo `FileManager`, e não pelo seam do store —
        // por isso este `seed` não entra no log de operações.
        storage.seed(file: destination.path, contents: payload)
        onProgress(1)
    }
}

/// Downloader que escreve no **disco de verdade**, para os testes que exercitam
/// `LiveTranscriptionModelStorage`. Não há rede em teste; o que se testa é o disco.
nonisolated struct RealDiskDownloader: TranscriptionModelDownloading {
    let payload: Data

    func download(
        _ artifact: TranscriptionModelArtifact,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        onProgress(0)
        try payload.write(to: destination)
        onProgress(1)
    }
}

nonisolated extension TranscriptionModelArtifact {
    /// Artefato de teste coerente com o dublê: o SHA esperado é o do payload.
    static func test(
        engine: TranscriptionEngineID = .fakeAlpha,
        model: TranscriptionModelID = .fakeHeavy,
        revision: String = "r1",
        fileName: String = "pesos.bin",
        payload: Data = Data("pesos".utf8),
        expectedBytes: Int64 = 1_000
    ) -> TranscriptionModelArtifact {
        TranscriptionModelArtifact(
            engine: engine,
            model: model,
            revision: revision,
            fileName: fileName,
            source: URL(string: "https://exemplo.invalido/\(revision)/\(fileName)")!,
            sha256: FakeModelStorage.digest(of: payload),
            expectedBytes: expectedBytes
        )
    }
}

/// Uma bandeira de "já terminou", para asserções NEGATIVAS: provar que uma operação **não**
/// completou enquanto a condição que ela deve esperar segue valendo.
actor CompletionFlag {
    private(set) var isSet = false

    func set() { isSet = true }
}
