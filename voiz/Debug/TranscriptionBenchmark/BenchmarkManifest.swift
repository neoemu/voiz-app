#if DEBUG
import Foundation

/// Item canônico do manifesto JSONL da T3.4 (schema em Tools/TranscriptionBenchmark).
///
/// `nonisolated`: default isolation do target é MainActor; o runner é um actor próprio.
nonisolated struct BenchmarkManifestItem: Sendable, Equatable {
    var id: String
    var audioPath: String
    var referenceText: String
    var meetingID: String
    var split: String
    var durationS: Double
    var language: String
    var category: String?
    var keywords: [String]?

    nonisolated func resolvedAudioURL(corpusRoot: URL) -> URL {
        let parts = audioPath.split(separator: "/").map(String.init)
        return parts.reduce(corpusRoot) { $0.appendingPathComponent($1) }
    }

    nonisolated var transcriptionLanguage: TranscriptionLanguage? {
        switch language {
        case "pt-BR": return .portugueseBrazil
        case "en": return .englishUS
        case "mixed": return nil
        default: return TranscriptionLanguage(language)
        }
    }
}

nonisolated enum BenchmarkManifestError: Error, LocalizedError, Sendable {
    case fileMissing(String)
    case empty
    case invalidLine(line: Int, detail: String)
    case duplicateID(String)
    case pathEscape(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .fileMissing(let p): return "Manifesto não encontrado: \(p)"
        case .empty: return "Manifesto vazio"
        case .invalidLine(let line, let detail): return "Linha \(line): \(detail)"
        case .duplicateID(let id): return "id duplicado: \(id)"
        case .pathEscape(let p): return "audio_path inválido (absoluto ou com ..): \(p)"
        }
    }
}

nonisolated enum BenchmarkManifestLoader {
    nonisolated static func findManifestURL(corpusRoot: URL) -> URL? {
        let manifestsDir = corpusRoot.appendingPathComponent("manifests", isDirectory: true)
        let preferred = [
            manifestsDir.appendingPathComponent("synthetic_example.jsonl"),
            manifestsDir.appendingPathComponent("ptbr_v1.jsonl"),
        ]
        for url in preferred where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: manifestsDir,
            includingPropertiesForKeys: nil
        ) {
            let jsonl = contents
                .filter { $0.pathExtension.lowercased() == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = jsonl.first { return first }
        }
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: corpusRoot,
            includingPropertiesForKeys: nil
        ) {
            return contents.first { $0.pathExtension.lowercased() == "jsonl" }
        }
        return nil
    }

    nonisolated static func load(from url: URL) throws -> [BenchmarkManifestItem] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkManifestError.fileMissing(url.path)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        var items: [BenchmarkManifestItem] = []
        var seen = Set<String>()
        for (idx, line) in raw.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let lineNo = idx + 1
            guard let data = trimmed.data(using: .utf8) else {
                throw BenchmarkManifestError.invalidLine(line: lineNo, detail: "utf-8")
            }
            let obj: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw BenchmarkManifestError.invalidLine(line: lineNo, detail: "não é objeto")
                }
                obj = parsed
            } catch let err as BenchmarkManifestError {
                throw err
            } catch {
                throw BenchmarkManifestError.invalidLine(line: lineNo, detail: "JSON inválido")
            }

            func reqString(_ key: String) throws -> String {
                guard let v = obj[key] as? String, !v.isEmpty else {
                    throw BenchmarkManifestError.invalidLine(line: lineNo, detail: "faltando \(key)")
                }
                return v
            }
            func reqDouble(_ key: String) throws -> Double {
                if let n = obj[key] as? Double { return n }
                if let n = obj[key] as? Int { return Double(n) }
                if let n = obj[key] as? NSNumber { return n.doubleValue }
                throw BenchmarkManifestError.invalidLine(line: lineNo, detail: "faltando \(key)")
            }

            let id = try reqString("id")
            if seen.contains(id) { throw BenchmarkManifestError.duplicateID(id) }
            seen.insert(id)

            let audioPath = try reqString("audio_path")
            if audioPath.hasPrefix("/") || audioPath.contains("..") {
                throw BenchmarkManifestError.pathEscape(audioPath)
            }

            let keywords = obj["keywords"] as? [String]
            let item = BenchmarkManifestItem(
                id: id,
                audioPath: audioPath,
                referenceText: (obj["reference_text"] as? String) ?? "",
                meetingID: try reqString("meeting_id"),
                split: try reqString("split"),
                durationS: try reqDouble("duration_s"),
                language: try reqString("language"),
                category: obj["category"] as? String,
                keywords: keywords
            )
            items.append(item)
        }
        if items.isEmpty { throw BenchmarkManifestError.empty }
        return items
    }

    nonisolated static func loadCorpus(root: URL) throws -> (manifestURL: URL, items: [BenchmarkManifestItem]) {
        guard let manifestURL = findManifestURL(corpusRoot: root) else {
            throw BenchmarkManifestError.fileMissing("\(root.path)/manifests/*.jsonl")
        }
        return (manifestURL, try load(from: manifestURL))
    }
}
#endif
