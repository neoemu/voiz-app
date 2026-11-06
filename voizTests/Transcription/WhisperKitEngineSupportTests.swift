import Testing
import Foundation

/// Testes das decisões do motor WhisperKit que não dependem do WhisperKit.
///
/// O alvo `voizTests` não linka o pacote WhisperKit (não tem host app), então o
/// `WhisperKitTranscriptionEngine` em si não é instanciável aqui — e um teste de contrato de
/// motor exigiria pesos de ~480 MB baixados, o que não é rápido nem offline. O que foi feito,
/// então, foi tirar do motor tudo que decide sem a biblioteca e testar isso de verdade: é
/// exatamente o código que o `TranscriptionService` legado também passou a usar, então uma
/// regressão aqui quebra os dois caminhos de uma vez.
@Suite("Suporte do motor WhisperKit")
struct WhisperKitEngineSupportTests {

    // MARK: - Sanitização

    @Test("Tags de som entre colchetes e parênteses somem do texto")
    func sanitizeRemovesSoundTags() {
        #expect(WhisperKitEngineSupport.sanitize("[MÚSICA] Bom dia") == "Bom dia")
        #expect(WhisperKitEngineSupport.sanitize("Bom dia [Music]") == "Bom dia")
        #expect(WhisperKitEngineSupport.sanitize("(aplausos) Obrigado") == "Obrigado")
        #expect(WhisperKitEngineSupport.sanitize("Oi [risos] tudo bem") == "Oi tudo bem")
    }

    @Test("Glifos musicais soltos somem do texto")
    func sanitizeRemovesMusicGlyphs() {
        #expect(WhisperKitEngineSupport.sanitize("♪ lá lá lá ♪") == "lá lá lá")
        #expect(WhisperKitEngineSupport.sanitize("🎵🎶 fim") == "fim")
        #expect(WhisperKitEngineSupport.sanitize("♫♬") == "")
    }

    @Test("Espaços duplicados e bordas são colapsados depois da limpeza")
    func sanitizeCollapsesWhitespace() {
        #expect(WhisperKitEngineSupport.sanitize("  a    b  ") == "a b")
        #expect(WhisperKitEngineSupport.sanitize("\n reunião \n") == "reunião")
        // O buraco deixado pela tag não vira espaço duplo.
        #expect(WhisperKitEngineSupport.sanitize("um [MÚSICA] dois") == "um dois")
    }

    @Test("Texto normal atravessa a sanitização intacto")
    func sanitizeKeepsPlainText() {
        let text = "A reunião começa às 9h e termina às 10h."
        #expect(WhisperKitEngineSupport.sanitize(text) == text)
        // Regressão do caso degenerado: um texto que é só tag vira vazio, não vira espaço.
        #expect(WhisperKitEngineSupport.sanitize("[MÚSICA]") == "")
    }

    // MARK: - Idioma

