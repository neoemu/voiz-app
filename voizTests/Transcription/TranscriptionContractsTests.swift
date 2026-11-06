import Testing
import Foundation

/// Testes dos tipos de contrato em si — idioma, caso de uso, áudio, proveniência e falhas.
/// São as peças que o roteador e os motores compartilham; se elas mentirem, o roteador acerta
/// a decisão errada com convicção.
@Suite("Contratos de transcrição")
struct TranscriptionContractsTests {

    // MARK: - Idioma

    @Test("O idioma é normalizado ao ser construído")
    func languageIsNormalized() {
        #expect(TranscriptionLanguage("pt_BR").rawValue == "pt-BR")
        #expect(TranscriptionLanguage("PT-br").rawValue == "pt-BR")
        #expect(TranscriptionLanguage("EN").rawValue == "en")
        #expect(TranscriptionLanguage("pt-BR") == .portugueseBrazil)
    }

    @Test("Código primário e região são extraídos do idioma")
    func languagePartsAreExtracted() {
        #expect(TranscriptionLanguage.portugueseBrazil.primaryCode == "pt")
        #expect(TranscriptionLanguage.portugueseBrazil.regionCode == "BR")
        #expect(TranscriptionLanguage.portuguese.primaryCode == "pt")
        #expect(TranscriptionLanguage.portuguese.regionCode == nil)
    }

    @Test("Compatibilidade de idioma: exato, genérico e regiões diferentes")
    func languageMatching() {
        // Iguais.
        #expect(TranscriptionLanguage.portugueseBrazil.matches(.portugueseBrazil))
        // Suportado regional atende pedido genérico.
        #expect(TranscriptionLanguage.portugueseBrazil.matches(.portuguese))
        // Suportado genérico cobre pedido regional.
        #expect(TranscriptionLanguage.portuguese.matches(.portugueseBrazil))
        // Regiões diferentes do mesmo idioma não se cobrem.
        #expect(!TranscriptionLanguage.portugueseBrazil.matches(TranscriptionLanguage("pt-PT")))
        // Idiomas diferentes, nunca.
        #expect(!TranscriptionLanguage.portugueseBrazil.matches(.englishUS))
        #expect(!TranscriptionLanguage.english.matches(.portuguese))
    }

    @Test("Idioma vai e volta do JSON como string pura")
    func languageCodesAsPlainString() throws {
        let data = try JSONEncoder().encode(TranscriptionLanguage.portugueseBrazil)
        #expect(String(data: data, encoding: .utf8) == "\"pt-BR\"")
        #expect(try JSONDecoder().decode(TranscriptionLanguage.self, from: data) == .portugueseBrazil)
    }

    @Test("Ids de motor e modelo também são strings puras no JSON")
    func identifiersCodeAsPlainStrings() throws {
        let engineData = try JSONEncoder().encode(TranscriptionEngineID.whisperKit)
        let modelData = try JSONEncoder().encode(TranscriptionModelID.whisperSmall)

        #expect(String(data: engineData, encoding: .utf8) == "\"whisperkit\"")
        #expect(String(data: modelData, encoding: .utf8) == "\"openai_whisper-small\"")
        #expect(try JSONDecoder().decode(TranscriptionEngineID.self, from: engineData) == .whisperKit)
        #expect(try JSONDecoder().decode(TranscriptionModelID.self, from: modelData) == .whisperSmall)
    }

    // MARK: - Caso de uso

    @Test("Só o preview da reunião exige streaming")
    func onlyPreviewRequiresStreaming() {
        #expect(TranscriptionUseCase.meetingPreview.requiresStreaming)
        #expect(!TranscriptionUseCase.dictation.requiresStreaming)
        #expect(!TranscriptionUseCase.translationChunk.requiresStreaming)
        #expect(!TranscriptionUseCase.meetingFinal.requiresStreaming)
    }

    @Test("Só o transcript oficial da reunião roda sem ninguém esperando")
    func onlyFinalTranscriptIsBackground() {
        #expect(!TranscriptionUseCase.meetingFinal.isInteractive)
        #expect(TranscriptionUseCase.dictation.isInteractive)
        #expect(TranscriptionUseCase.translationChunk.isInteractive)
        #expect(TranscriptionUseCase.meetingPreview.isInteractive)
    }

    // MARK: - Áudio

    @Test("A duração do áudio sai das amostras e da taxa")
    func audioDuration() {
        let audio = TranscriptionAudio(samples: [Float](repeating: 0, count: 32_000), sampleRate: 16_000)
        #expect(audio.duration == 2.0)
        #expect(!audio.isEmpty)

        let empty = TranscriptionAudio(samples: [])
        #expect(empty.isEmpty)
        #expect(empty.duration == 0)
    }

    @Test("Taxa inválida não vira divisão por zero")
    func audioWithZeroSampleRate() {
        let audio = TranscriptionAudio(samples: [0, 0, 0], sampleRate: 0)
        #expect(audio.duration == 0)
    }

    // MARK: - Proveniência

