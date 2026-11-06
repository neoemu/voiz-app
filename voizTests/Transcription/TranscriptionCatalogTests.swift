import Testing
import Foundation

/// Testes do catálogo de produção e dos protocolos de motor.
///
/// O catálogo é dado, e dado errado aqui vira roteamento errado em todo o app — daí travar
/// aqui o que a regra 6 do plano exige: enquanto os gates de benchmark não passarem, o
/// WhisperKit continua sendo a primeira escolha — **com uma exceção nomeada**, a Q2, que promoveu
/// o Apple SpeechAnalyzer a rank 0 só no `.meetingFinal` (autorizada pelo humano em 2026-08-18,
/// registrada em DECISOES). A suíte trava as duas coisas: a exceção **e** o que ela não encostou.
@Suite("Catálogo e motores")
struct TranscriptionCatalogTests {

    // MARK: - Integridade do catálogo

    @Test("Ids de motor são únicos e cada modelo aponta para o motor que o declara")
    func catalogIsInternallyConsistent() {
        let engines = TranscriptionCatalog.shipping.engines

        #expect(Set(engines.map(\.engine)).count == engines.count)
        for descriptor in engines {
            #expect(!descriptor.models.isEmpty)
            #expect(descriptor.models.allSatisfy { $0.engine == descriptor.engine })
            #expect(Set(descriptor.models.map(\.id)).count == descriptor.models.count)
            if let defaultModel = descriptor.defaultModel {
                #expect(descriptor.model(defaultModel) != nil)
            }
            #expect(descriptor.supportsBatch || descriptor.supportsStreaming)
            #expect(!descriptor.supportedUseCases.isEmpty)
        }
    }

    @Test("Motor com casos de uso de streaming declara streaming (e o mesmo para lote)")
    func declaredUseCasesMatchDeclaredModes() {
        for descriptor in TranscriptionCatalog.shipping.engines {
            for useCase in descriptor.supportedUseCases {
                #expect(descriptor.supports(useCase: useCase))
            }
        }
    }

