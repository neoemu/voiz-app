import Foundation
import Testing

@Suite("Ditado — áudio completo, contexto e fidelidade")
struct DictationFidelityTests {
    @Test("Dez minutos chegam inteiros, inclusive respostas do começo e do fim")
    func tenMinuteCapture() {
        let buffer = RecordingSampleBuffer(retention: .entireRecording)
        let id = buffer.begin()
        for second in 0..<600 {
            buffer.append(Array(repeating: Float(second), count: 16_000), generation: id)
        }
        let captured = buffer.finish()
        #expect(captured.count == 600 * 16_000)
        for second in [0, 5, 29, 30, 300, 599] {
            #expect(captured[second * 16_000] == Float(second))
        }
        #expect(buffer.snapshot().isEmpty)
    }

    @Test("Stop e callbacks atrasados não contaminam a gravação seguinte")
    func lateAudioIsRejected() {
        let buffer = RecordingSampleBuffer(retention: .entireRecording)
        let first = buffer.begin()
        buffer.append([1, 2], generation: first)
        #expect(buffer.finish() == [1, 2])
        #expect(!buffer.append([3], generation: first))
        let second = buffer.begin()
        #expect(!buffer.append([4], generation: first))
        buffer.append([5], generation: second)
        #expect(buffer.finish() == [5])
    }

    @Test("A janela da tradução continua limitada quando pedida explicitamente")
    func rollingCaptureRemainsAvailable() {
        let buffer = RecordingSampleBuffer(retention: .latestSamples(3))
        let id = buffer.begin()
        buffer.append([1, 2], generation: id)
        buffer.append([3, 4, 5], generation: id)
        #expect(buffer.finish() == [3, 4, 5])
    }

    @Test("Sem correções, listas, negações, muletas, código e palavrões passam intactos",
          arguments: [
            "5. A\n6. Concordo.\n7. Não faça o merge.\n8. A",
            "I'd prefer to never merge this. I haven't approved it. Do not deploy.",
            "Eu, tipo, não quero isso. Nunca publique sem autorização.",
            "I, like, use auth, not off. This is pissing me off.",
            "Use array[5] e foo(bar). (Não remover esta condição.)",
            "orange, err, yellow", "laranja, corrigindo, amarelo"
          ])
    func literalByDefault(_ text: String) {
        #expect(DictationTextPolicy.applyingCorrections(to: text, enabled: false, markers: "err\ncorrigindo") == text)
    }

    @Test("Correção explícita funciona em português e inglês sem atravessar linhas")
    func explicitCorrections() {
        let markers = "err\ncorrigindo\nquer dizer\nI mean"
        let fixtures = [
            ("Quero laranja, corrigindo, amarelo.", "Quero amarelo."),
            ("I want orange, err, yellow.", "I want yellow."),
            ("Quero banana, quer dizer, maçã.", "Quero maçã."),
            ("orange, I mean, yellow", "yellow"),
            ("orange, err, yellow, err, blue", "blue"),
            ("Estou corrigindo o bug.", "Estou corrigindo o bug."),
            ("Orange or yellow.", "Orange or yellow."),
            ("Quero laranja, corrigindo,\n5. amarelo", "Quero laranja, corrigindo,\n5. amarelo"),
            ("I want orange, err,", "I want orange, err,"),
            ("Não, eu não quero amarelo.", "Não, eu não quero amarelo.")
        ]
        for (raw, expected) in fixtures {
            #expect(DictationTextPolicy.applyingCorrections(to: raw, enabled: true, markers: markers) == expected)
        }
    }

