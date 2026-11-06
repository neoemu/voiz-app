#if DEBUG
import Foundation

/// Alvo de medição STRICT (um motor + um modelo). Sem fallback — o dado é por motor.
nonisolated struct BenchmarkEngineTarget: Sendable, Hashable, Identifiable {
    var engine: TranscriptionEngineID
    var model: TranscriptionModelID
    /// Rótulo estável para nomes de arquivo (sem espaços).
    var slug: String

    nonisolated var id: String { slug }

    nonisolated var displayName: String {
        "\(engine.rawValue) / \(model.rawValue)"
    }

    nonisolated static let whisperKitSmall = BenchmarkEngineTarget(
        engine: .whisperKit,
        model: .whisperSmall,
        slug: "whisperkit-openai_whisper-small"
    )
    nonisolated static let whisperKitBase = BenchmarkEngineTarget(
        engine: .whisperKit,
        model: .whisperBase,
        slug: "whisperkit-openai_whisper-base"
    )
    nonisolated static let whisperKitMedium = BenchmarkEngineTarget(
        engine: .whisperKit,
        model: .whisperMedium,
        slug: "whisperkit-openai_whisper-medium"
    )
    nonisolated static let whisperKitLargeV3Turbo = BenchmarkEngineTarget(
        engine: .whisperKit,
        model: .whisperLargeV3Turbo,
        slug: "whisperkit-openai_whisper-large-v3_turbo"
    )
    nonisolated static let parakeet = BenchmarkEngineTarget(
        engine: .parakeet,
        model: .parakeetTDT06BV3,
        slug: "parakeet-parakeet-tdt-0.6b-v3"
    )
    nonisolated static let applePTBR = BenchmarkEngineTarget(
        engine: .appleSpeechAnalyzer,
        model: .appleSystemSpeechPTBR,
        slug: "apple-speech-analyzer-pt-BR"
    )
    nonisolated static let appleENUS = BenchmarkEngineTarget(
        engine: .appleSpeechAnalyzer,
        model: .appleSystemSpeechENUS,
        slug: "apple-speech-analyzer-en-US"
    )

    nonisolated static let allSelectable: [BenchmarkEngineTarget] = [
        .whisperKitSmall,
        .whisperKitBase,
        .whisperKitMedium,
        .whisperKitLargeV3Turbo,
        .parakeet,
        .applePTBR,
        .appleENUS,
    ]

    /// Parse de CLI: `whisperkit-small`, `apple-pt-BR`, `parakeet`, ou slug completo.
    nonisolated static func parse(_ token: String) -> BenchmarkEngineTarget? {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "whisperkit-small", "whisper-small", "whisperkit-openai_whisper-small":
            return .whisperKitSmall
        case "whisperkit-base", "whisper-base", "whisperkit-openai_whisper-base":
            return .whisperKitBase
        case "whisperkit-medium", "whisper-medium", "whisperkit-openai_whisper-medium":
            return .whisperKitMedium
        case "whisperkit-large-v3-turbo", "whisper-large-v3-turbo",
             "whisperkit-openai_whisper-large-v3_turbo":
            return .whisperKitLargeV3Turbo
        case "parakeet", "parakeet-parakeet-tdt-0.6b-v3":
            return .parakeet
        case "apple", "apple-pt-br", "apple-ptbr", "apple-speech-analyzer-pt-br":
            return .applePTBR
        case "apple-en", "apple-en-us", "apple-enus", "apple-speech-analyzer-en-us":
            return .appleENUS
        default:
            return allSelectable.first { $0.slug.lowercased() == key }
        }
    }
}
#endif
