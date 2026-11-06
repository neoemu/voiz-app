import Foundation

/// Hints belong to one request; they must never leak into the next meeting or dictation.
nonisolated struct TranscriptionContext: Sendable, Equatable {
    var vocabulary: [String] = []
    var isDictation = false
    var isTranslation = false
    var requiresVocabulary: Bool { isDictation && !vocabulary.isEmpty }
    var usesAppleDictationVocabulary: Bool { requiresVocabulary }
    /// Apple's documented upper limit across all contextual string tags.
    var appleVocabulary: [String] { Array(vocabulary.prefix(100)) }

    /// Some CoreML exports have a 224-token cache, although Whisper's nominal limit is 448.
    /// Exceeding the actual cache crashes CoreML rather than throwing a recoverable Swift error.
    static func whisperBudget(cacheTokens: Int?) -> (sampleLength: Int, promptTokens: Int) {
        let length = max(1, min(448, cacheTokens ?? 224))
        return (length, min(160, max(0, length - 176)))
    }

    static func terms(from text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap {
            let term = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    /// Keep complete terms, in user order, within Whisper's limited conditioning context.
    /// Report omissions instead of silently truncating a word or pretending every hint fitted.
    func whisperPrompt(tokenize: (String) -> [Int], budget: Int = 160) -> (tokens: [Int], used: Int) {
        var accepted: [String] = []
        var tokens: [Int] = []
        for term in vocabulary {
            let candidate = tokenize((accepted + [term]).joined(separator: ", ") + ".")
            guard candidate.count <= budget else { continue }
            accepted.append(term)
            tokens = candidate
        }
        return (tokens, accepted.count)
    }
}

/// Bounded requests for the system dictation module. Quiet boundaries reduce split words;
/// silence is never removed, and every sample belongs to exactly one range.
nonisolated enum AppleDictationChunks {
    static func ranges(samples: [Float], sampleRate: Double) -> [Range<Int>] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let maximum = max(1, Int(sampleRate * 12))
        let lookBack = max(1, Int(sampleRate * 2))
        let quietWindow = max(1, Int(sampleRate * 0.12))
        let step = max(1, Int(sampleRate * 0.02))
        var start = 0
        var ranges: [Range<Int>] = []
        while start < samples.count {
            var end = min(start + maximum, samples.count)
            if end < samples.count {
                for candidate in stride(from: end, through: max(start + quietWindow, end - lookBack), by: -step) {
                    let range = (candidate - quietWindow)..<candidate
                    if samples[range].allSatisfy({ abs($0) < 0.004 }) {
                        end = candidate - quietWindow / 2
                        break
                    }
                }
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}

nonisolated enum DictationTextPolicy {
    /// Explicit, opt-in, single-word correction. Commas on BOTH sides of the marker are
    /// required: ordinary "estou corrigindo o bug" and "orange or yellow" stay untouched.
    /// The raw transcript is retained by the caller so every edit is inspectable/reversible.
    static func applyingCorrections(to raw: String, enabled: Bool, markers: String) -> String {
        guard enabled else { return raw }
        let terms = TranscriptionContext.terms(from: markers)
        let alternatives = terms.filter { term in
            term.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0) || CharacterSet.whitespaces.contains($0)
            }
        }.map(NSRegularExpression.escapedPattern(for:))
        guard !alternatives.isEmpty else { return raw }
        let pattern = #"(?<![\p{L}\p{M}\p{N}_'’])(?:[\p{L}\p{M}\p{N}_'’]+)[ \t]*,[ \t]*(?:"#
            + alternatives.joined(separator: "|") + #")[ \t]*,[ \t]*(?=[\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return raw }
        return regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
    }
}
