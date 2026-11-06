import Foundation

// As decisões do motor WhisperKit que **não** dependem do WhisperKit.
//
// Este arquivo compila também no alvo `voizTests` (membership exception), e por isso importa
// só Foundation: o alvo de testes não tem host app nem linka o pacote WhisperKit. Tudo que dá
// para decidir sem os pesos carregados — limpar o texto, dizer se um erro é "modelo
// corrompido", achar a pasta do modelo, traduzir um erro em `TranscriptionEngineFailure` —
// mora aqui e é testado de verdade; o `WhisperKitTranscriptionEngine` fica sendo só a cola
// com a biblioteca.
//
// Também é a fonte única do que o `TranscriptionService` já fazia: o serviço legado delega
// para cá em vez de manter cópias privadas, para que o caminho antigo e o novo não possam
// divergir enquanto os dois coexistem (Ondas 2–7).

/// Regras do motor WhisperKit que independem da biblioteca.
nonisolated enum WhisperKitEngineSupport {

    // MARK: - Saída

    /// Remove anotações de evento não-fala que o Whisper emite em trechos de música/silêncio
    /// (ex.: `[MÚSICA]`, `[Music]`, `(aplausos)`, `♪`) para não "narrar" tudo que ouve.
    ///
    /// Compartilhado pelos caminhos de reunião e pelo serviço legado. O ditado conserva
    /// a saída original do motor, sem aplicar esta limpeza.
    static func sanitize(_ text: String) -> String {
        var cleaned = text
        // Only known non-speech annotations. Parentheses/brackets can contain real content,
        // especially in code. Dictation bypasses this cleanup entirely to preserve the source.
        let tags = "(?:música|musica|music|aplausos|applause|risos|laughter|silêncio|silencio|silence|blank_audio|no_speech)"
        cleaned = cleaned.replacingOccurrences(of: "\\[[ \\t]*" + tags + "[ \\t]*\\]|\\([ \\t]*" + tags + "[ \\t]*\\)",
                                              with: "", options: [.regularExpression, .caseInsensitive])
        // Glifos musicais soltos.
        cleaned = cleaned.replacingOccurrences(of: "[♪♫♬🎵🎶]", with: "", options: .regularExpression)
        // Espaços duplicados resultantes.
        cleaned = cleaned.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Idioma

    /// O código de idioma que vai nas `DecodingOptions` do Whisper. `nil` = detecção automática.
    ///
    /// O Whisper fala o código primário (`pt`, `en`), não a variante regional: um pedido
    /// `pt-BR` vira `pt`. Mandar `pt-BR` faria o Whisper não reconhecer o token de idioma.
    static func whisperLanguageCode(for language: TranscriptionLanguage?) -> String? {
        guard let language else { return nil }
        let primary = language.primaryCode
        return primary.isEmpty ? nil : primary
    }

    /// O idioma que o Whisper diz ter ouvido, normalizado.
    ///
    /// Ao contrário do `detectLanguage(from:)` do `TranscriptionService` — que precisa devolver
    /// um `Language` do app e por isso colapsa qualquer idioma desconhecido em `.english` —
    /// aqui um idioma fora dos dois suportados é reportado como ele mesmo. Quem consome
    /// (`TranscriptionCoordinator`, na T2.3) é que decide o que fazer com um `fr`; inventar
    /// "inglês" neste nível apagaria a informação antes de alguém poder usá-la.
    static func detectedLanguage(fromWhisperCode code: String?) -> TranscriptionLanguage? {
        guard let code else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "portuguese": return .portuguese
        case "english": return .english
        default:
            let language = TranscriptionLanguage(trimmed)
            return language.rawValue.isEmpty ? nil : language
        }
    }

    // MARK: - Modelo

    /// A variante do repositório `whisperkit-coreml` correspondente a `model`, validada contra
    /// o descritor do motor.
    ///
    /// O `rawValue` do `TranscriptionModelID` **é** o nome da variante (`openai_whisper-small`)
    /// desde a T1.2, então a "tradução" é a identidade — o que esta função de fato faz é
    /// recusar um id que não pertence ao WhisperKit. Sem isso, uma seleção salva apontando
    /// para o Parakeet viraria um `WhisperKit.download(variant: "parakeet-tdt-0.6b-v3")` que
    /// só falha depois de bater na rede.
    static func resolveVariant(
        for model: TranscriptionModelID,
        descriptor: TranscriptionEngineDescriptor = .whisperKit
    ) throws -> String {
        guard descriptor.model(model) != nil else {
            throw TranscriptionEngineFailure.modelUnavailable(model)
        }
        return model.rawValue
    }

    /// Pasta onde o WhisperKit guarda a variante `variant`, dado o diretório de Documentos.
    ///
    /// Confere com o `HubApi`: `downloadBase` padrão = `Documents/huggingface`.
    static func modelFolder(inDocuments documents: URL, variant: String) -> URL {
        documents
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(variant)
    }

    /// A mesma pasta, resolvendo o diretório de Documentos do usuário.
    static func modelFolderURL(
        for variant: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return modelFolder(inDocuments: documents, variant: variant)
    }

    /// Os pesos dos submodelos críticos estão no disco?
    ///
    /// Serve para a UI dizer "baixado" vs "baixando" e — mais importante — detecta um download
    /// interrompido que deixou a pasta existindo sem os pesos dentro.
    static func areWeightsPresent(inModelFolder folder: URL, fileManager: FileManager = .default) -> Bool {
        let decoder = folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
        return fileManager.fileExists(atPath: decoder.path) && fileManager.fileExists(atPath: encoder.path)
    }

    /// `true` se a variante já está baixada e íntegra no disco deste usuário.
    static func isModelDownloaded(_ variant: String, fileManager: FileManager = .default) -> Bool {
        guard let folder = modelFolderURL(for: variant, fileManager: fileManager) else { return false }
        return areWeightsPresent(inModelFolder: folder, fileManager: fileManager)
    }

    /// Apaga a pasta da variante. Usado só na recuperação de modelo corrompido.
    ///
    /// Devolve `true` quando a pasta deixou de existir (removida agora ou já ausente) — é o que
    /// permite ao chamador saber se vale mesmo re-baixar.
    @discardableResult
    static func removeModelFolder(_ variant: String, fileManager: FileManager = .default) -> Bool {
        guard let folder = modelFolderURL(for: variant, fileManager: fileManager) else { return false }
        guard fileManager.fileExists(atPath: folder.path) else { return true }
        do {
            try fileManager.removeItem(at: folder)
            print("🗑️ Modelo corrompido removido: \(folder.path)")
            return true
        } catch {
            print("⚠️ Falha ao remover modelo corrompido: \(error)")
            return false
        }
    }

    // MARK: - Erros

    /// Heurística: o erro indica arquivos do modelo ausentes/corrompidos (vs. um erro
    /// transitório de rede), sinalizando que vale apagar a pasta e re-baixar.
    ///
    /// É por texto porque o CoreML e o Hub reportam isso como `NSError` genérico com a causa
    /// só na mensagem — não há código de erro para casar.
    static func isIncompleteModelError(_ error: any Error) -> Bool {
        isIncompleteModelDescription("\(error)")
    }

    /// A mesma heurística sobre a descrição já em texto. Existe separada para o teste poder
    /// exercitar as frases reais que aparecem no log sem forjar um `NSError` para cada uma.
    static func isIncompleteModelDescription(_ description: String) -> Bool {
        let text = description.lowercased()
        return text.contains("weight.bin")
            || text.contains("error parsing mil")
            || text.contains("could not open")
            || text.contains("no such file")
            || text.contains("failed to load")
    }

    /// O erro é um cancelamento (usuário parou a gravação, tarefa cancelada)?
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return true }
        return false
    }

    /// Traduz um erro cru **da carga** em `TranscriptionEngineFailure`, que é o que o
    /// coordenador da T2.3 entende — o `allowsFallback` dele é que decide se o próximo
    /// candidato do plano é tentado.
    ///
    /// Uma falha já classificada passa direto: quem lançou sabia mais do que esta heurística.
    /// Rede caída durante a carga vira `modelUnavailable` porque é literalmente o que aconteceu:
    /// os pesos não puderam ser obtidos.
    ///
    /// `engineInternal` leva só a descrição técnica do erro; texto transcrito nunca chega aqui.
    static func loadFailure(for error: any Error, model: TranscriptionModelID) -> TranscriptionEngineFailure {
        if let failure = error as? TranscriptionEngineFailure { return failure }
        if isCancellation(error) { return .cancelled }
        if isIncompleteModelError(error) { return .modelUnavailable(model) }
        if (error as NSError).domain == NSURLErrorDomain { return .modelUnavailable(model) }
        return .engineInternal(error.localizedDescription)
    }

    /// Traduz um erro cru **da inferência**.
    ///
    /// Difere de `loadFailure` num ponto: erro de rede aqui **não** vira `modelUnavailable`. Com
    /// o modelo já carregado, a rede não diz nada sobre os pesos — chamar de "modelo
    /// indisponível" gravaria proveniência e telemetria erradas (achado MENOR da review de
    /// arquitetura). Já um erro de arquivo do modelo continua sendo `modelUnavailable`: aí os
    /// pesos sumiram mesmo debaixo do processo.
    static func inferenceFailure(for error: any Error, model: TranscriptionModelID) -> TranscriptionEngineFailure {
        if let failure = error as? TranscriptionEngineFailure { return failure }
        if isCancellation(error) { return .cancelled }
        if isIncompleteModelError(error) { return .modelUnavailable(model) }
        return .engineInternal(error.localizedDescription)
    }

    // MARK: - Áudio

    /// O áudio serve para o WhisperKit? Devolve a falha quando não serve, `nil` quando serve.
    ///
    /// O WhisperKit assume 16 kHz mono; entregar outra taxa não dá erro, dá texto errado —
    /// então é melhor recusar. Áudio vazio é recusado porque não há o que transcrever, e
    /// `invalidAudio` não permite fallback: o silêncio seguiria silêncio no próximo motor.
    static func validate(_ audio: TranscriptionAudio) -> TranscriptionEngineFailure? {
        if audio.isEmpty {
            return .invalidAudio("áudio vazio")
        }
        guard audio.sampleRate == TranscriptionAudio.defaultSampleRate else {
            return .invalidAudio("taxa de amostragem \(Int(audio.sampleRate)) Hz; o WhisperKit exige \(Int(TranscriptionAudio.defaultSampleRate)) Hz")
        }
        return nil
    }
}
