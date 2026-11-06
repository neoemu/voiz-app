import Foundation
import Combine

final class AICompletionService: ObservableObject {
    @Published var isRunning = false
    @Published var error: String?

    /// Os dois timeouts medem coisas diferentes: `timeoutIntervalForRequest` é o **silêncio** entre
    /// pacotes e `timeoutIntervalForResource` é o relógio total da requisição.
    ///
    /// Os dois estavam em 45s, e é isso que derrubava resumo de reunião grande: um modelo de
    /// raciocínio pensa minutos antes do primeiro byte, o app cortava a conexão aos 45s e a borda
    /// registrava 499 ("cliente fechou"). Com streaming os `ping` do SSE seguram o silêncio, então
    /// o que protege de verdade é o relógio total.
    private let session: URLSession

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    private var provider: AppSettings.TranslationProvider
    private var apiKey: String
    private var model: String
    /// Endpoint custom (OpenAI-compatible). Quando presente, sobrepõe `provider.baseURL`.
    private var baseURLOverride: String?
    /// Valor de `reasoning_effort`; `nil` omite o campo (fica o default do modelo).
    private var reasoningEffort: String?
    /// Modelos de raciocínio recentes rejeitam `temperature` com 400 — nesses, o campo não vai.
    private var acceptsTemperature: Bool = true

    init(provider: AppSettings.TranslationProvider = .openai, apiKey: String = "", model: String = "gpt-5.6-luna", baseURL: String? = nil, reasoningEffort: String? = nil, session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.baseURLOverride = (baseURL?.isEmpty == false) ? baseURL : nil
        self.reasoningEffort = reasoningEffort
    }

    /// Reaponta o serviço para um modelo. Sem `choice`, vale o provider/modelo das Configurações;
    /// com ele, o modelo que a tela escolheu por conta própria (o seletor do Chat).
    ///
    /// Existe para os chamadores não precisarem lembrar de cada setter — esquecer um deixava o
    /// serviço numa combinação inconsistente (ex.: modelo novo com endpoint ou chave do antigo).
    /// Uma escolha de provider sem chave configurada cai no padrão em `resolvedChoice`.
    func apply(_ settings: AppSettings, choice: AppSettings.ModelChoice? = nil) {
        let resolved = settings.resolvedChoice(choice)
        setProvider(resolved.provider)
        setAPIKey(settings.apiKey(for: resolved.provider))
        setModel(resolved.modelId)
        setBaseURL(resolved.provider == .custom ? settings.currentBaseURL : nil)
        setReasoningEffort(settings.effectiveReasoningEffort(for: resolved).apiValue)
        acceptsTemperature = settings.acceptsTemperature(for: resolved)
    }

    func setProvider(_ provider: AppSettings.TranslationProvider) {
        self.provider = provider
    }

    func setBaseURL(_ url: String?) {
        self.baseURLOverride = (url?.isEmpty == false) ? url : nil
    }

    func setAPIKey(_ key: String) {
        self.apiKey = key
    }

    func setModel(_ modelId: String) {
        self.model = modelId
    }

    func setReasoningEffort(_ effort: String?) {
        self.reasoningEffort = effort
    }

    /// A single turn in a chat conversation (system, user or assistant).
    struct ChatTurn {
        let role: String
        let content: String

