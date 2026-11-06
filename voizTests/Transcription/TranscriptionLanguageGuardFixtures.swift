import Foundation

/// Áudio e snapshots sintéticos compartilhados pela suíte comportamental da guarda de idioma.
nonisolated enum LanguageProbeFixtures {
    static let sampleRate: Double = TranscriptionAudio.defaultSampleRate

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    static func speech(seconds: Double, amplitude: Float = 0.2) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            amplitude * Float(sin(Double(index) * 0.05))
        }
    }

    static func snapshot(
        language: TranscriptionLanguage? = .portuguese,
        languageOrigin: TranscriptionPlanSnapshot.LanguageOrigin? = nil,
        candidates: [(TranscriptionEngineID, TranscriptionModelID)] = [
            (.appleSpeechAnalyzer, .appleSystemSpeechPTBR),
            (.whisperKit, .whisperSmall),
            (.parakeet, .parakeetTDT06BV3)
        ],
        isStrict: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> TranscriptionPlanSnapshot {
        TranscriptionPlanSnapshot(
            language: language,
            languageOrigin: languageOrigin ?? (language == nil ? .autoAdopted : .explicit),
            candidates: candidates.enumerated().map { index, pair in
                TranscriptionPlanSnapshot.Candidate(
                    engine: pair.0,
                    model: pair.1,
                    rank: index,
                    origin: .automatic
                )
            },
            isStrict: isStrict,
            createdAt: createdAt
        )
    }

    static func autoAdopted(language: TranscriptionLanguage) -> TranscriptionPlanSnapshot {
        snapshot(
            language: language,
            languageOrigin: .autoAdopted,
            candidates: [
                (.whisperKit, .whisperSmall),
                (.parakeet, .parakeetTDT06BV3)
            ]
        )
    }
}
