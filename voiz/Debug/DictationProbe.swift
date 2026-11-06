#if DEBUG
import Foundation

/// Opt-in end-to-end smoke test using synthetic CAFs in the app container. Never records a
/// microphone, opens history, or changes settings. Reports metrics without transcript content.
@MainActor
enum DictationProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--voiz-dictation-probe") }

    private struct Item: Decodable {
        var id: UUID
        var language: String
        var vocabulary: [String]
        var expectedWords: [String]
        var expectedExactTerms: [String]?
    }

    static func run() async {
        do {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--voiz-dictation-probe"), index + 1 < args.count else {
                exit(2)
            }
            let root = URL(fileURLWithPath: args[index + 1])
            let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent("items.json")))
            let input = DictationAudioStore(directory: root.appendingPathComponent("inputs"))
            let recovered = DictationAudioStore(directory: root.appendingPathComponent("recovered"))
            let coordinator = AppTranscriptionCoordinator.shared.coordinator
            var report: [[String: Any]] = []
            for item in items {
                let samples = try input.load(item.id)
                let capture = RecordingSampleBuffer(retention: .entireRecording)
                let generation = capture.begin()
                for start in stride(from: 0, to: samples.count, by: 4096) {
                    capture.append(Array(samples[start..<min(start + 4096, samples.count)]), generation: generation)
                }
                let captured = capture.finish()
                guard captured == samples else { throw CocoaError(.fileReadCorruptFile) }
                try recovered.remove(item.id)
                try recovered.save(captured, id: item.id)
                let replay = try recovered.load(item.id)
                guard replay == samples else { throw CocoaError(.fileReadCorruptFile) }
                for engine: TranscriptionEngineID in [.whisperKit, .appleSpeechAnalyzer] {
                    let locale: AppleSpeechLocale = item.language == "pt" ? .portugueseBrazil : .englishUS
                    let choice = TranscriptionEngineChoice(engine: engine, model: engine == .whisperKit ? .whisperSmall : locale.model)
                    let result = try await coordinator.transcribe(
                        TranscriptionRequest(useCase: .dictation, language: TranscriptionLanguage(item.language),
                                             audio: TranscriptionAudio(samples: replay),
                                             context: TranscriptionContext(vocabulary: item.vocabulary, isDictation: true)),
                        selection: TranscriptionUserSelection(preferred: choice, strictEngineSelection: true)
                    )
                    let words = Set(result.text.lowercased().components(separatedBy: .alphanumerics.inverted))
                    let found = item.expectedWords.filter { words.contains($0.lowercased()) }
                    report.append([
                        "id": item.id.uuidString, "engine": engine.rawValue,
                        "audioSeconds": Double(samples.count) / 16_000, "characters": result.text.count,
                        "expectedWords": item.expectedWords.count, "foundWords": found.count,
                        "hintCount": result.result.vocabularyTermsUsed ?? 0,
                        "exactTermsFound": (item.expectedExactTerms ?? []).filter { result.text.contains($0) }.count,
                        "vocabularyChangedText": result.result.unadaptedText != nil,
                        "wordCount": AppleVocabularyFusion.lexicalRanges(in: result.text).count,
                        "baseWordCount": AppleVocabularyFusion.lexicalRanges(in: result.result.unadaptedText ?? result.text).count,
                        "recognizer": result.provenance.recognizer ?? engine.rawValue,
                        "processingSeconds": result.result.processingTime,
                        "archiveExact": true
                    ])
                    fputs("[dictation-probe] \(engine.rawValue): \(samples.count) samples, \(result.text.count) characters, \(found.count)/\(item.expectedWords.count) keywords\n", stderr)
                }
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("report.json"), options: .atomic)
            exit(report.allSatisfy { ($0["characters"] as? Int ?? 0) > 0 } ? 0 : 1)
        } catch {
            fputs("[dictation-probe] failed: \(type(of: error))\n", stderr)
            exit(1)
        }
    }
}
#endif
