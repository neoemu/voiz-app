import Foundation
import Combine

/// Traduz um trecho chamando o provedor de completions escolhido nas Configurações.
///
/// **Todo `print` deste arquivo é uma chamada de `TranscriptionLogRedaction`, sem interpolação
/// solta.** Não é estilo: é a regra 7 do PLANO ("logs sem texto transcrito") no ponto em que ela
/// tinha mais chance de falhar. Este serviço vê as três coisas que não podem ir para o console ao
/// mesmo tempo — o transcript que entra, a tradução que sai (derivada dele palavra a palavra) e a
/// chave do provedor — e é chamado a cada trecho de 1,2 s da tradução ao vivo, então uma
/// interpolação distraída aqui vaza a conversa inteira do usuário. A guarda que trava isso é
/// mecânica e mora em `TranscriptionLogRedactionTests`: ela lê este arquivo e reprova se algum
/// `print` interpolar qualquer coisa que não seja um construtor de redação.
class TranslationService: ObservableObject {
    /// Reuse HTTP connections across immutable per-chunk configurations.
    private static let sharedSession = AICompletionService.makeSession()
    @Published var isTranslating = false
    @Published var error: String?

    private let completionService: AICompletionService
    private var provider: AppSettings.TranslationProvider
    private var apiKey: String
    private var model: String

    init(provider: AppSettings.TranslationProvider = .openai, apiKey: String = "", model: String = "gpt-5.6-luna", baseURL: String? = nil, reasoningEffort: String? = nil, session: URLSession? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.completionService = AICompletionService(provider: provider, apiKey: apiKey, model: model, baseURL: baseURL, reasoningEffort: reasoningEffort, session: session)
    }

    /// One settings snapshot per request, including the provider's parameter capabilities.
    convenience init(settings: AppSettings, session: URLSession? = nil) {
        self.init(provider: settings.translationProvider, apiKey: settings.currentAPIKey,
                  model: settings.currentModelId, baseURL: settings.currentBaseURL,
                  reasoningEffort: settings.currentReasoningEffort, session: session ?? Self.sharedSession)
        apply(settings)
    }

    /// Reaponta tradutor e serviço de completions para as configurações atuais.
    func apply(_ settings: AppSettings) {
        self.provider = settings.translationProvider
        self.apiKey = settings.currentAPIKey
        self.model = settings.currentModelId
        completionService.apply(settings)
    }

    func setAPIKey(_ key: String) {
        self.apiKey = key
        completionService.setAPIKey(key)
    }

    func setBaseURL(_ url: String?) {
        completionService.setBaseURL(url)
    }

    func setModel(_ modelId: String) {
        self.model = modelId
        completionService.setModel(modelId)
        print(TranscriptionLogRedaction.translationModelChanged(to: modelId))
    }

    func setProvider(_ provider: AppSettings.TranslationProvider) {
        self.provider = provider
        completionService.setProvider(provider)
        print(TranscriptionLogRedaction.translationProviderChanged(to: provider.displayName))
    }

    func translate(text: String, from sourceLanguage: Language, to targetLanguage: Language) async throws -> String {
        print(TranscriptionLogRedaction.translationRequested(text, provider: provider.displayName, model: model))

        guard !text.isEmpty else {
            print(TranscriptionLogRedaction.translationFailed(kind: Self.emptyTextKind, detail: ""))
            throw TranslationError.emptyText
        }

        guard !provider.requiresAPIKey || !apiKey.isEmpty else {
            print(TranscriptionLogRedaction.translationFailed(kind: Self.missingKeyKind, detail: ""))
            throw TranslationError.missingAPIKey
        }

        if provider.requiresAPIKey {
            print(TranscriptionLogRedaction.translationKey(apiKey))
        }

        isTranslating = true
        defer { isTranslating = false }

        let fromLang = languageDisplayName(sourceLanguage)
        let toLang = languageDisplayName(targetLanguage)

        print(TranscriptionLogRedaction.translationRoute(from: fromLang, to: toLang))

        let prompt = "Translate the following text from \(fromLang) to \(toLang). Return ONLY the translation, nothing else:\n\n\(text)"

        print(TranscriptionLogRedaction.translationSending(to: provider.displayName))

        do {
            let result = try await completionService.complete(prompt: prompt, temperature: 0.3)
            print(TranscriptionLogRedaction.translationSucceeded(result))
            return result
        } catch let error as TranslationError {
            print(TranscriptionLogRedaction.translationFailed(kind: error.logKind, detail: error.providerDetail))
            throw error
        } catch let error as AICompletionService.AICompletionError {
            switch error {
            case .missingAPIKey:
                print(TranscriptionLogRedaction.translationFailed(kind: Self.missingKeyKind, detail: ""))
                throw TranslationError.missingAPIKey
            case .emptyPrompt:
                print(TranscriptionLogRedaction.translationFailed(kind: Self.emptyTextKind, detail: ""))
                throw TranslationError.emptyText
            case .requestFailed(let message):
                print(TranscriptionLogRedaction.translationFailed(kind: Self.providerRefusedKind, detail: message))
                throw TranslationError.translationFailed(message)
            case .http(_, let detail):
                print(TranscriptionLogRedaction.translationFailed(kind: Self.providerRefusedKind, detail: detail ?? ""))
                throw TranslationError.translationFailed(error.localizedDescription)
            }
        } catch {
            // `error` aqui é o que a rede/URLSession devolveu, e a descrição dela é do sistema —
            // mas o caminho é o mesmo do corpo de erro do provedor e não vale abrir exceção para
            // ele: entra pelo `detail`, que só publica o tamanho.
            print(TranscriptionLogRedaction.translationFailed(kind: Self.unexpectedKind, detail: error.localizedDescription))
            throw TranslationError.translationFailed("Erro inesperado: \(error.localizedDescription)")
        }
    }