    @Test("A proveniência de um fallback se identifica como fallback")
    func provenanceKnowsItIsFallback() {
        let first = TranscriptionRoutingCandidate(engine: .whisperKit, model: .whisperSmall, rank: 0, origin: .userSelection)
        let second = TranscriptionRoutingCandidate(engine: .parakeet, model: .parakeetTDT06BV3, rank: 1, origin: .automatic)

        #expect(!TranscriptionProvenance(candidate: first, useCase: .dictation).isFallback)
        #expect(TranscriptionProvenance(candidate: second, useCase: .dictation).isFallback)
    }

    @Test("A proveniência sai do candidato sem perder nada")
    func provenanceCarriesTheCandidate() {
        let candidate = TranscriptionRoutingCandidate(
            engine: .appleSpeechAnalyzer,
            model: .appleSystemSpeechPTBR,
            rank: 2,
            origin: .automatic
        )
        let provenance = TranscriptionProvenance(candidate: candidate, useCase: .meetingFinal)

        #expect(provenance.engine == .appleSpeechAnalyzer)
        #expect(provenance.model == .appleSystemSpeechPTBR)
        #expect(provenance.useCase == .meetingFinal)
        #expect(provenance.origin == .automatic)
        #expect(provenance.candidateRank == 2)
    }

    @Test("A proveniência sobrevive a um round-trip de JSON")
    func provenanceRoundTrips() throws {
        let provenance = TranscriptionProvenance(
            engine: .whisperKit,
            model: .whisperLargeV3Turbo,
            useCase: .translationChunk,
            origin: .userSelection,
            candidateRank: 0
        )
        let data = try JSONEncoder().encode(provenance)
        #expect(try JSONDecoder().decode(TranscriptionProvenance.self, from: data) == provenance)
    }

    // MARK: - Falhas

    @Test("Só falhas que outro motor poderia resolver permitem fallback")
    func failureFallbackPolicy() {
        #expect(TranscriptionEngineFailure.modelUnavailable(.whisperSmall).allowsFallback)
        #expect(TranscriptionEngineFailure.languageUnsupported(.portugueseBrazil).allowsFallback)
        #expect(TranscriptionEngineFailure.hardwareUnsupported.allowsFallback)
        #expect(TranscriptionEngineFailure.engineInternal("erro qualquer").allowsFallback)

        // Áudio ruim segue ruim no próximo motor; cancelamento é vontade do usuário.
        #expect(!TranscriptionEngineFailure.invalidAudio("vazio").allowsFallback)
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)
    }

    // MARK: - Hardware

    @Test("Requisito de hardware compara arquitetura, Neural Engine e memória")
    func hardwareRequirementMatching() {
        #expect(TranscriptionHardwareRequirement.none.isSatisfied(by: .intel8GB))
        #expect(TranscriptionHardwareRequirement.appleSiliconNeuralEngine.isSatisfied(by: .appleSilicon16GB))
        #expect(!TranscriptionHardwareRequirement.appleSiliconNeuralEngine.isSatisfied(by: .intel8GB))
        // Apple Silicon, mas sem os 8 GB que o requisito pede.
        #expect(!TranscriptionHardwareRequirement.appleSiliconNeuralEngine.isSatisfied(by: .appleSilicon4GB))

        let neuralOnly = TranscriptionHardwareRequirement(requiresNeuralEngine: true)
        #expect(!neuralOnly.isSatisfied(by: .intel8GB))
        #expect(neuralOnly.isSatisfied(by: .appleSilicon4GB))
    }

    @Test("O perfil detectado descreve a máquina que roda o teste de forma coerente")
    func detectedProfileIsCoherent() {
        let profile = TranscriptionHardwareProfile.detected()

        #expect(profile.physicalMemoryBytes > 0)
        #expect(profile.hasNeuralEngine == (profile.architecture == .appleSilicon))
    }

    // MARK: - Descritor

    @Test("O descritor responde por idioma, caso de uso e modo")
    func descriptorCapabilities() {
        let batchOnly = TranscriptionFixtures.engine(
            .fakeAlpha,
            languages: [.portugueseBrazil],
            detectsLanguage: false,
            useCases: [.dictation, .meetingPreview],
            batch: true,
            streaming: false
        )

        #expect(batchOnly.supports(language: .portugueseBrazil))
        #expect(batchOnly.supports(language: .portuguese))
        #expect(!batchOnly.supports(language: .englishUS))
        // Sem detecção automática, um pedido sem idioma não pode ir para ele.
        #expect(!batchOnly.supports(language: nil))

        #expect(batchOnly.supports(useCase: .dictation))
        // Está na lista de casos de uso, mas exige streaming, que ele não tem.
        #expect(!batchOnly.supports(useCase: .meetingPreview))
        #expect(!batchOnly.supports(useCase: .meetingFinal))
    }

    @Test("Modelo sem idioma declarado herda os do motor")
    func modelWithoutLanguagesAcceptsEverything() {
        let inherited = TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha)
        let restricted = TranscriptionFixtures.model(.fakePtOnly, engine: .fakeAlpha, languages: [.portugueseBrazil])

        #expect(inherited.supports(language: .englishUS))
        #expect(inherited.supports(language: nil))
        #expect(restricted.supports(language: .portugueseBrazil))
        #expect(!restricted.supports(language: .englishUS))
        // Detecção automática é decisão do motor: o modelo não barra.
        #expect(restricted.supports(language: nil))
    }
}