    @Test("O catálogo de produção tem exatamente os três motores das Ondas 2–4")
    func shippingCatalogContents() {
        #expect(TranscriptionCatalog.shipping.engines.map(\.engine) == [
            .whisperKit, .appleSpeechAnalyzer, .parakeet
        ])
        // O TAGARELA entra só na Onda 5, com os artefatos CoreML dele.
        #expect(TranscriptionCatalog.shipping.descriptor(for: TranscriptionEngineID("tagarela")) == nil)
    }

    // MARK: - Comportamento travado pela regra 6 (fora da exceção Q2, nada muda até a Onda 6)

    /// Os casos de uso que a Q2 **não** podia encostar. A lista é escrita à mão, e não derivada de
    /// `allCases` menos `.meetingFinal`: um caso de uso novo tem que aparecer aqui de propósito,
    /// não herdar a garantia em silêncio.
    static let useCasesUntouchedByQ2: [TranscriptionUseCase] = [
        .dictation, .translationChunk, .meetingPreview
    ]

    @Test("O WhisperKit segue a primeira escolha automática em ditado, tradução e prévia")
    func whisperKitLeadsOutsideTheMeetingTranscript() {
        let router = TranscriptionRouter()
        let hardwares: [TranscriptionHardwareProfile] = [.appleSilicon16GB, .intel8GB, .appleSilicon4GB]
        let languages: [TranscriptionLanguage?] = [nil, .portugueseBrazil, .englishUS]

        for useCase in Self.useCasesUntouchedByQ2 {
            for hardware in hardwares {
                for language in languages {
                    let plan = router.plan(
                        for: TranscriptionRoutingContext(
                            useCase: useCase,
                            language: language,
                            hardware: hardware,
                            selection: .automatic
                        )
                    )
                    #expect(plan.primary?.engine == .whisperKit)
                    #expect(plan.primary?.model == .whisperSmall)
                }
            }
        }
    }

    // MARK: - Q2: a política do transcript oficial da reunião

    @Test("No transcript oficial da reunião com idioma explícito, o Apple é rank 0 e o Whisper o fallback")
    func appleLeadsTheMeetingTranscript() {
        let router = TranscriptionRouter()

        for language in [TranscriptionLanguage.portugueseBrazil, .englishUS] {
            let plan = router.plan(
                for: TranscriptionRoutingContext(
                    useCase: .meetingFinal,
                    language: language,
                    hardware: .appleSilicon16GB,
                    selection: .automatic
                )
            )

            // O Parakeet só entra no plano em português: desde a Onda 5 os pesos são um fine-tune
            // pt-BR que esqueceu inglês, então em `en-US` ele não é candidato — e é por isso que a
            // expectativa depende do idioma em vez de ser uma lista fixa.
            let esperados: [TranscriptionEngineID] = language == .portugueseBrazil
                ? [.appleSpeechAnalyzer, .whisperKit, .parakeet]
                : [.appleSpeechAnalyzer, .whisperKit]
            #expect(plan.candidates.map(\.engine) == esperados)
            #expect(plan.candidates.map(\.rank) == Array(0..<esperados.count))
            // O modelo do Apple é **por locale**: o rank 0 tem que ser o do idioma pedido, senão a
            // promoção entrega justamente o vazio que a guarda existe para evitar.
            #expect(plan.primary?.model == (
                language == .portugueseBrazil ? .appleSystemSpeechPTBR : .appleSystemSpeechENUS
            ))
            #expect(plan.candidates.first { $0.engine == .whisperKit }?.model == .whisperSmall)
            #expect(plan.candidates.allSatisfy { $0.origin == .automatic })
        }
    }

    @Test("A promoção do Apple vale só no .meetingFinal — a ordem dos outros casos de uso não mudou")
    func q2PolicyIsScopedToTheMeetingTranscript() {
        let router = TranscriptionRouter()

        // Ditado e tradução aceitam os três motores; a prévia exclui o Parakeet (só lote).
        let expected: [TranscriptionUseCase: [TranscriptionEngineID]] = [
            .dictation: [.whisperKit, .appleSpeechAnalyzer, .parakeet],
            .translationChunk: [.whisperKit, .appleSpeechAnalyzer, .parakeet],
            .meetingPreview: [.whisperKit, .appleSpeechAnalyzer],
            .meetingFinal: [.appleSpeechAnalyzer, .whisperKit, .parakeet]
        ]

        for useCase in TranscriptionUseCase.allCases {
            let plan = router.plan(
                for: TranscriptionRoutingContext(
                    useCase: useCase,
                    language: .portugueseBrazil,
                    hardware: .appleSilicon16GB,
                    selection: .automatic
                )
            )
            #expect(plan.candidates.map(\.engine) == expected[useCase])
        }

        // E a leitura crua do dado, que é onde a política mora: sem override, a base responde.
        #expect(TranscriptionEngineDescriptor.whisperKit.automaticPriority(for: .dictation) == 0)
        #expect(TranscriptionEngineDescriptor.whisperKit.automaticPriority(for: .meetingFinal) == 1)
        #expect(TranscriptionEngineDescriptor.appleSpeechAnalyzer.automaticPriority(for: .dictation) == 50)
        #expect(TranscriptionEngineDescriptor.appleSpeechAnalyzer.automaticPriority(for: .meetingFinal) == 0)
        #expect(TranscriptionEngineDescriptor.parakeet.automaticPriority(for: .dictation) == 100)
        #expect(TranscriptionEngineDescriptor.parakeet.automaticPriority(for: .meetingFinal) == 2)
    }

    @Test("Escolha explícita do usuário continua vencendo a Q2 — o Apple vira o fallback dela")
    func userSelectionStillOutranksTheQ2Policy() {
        let router = TranscriptionRouter()

        // Quem pinou `large-v3-turbo` (ou Parakeet) escolheu de propósito e baixou os pesos; a Q2
        // muda o **automático**, e trocar essa escolha por baixo seria a troca silenciosa que a
        // T1.4 e a T2.4a existem para impedir.
        let pinnedWhisper = router.plan(
            for: TranscriptionRoutingContext(
                useCase: .meetingFinal,
                language: .portugueseBrazil,
                hardware: .appleSilicon16GB,
                selection: .manual(engine: .whisperKit, model: .whisperLargeV3Turbo)
            )
        )
        #expect(pinnedWhisper.primary?.engine == .whisperKit)
        #expect(pinnedWhisper.primary?.model == .whisperLargeV3Turbo)
        #expect(pinnedWhisper.primary?.origin == .userSelection)
        #expect(pinnedWhisper.candidates.map(\.engine) == [.whisperKit, .appleSpeechAnalyzer, .parakeet])

        let pinnedParakeet = router.plan(
            for: TranscriptionRoutingContext(
                useCase: .meetingFinal,
                language: .portugueseBrazil,
                hardware: .appleSilicon16GB,
                selection: .manual(engine: .parakeet)
            )
        )
        #expect(pinnedParakeet.primary?.engine == .parakeet)
        #expect(pinnedParakeet.primary?.origin == .userSelection)
        #expect(pinnedParakeet.candidates.map(\.engine) == [.parakeet, .appleSpeechAnalyzer, .whisperKit])
    }

    @Test("O modelo padrão do WhisperKit é o small, como o app usa hoje")
    func whisperDefaultModelIsSmall() {
        #expect(TranscriptionEngineDescriptor.whisperKit.defaultModel == .whisperSmall)
        #expect(TranscriptionModelID.whisperSmall.rawValue == "openai_whisper-small")
    }

    @Test("Num Intel simulado sobra só o WhisperKit — em qualquer caso de uso")
    func intelKeepsOnlyWhisperKit() {
        let router = TranscriptionRouter()

        for useCase in TranscriptionUseCase.allCases {
            let plan = router.plan(
                for: TranscriptionRoutingContext(
                    useCase: useCase,
                    language: .portugueseBrazil,
                    hardware: .intel8GB,
                    selection: .automatic
                )
            )
            #expect(plan.candidates.map(\.engine) == [.whisperKit])
            #expect(plan.rejectionReason(for: .appleSpeechAnalyzer) == .hardwareUnsupported)
            // No preview o Parakeet cai antes por não fazer streaming — a recusa é avaliada
            // na ordem caso de uso → modo → idioma → hardware, e a primeira que bater vale.
            #expect(plan.rejectionReason(for: .parakeet) == (
                useCase == .meetingPreview ? .useCaseUnsupported(.meetingPreview) : .hardwareUnsupported
            ))
        }
    }

    @Test("Num Intel simulado, nenhum modelo pesado é oferecido")
    func intelNeverGetsHeavyModels() {
        let router = TranscriptionRouter()
        let catalog = TranscriptionCatalog.shipping

        for useCase in TranscriptionUseCase.allCases {
            let plan = router.plan(
                for: TranscriptionRoutingContext(
                    useCase: useCase,
                    language: .portugueseBrazil,
                    hardware: .intel8GB,
                    selection: .automatic
                )
            )
            for candidate in plan.candidates {
                let model = catalog.descriptor(for: candidate.engine)?.model(candidate.model)
                #expect(model?.weight == .light)
            }
        }
    }

    @Test("O Parakeet não entra no preview: o adapter dele é só de lote")
    func parakeetIsOutOfPreview() {
        let plan = TranscriptionRouter().plan(
            for: TranscriptionRoutingContext(
                useCase: .meetingPreview,
                language: .portugueseBrazil,
                hardware: .appleSilicon16GB,
                selection: .automatic
            )
        )

        #expect(!plan.candidates.map(\.engine).contains(.parakeet))
        #expect(plan.rejectionReason(for: .parakeet) == .useCaseUnsupported(.meetingPreview))
    }

    @Test("O SpeechAnalyzer não é escolhido quando o idioma é automático")
    func appleEngineNeedsExplicitLanguage() {
        let router = TranscriptionRouter()

        let automatic = router.plan(
            for: TranscriptionRoutingContext(
                useCase: .meetingFinal,
                language: nil,
                hardware: .appleSilicon16GB,
                selection: .automatic
            )
        )
        #expect(!automatic.candidates.map(\.engine).contains(.appleSpeechAnalyzer))
        #expect(automatic.rejectionReason(for: .appleSpeechAnalyzer) == .languageUnsupported(nil))
        // A consequência disso **depois da Q2**, e ela é o que dispensa caso especial no roteador:
        // sem idioma explícito o rank 0 da reunião volta a ser o Whisper sozinho. O `.meetingFinal`
        // é o único caso de uso em que isso importa, porque é o único cujo rank 0 é o Apple.
        // Parakeet fora daqui desde a troca de pesos da Onda 5: sem detecção de idioma, ele não é
        // candidato no modo automático.
        #expect(automatic.candidates.map(\.engine) == [.whisperKit])
        #expect(automatic.primary?.model == .whisperSmall)

        let explicit = router.plan(
            for: TranscriptionRoutingContext(
                useCase: .meetingFinal,
                language: .portugueseBrazil,
                hardware: .appleSilicon16GB,
                selection: .automatic
            )
        )
        #expect(explicit.candidates.map(\.engine).contains(.appleSpeechAnalyzer))
    }

    @Test("Em Apple Silicon com idioma explícito, o plano tem os três motores e ninguém é rejeitado")
    func fullPlanOnAppleSilicon() {
        let plan = TranscriptionRouter().plan(
            for: TranscriptionRoutingContext(
                useCase: .meetingFinal,
                language: .portugueseBrazil,
                hardware: .appleSilicon16GB,
                selection: .automatic
            )
        )

        // Ordem da Q2. Antes dela era `[.whisperKit, .appleSpeechAnalyzer, .parakeet]` — esta linha
        // é a trava da regra 6 mudando **junto** com a exceção autorizada, e não sendo silenciada.
        #expect(plan.candidates.map(\.engine) == [.appleSpeechAnalyzer, .whisperKit, .parakeet])
        #expect(plan.rejections.isEmpty)
    }

    // MARK: - Protocolos de motor, com dublês

    @Test("Motor em lote: prepara, transcreve e devolve a proveniência do candidato")
    func batchEngineHappyPath() async throws {
        let engine = FakeBatchEngine(descriptor: .whisperKit, transcript: "olá mundo")
        let candidate = TranscriptionRoutingCandidate(
            engine: .whisperKit,
            model: .whisperSmall,
            rank: 1,
            origin: .automatic
        )
        let request = TranscriptionRequest(
            useCase: .dictation,
            language: .portugueseBrazil,
            audio: TranscriptionFixtures.audio(seconds: 2)
        )

        try await engine.prepare(model: candidate.model)
        let result = try await engine.transcribe(request, candidate: candidate)

        #expect(await engine.preparedModels == [.whisperSmall])
        #expect(result.text == "olá mundo")
        #expect(result.segments.first?.duration == 2.0)
        #expect(result.detectedLanguage == .portugueseBrazil)
        #expect(result.provenance.engine == .whisperKit)
        #expect(result.provenance.model == .whisperSmall)
        #expect(result.provenance.useCase == .dictation)
        #expect(result.provenance.isFallback)

        await engine.unload()
        #expect(await engine.unloadCount == 1)
    }

    @Test("Falha do motor chega tipada, com a política de fallback junto")
    func batchEngineFailurePropagates() async {
        let engine = FakeBatchEngine(
            descriptor: .whisperKit,
            transcribeFailure: .modelUnavailable(.whisperSmall)
        )
        let candidate = TranscriptionRoutingCandidate(
            engine: .whisperKit,
            model: .whisperSmall,
            rank: 0,
            origin: .automatic
        )
        let request = TranscriptionRequest(
            useCase: .dictation,
            language: .portugueseBrazil,
            audio: TranscriptionFixtures.audio()
        )

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(request, candidate: candidate)
        }
    }

    @Test("Sessão de streaming emite parciais e fecha com um final")
    func streamingSessionEmitsPartialsThenFinal() async throws {
        let engine = FakeStreamingEngine(descriptor: .appleSpeechAnalyzer)
        let candidate = TranscriptionRoutingCandidate(
            engine: .appleSpeechAnalyzer,
            model: .appleSystemSpeechPTBR,
            rank: 0,
            origin: .userSelection
        )
        let stream = try await engine.startStream(
            TranscriptionStreamRequest(useCase: .meetingPreview, language: .portugueseBrazil),
            candidate: candidate
        )

        let collector = Task {
            var collected: [TranscriptionStreamEvent] = []
            for try await event in stream.events {
                collected.append(event)
            }
            return collected
        }

        try await stream.append(TranscriptionFixtures.audio(seconds: 1))
        try await stream.append(TranscriptionFixtures.audio(seconds: 1))
        await stream.finish()

        let events = try await collector.value
        #expect(events.count == 3)
        if case .partial(let first) = events[0] {
            #expect(first.start == 0)
            #expect(first.end == 1)
        } else {
            Issue.record("O primeiro evento deveria ser um parcial")
        }
        if case .final(let last) = events[2] {
            #expect(last.end == 2)
        } else {
            Issue.record("O último evento deveria ser um final")
        }
        #expect(stream.provenance.engine == .appleSpeechAnalyzer)
        #expect(stream.provenance.useCase == .meetingPreview)
    }

    @Test("Sessão cancelada não emite final")
    func cancelledStreamEmitsNoFinal() async throws {
        let engine = FakeStreamingEngine(descriptor: .appleSpeechAnalyzer)
        let stream = try await engine.startStream(
            TranscriptionStreamRequest(useCase: .meetingPreview, language: .portugueseBrazil),
            candidate: TranscriptionRoutingCandidate(
                engine: .appleSpeechAnalyzer,
                model: .appleSystemSpeechPTBR,
                rank: 0,
                origin: .automatic
            )
        )

        let collector = Task {
            var collected: [TranscriptionStreamEvent] = []
            for try await event in stream.events {
                collected.append(event)
            }
            return collected
        }

        try await stream.append(TranscriptionFixtures.audio(seconds: 1))
        await stream.cancel()

        let events = try await collector.value
        #expect(events.count == 1)
        #expect(events.allSatisfy { if case .partial = $0 { return true } else { return false } })
    }
}
