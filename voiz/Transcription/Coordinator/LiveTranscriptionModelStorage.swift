import Foundation
import CryptoKit

// As implementações de produção dos dois seams do `TranscriptionModelStore`: o disco
// (`FileManager` + SHA-256 do CryptoKit) e a rede (`URLSession`).
//
// Diferente do `LiveWhisperKitRuntime`, este arquivo **compila também no alvo `voizTests`**: ele
// não importa nenhuma dependência externa (CryptoKit e Foundation são do sistema) e o hash é a
// única parte da validação que um dublê não consegue provar — um teste que compara duas strings
// que ele mesmo inventou não diz nada sobre o digest de verdade.
//
// Decisão nenhuma mora aqui: quem decide o que é espaço suficiente, quando validar e o que apagar
// é o store.

/// O disco de verdade.
nonisolated struct LiveTranscriptionModelStorage: TranscriptionModelStorage {
    /// Tamanho do bloco de leitura do hash. Fixo e pequeno: os artefatos passam de 1 GB e ler
    /// tudo na memória para tirar um digest anularia o cuidado com espaço logo acima.
    private let chunkBytes: Int

    init(chunkBytes: Int = 1024 * 1024) {
        self.chunkBytes = chunkBytes
    }

    /// `FileManager.default` é a única instância documentada como segura para uso concorrente —
    /// guardar uma injetada aqui tornaria este `Sendable` uma mentira (`FileManager` não é
    /// `Sendable`). O seam para os testes é o protocolo, não o gerenciador.
    private var fileManager: FileManager { .default }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func moveItem(from source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func read(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Espaço livre **para dados importantes** (`volumeAvailableCapacityForImportantUsage`), e não
    /// a capacidade bruta: no APFS a capacidade bruta ignora o que o sistema pode liberar
    /// apagando caches, e é a chave "importante" que o macOS usa para decidir se um download cabe.
    func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return capacity
    }

    /// SHA-256 do arquivo, em hex minúsculo, lido em blocos.
    func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// O downloader de produção.
///
/// `URLSession.download(from:)` já escreve num arquivo temporário próprio; o que fazemos aqui é
/// movê-lo para dentro do staging que o store criou. O store é quem valida e quem instala — este
/// tipo nunca toca na pasta definitiva.
nonisolated struct LiveTranscriptionModelDownloader: TranscriptionModelDownloading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(
        _ artifact: TranscriptionModelArtifact,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        onProgress(0)
        let (temporary, response) = try await session.download(from: artifact.source)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw TranscriptionModelStoreError.downloadFailed("HTTP \(http.statusCode)")
        }
        // Se já existe alguma coisa no destino, ela é lixo de uma tentativa anterior dentro do
        // mesmo staging — o store nos entrega uma pasta recém-criada.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        onProgress(1)
    }
}
