import Foundation
import Testing

@MainActor
@Suite("IA — migração do provedor removido")
struct AIProviderMigrationTests {
    @Test("Preferências antigas preservam todos os campos e migram para API")
    func legacySettingsPreservePreferences() throws {
        var expected = AppSettings.fullyCustomizedForTests
        expected.translationProvider = .openai
        let data = try JSONEncoder().encode(expected)
        var raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw["translationProvider"] = "chatgpt"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(decoded == expected)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(saved["translationProvider"] as? String == "openai")
    }

    @Test("Escolha antiga do Chat preserva modelo e exige uma chave própria")
    func legacyChatChoiceRequiresAPIKey() throws {
        let data = Data(#"{"provider":"chatgpt","modelId":"gpt-5.6-sol"}"#.utf8)
        let choice = try JSONDecoder().decode(AppSettings.ModelChoice.self, from: data)
        #expect(choice == AppSettings.ModelChoice(provider: .openai, modelId: "gpt-5.6-sol"))
        var settings = AppSettings()
        #expect(!settings.isUsable(choice))
        #expect(settings.configuredProviders.isEmpty)
        settings.openAIKey = "fixture-api-key"
        #expect(settings.isUsable(choice))
        #expect(settings.configuredProviders == [.openai])
    }

    @Test("Atualização sem API key bloqueia chamadas normais e streaming")
    func migratedProviderCannotReuseSubscription() async throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"translationProvider":"chatgpt"}"#.utf8))
        let service = AICompletionService()
        service.apply(settings)
        do {
            _ = try await service.complete(prompt: "Teste")
            Issue.record("A chamada sem chave deve falhar")
        } catch AICompletionService.AICompletionError.missingAPIKey {
        }
        do {
            for try await _ in service.completeStream(messages: [.init(role: "user", content: "Teste")]) {
                Issue.record("Não deve produzir texto sem chave")
            }
            Issue.record("O streaming sem chave deve falhar")
        } catch AICompletionService.AICompletionError.missingAPIKey {
        }
    }

    @Test("Provedores atuais continuam compatíveis com preferências salvas", arguments: AppSettings.TranslationProvider.allCases)
    func currentProvidersRoundTrip(_ provider: AppSettings.TranslationProvider) throws {
        let decoded = try JSONDecoder().decode(AppSettings.TranslationProvider.self, from: JSONEncoder().encode(provider))
        #expect(decoded == provider)
        #expect(provider.requiresAPIKey)
    }
}
