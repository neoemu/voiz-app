import Foundation

/// Preserve SpeechTranscriber's transcript. Only a configured term recognized confidently
/// at the same audio interval by DictationTranscriber can replace an aligned word/phrase.
/// Missing, low-confidence, ambiguous or untimed secondary output never deletes primary text.
nonisolated enum AppleVocabularyFusion {
    private static let lexical = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+(?:['’\-][\p{L}\p{M}\p{N}_]+)*"#)
    private static let protectedWords: Set<String> = [
        "nao", "nunca", "jamais", "sem", "nenhum", "nenhuma", "ninguem", "tampouco", "tipo",
        "no", "not", "never", "without", "neither", "nor", "cannot", "can't", "don't", "won't",
        "isn't", "aren't", "wasn't", "weren't", "didn't", "doesn't", "haven't", "hasn't", "hadn't",
        "shouldn't", "wouldn't", "couldn't", "like", "non", "pas", "ne", "jamais", "sans",
        "nicht", "kein", "keine", "ohne", "nunca", "sin", "ningun", "ninguna"
    ]

    static func lexicalRanges(in text: String) -> [NSRange] {
        lexical.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func tokens(_ text: String) -> [String] {
        lexicalRanges(in: text).map { normalized((text as NSString).substring(with: $0)) }
    }

    static func combine(base: AppleSpeechRuntimeOutput, adapted: AppleSpeechRuntimeOutput,
                        vocabulary: [String]) -> AppleSpeechRuntimeOutput {
        var result = base
        let secondary = adapted.segments.flatMap(\.words)
        var termMatches = 0
        var confidentMatches = 0
        var alignedMatches = 0
        var editsApplied = 0
        for index in result.segments.indices {
            let primary = result.segments[index]
            // Search only this segment's audio interval, so long dictations do not compare
            // every word of every sentence with every word of the whole secondary transcript.
            let localSecondary = secondary.filter { $0.end >= primary.start - 0.4 && $0.start <= primary.end + 0.4 }
            var edits: [(range: NSRange, term: String)] = []
            for term in vocabulary {
                let wanted = tokens(term)
                guard !wanted.isEmpty, localSecondary.count >= wanted.count else { continue }
                for startIndex in 0...(localSecondary.count - wanted.count) {
                    let matched = Array(localSecondary[startIndex..<(startIndex + wanted.count)])
                    guard matched.map({ normalized($0.text) }) == wanted else { continue }
                    termMatches += 1
                    guard matched.allSatisfy({ ($0.confidence ?? 0) >= 0.8 && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }),
                          let first = matched.first, let last = matched.last,
                          last.end - first.start <= 3 else { continue }
                    confidentMatches += 1
                    var aligned = primary.words.filter {
                        let center = ($0.start + $0.end) / 2
                        return center >= first.start - 0.12 && center <= last.end + 0.12
                    }
                    // A timestamp may include the edge of a neighbouring word. Prefer an
                    // exact spelling match inside that interval instead of consuming it too.
                    var exactSpans: [[AppleSpeechTimedWord]] = []
                    for lower in aligned.indices {
                        for upper in (lower + 1)...min(aligned.count, lower + wanted.count + 1) {
                            let span = Array(aligned[lower..<upper])
                            if span.map({ normalized($0.text) }).joined() == wanted.joined() { exactSpans.append(span) }
                        }
                    }
                    if exactSpans.count > 1 { continue }
                    if let exact = exactSpans.first { aligned = exact }
                    guard let left = aligned.first, let right = aligned.last,
                          aligned.count <= wanted.count + 1,
                          (aligned.count == wanted.count || aligned.map({ normalized($0.text) }).joined() == wanted.joined()),
                          abs(left.start - first.start) <= 0.25, abs(right.end - last.end) <= 0.25,
                          aligned.allSatisfy({ !protectedWords.contains(normalized($0.text)) && $0.text.rangeOfCharacter(from: .decimalDigits) == nil })
                    else { continue }
                    alignedMatches += 1
                    if ["off", "on"].contains(normalized(left.text)),
                       let position = primary.words.firstIndex(where: { $0.range == left.range }),
                       primary.words[max(0, position - 3)..<position].contains(where: { ["turn", "switch", "toggle", "set"].contains(normalized($0.text)) }) {
                        continue
                    }
                    let range = NSRange(location: left.range.location, length: NSMaxRange(right.range) - left.range.location)
                    guard range.location >= 0, range.length > 0, NSMaxRange(range) <= (primary.text as NSString).length,
                          tokens((primary.text as NSString).substring(with: range)).count == aligned.count,
                          !edits.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                    // Do not merge across punctuation or consume adjacent code syntax.
                    let original = (primary.text as NSString).substring(with: range)
                    let separators = lexical.stringByReplacingMatches(in: original, range: NSRange(original.startIndex..., in: original), withTemplate: "")
                    guard separators.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
                    edits.append((range, term))
                    editsApplied += 1
                }
            }
            if !edits.isEmpty {
                let text = NSMutableString(string: primary.text)
                for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                    text.replaceCharacters(in: edit.range, with: edit.term)
                }
                result.segments[index].text = text as String
                result.segments[index].words = [] // Old UTF-16 ranges no longer address the edited text.
            }
        }
        result.processingTime += adapted.processingTime
        let original = base.segments.map(\.text).joined(separator: " ")
        if result.segments.map(\.text).joined(separator: " ") != original { result.unadaptedText = original }
        result.vocabularyTermsUsed = adapted.vocabularyTermsUsed
        result.recognizer = "Apple SpeechTranscriber + DictationTranscriber"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--voiz-dictation-probe") {
            fputs("[apple-vocabulary-fusion] primaryWords=\(base.segments.flatMap(\.words).count) secondaryWords=\(secondary.count) matches=\(termMatches) confident=\(confidentMatches) aligned=\(alignedMatches) edits=\(editsApplied) maxConfidence=\(secondary.compactMap(\.confidence).max() ?? -1)\n", stderr)
        }
        #endif
        return result
    }
}
