#if DEBUG
import Foundation

/// Bookmarks com security scope para pastas escolhidas via NSOpenPanel (sandbox).
///
/// Também usados no CLI headless: a flag de path só funciona se coincidir com o bookmark
/// gravado pela UI **ou** se o path estiver dentro do container do app.
nonisolated enum BenchmarkSecurityScopedBookmarks {
    nonisolated private static let corpusKey = "debug.benchmark.corpusBookmark"
    nonisolated private static let outputKey = "debug.benchmark.outputBookmark"

    nonisolated static func saveCorpus(_ url: URL) {
        save(url, key: corpusKey)
    }

    nonisolated static func saveOutput(_ url: URL) {
        save(url, key: outputKey)
    }

    nonisolated static func loadCorpus() -> URL? { load(key: corpusKey) }
    nonisolated static func loadOutput() -> URL? { load(key: outputKey) }

    /// Resolve corpus+output para CLI ou UI, aplicando a política de sandbox.
    nonisolated static func resolvePair(
        corpusFlag: String?,
        outputFlag: String?
    ) throws -> (corpus: URL, output: URL) {
        let corpus = try BenchmarkPathResolver.resolve(
            flagPath: corpusFlag,
            kind: .corpus,
            bookmarkURL: loadCorpus()
        )
        let output = try BenchmarkPathResolver.resolve(
            flagPath: outputFlag,
            kind: .output,
            bookmarkURL: loadOutput()
        )
        return (corpus, output)
    }

    /// Mantém o acesso security-scoped enquanto o body roda.
    nonisolated static func withAccess<T>(
        to urls: [URL],
        _ body: () async throws -> T
    ) async rethrows -> T {
        var started: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                started.append(url)
            }
        }
        defer {
            for url in started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await body()
    }

    nonisolated private static func save(_ url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            fputs("[bench] bookmark save failed for \(key): \(error.localizedDescription)\n", stderr)
        }
    }

    nonisolated private static func load(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                save(url, key: key)
            }
            return url
        } catch {
            fputs("[bench] bookmark load failed for \(key): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}
#endif
