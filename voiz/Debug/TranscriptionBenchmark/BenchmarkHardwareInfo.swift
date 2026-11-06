#if DEBUG
import Foundation

/// Snapshot de hardware + build para o cabeçalho da rodada (DEBUG-only).
///
/// `app_commit` resolve, nesta ordem:
/// 1. `commitOverride` (CLI / chamada explícita)
/// 2. env `VOIZ_GIT_COMMIT`
/// 3. `VoizGitCommit.txt` no bundle — gerado no **build Debug** (fase "Embed Debug Git
///    Commit"), nunca versionado; Release não o empacota
/// 4. commit Git a partir da árvore de fontes (`#filePath` → `.git`) — testes / fora do sandbox
nonisolated struct BenchmarkHardwareInfo: Sendable, Equatable {
    var chip: String
    var ramGB: Double
    var macOS: String
    var arch: String
    var appCommit: String
    var appVersion: String

    nonisolated static func capture(
        processInfo: ProcessInfo = .processInfo,
        commitOverride: String? = nil,
        bundle: Bundle = .main
    ) -> BenchmarkHardwareInfo {
        let mem = Double(processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        let v = processInfo.operatingSystemVersion
        let macOS = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let chip = sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? arch
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let commit = resolveAppCommit(
            override: commitOverride,
            environment: processInfo.environment
        )
        return BenchmarkHardwareInfo(
            chip: chip,
            ramGB: (mem * 10).rounded() / 10,
            macOS: macOS,
            arch: arch,
            appCommit: commit,
            appVersion: version
        )
    }

    /// Resolução do commit da build DEBUG. `bundleResourceCommit` injeta o txt do bundle
    /// (testável sem `Bundle.main`).
    nonisolated static func resolveAppCommit(
        override: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceCommit: String? = nil,
        sourceFilePath: String = #filePath
    ) -> String {
        if let override, !override.isEmpty, override != "unknown" {
            return override
        }
        if let env = environment["VOIZ_GIT_COMMIT"], !env.isEmpty {
            return env
        }
        let fromBundle = bundleResourceCommit ?? readBundleGitCommit()
        if let fromBundle, !fromBundle.isEmpty, fromBundle != "unknown" {
            return fromBundle
        }
        if let fromGit = readGitCommitNearSourceTree(startingAt: sourceFilePath) {
            return fromGit
        }
        return "unknown"
    }

    /// Lê o recurso gerado no build Debug (`VoizGitCommit.txt`). Release não o tem.
    nonisolated static func readBundleGitCommit(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "VoizGitCommit", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated func asDictionary() -> [String: Any] {
        [
            "chip": chip,
            "ram_gb": ramGB,
            "macos": macOS,
            "arch": arch,
            "app_commit": appCommit,
            "app_version": appVersion,
        ]
    }

    /// Cabeçalho completo da rodada (sem I/O de métricas) — testável sem áudio.
    nonisolated static func makeHeaderDictionary(
        hardware: BenchmarkHardwareInfo,
        target: BenchmarkEngineTarget,
        modelRevision: String,
        timestamp: Date,
        manifestName: String,
        itemCount: Int,
        warmUpCount: Int,
        hypothesesFile: String
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "record": "header",
            "timestamp": iso.string(from: timestamp),
            "hardware": hardware.asDictionary(),
            "engine": target.engine.rawValue,
            "model": target.model.rawValue,
            "model_revision": modelRevision,
            "strict": true,
            "warm_ups_discarded": warmUpCount,
            "manifest": manifestName,
            "item_count": itemCount,
            "hypotheses_file": hypothesesFile,
            "transcripts_in_metrics": false,
        ]
    }

    nonisolated private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Sobe a partir de um path de fonte até achar `.git` e lê HEAD (sem rede).
    nonisolated static func readGitCommitNearSourceTree(startingAt filePath: String) -> String? {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<16 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return parseGitHEAD(gitDir: git)
                }
                // worktree: .git é arquivo com `gitdir: ...`
                if let text = try? String(contentsOf: git, encoding: .utf8),
                   let line = text.split(separator: "\n").first,
                   line.hasPrefix("gitdir:") {
                    let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let gitDir: URL
                    if raw.hasPrefix("/") {
                        gitDir = URL(fileURLWithPath: raw, isDirectory: true)
                    } else {
                        gitDir = dir.appendingPathComponent(raw, isDirectory: true)
                    }
                    return parseGitHEAD(gitDir: gitDir)
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    nonisolated static func parseGitHEAD(gitDir: URL) -> String? {
        let head = gitDir.appendingPathComponent("HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref:") {
            let ref = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            // Worktree: refs vivem no gitdir comum (`commondir`), não no gitdir do worktree.
            let searchRoots = [gitDir, commonGitDir(from: gitDir)].compactMap { $0 }
            for root in searchRoots {
                let refFile = root.appendingPathComponent(ref)
                if let hash = try? String(contentsOf: refFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   hash.count >= 7 {
                    return String(hash.prefix(12))
                }
            }
            for root in searchRoots {
                let packed = root.appendingPathComponent("packed-refs")
                if let packedText = try? String(contentsOf: packed, encoding: .utf8) {
                    let needle = " " + ref
                    for line in packedText.split(whereSeparator: \.isNewline) {
                        if line.hasSuffix(Substring(needle)), !line.hasPrefix("#") {
                            let hash = line.split(separator: " ").first.map(String.init) ?? ""
                            if hash.count >= 7 { return String(hash.prefix(12)) }
                        }
                    }
                }
            }
            return nil
        }
        if trimmed.count >= 7 {
            return String(trimmed.prefix(12))
        }
        return nil
    }

    /// Resolve `commondir` de um gitdir de worktree (path relativo ou absoluto).
    nonisolated static func commonGitDir(from gitDir: URL) -> URL? {
        let commonFile = gitDir.appendingPathComponent("commondir")
        guard let raw = try? String(contentsOf: commonFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return gitDir.appendingPathComponent(raw).standardizedFileURL
    }
}
#endif
