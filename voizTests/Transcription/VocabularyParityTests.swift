import Foundation
import Testing

private actor VocabularyEngine: BatchTranscriptionEngine {
    nonisolated let descriptor: TranscriptionEngineDescriptor
    var requests: [TranscriptionRequest] = []
    var preparations = 0
    let ignoreVocabulary: Bool
    let failVocabulary: Bool

    init(_ descriptor: TranscriptionEngineDescriptor, ignoreVocabulary: Bool = false, failVocabulary: Bool = false) {
        self.descriptor = descriptor
        self.ignoreVocabulary = ignoreVocabulary
        self.failVocabulary = failVocabulary
    }
    func prepare(model: TranscriptionModelID) async throws { preparations += 1 }
    func unload() async {}
    func transcribe(_ request: TranscriptionRequest, candidate: TranscriptionRoutingCandidate) async throws -> TranscriptionEngineResult {
        requests.append(request)
        if request.context.requiresVocabulary && failVocabulary { throw TranscriptionEngineFailure.engineInternal("vocabulary fixture") }
        var provenance = TranscriptionProvenance(candidate: candidate, useCase: request.useCase)
        provenance.recognizer = "Apple SpeechTranscriber + DictationTranscriber"
        return TranscriptionEngineResult(text: "Nunca remover auth.", provenance: provenance,
                                         vocabularyTermsUsed: ignoreVocabulary ? nil : request.context.vocabulary.count)
    }
}

@Suite("Vocabulário — paridade de recursos e Apple")
struct VocabularyParityTests {
    private func request(vocabulary: [String] = ["auth", "Voiz"]) -> TranscriptionRequest {
        TranscriptionRequest(useCase: .dictation, language: .portuguese,
                             audio: TranscriptionAudio(samples: [0.1, 0.2]),
                             context: TranscriptionContext(vocabulary: vocabulary))
    }

    @Test("Apple e Whisper aceitam a mesma lista; Parakeet não pode ignorá-la")
    func routingHonorsTheFeature() {
        let router = TranscriptionRouter()
        for selected: TranscriptionEngineID in [.appleSpeechAnalyzer, .whisperKit, .parakeet] {
            let plan = router.plan(for: TranscriptionRoutingContext(useCase: .dictation, language: .portuguese,
                hardware: .appleSilicon16GB, selection: .manual(engine: selected), requiresVocabulary: true))
            #expect(plan.candidates.allSatisfy { $0.engine != .parakeet })
            #expect(plan.primary?.engine == (selected == .whisperKit ? .whisperKit : .appleSpeechAnalyzer))
        }
        let strict = router.plan(for: TranscriptionRoutingContext(useCase: .dictation, language: .portuguese,
            hardware: .appleSilicon16GB, selection: .manual(engine: .parakeet, strict: true), requiresVocabulary: true))
        #expect(strict.isEmpty)
        #expect(strict.rejections.contains { $0.engine == .parakeet && $0.reason == .vocabularyUnsupported })
        let ordinary = router.plan(for: TranscriptionRoutingContext(useCase: .dictation, language: .portuguese,
            hardware: .appleSilicon16GB, selection: .manual(engine: .parakeet)))
        #expect(ordinary.primary?.engine == .parakeet)
    }

    @Test("Um plano antigo também não permite fallback que descarte vocabulário")
    func storedPlanCannotBypassVocabulary() async throws {
        let apple = VocabularyEngine(.appleSpeechAnalyzer)
        let whisper = VocabularyEngine(.whisperKit)
        let parakeet = VocabularyEngine(.parakeet)
        let coordinator = TranscriptionCoordinator(engines: [.appleSpeechAnalyzer: apple, .whisperKit: whisper, .parakeet: parakeet], hardware: .appleSilicon16GB)
        let old = await coordinator.plan(for: .dictation, language: .portuguese, selection: .manual(engine: .parakeet))
        let result = try await coordinator.transcribe(request(), using: old)
        #expect(result.provenance.engine != .parakeet)
        #expect(await parakeet.preparations == 0)
        #expect(await parakeet.requests.isEmpty)
        #expect(result.result.vocabularyTermsUsed == 2)
    }

    @Test("O coordenador exige confirmação de vocabulário e preserva a identidade do módulo")
    func ignoringHintsIsNotSuccess() async throws {
        let apple = VocabularyEngine(.appleSpeechAnalyzer, ignoreVocabulary: true)
        let whisper = VocabularyEngine(.whisperKit)
        let coordinator = TranscriptionCoordinator(engines: [.appleSpeechAnalyzer: apple, .whisperKit: whisper], hardware: .appleSilicon16GB)
        let outcome = try await coordinator.transcribe(request(), selection: .manual(engine: .appleSpeechAnalyzer))
        #expect(outcome.provenance.engine == .whisperKit)
        #expect(outcome.result.vocabularyTermsUsed == 2)
        #expect(await whisper.requests.first?.context.vocabulary == ["auth", "Voiz"])
        #expect(outcome.provenance.recognizer == "Apple SpeechTranscriber + DictationTranscriber")
    }

    @Test("Falha do módulo de vocabulário não bloqueia o Apple sem vocabulário")
    func vocabularyFailureIsIsolated() async throws {
        let apple = VocabularyEngine(.appleSpeechAnalyzer, failVocabulary: true)
        let whisper = VocabularyEngine(.whisperKit)
        let coordinator = TranscriptionCoordinator(engines: [.appleSpeechAnalyzer: apple, .whisperKit: whisper], hardware: .appleSilicon16GB)
        _ = try await coordinator.transcribe(request(), selection: .manual(engine: .appleSpeechAnalyzer))
        let normal = try await coordinator.transcribe(request(vocabulary: []), selection: .manual(engine: .appleSpeechAnalyzer))
        #expect(normal.provenance.engine == .appleSpeechAnalyzer)
        #expect(await apple.requests.count == 2)
    }