    @Test("O código do Whisper é o primário: pt-BR vira pt")
    func whisperLanguageCodeUsesPrimaryCode() {
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: .portugueseBrazil) == "pt")
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: .portuguese) == "pt")
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: .englishUS) == "en")
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: .english) == "en")
    }

    @Test("Idioma ausente vira detecção automática (nil), não uma string vazia")
    func whisperLanguageCodeIsNilForAutomatic() {
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: nil) == nil)
        #expect(WhisperKitEngineSupport.whisperLanguageCode(for: TranscriptionLanguage("")) == nil)
    }

    @Test("O idioma detectado aceita tanto o código quanto o nome que o Whisper devolve")
    func detectedLanguageAcceptsCodeAndName() {
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "pt") == .portuguese)
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "portuguese") == .portuguese)
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "English") == .english)
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "EN") == .english)
    }

    @Test("Idioma desconhecido é reportado como ele mesmo, não colapsado em inglês")
    func detectedLanguageKeepsUnknownLanguages() {
        // Diferença consciente em relação ao `detectLanguage(from:)` do TranscriptionService,
        // que precisa devolver um `Language` do app e por isso vira `.english`. Aqui a
        // informação é preservada para o coordenador da T2.3 poder usá-la.
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "fr") == TranscriptionLanguage("fr"))
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "pt_BR") == .portugueseBrazil)
    }

    @Test("Sem código, não há idioma detectado")
    func detectedLanguageIsNilWithoutCode() {
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: nil) == nil)
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "") == nil)
        #expect(WhisperKitEngineSupport.detectedLanguage(fromWhisperCode: "   ") == nil)
    }

    // MARK: - Seleção da variante do modelo

    @Test("Todo modelo do descritor do WhisperKit resolve para a variante de mesmo nome")
    func resolveVariantAcceptsEveryModelOfTheDescriptor() throws {
        for model in TranscriptionEngineDescriptor.whisperKit.models {
            #expect(try WhisperKitEngineSupport.resolveVariant(for: model.id) == model.id.rawValue)
        }
        #expect(try WhisperKitEngineSupport.resolveVariant(for: .whisperSmall) == "openai_whisper-small")
        #expect(try WhisperKitEngineSupport.resolveVariant(for: .whisperLargeV3Turbo) == "openai_whisper-large-v3_turbo")
    }

    @Test("Modelo de outro motor é recusado antes de virar download")
    func resolveVariantRejectsForeignModels() {
        // Uma seleção salva apontando para o Parakeet não pode virar
        // `WhisperKit.download(variant: "parakeet-tdt-0.6b-v3")`.
        #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try WhisperKitEngineSupport.resolveVariant(for: .parakeetTDT06BV3)
        }
        let unknown = TranscriptionModelID("openai_whisper-tiny")
        #expect(throws: TranscriptionEngineFailure.modelUnavailable(unknown)) {
            try WhisperKitEngineSupport.resolveVariant(for: unknown)
        }
    }

    @Test("A recusa respeita o descritor recebido, não uma lista fixa")
    func resolveVariantUsesTheGivenDescriptor() throws {
        // O catálogo cresce por onda; um descritor com um modelo novo já passa a valer.
        let futureModel = TranscriptionModelID("openai_whisper-tiny")
        var descriptor = TranscriptionEngineDescriptor.whisperKit
        descriptor.models.append(
            TranscriptionModelDescriptor(
                id: futureModel,
                engine: .whisperKit,
                productName: "Whisper tiny",
                weight: .light,
                downloadBytes: 40 * 1024 * 1024
            )
        )
        #expect(try WhisperKitEngineSupport.resolveVariant(for: futureModel, descriptor: descriptor) == futureModel.rawValue)
    }

    // MARK: - Pasta do modelo

    @Test("A pasta do modelo é a do HubApi: huggingface/models/argmaxinc/whisperkit-coreml/<variante>")
    func modelFolderMatchesHubLayout() {
        let documents = URL(fileURLWithPath: "/Users/alguem/Documents", isDirectory: true)
        let folder = WhisperKitEngineSupport.modelFolder(inDocuments: documents, variant: "openai_whisper-small")
        #expect(folder.path == "/Users/alguem/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small")
    }

    @Test("A pasta real do usuário fica sob o diretório de Documentos")
    func modelFolderURLResolvesUnderDocuments() throws {
        let folder = try #require(WhisperKitEngineSupport.modelFolderURL(for: "openai_whisper-small"))
        let documents = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        #expect(folder.path.hasPrefix(documents.path))
        #expect(folder.lastPathComponent == "openai_whisper-small")
    }

    @Test("Só com os dois weight.bin críticos a variante conta como baixada")
    func weightsPresenceNeedsBothCriticalFiles() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("voiz-whisperkit-support-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folder = WhisperKitEngineSupport.modelFolder(inDocuments: root, variant: "openai_whisper-small")

        // Pasta inexistente.
        #expect(!WhisperKitEngineSupport.areWeightsPresent(inModelFolder: folder))

        func write(_ relativePath: String) throws {
            let file = folder.appendingPathComponent(relativePath)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: file)
        }

        // Download interrompido: só o decoder chegou.
        try write("TextDecoder.mlmodelc/weights/weight.bin")
        #expect(!WhisperKitEngineSupport.areWeightsPresent(inModelFolder: folder))

        try write("AudioEncoder.mlmodelc/weights/weight.bin")
        #expect(WhisperKitEngineSupport.areWeightsPresent(inModelFolder: folder))
    }

    // MARK: - Erros de modelo incompleto

    @Test("As mensagens reais de modelo corrompido acionam a recuperação")
    func incompleteModelHeuristicMatchesRealMessages() {
        let corrupted = [
            "Error: could not open weight.bin",
            "Error parsing MIL file",
            "Could not open model",
            "No such file or directory",
            "Failed to load model from disk",
            // Caixa não importa: as mensagens chegam de camadas diferentes.
            "FAILED TO LOAD"
        ]
        for message in corrupted {
            #expect(WhisperKitEngineSupport.isIncompleteModelDescription(message), "não casou: \(message)")
        }
    }

    @Test("Erro transitório de rede não é confundido com modelo corrompido")
    func incompleteModelHeuristicIgnoresTransientErrors() {
        let transient = [
            "The Internet connection appears to be offline.",
            "The request timed out.",
            "Server returned 503"
        ]
        for message in transient {
            #expect(!WhisperKitEngineSupport.isIncompleteModelDescription(message), "casou à toa: \(message)")
        }
    }

    @Test("A heurística lê a descrição do erro, não só a mensagem localizada")
    func incompleteModelHeuristicReadsErrorDescription() {
        struct OpaqueError: Error, CustomStringConvertible {
            var description: String { "MLModel: could not open TextDecoder.mlmodelc" }
        }
        #expect(WhisperKitEngineSupport.isIncompleteModelError(OpaqueError()))
        #expect(!WhisperKitEngineSupport.isIncompleteModelError(CancellationError()))
    }

    // MARK: - Tradução de erros

    @Test("Falha já classificada passa direto, sem re-classificação")
    func failureKeepsAlreadyClassifiedFailures() {
        let original = TranscriptionEngineFailure.invalidAudio("áudio vazio")
        #expect(WhisperKitEngineSupport.loadFailure(for: original, model: .whisperSmall) == original)
        #expect(WhisperKitEngineSupport.inferenceFailure(for: original, model: .whisperSmall) == original)
        #expect(
            WhisperKitEngineSupport.loadFailure(for: TranscriptionEngineFailure.hardwareUnsupported, model: .whisperSmall)
                == .hardwareUnsupported
        )
    }

    @Test("Cancelamento vira .cancelled nos dois caminhos, e não permite fallback")
    func failureMapsCancellation() {
        for model in [TranscriptionModelID.whisperSmall] {
            #expect(WhisperKitEngineSupport.loadFailure(for: CancellationError(), model: model) == .cancelled)
            #expect(WhisperKitEngineSupport.inferenceFailure(for: CancellationError(), model: model) == .cancelled)

            let urlCancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            #expect(WhisperKitEngineSupport.loadFailure(for: urlCancelled, model: model) == .cancelled)
            #expect(WhisperKitEngineSupport.inferenceFailure(for: urlCancelled, model: model) == .cancelled)

            let userCancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            #expect(WhisperKitEngineSupport.loadFailure(for: userCancelled, model: model) == .cancelled)
        }
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)
    }

    @Test("Na carga, modelo corrompido e rede caída viram modelUnavailable do modelo pedido")
    func loadFailureMapsModelProblems() {
        struct Corrupted: Error, CustomStringConvertible {
            var description: String { "could not open weight.bin" }
        }
        #expect(
            WhisperKitEngineSupport.loadFailure(for: Corrupted(), model: .whisperLargeV3Turbo)
                == .modelUnavailable(.whisperLargeV3Turbo)
        )

        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(
            WhisperKitEngineSupport.loadFailure(for: offline, model: .whisperSmall)
                == .modelUnavailable(.whisperSmall)
        )
        // Os dois permitem tentar o próximo candidato do plano.
        #expect(TranscriptionEngineFailure.modelUnavailable(.whisperSmall).allowsFallback)
    }

    @Test("Na inferência, rede caída NÃO vira modelUnavailable — os pesos estão carregados")
    func inferenceFailureKeepsNetworkErrorsInternal() {
        // Achado MENOR da review de arquitetura: mapear para modelUnavailable com o modelo já
        // residente grava proveniência e telemetria erradas.
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let failure = WhisperKitEngineSupport.inferenceFailure(for: offline, model: .whisperSmall)
        guard case .engineInternal = failure else {
            Issue.record("esperava engineInternal, veio \(failure)")
            return
        }

        // Já um arquivo do modelo sumindo debaixo do processo continua sendo problema de modelo.
        struct Corrupted: Error, CustomStringConvertible {
            var description: String { "could not open weight.bin" }
        }
        #expect(
            WhisperKitEngineSupport.inferenceFailure(for: Corrupted(), model: .whisperSmall)
                == .modelUnavailable(.whisperSmall)
        )
    }

    @Test("Erro desconhecido vira engineInternal com a descrição técnica")
    func failureMapsUnknownErrorsToEngineInternal() {
        let odd = NSError(
            domain: "WhisperKit",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "decoder returned an unexpected token count"]
        )
        #expect(
            WhisperKitEngineSupport.loadFailure(for: odd, model: .whisperSmall)
                == .engineInternal("decoder returned an unexpected token count")
        )
        #expect(
            WhisperKitEngineSupport.inferenceFailure(for: odd, model: .whisperSmall)
                == .engineInternal("decoder returned an unexpected token count")
        )
    }

    // MARK: - Validação de áudio

    @Test("Áudio de 16 kHz com amostras é aceito")
    func validateAcceptsSupportedAudio() {
        let audio = TranscriptionAudio(samples: Array(repeating: 0.1, count: 16_000))
        #expect(WhisperKitEngineSupport.validate(audio) == nil)
    }

    @Test("Áudio vazio é recusado sem permitir fallback")
    func validateRejectsEmptyAudio() throws {
        let failure = try #require(WhisperKitEngineSupport.validate(TranscriptionAudio(samples: [])))
        guard case .invalidAudio = failure else {
            Issue.record("esperava invalidAudio, veio \(failure)")
            return
        }
        // Reprocessar silêncio em outro motor só gastaria bateria.
        #expect(!failure.allowsFallback)
    }

    @Test("Taxa diferente de 16 kHz é recusada — ela daria texto errado, não erro")
    func validateRejectsWrongSampleRate() throws {
        let audio = TranscriptionAudio(samples: Array(repeating: 0.1, count: 48_000), sampleRate: 48_000)
        let failure = try #require(WhisperKitEngineSupport.validate(audio))
        guard case .invalidAudio(let reason) = failure else {
            Issue.record("esperava invalidAudio, veio \(failure)")
            return
        }
        #expect(reason.contains("48000"))
        #expect(reason.contains("16000"))
    }
}
