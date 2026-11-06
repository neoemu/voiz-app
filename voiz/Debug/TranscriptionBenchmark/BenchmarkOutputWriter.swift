#if DEBUG
import Foundation

/// Erros do runner / writer puros (sem motores).
nonisolated enum BenchmarkRunnerError: Error, LocalizedError, Sendable {
    case noTargets
    case noItems
    case writeFailed(String)
    case enginePrepare(String)
    case cancelled

    nonisolated var errorDescription: String? {
        switch self {
        case .noTargets: return "Nenhum motor selecionado"
        case .noItems: return "Corpus sem itens"
        case .writeFailed(let d): return "Falha ao escrever saída: \(d)"
        case .enginePrepare(let d): return "prepare falhou: \(d)"
        case .cancelled: return "Cancelado"
        }
    }
}

/// Métricas por item — SEM texto transcrito (regra 7).
nonisolated struct BenchmarkItemMetrics: Sendable, Equatable {
    var id: String
    var audioDurationS: Double
    var latencyS: Double
    var rtfx: Double
    var charCount: Int
    var error: String?

    nonisolated func asDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "record": "item",
            "id": id,
            "audio_duration_s": audioDurationS,
            "latency_s": latencyS,
            "rtfx": rtfx.isFinite ? rtfx : NSNull(),
            "char_count": charCount,
        ]
        if let error {
            d["error"] = error
        } else {
            d["error"] = NSNull()
        }
        return d
    }
}

/// Constantes de contrato do runner (testáveis sem motores).
nonisolated enum BenchmarkContract {
    /// Warm-ups descartados antes das medições (T3.2).
    nonisolated static let warmUpCount = 2
}

/// Chaves proibidas no JSONL de métricas (regra 7 / contrato T3.2).
nonisolated enum BenchmarkMetricsSchema {
    nonisolated static let forbiddenTranscriptKeys: Set<String> = [
        "text", "transcript", "hypothesis", "reference", "reference_text", "hyp",
    ]

    nonisolated static let requiredItemKeys: Set<String> = [
        "record", "id", "audio_duration_s", "latency_s", "rtfx", "char_count", "error",
    ]

    nonisolated static let requiredHeaderKeys: Set<String> = [
        "record", "timestamp", "hardware", "engine", "model", "model_revision",
        "strict", "warm_ups_discarded", "transcripts_in_metrics",
    ]
}

/// Escreve JSONL de métricas + arquivo de hipóteses separado (mock_map da T3.1).
nonisolated enum BenchmarkOutputWriter {
    nonisolated static func hypothesesFileName(slug: String) -> String {
        "hypotheses-\(slug).mock_map.json"
    }

    nonisolated static func metricsFileName(slug: String) -> String {
        "metrics-\(slug).jsonl"
    }

    /// Monta as linhas JSONL (header + items) sem escrever no disco — testável.
    nonisolated static func metricsLines(
        header: [String: Any],
        items: [BenchmarkItemMetrics]
    ) throws -> [String] {
        var lines: [String] = []
        lines.append(try jsonLine(header))
        for item in items {
            let dict = item.asDictionary()
            try assertNoTranscriptKeys(dict)
            lines.append(try jsonLine(dict))
        }
        return lines
    }

    nonisolated static func writeRound(
        outputDirectory: URL,
        target: BenchmarkEngineTarget,
        hardware: BenchmarkHardwareInfo,
        modelRevision: String,
        timestamp: Date,
        items: [BenchmarkItemMetrics],
        hypotheses: [String: String],
        manifestURL: URL,
        warmUpCount: Int
    ) throws -> (metricsURL: URL, hypothesesURL: URL) {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let header = BenchmarkHardwareInfo.makeHeaderDictionary(
            hardware: hardware,
            target: target,
            modelRevision: modelRevision,
            timestamp: timestamp,
            manifestName: manifestURL.lastPathComponent,
            itemCount: items.count,
            warmUpCount: warmUpCount,
            hypothesesFile: hypothesesFileName(slug: target.slug)
        )
        try assertNoTranscriptKeys(header)

        let lines = try metricsLines(header: header, items: items)
        let metricsURL = outputDirectory.appendingPathComponent(metricsFileName(slug: target.slug))
        try lines.joined(separator: "\n").appending("\n").write(
            to: metricsURL,
            atomically: true,
            encoding: .utf8
        )

        let hypothesesURL = outputDirectory.appendingPathComponent(
            hypothesesFileName(slug: target.slug)
        )
        let hypData = try JSONSerialization.data(
            withJSONObject: hypotheses,
            options: [.prettyPrinted, .sortedKeys]
        )
        try hypData.write(to: hypothesesURL, options: .atomic)

        return (metricsURL, hypothesesURL)
    }

    nonisolated static func assertNoTranscriptKeys(_ object: [String: Any]) throws {
        for key in object.keys {
            if BenchmarkMetricsSchema.forbiddenTranscriptKeys.contains(key.lowercased()) {
                throw BenchmarkRunnerError.writeFailed("chave proibida no JSONL de métricas: \(key)")
            }
        }
    }

    nonisolated private static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let s = String(data: data, encoding: .utf8) else {
            throw BenchmarkRunnerError.writeFailed("utf-8")
        }
        return s
    }
}
#endif
