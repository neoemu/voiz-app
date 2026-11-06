#if DEBUG
import Foundation

/// Configuração headless do runner (parse puro de argv/env — sem UI, sem I/O).
///
/// `nonisolated` de propósito: o default isolation do target é MainActor; o `BenchmarkRunner`
/// é um actor próprio e precisa chamar este parse sem hop.
nonisolated struct BenchmarkCLIConfig: Sendable, Equatable {
    var corpusPath: String?
    var outputPath: String?
    var enginesRaw: String
    var shouldExit: Bool
    var commitOverride: String?

    /// `nil` quando `--voiz-bench-run` não está em `arguments`.
    static func parse(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BenchmarkCLIConfig? {
        guard arguments.contains("--voiz-bench-run") else { return nil }
        return BenchmarkCLIConfig(
            corpusPath: value(for: "--voiz-bench-corpus", in: arguments),
            outputPath: value(for: "--voiz-bench-out", in: arguments),
            enginesRaw: value(for: "--voiz-bench-engines", in: arguments)
                ?? "whisperkit-small,apple-pt-BR",
            shouldExit: arguments.contains("--voiz-bench-exit"),
            commitOverride: value(for: "--voiz-bench-commit", in: arguments)
                ?? environment["VOIZ_GIT_COMMIT"]
        )
    }

    /// Tokens de motor válidos na ordem pedida (ignora desconhecidos).
    func resolvedTargets() -> [BenchmarkEngineTarget] {
        enginesRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { BenchmarkEngineTarget.parse($0) }
    }

    nonisolated static func value(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag) else { return nil }
        let next = args.index(after: idx)
        guard next < args.endIndex else { return nil }
        return args[next]
    }
}

/// Resolve paths de corpus/saída sob App Sandbox real.
///
/// Prioridade:
/// 1. Bookmark security-scoped persistido (UI) cujo path padronizado **coincide** com a flag
///    (ou a flag está ausente → usa o bookmark).
/// 2. Path da flag se estiver **dentro do container** do app (Documents/Caches/tmp do sandbox).
/// 3. Erro claro pedindo escolha prévia na UI (para gravar o bookmark).
nonisolated enum BenchmarkPathResolver {
    nonisolated enum Kind: String, Sendable {
        case corpus
        case output
    }

    nonisolated enum ResolveError: Error, LocalizedError, Sendable {
        case missingCorpus
        case missingOutput
        case inaccessible(kind: Kind, path: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .missingCorpus:
                return """
                Corpus: informe --voiz-bench-corpus apontando para um path já concedido \
                (bookmark da UI Debug→Benchmark, ou pasta dentro do container do app). \
                Sem bookmark, o App Sandbox bloqueia paths externos.
                """
            case .missingOutput:
                return """
                Saída: informe --voiz-bench-out apontando para um path já concedido \
                (bookmark da UI Debug→Benchmark, ou pasta dentro do container do app).
                """
            case .inaccessible(let kind, let path, let detail):
                return "\(kind.rawValue) inacessível sob sandbox: \(path) (\(detail))"
            }
        }
    }

    /// URL pronta para `startAccessingSecurityScopedResource` quando vier de bookmark.
    nonisolated static func resolve(
        flagPath: String?,
        kind: Kind,
        bookmarkURL: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        let bookmarked = bookmarkURL.map { $0.standardizedFileURL }

        if let flagPath {
            let requested = URL(fileURLWithPath: flagPath, isDirectory: true).standardizedFileURL
            if let bookmarked, pathsMatch(requested, bookmarked) {
                return bookmarked
            }
            if isInsideAppContainer(requested, fileManager: fileManager) {
                return requested
            }
            // Flag sem bookmark correspondente e fora do container → falha explícita.
            let detail: String
            if let bookmarked {
                detail = "flag≠bookmark (\(bookmarked.path)); escolha de novo na UI ou use o path do bookmark"
            } else {
                detail = "sem bookmark; abra Debug→Benchmark, escolha a pasta uma vez, depois repita o CLI"
            }
            throw ResolveError.inaccessible(kind: kind, path: requested.path, detail: detail)
        }

        if let bookmarked {
            return bookmarked
        }
        switch kind {
        case .corpus: throw ResolveError.missingCorpus
        case .output: throw ResolveError.missingOutput
        }
    }

    nonisolated static func pathsMatch(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Paths que o sandbox já permite sem user-selected bookmark.
    nonisolated static func isInsideAppContainer(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let path = url.standardizedFileURL.path
        let candidates: [URL?] = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            fileManager.homeDirectoryForCurrentUser,
        ]
        for base in candidates.compactMap({ $0?.standardizedFileURL }) {
            let basePath = base.path
            if path == basePath || path.hasPrefix(basePath + "/") {
                return true
            }
        }
        // Container clássico: ~/Library/Containers/<bundle>/Data/...
        if path.contains("/Library/Containers/"), path.contains("/Data/") {
            return true
        }
        return false
    }
}
#endif