        init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Convenience for a single-shot user prompt (no system message / history).
    func complete(prompt: String, temperature: Double = 0.3) async throws -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AICompletionError.emptyPrompt
        }
        return try await complete(
            messages: [ChatTurn(role: "user", content: trimmedPrompt)],
            temperature: temperature
        )
    }

    /// Full conversation completion: pass a system turn, prior history and the new user turn.
    func complete(messages: [ChatTurn], temperature: Double = 0.3) async throws -> String {
        let sanitized = messages
            .map { ChatTurn(role: $0.role, content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.content.isEmpty }

        guard !sanitized.isEmpty else {
            throw AICompletionError.emptyPrompt
        }

        guard !apiKey.isEmpty else {
            throw AICompletionError.missingAPIKey
        }

        isRunning = true
        defer { isRunning = false }

        let request = try makeRequest(sanitized: sanitized, temperature: temperature, stream: false)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AICompletionError.requestFailed(String(localized: "Resposta inválida do provedor."))
            }

            guard httpResponse.statusCode == 200 else {
                let detail = Self.errorMessage(from: data) ?? String(data: data, encoding: .utf8)
                throw AICompletionError.http(status: httpResponse.statusCode, detail: detail)
            }

            let content = try Self.text(from: data, protocol: provider.wireProtocol)

            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as AICompletionError {
            self.error = error.localizedDescription
            throw error
        } catch {
            self.error = error.localizedDescription
            throw AICompletionError.requestFailed(error.localizedDescription)
        }
    }

    /// Mesma coisa que `complete`, mas por baixo usa streaming e devolve o texto inteiro no fim.
    ///
    /// É o caminho certo para as chamadas longas (resumo, capítulos): numa requisição sem streaming
    /// o servidor fica minutos calado enquanto o modelo raciocina, e qualquer timeout de ociosidade
    /// — o nosso, um proxy no meio, o Wi-Fi — mata a conexão antes da primeira letra. Com streaming
    /// chegam eventos o tempo todo, e ainda dá para pedir mais tokens de saída sem risco.
    func completeAccumulating(prompt: String, temperature: Double = 0.3) async throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AICompletionError.emptyPrompt }
        return try await completeAccumulating(
            messages: [ChatTurn(role: "user", content: trimmed)],
            temperature: temperature
        )
    }

    func completeAccumulating(messages: [ChatTurn], temperature: Double = 0.3) async throws -> String {
        var text = ""
        for try await delta in completeStream(messages: messages, temperature: temperature) {
            text += delta
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AICompletionError.requestFailed("Resposta sem conteúdo")
        }
        return result
    }

    /// Completion com streaming real (SSE `stream: true`). Emite os **deltas** de texto conforme
    /// chegam — o consumidor acumula. Funciona em qualquer endpoint OpenAI-compatible (inclui o
    /// provider custom / LiteLLM).
    func completeStream(messages: [ChatTurn], temperature: Double = 0.3) -> AsyncThrowingStream<String, Error> {
        let sanitized = messages
            .map { ChatTurn(role: $0.role, content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.content.isEmpty }

        return AsyncThrowingStream { continuation in
            let task = Task {
                guard !sanitized.isEmpty else {
                    continuation.finish(throwing: AICompletionError.emptyPrompt); return
                }

                guard !apiKey.isEmpty else {
                    continuation.finish(throwing: AICompletionError.missingAPIKey); return
                }

                await MainActor.run { self.isRunning = true }
                defer { Task { @MainActor in self.isRunning = false } }

                do {
                    let request = try makeRequest(sanitized: sanitized, temperature: temperature, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw AICompletionError.requestFailed(String(localized: "Resposta inválida do provedor."))
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw AICompletionError.http(status: http.statusCode,
                                                     detail: Self.errorMessage(from: Data(body.utf8)) ?? body)
                    }

                    let wire = provider.wireProtocol
                    // O laço é rotulado de propósito: os `break` abaixo moram dentro de um `switch`,
                    // onde um `break` nu sairia só do `switch` e continuaria lendo o stream.
                    streamLoop: for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break streamLoop }
                        guard let data = payload.data(using: .utf8) else { continue }

                        switch wire {
                        case .openAIResponses:
                            guard let event = try? JSONDecoder().decode(OpenAIResponsesStreamEvent.self, from: data) else { continue }
                            if event.type == "response.completed" { break streamLoop }
                            // `error` e `response.failed` chegam com HTTP 200 no meio do stream.
                            if event.type == "error" || event.type == "response.failed" {
                                throw AICompletionError.requestFailed(
                                    event.message ?? event.response?.error?.message ?? "Erro no streaming"
                                )
                            }
                            guard event.type == "response.output_text.delta",
                                  let delta = event.delta, !delta.isEmpty
                            else { continue }
                            continuation.yield(delta)

                        case .anthropicMessages:
                            guard let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else { continue }
                            if event.type == "message_stop" { break streamLoop }
                            // Erro no meio do stream: sem isso o texto parava na metade e a
                            // chamada terminava como sucesso.
                            if event.type == "error" {
                                throw AICompletionError.requestFailed(event.error?.message ?? "Erro no streaming")
                            }
                            if event.delta?.stopReason == "refusal" {
                                throw AICompletionError.requestFailed(
                                    String(localized: "O modelo recusou a requisição por política de segurança.")
                                )
                            }
                            guard event.type == "content_block_delta",
                                  event.delta?.type == "text_delta",
                                  let delta = event.delta?.text, !delta.isEmpty
                            else { continue }
                            continuation.yield(delta)

                        case .chatCompletions:
                            guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                                  let delta = chunk.choices.first?.delta.content, !delta.isEmpty
                            else { continue }
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    await MainActor.run { self.error = error.localizedDescription }
                    if error is AICompletionError {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish(throwing: AICompletionError.requestFailed(error.localizedDescription))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func text(from data: Data, protocol wire: AppSettings.TranslationProvider.WireProtocol) throws -> String {
        switch wire {
        case .chatCompletions: return try chatCompletionsText(from: data)
        case .openAIResponses: return try responsesText(from: data)
        case .anthropicMessages: return try anthropicText(from: data)
        }
    }

    /// O texto da Responses API mora em `output[] → content[]` nos itens do tipo `message`; os
    /// itens `reasoning` que vêm antes não têm texto visível e são ignorados.
    private static func responsesText(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(OpenAIResponsesResult.self, from: data)
        let parts = decoded.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        let text = parts.filter { $0.type == "output_text" }.compactMap(\.text).joined()
        if text.isEmpty, let refusal = parts.compactMap(\.refusal).first {
            throw AICompletionError.requestFailed(refusal)
        }
        guard !text.isEmpty else {
            throw AICompletionError.requestFailed("Resposta sem conteúdo")
        }
        return text
    }

    private static func chatCompletionsText(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw AICompletionError.requestFailed("Resposta sem conteúdo")
        }
        return content
    }

    /// Junta os blocos de texto da Messages API. A recusa por classificador de segurança chega
    /// como **HTTP 200** com `stop_reason: "refusal"` e `content` vazio — sem tratar aqui, o
    /// usuário veria só "Resposta sem conteúdo" e nenhuma pista do motivo.
    private static func anthropicText(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        if decoded.stopReason == "refusal" {
            throw AICompletionError.requestFailed(
                String(localized: "O modelo recusou a requisição por política de segurança.")
            )
        }
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else {
            throw AICompletionError.requestFailed("Resposta sem conteúdo")
        }
        return text
    }

    /// Extrai a mensagem de erro do corpo da resposta. Aceita as duas formas que aparecem na prática:
    /// o objeto `{"error": {...}}` da OpenAI/xAI e o **array** `[{"error": {...}}]` que o Gemini
    /// devolve pela camada OpenAI-compatible. Sem o segundo caso, o usuário via um dump de JSON cru
    /// no lugar de "Please pass a valid API key".
    static func errorMessage(from data: Data) -> String? {
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(OpenAIErrorResponse.self, from: data) {
            return single.error.message
        }
        if let list = try? decoder.decode([OpenAIErrorResponse].self, from: data) {
            return list.first?.error.message
        }
        return nil
    }

    /// Monta o `URLRequest` para o endpoint de chat/completions (compartilhado por `complete` e
    /// `completeStream`). Lança erro claro se o endpoint não estiver configurado.
    private func makeRequest(sanitized: [ChatTurn], temperature: Double, stream: Bool) throws -> URLRequest {
        let endpoint = baseURLOverride ?? provider.baseURL
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            let message = endpoint.isEmpty
                ? String(localized: "Endpoint não configurado. Defina a URL em Configurações → IA & Tradução.")
                : String(localized: "Endpoint inválido. Revise a URL em Configurações → IA & Tradução.")
            self.error = message
            throw AICompletionError.requestFailed(message)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any]
        switch provider.wireProtocol {
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body = try anthropicBody(sanitized: sanitized, temperature: temperature, stream: stream)

        case .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                // Aqui é `input`, não `messages`; aceita os mesmos papéis (system/user/assistant).
                "input": sanitized.map { ["role": $0.role, "content": $0.content] },
                // Diferente do `chat/completions`, este teto conta os tokens de raciocínio junto.
                "max_output_tokens": stream ? Self.maxOutputTokensStreaming : Self.maxOutputTokens
            ]
            if acceptsTemperature { body["temperature"] = temperature }
            if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }
            if stream { body["stream"] = true }

        case .chatCompletions:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "messages": sanitized.map { ["role": $0.role, "content": $0.content] }
            ]
            if acceptsTemperature { body["temperature"] = temperature }
            if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
            if stream { body["stream"] = true }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Corpo da Messages API. Três diferenças que quebram se copiadas do `chat/completions`:
    /// o system sai do array e vira campo próprio, `max_tokens` é **obrigatório**, e o esforço
    /// mora em `output_config.effort` (não em `reasoning_effort`).
    private func anthropicBody(sanitized: [ChatTurn], temperature: Double, stream: Bool) throws -> [String: Any] {
        let systemPrompt = sanitized.filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        // A API exige que o primeiro turno seja do usuário; os `assistant` que sobrarem na frente
        // (histórico cortado no meio) derrubariam a requisição com 400.
        var turns = sanitized.filter { $0.role != "system" }
        while turns.first?.role == "assistant" { turns.removeFirst() }
        // Diferente do `chat/completions`, aqui não dá para mandar só system: `messages` vazio é 400.
        guard !turns.isEmpty else { throw AICompletionError.emptyPrompt }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": stream ? Self.maxOutputTokensStreaming : Self.maxOutputTokens,
            "messages": turns.map { ["role": $0.role, "content": $0.content] }
        ]
        if !systemPrompt.isEmpty { body["system"] = systemPrompt }
        if acceptsTemperature { body["temperature"] = temperature }
        if let reasoningEffort { body["output_config"] = ["effort": reasoningEffort] }
        if stream { body["stream"] = true }
        return body
    }

    private static let anthropicVersion = "2023-06-01"
    /// Teto de saída, obrigatório na Messages API e usado também na Responses API. Nos dois casos
    /// limita **raciocínio + texto** juntos. Sem streaming fica em 16k para não esbarrar no timeout
    /// HTTP; com streaming dá para soltar mais, que é o que os tiers altos de esforço pedem.
    private static let maxOutputTokens = 16_000
    private static let maxOutputTokensStreaming = 64_000

    enum AICompletionError: Error, LocalizedError {
        case emptyPrompt
        case missingAPIKey
        case requestFailed(String)
        /// The provider's own message stays in `detail` for diagnostics; people see what to do.
        case http(status: Int, detail: String?)

        var errorDescription: String? {
            switch self {
            case .emptyPrompt:
                return String(localized: "Escreva uma mensagem para enviar.")
            case .missingAPIKey:
                return String(localized: "Adicione uma chave de API em Configurações → IA & Tradução.")
            case .requestFailed(let message):
                return String(localized: "Falha na IA: \(message)")
            case .http(let status, _):
                switch status {
                case 401, 403: return String(localized: "O provedor recusou a chave de API. Revise em Configurações → IA & Tradução.")
                case 404: return String(localized: "Modelo ou endpoint não encontrado. Revise em Configurações → IA & Tradução.")
                case 429: return String(localized: "O provedor limitou as solicitações. Tente de novo em instantes.")
                case 500...599: return String(localized: "O provedor está indisponível. Tente de novo em instantes.")
                default: return String(localized: "O provedor recusou a solicitação (código \(status)).")
                }
            }
        }
    }
}

struct OpenAIResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    /// `content` é opcional de propósito: o Gemini (camada OpenAI-compatible) devolve `null` quando
    /// a resposta é cortada antes de sair texto — com `String` não-opcional o decode explodia e o
    /// erro chegava ao usuário como "dados corrompidos" em vez da causa real.
    struct Message: Codable {
        let content: String?
    }
}

