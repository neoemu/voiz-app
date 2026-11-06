import Foundation

/// Busca dos pesos pt-BR do Parakeet (fine-tune convertido para CoreML na Onda 5).
///
/// O `Repo` do FluidAudio é um enum fechado com os repositórios da FluidInference, então o
/// `ModelHub` não sabe baixar de um repositório de terceiro. Este tipo faz o download e entrega uma
/// pasta pronta para o `AsrModels.load(from:)`, que é o caminho já validado.
///
/// Nada de texto reconhecido passa por aqui: são nomes de arquivo e bytes de modelo.
enum ParakeetPTBRWeights {

    /// Repositório publicado com a cadeia de atribuição no model card (NVIDIA → fine-tune → conversão).
    static let repoID = "neoemu/parakeet-tdt-0.6b-v3-ptBR-coreml"

    /// Arquivo cuja presença marca "pesos completos no disco".
    ///
    /// É o último a ser movido para o lugar, então existir significa que os outros já estão lá — um
    /// download interrompido não deixa a pasta parecendo pronta.
    static let sentinelName = "Encoder.mlmodelc"

    enum Failure: Error, LocalizedError {
        case noApplicationSupport
        case listing(String)
        case download(file: String, status: Int)

        var errorDescription: String? {
            switch self {
            case .noApplicationSupport:
                return "sem Application Support para guardar os pesos"
            case .listing(let detail):
                return "não consegui listar os arquivos do modelo: \(detail)"
            case .download(let file, let status):
                return "download de \(file) falhou (HTTP \(status))"
            }
        }
    }

    /// Pasta onde os pesos moram.
    ///
    /// O caminho precisa TERMINAR no nome do repositório do FluidAudio: `AsrModels.load(from:)`
    /// remove o último componente e o reanexa a partir do `version.repo`. Passar a pasta de cima faz
    /// ele procurar no lugar errado e cair, em silêncio, nos pesos em cache do modelo base.
    static func directory(inside support: URL) -> URL {
        support.appendingPathComponent(
            "FluidAudio/Models-ptbr/parakeet-tdt-0.6b-v3", isDirectory: true
        )
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return directory(inside: support)
    }

    /// URL de download de um arquivo do repositório.
    static func fileURL(path: String) -> URL? {
        URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(path)")
    }

    /// Os pesos já estão completos no disco?
    static func isInstalled(at directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(sentinelName).path)
    }

    /// Arquivos do repositório que interessam ao carregador.
    ///
    /// O model card e os checksums ficam de fora: são para quem lê a página, não para o runtime, e
    /// baixá-los só gastaria rede.
    static func modelFiles(from listed: [String]) -> [String] {
        listed
            .filter { $0.contains(".mlmodelc/") || $0.hasSuffix(".json") }
            .filter { $0 != "conversion-metadata.json" }
            .sorted { a, b in
                // O sentinela por último: a pasta só "fica pronta" quando o resto já está lá.
                if a.hasPrefix(sentinelName) != b.hasPrefix(sentinelName) {
                    return b.hasPrefix(sentinelName)
                }
                return a < b
            }
    }

    /// Garante os pesos no disco e devolve a pasta. Não baixa de novo o que já está lá.
    static func ensureAvailable(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) async throws -> URL {
        guard let directory = defaultDirectory(fileManager: fileManager) else {
            throw Failure.noApplicationSupport
        }
        if isInstalled(at: directory, fileManager: fileManager) { return directory }

        let files = modelFiles(from: try await listFiles(session: session))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for path in files {
            guard let remote = fileURL(path: path) else { continue }
            let destination = directory.appendingPathComponent(path)
            if fileManager.fileExists(atPath: destination.path) { continue }

            let (temporary, response) = try await session.download(from: remote)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                try? fileManager.removeItem(at: temporary)
                throw Failure.download(file: path, status: status)
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Move para o lugar só depois do corpo inteiro chegar: um arquivo pela metade no destino
            // faria a próxima carga achar que já baixou.
            _ = try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return directory
    }

    private static func listFiles(session: URLSession) async throws -> [String] {
        guard let api = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            throw Failure.listing("URL inválida")
        }
        let (data, response) = try await session.data(from: api)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.listing("HTTP \(status)") }
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let siblings = object["siblings"] as? [[String: Any]]
        else { throw Failure.listing("resposta sem lista de arquivos") }
        return siblings.compactMap { $0["rfilename"] as? String }
    }
}