    @Test("Contexto não corta termos ao meio e informa quantos couberam")
    func promptBudget() {
        #expect(TranscriptionRequest.test().context.isDictation)
        #expect(!TranscriptionRequest.test(useCase: .meetingFinal).context.isDictation)
        let small = TranscriptionContext.whisperBudget(cacheTokens: 224)
        #expect(small.sampleLength == 224)
        #expect(small.promptTokens == 48)
        let large = TranscriptionContext.whisperBudget(cacheTokens: 448)
        #expect(large.sampleLength == 448)
        #expect(large.promptTokens == 160)
        #expect(TranscriptionContext.whisperBudget(cacheTokens: nil).sampleLength == 224)
        let context = TranscriptionContext(vocabulary: ["auth", "too long to fit", "API"])
        let prompt = context.whisperPrompt(tokenize: { Array($0.utf8).map(Int.init) }, budget: 10)
        #expect(String(bytes: prompt.tokens.map(UInt8.init), encoding: .utf8) == "auth, API.")
        #expect(prompt.used == 2)
        #expect(TranscriptionContext.terms(from: " auth\n\nAPI\nauth \nSão Paulo") == ["auth", "API", "São Paulo"])
    }

    @Test("Vocabulário chega ao runtime antes da inferência e não vaza para reuniões")
    func hintsReachWhisper() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = WhisperKitTranscriptionEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let context = TranscriptionContext(vocabulary: ["auth", "João", "Kubernetes"], isDictation: true)
        let request = TranscriptionRequest(useCase: .dictation, language: .portuguese,
                                           audio: TranscriptionAudio(samples: [0.1, 0.2]), context: context)
        let result = try await engine.transcribe(request, candidate: .test())
        #expect(result.text == "[MÚSICA] olá  mundo")
        _ = try await engine.transcribe(.test(useCase: .meetingFinal), candidate: .test())
        let session = try #require(runtime.sessions.first)
        #expect(session.contexts == [context, TranscriptionContext()])
    }

    @Test("Limpeza das reuniões mantém colchetes, condições e listas legítimas")
    func conservativeSoundTags() {
        let text = "5. foo(bar)\n6. array[5]\n7. (não publicar)\n8. [auth]"
        #expect(WhisperKitEngineSupport.sanitize(text) == text)
        #expect(WhisperKitEngineSupport.sanitize("[MÚSICA] Não publicar (nunca).") == "Não publicar (nunca).")
    }
}

@Suite("Ditado — recuperação e histórico")
@MainActor
struct DictationRecoveryTests {
    @Test("CAF preserva todas as amostras e pode ser removido pelo histórico")
    func recordingRoundTripAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioStore = DictationAudioStore(directory: directory)
        let id = UUID()
        let samples = (0..<1_000_123).map { Float($0 % 2000) / 2000 - 0.5 }
        try audioStore.save(samples, id: id)
        #expect(try audioStore.load(id) == samples)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = TranscriptionHistoryStore(defaults: defaults, audioStore: audioStore)
        let entry = TranscriptionEntry(id: id, text: "", language: .portuguese, audioID: id,
                                       processingMessage: "Falha no reconhecimento")
        history.addEntry(entry)
        let restored = TranscriptionHistoryStore(defaults: defaults, audioStore: audioStore)
        #expect(restored.entries.first == entry)
        restored.deleteEntry(entry)
        #expect(!audioStore.exists(id))
        #expect(restored.entries.isEmpty)
    }

    @Test("Retry vazio preserva resultado anterior; retry bem-sucedido conserva comparação e original")
    func retryPreservesContent() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = TranscriptionHistoryStore(defaults: defaults)
        let entry = TranscriptionEntry(text: "Nunca publicar.", language: .portuguese)
        let provenance = TranscriptionProvenance(candidate: .test(), useCase: .dictation)
        history.addEntry(entry)
        history.complete(entry.id, raw: "", text: "", provenance: provenance, message: "Não reconhecido")
        #expect(history.entries[0].text == "Nunca publicar.")
        history.complete(entry.id, raw: "Quero laranja, corrigindo, amarelo.", text: "Quero amarelo.", provenance: provenance, message: nil)
        #expect(history.entries[0].previousText == "Nunca publicar.")
        #expect(history.entries[0].rawText == "Quero laranja, corrigindo, amarelo.")
        #expect(history.entries[0].text == "Quero amarelo.")
    }

    @Test("Áudio ilegível ou diretório sem permissão produz erro, nunca sucesso falso")
    func storageFailures() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictationAudioStore(directory: url)
        #expect(throws: (any Error).self) { try store.save([0.1], id: UUID()) }
        #expect(throws: (any Error).self) { try store.load(UUID()) }
    }
}
