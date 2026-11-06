import Foundation
import AVFoundation
import Speech

/// Apple's contextual vocabulary is documented for DictationTranscriber. A fresh module
/// and context per request prevent names from one dictation leaking into another session.
nonisolated enum AppleDictationVocabularyCalls {
    static func transcribe(samples: [Float], sampleRate: Double, locale: AppleSpeechLocale,
                           vocabulary: [String]) async throws -> AppleSpeechRuntimeOutput {
        let started = Date()
        var segments: [AppleSpeechTranscriptSegment] = []
        for range in AppleDictationChunks.ranges(samples: samples, sampleRate: sampleRate) {
            try Task.checkCancellation()
            let output = try await transcribeChunk(samples: Array(samples[range]), sampleRate: sampleRate,
                                                   locale: locale, vocabulary: vocabulary)
            let offset = Double(range.lowerBound) / sampleRate
            segments.append(contentsOf: output.segments.map { segment in
                var shifted = segment
                shifted.start += offset
                shifted.end += offset
                shifted.words = shifted.words.map { word in
                    var adjusted = word
                    adjusted.start += offset
                    adjusted.end += offset
                    return adjusted
                }
                return shifted
            })
        }
        return AppleSpeechRuntimeOutput(segments: segments, processingTime: Date().timeIntervalSince(started),
                                        vocabularyTermsUsed: vocabulary.count, recognizer: "Apple DictationTranscriber")
    }

    private static func transcribeChunk(samples: [Float], sampleRate: Double, locale: AppleSpeechLocale,
                                       vocabulary: [String]) async throws -> AppleSpeechRuntimeOutput {
        try Task.checkCancellation()
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale.identifier)) else {
            throw AppleSpeechRuntimeError.localeUnsupported(locale.identifier)
        }
        _ = try await AssetInventory.reserve(locale: supported)
        let module = DictationTranscriber(
            locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        if await AssetInventory.status(forModules: [module]) != .installed {
            guard let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                throw AppleSpeechRuntimeError.assetUnavailable("Asset do ditado Apple indisponível")
            }
            try await installation.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw AppleSpeechRuntimeError.assetUnavailable("Asset do ditado Apple não instalado")
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppleSpeechCallFailure.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        let started = Date()
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task {
            var segments: [AppleSpeechTranscriptSegment] = []
            for try await result in module.results {
                segments.append(AppleSpeechAnalyzerCalls.segment(text: result.text, range: result.range))
            }
            return segments
        }
        defer { collector.cancel() }
        do {
            // Hints are attached before preparation and before a single audio sample is sent.
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputs)
            let buffer = try AppleSpeechAnalyzerCalls.buffer(samples: samples, sampleRate: sampleRate, target: format)
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let segments = try await AppleSpeechBatchCollection.collect(
                collector, timeout: AppleSpeechBatchCollection.deadline(forAudioSeconds: Double(samples.count) / sampleRate)
            )
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--voiz-dictation-probe") {
                fputs("[apple-vocabulary-chunk] input=\(samples.count) words=\(segments.flatMap(\.words).count) chars=\(segments.map(\.text).joined().count)\n", stderr)
            }
            #endif
            try Task.checkCancellation()
            return AppleSpeechRuntimeOutput(segments: segments, processingTime: Date().timeIntervalSince(started),
                                            vocabularyTermsUsed: vocabulary.count, recognizer: "Apple DictationTranscriber")
        } catch {
            continuation.finish()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