    @Test("O contexto atravessa motor, runtime e chamadas Apple sem vazar para o próximo pedido")
    func appleContextIsForwarded() async throws {
        let calls = FakeAppleSpeechCalls(output: AppleSpeechRuntimeOutput(vocabularyTermsUsed: 2,
            recognizer: "Apple SpeechTranscriber + DictationTranscriber"))
        let runtime = AppleSpeechAssetRuntime(calls: calls)
        let engine = AppleSpeechAnalyzerEngine(runtime: runtime)
        let candidate = TranscriptionRoutingCandidate(engine: .appleSpeechAnalyzer, model: .appleSystemSpeechPTBR, rank: 0, origin: .userSelection)
        try await engine.prepare(model: candidate.model)
        let output = try await engine.transcribe(request(), candidate: candidate)
        _ = try await engine.transcribe(request(vocabulary: []), candidate: candidate)
        #expect(await calls.contexts.map(\.vocabulary) == [["auth", "Voiz"], []])
        #expect(output.vocabularyTermsUsed == 2)
        #expect(output.provenance.recognizer == "Apple SpeechTranscriber + DictationTranscriber")
    }

    @Test("Lotes Apple preservam todas as amostras e respeitam o limite")
    func appleChunkCoverage() {
        let samples = Array(repeating: Float(0.1), count: 600 * 16000)
        let ranges = AppleDictationChunks.ranges(samples: samples, sampleRate: 16000)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        #expect(ranges.reduce(0) { $0 + $1.count } == samples.count)
        #expect(ranges.allSatisfy { $0.count <= 12 * 16000 && !$0.isEmpty })
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(TranscriptionContext(vocabulary: (0..<120).map(String.init)).appleVocabulary.count == 100)
    }
}

@Suite("Apple — adaptação conserva o transcript principal")
struct AppleVocabularyFusionTests {
    private func segment(_ text: String, start: Double = 0, confidence: Float = 0.95) -> AppleSpeechTranscriptSegment {
        var segment = AppleSpeechTranscriptSegment(text: text, start: start, end: start + 5)
        segment.words = AppleVocabularyFusion.lexicalRanges(in: text).enumerated().map { index, range in
            AppleSpeechTimedWord(text: (text as NSString).substring(with: range), range: range,
                                 start: start + Double(index) * 0.5, end: start + Double(index) * 0.5 + 0.4, confidence: confidence)
        }
        return segment
    }

    @Test("Só o termo configurado e alinhado muda; o resto da frase é preservado")
    func alignedTermOnly() {
        let base = AppleSpeechRuntimeOutput(segments: [segment("Configure off sem remover validação.")])
        let adapted = AppleSpeechRuntimeOutput(segments: [segment("auth", start: 0.5)], vocabularyTermsUsed: 1)
        let result = AppleVocabularyFusion.combine(base: base, adapted: adapted, vocabulary: ["auth"])
        #expect(result.segments[0].text == "Configure auth sem remover validação.")
        #expect(result.unadaptedText == "Configure off sem remover validação.")
    }

    @Test("Secundário vazio, incompleto, incerto ou desalinhado nunca apaga texto")
    func incompleteSecondaryPreservesPrimary() {
        let text = "Nunca apagar frases. 5. A. 6. Concordo. Eu, tipo, não quero perder isso."
        let base = AppleSpeechRuntimeOutput(segments: [segment(text)])
        for adapted in [AppleSpeechRuntimeOutput(), AppleSpeechRuntimeOutput(segments: [segment("auth", start: 40)]),
                        AppleSpeechRuntimeOutput(segments: [segment("auth", confidence: 0.2)]),
                        AppleSpeechRuntimeOutput(segments: [AppleSpeechTranscriptSegment(text: "auth")])] {
            #expect(AppleVocabularyFusion.combine(base: base, adapted: adapted, vocabulary: ["auth"]).segments[0].text == text)
        }
    }

    @Test("Vocabulário não consome negações, números, muletas nem turn off")
    func criticalWordsAreProtected() {
        for text in ["não", "never", "haven't", "like", "tipo", "5", "Turn off"] {
            let base = AppleSpeechRuntimeOutput(segments: [segment(text)])
            let adapted = AppleSpeechRuntimeOutput(segments: [segment("auth", start: text == "Turn off" ? 0.5 : 0)])
            #expect(AppleVocabularyFusion.combine(base: base, adapted: adapted, vocabulary: ["auth"]).segments[0].text == text)
        }
    }

    @Test("Imprecisão de tempo não consome this ao aplicar PROJECT")
    func neighbouringWordsArePreserved() {
        let base = AppleSpeechRuntimeOutput(segments: [segment("Use this project")])
        let adapted = AppleSpeechRuntimeOutput(segments: [segment("PROJECT", start: 0.75)])
        #expect(AppleVocabularyFusion.combine(base: base, adapted: adapted, vocabulary: ["PROJECT"]).segments[0].text == "Use this PROJECT")
        let ambiguous = AppleSpeechRuntimeOutput(segments: [segment("auth", start: 0.75)])
        #expect(AppleVocabularyFusion.combine(base: base, adapted: ambiguous, vocabulary: ["auth"]).segments[0].text == "Use this project")
    }
}