struct OpenAIErrorResponse: Codable {
    let error: ErrorDetail

    struct ErrorDetail: Codable {
        let message: String
    }
}

/// Resposta da Responses API da OpenAI (`/v1/responses`).
struct OpenAIResponsesResult: Codable {
    let output: [Item]

    struct Item: Codable {
        let type: String
        let content: [Content]?

        struct Content: Codable {
            let type: String
            let text: String?
            let refusal: String?
        }
    }
}

/// Evento do SSE da Responses API. Os deltas de texto vêm em `response.output_text.delta`, e o
/// fim é `response.completed` — não existe o sentinela `[DONE]` do `chat/completions`.
struct OpenAIResponsesStreamEvent: Codable {
    let type: String
    let delta: String?
    let message: String?
    let response: ResponseEnvelope?

    struct ResponseEnvelope: Codable {
        let error: ErrorDetail?

        struct ErrorDetail: Codable {
            let message: String?
        }
    }
}

/// Resposta da Messages API da Anthropic: o texto vem numa lista de blocos, não num `message`.
struct AnthropicResponse: Codable {
    let content: [Block]
    let stopReason: String?

    struct Block: Codable {
        let type: String
        let text: String?
    }

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

/// Evento do SSE da Messages API. O texto chega em `content_block_delta` → `delta.text`, e o
/// stream termina em `message_stop` (não existe o sentinela `[DONE]` da OpenAI).
struct AnthropicStreamEvent: Codable {
    let type: String
    let delta: Delta?
    let error: ErrorDetail?

    struct Delta: Codable {
        let type: String?
        let text: String?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
        }
    }

    struct ErrorDetail: Codable {
        let message: String
    }
}

/// Um chunk do streaming SSE (`chat/completions` com `stream: true`).
struct OpenAIStreamChunk: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let delta: Delta
    }

    struct Delta: Codable {
        let content: String?
    }
}
