import Foundation
import Testing

@MainActor
@Suite("Tradução — provedor atual e falhas visíveis", .serialized)
struct TranslationServiceTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("Each request uses its selected provider, model and key without mutating earlier requests")
    func currentSettingsAreIsolated() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TranslationURLProtocol.handler = nil }
        var settings = AppSettings()
        settings.translationProvider = .xai
        settings.xaiKey = "fixture-xai"
        settings.xaiModel = .grok45
        let firstModel = settings.currentModelId
        let first = TranslationService(settings: settings, session: session)

        settings.translationProvider = .openai
        settings.openAIKey = "fixture-openai"
        settings.translationModel = .gpt56Terra
        let secondModel = settings.currentModelId
        let second = TranslationService(settings: settings, session: session)

        TranslationURLProtocol.handler = { request in
            let body = try TranslationURLProtocol.body(request)
            if request.url?.host == "api.x.ai" {
                #expect(request.url?.path == "/v1/chat/completions")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-xai")
                #expect(body["model"] as? String == firstModel)
                #expect(body["messages"] != nil)
                return (200, Data(#"{"choices":[{"message":{"content":"Primeira tradução"}}]}"#.utf8))
            }
            #expect(request.url?.host == "api.openai.com")
            #expect(request.url?.path == "/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-openai")
            #expect(body["model"] as? String == secondModel)
            #expect(body["input"] != nil)
            #expect(body["temperature"] == nil)
            return (200, Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Deuxième traduction"}]}]}"#.utf8))
        }

        #expect(try await first.translate(text: "Hello", from: .english, to: .portuguese) == "Primeira tradução")
        #expect(try await second.translate(text: "Hola", from: .spanish, to: .french) == "Deuxième traduction")
    }

    @Test("New catalog models use supported reasoning fields and survive saved settings")
    func updatedCatalogRequests() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TranslationURLProtocol.handler = nil }
        let choices: [(AppSettings.TranslationProvider, String, String)] = [
            (.xai, "grok-4.6", "xhigh"),
            (.openai, "gpt-6-astra", "max"),
            (.anthropic, "claude-fable-5-1", "max"),
            (.gemini, "gemini-3.8-flash", "high"),
            (.gemini, "gemini-3.7-flash", "high"),
            (.gemini, "gemini-3.1-flash-lite", "high"),
            (.xai, "grok-4.3", "high"),
            (.gemini, "gemini-2.5-flash", "high")
        ]
        for (provider, model, effort) in choices {
            var settings = AppSettings()
            settings.translationProvider = provider
            settings.openAIKey = "fixture"
            settings.anthropicKey = "fixture"
            settings.xaiKey = "fixture"
            settings.geminiKey = "fixture"
            settings.reasoningEffort = .max
            switch provider {
            case .openai: settings.translationModel = try #require(.init(rawValue: model))
            case .anthropic: settings.anthropicModel = try #require(.init(rawValue: model))
            case .xai: settings.xaiModel = try #require(.init(rawValue: model))
            case .gemini: settings.geminiModel = try #require(.init(rawValue: model))
            default: Issue.record("Unexpected provider")
            }
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(restored.currentModelId == model)
            #expect(restored.models(for: provider).contains(restored.currentChoice))
            TranslationURLProtocol.handler = { request in
                let body = try TranslationURLProtocol.body(request)
                #expect(body["model"] as? String == model)
                switch provider {
                case .openai:
                    #expect(request.url?.path == "/v1/responses")
                    #expect((body["reasoning"] as? [String: String])?["effort"] == effort)
                    #expect(body["temperature"] == nil)
                    return (200, Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Olá"}]}]}"#.utf8))
                case .anthropic:
                    #expect(request.url?.path == "/v1/messages")
                    #expect((body["output_config"] as? [String: String])?["effort"] == effort)
                    #expect(body["temperature"] == nil)
                    return (200, Data(#"{"content":[{"type":"text","text":"Olá"}],"stop_reason":"end_turn"}"#.utf8))
                default:
                    #expect(body["reasoning_effort"] as? String == effort)
                    return (200, Data(#"{"choices":[{"message":{"content":"Olá"}}]}"#.utf8))
                }
            }
            #expect(try await TranslationService(settings: restored, session: session)
                .translate(text: "Hello", from: .english, to: .portuguese) == "Olá")
        }
    }

    @Test("Models with mandatory reasoning clamp none to low")
    func mandatoryReasoning() {
        var settings = AppSettings()
        settings.reasoningEffort = .none
        for choice in [
            AppSettings.ModelChoice(provider: .xai, modelId: "grok-4.6"),
            .init(provider: .openai, modelId: "gpt-6-astra"),
            .init(provider: .anthropic, modelId: "claude-fable-5-1")
        ] {
            #expect(settings.effectiveReasoningEffort(for: choice) == .low)
        }
    }

    @Test("The selected provider without a key does not fall back to a different configured provider")
    func missingKeyDoesNotChangeProvider() async {
        let session = session()
        defer { session.invalidateAndCancel(); TranslationURLProtocol.handler = nil }
        var settings = AppSettings()
        settings.translationProvider = .openai
        settings.openAIKey = ""
        settings.xaiKey = "fixture-unused"
        TranslationURLProtocol.handler = { _ in
            Issue.record("Missing credentials must be reported before making an HTTP request")
            return (500, Data())
        }
        do {
            _ = try await TranslationService(settings: settings, session: session)
                .translate(text: "Hello", from: .english, to: .portuguese)
            Issue.record("The missing-key error was swallowed")
        } catch TranslationService.TranslationError.missingAPIKey {
            #expect(TranslationIssue.configuration(in: settings) == .missingAPIKey(provider: "OpenAI"))
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("An Anthropic selection uses its own endpoint and authentication")
    func anthropicConfiguration() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); TranslationURLProtocol.handler = nil }
        var settings = AppSettings()
        settings.translationProvider = .anthropic
        settings.anthropicKey = "fixture-anthropic"
        settings.anthropicModel = .haiku45
        let model = settings.currentModelId
        TranslationURLProtocol.handler = { request in
            #expect(request.url?.host == "api.anthropic.com")
            #expect(request.url?.path == "/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-anthropic")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try TranslationURLProtocol.body(request)
            #expect(body["model"] as? String == model)
            return (200, Data(#"{"content":[{"type":"text","text":"こんにちは"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let translated = try await TranslationService(settings: settings, session: session)
            .translate(text: "Hello", from: .english, to: .japanese)
        #expect(translated == "こんにちは")
    }

    @Test("Provider errors reach the caller instead of becoming an empty successful translation")
    func providerFailure() async {
        let session = session()
        defer { session.invalidateAndCancel(); TranslationURLProtocol.handler = nil }
        var settings = AppSettings()
        settings.translationProvider = .xai
        settings.xaiKey = "fixture-rejected"
        TranslationURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"message":"Invalid credential"}}"#.utf8))
        }
        do {
            _ = try await TranslationService(settings: settings, session: session)
                .translate(text: "Hello", from: .english, to: .portuguese)
            Issue.record("Provider failure must not be reported as success")
        } catch TranslationService.TranslationError.translationFailed(let message) {
            // The person sees what to do; the provider's raw text stays out of the UI.
            #expect(message == AICompletionService.AICompletionError.http(status: 401, detail: nil).localizedDescription)
            #expect(!message.contains("Invalid credential"))
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test("Every API provider requires its own key")
    func configurationIssues() {
        #expect(TranslationIssue.configuration(in: AppSettings(), credentialsAreReady: false) == nil)
        #expect(TranslationIssue.credentialsUnavailable != .missingAPIKey(provider: "OpenAI"))
        for provider in AppSettings.TranslationProvider.allCases {
            var settings = AppSettings()
            settings.translationProvider = provider
            #expect(TranslationIssue.configuration(in: settings) == .missingAPIKey(provider: provider.displayName))
        }
        var settings = AppSettings()
        settings.openAIKey = " \n "
        #expect(TranslationIssue.configuration(in: settings) != nil)
        settings.openAIKey = "fixture-configured"
        #expect(TranslationIssue.configuration(in: settings) == nil)
    }

    @Test("Credential retry clears the access notice even when settings and keys are unchanged")
    func recoveredCredentialAccessClearsStaleNotice() async throws {
        let suite = "TranslationServiceTests.retry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MockSettingsCredentialsStore(record: SettingsCredentialRecord(values: [.openAIKey: "SYNTHETIC_RETRY"]))
        let store = SettingsStore(defaults: defaults, credentials: backend)
        let previous = try await store.settingsForCredentialUse()
        backend.failReads = true
        _ = store.reloadCredentials()
        #expect(!store.credentialsAreReady)
        let failedSettings = store.load()
        #expect(failedSettings == previous)
        let issue = TranslationIssue.credentialsUnavailable
        #expect(issue.afterSettingsReload(settingsChanged: false, credentialsAreReady: store.credentialsAreReady) == issue)
        // Editing an unrelated preference is not proof that credential access recovered.
        #expect(issue.afterSettingsReload(settingsChanged: true, credentialsAreReady: store.credentialsAreReady) == issue)

        backend.failReads = false
        let recoveredSettings = try await store.settingsForCredentialUse()
        #expect(recoveredSettings == previous)
        #expect(issue.afterSettingsReload(settingsChanged: recoveredSettings != previous,
                                         credentialsAreReady: store.credentialsAreReady) == nil)
        // Recovery does not hide an unrelated request failure or repair missing translated text.
        #expect(TranslationIssue.requestFailed.afterSettingsReload(settingsChanged: false,
            credentialsAreReady: store.credentialsAreReady) == .requestFailed)
        let archive = TranslationArchiveNotice.result(drainCompleted: true, translationFailed: true)
        #expect(archive == .translationIncomplete && !archive.shouldClearWorkspace)
    }

    @Test("Saving the original after failed translation preserves the workspace and reports incomplete translation")
    func originalIsPreservedOnFailure() {
        for drainCompleted in [true, false] {
            let notice = TranslationArchiveNotice.result(drainCompleted: drainCompleted, translationFailed: true)
            #expect(notice == .translationIncomplete)
            #expect(!notice.shouldClearWorkspace)
        }
        let success = TranslationArchiveNotice.result(drainCompleted: true, translationFailed: false)
        #expect(success == .complete)
        #expect(success.shouldClearWorkspace)
        #expect(TranslationArchiveNotice.result(drainCompleted: false, translationFailed: false) == .missingTail)
    }
}

private final class TranslationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}

    nonisolated override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    nonisolated static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
