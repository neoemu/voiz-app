#if DEBUG
import Foundation

/// Explicit synthetic-file validation of the same VAD/framing path as live translation.
/// No microphone, provider credentials, history, transcript logging or preferences writes.
@MainActor
enum TranslationSpeechProbe {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("--voiz-translation-speech-probe") }
    private struct Item: Decodable {
        let name: String
        let file: String
        let language: String
        let expectedWords: [String]
        let expectSilence: Bool
    }

    static func run() async {
        do {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--voiz-translation-speech-probe"), index + 1 < args.count else { exit(2) }
            let root = URL(fileURLWithPath: args[index + 1])
            let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent("items.json")))
            var report: [[String: Any]] = []
            let coordinator = AppTranscriptionCoordinator.shared.coordinator
            for item in items {
                // File names are local components, never arbitrary paths from a manifest.
                guard !item.file.contains("/"), item.file != ".." else { throw CocoaError(.fileReadInvalidFileName) }
                let audio = try BenchmarkAudioLoader.load(url: root.appendingPathComponent(item.file))
                let pipeline = try await TranslationSpeechPipeline.make()
                var phrases: [[Float]] = []
                // Irregular capture packets exercise residual frames and the end fence.
                let packetSizes = [137, 1365, 4096, 789]
                var offset = 0, packet = 0
                while offset < audio.samples.count {
                    let end = min(audio.samples.count, offset + packetSizes[packet % packetSizes.count])
                    phrases += try await pipeline.append(Array(audio.samples[offset..<end]))
                    offset = end
                    packet += 1
                }
                phrases += try await pipeline.finish()
                var texts: [String] = []
                for phrase in phrases {
                    let outcome = try await coordinator.transcribe(
                        TranscriptionRequest(useCase: .translationChunk, language: TranscriptionLanguage(item.language),
                            audio: TranscriptionAudio(samples: phrase)),
                        selection: TranscriptionUserSelection(preferred: .init(engine: .whisperKit, model: .whisperSmall),
                            strictEngineSelection: true), retryPolicy: .silentInteractive)
                    texts.append(outcome.text)
                }
                let text = texts.joined(separator: " ")
                let words = Set(text.lowercased().components(separatedBy: .alphanumerics.inverted))
                let found = item.expectedWords.filter { words.contains($0.lowercased()) }.count
                let passed = item.expectSilence ? phrases.isEmpty && text.isEmpty : found == item.expectedWords.count && !text.isEmpty
                report.append(["name": item.name, "audioSeconds": audio.duration, "phraseCount": phrases.count,
                    "phraseSeconds": phrases.map { Double($0.count) / 16_000 }, "characters": text.count,
                    "expectedWords": item.expectedWords.count, "foundWords": found, "passed": passed])
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("report.json"), options: .atomic)
            }
            exit(report.allSatisfy { $0["passed"] as? Bool == true } ? 0 : 1)
        } catch {
            fputs("[translation-speech-probe] failed; no content logged\n", stderr)
            exit(1)
        }
    }
}
#endif