    // MARK: - Rótulos de falha para o log

    // Rótulos escritos pelo app — nunca texto do provedor. São o que resta de acionável na linha de
    // falha depois que a mensagem do servidor vira só um tamanho, então valem constantes com nome
    // em vez de literais soltos nos `catch`.
    private static let emptyTextKind = "texto vazio"
    private static let missingKeyKind = "chave do provedor ausente"
    private static let providerRefusedKind = "provedor recusou o pedido"
    private static let unexpectedKind = "falha inesperada"
    
    func translateStream(text: String, from sourceLanguage: Language, to targetLanguage: Language) async throws -> AsyncThrowingStream<String, Error> {
        guard !provider.requiresAPIKey || !apiKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    
                    var translatedParts: [String] = []
                    
                    for sentence in sentences {
                        let translated = try await self.translate(
                            text: sentence,
                            from: sourceLanguage,
                            to: targetLanguage
                        )
                        
                        translatedParts.append(translated)
                        
                        let partial = translatedParts.joined(separator: ". ")
                        continuation.yield(partial)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func languageCode(_ language: Language) -> String {
        switch language {
        case .portuguese:
            return "pt"
        case .english:
            return "en"
        case .spanish:
            return "es"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .japanese:
            return "ja"
        case .chinese:
            return "zh"
        }
    }
    
    private func languageDisplayName(_ language: Language) -> String {
        switch language {
        case .portuguese:
            return "Portuguese (Brazil)"
        case .english:
            return "English"
        case .spanish:
            return "Spanish"
        case .french:
            return "French"
        case .german:
            return "German"
        case .japanese:
            return "Japanese"
        case .chinese:
            return "Chinese (Simplified)"
        }
    }
    
    enum TranslationError: Error, LocalizedError {
        case emptyText
        case translationFailed(String)
        case unsupportedLanguage
        case missingAPIKey
        
        var errorDescription: String? {
            switch self {
            case .emptyText:
                return String(localized: "Texto vazio para traduzir")
            case .translationFailed(let message):
                return String(localized: "Falha na tradução: \(message)")
            case .unsupportedLanguage:
                return String(localized: "Idioma não suportado")
            case .missingAPIKey:
                return String(localized: "API Key não configurada. Configure em Ajustes.")
            }
        }

        /// Como esta falha é **nomeada** no log: rótulo do app, sempre.
        ///
        /// Não é `errorDescription`: aquela é copy de UI e, em `translationFailed`, ela interpola a
        /// mensagem do provedor — que é justamente o que não pode ir para o console.
        var logKind: String {
            switch self {
            case .emptyText: return TranslationService.emptyTextKind
            case .missingAPIKey: return TranslationService.missingKeyKind
            case .unsupportedLanguage: return "idioma não suportado"
            case .translationFailed: return TranslationService.providerRefusedKind
            }
        }

        /// O pedaço da falha que **veio de fora** do app. Só o tamanho dele chega ao log.
        var providerDetail: String {
            switch self {
            case .translationFailed(let message): return message
            case .emptyText, .missingAPIKey, .unsupportedLanguage: return ""
            }
        }

        /// A linha de log pronta para qualquer erro que suba de `translate`, redigida.
        ///
        /// Existe para o `TranslationViewModel`: lá o `catch` é de `Error` genérico e imprimir
        /// `error.localizedDescription` reabriria o vazamento um quadro acima — em
        /// `translationFailed` a descrição carrega o corpo de resposta do provedor.
        static func logMessage(for error: Error) -> String {
            guard let translation = error as? TranslationError else {
                return TranscriptionLogRedaction.translationFailed(
                    kind: TranslationService.unexpectedKind,
                    detail: error.localizedDescription
                )
            }
            return TranscriptionLogRedaction.translationFailed(
                kind: translation.logKind,
                detail: translation.providerDetail
            )
        }
    }
}
