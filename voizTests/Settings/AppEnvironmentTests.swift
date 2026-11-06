import Foundation
import Testing

@Suite("Ambiente — isolamento do Voiz Dev")
struct AppEnvironmentTests {
    private var production: AppEnvironment {
        AppEnvironment(bundleIdentifier: "com.rmb.voiz")
    }

    private var development: AppEnvironment {
        AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev")
    }

    @Test("App oficial preserva credenciais, porta e nome da integração existentes")
    func preservesProductionNamespace() {
        #expect(!production.isDevelopment)
        #expect(production.bundleIdentifier == "com.rmb.voiz")
        #expect(production.keychainService(suffix: "notion") == "com.rmb.voiz.notion")
        #expect(production.keychainService(suffix: "mcp") == "com.rmb.voiz.mcp")
        #expect(production.localMCPPort == 39_761)
        #expect(production.mcpServerName == "voiz")
    }

    @Test("Dev não reutiliza Keychain, porta ou cadastro MCP do app oficial")
    func isolatesDevelopmentNamespace() {
        #expect(development.isDevelopment)
        #expect(development.bundleIdentifier == "com.rmb.voiz.dev")
        #expect(development.keychainService(suffix: "notion") == "com.rmb.voiz.dev.notion")
        #expect(development.keychainService(suffix: "mcp") == "com.rmb.voiz.dev.mcp")
        #expect(development.localMCPPort == 39_762)
        #expect(development.localMCPPort != production.localMCPPort)
        #expect(development.mcpServerName == "voiz-dev")
        #expect(development.mcpServerName != production.mcpServerName)
    }

    @Test("Somente a identidade Dev explícita muda o ambiente",
          arguments: [nil, "com.rmb.voizTests", "com.rmb.voiz.developer", "com.rmb.voiz.dev.helper"] as [String?])
    func exactDevelopmentIdentity(_ identifier: String?) {
        #expect(!AppEnvironment(bundleIdentifier: identifier).isDevelopment)
    }

    @Test("Instalação Dev não compete por atalhos nem detecta reuniões automaticamente")
    func developmentStartsWithoutGlobalAutomation() {
        let settings = AppSettings(environment: development)
        #expect(!settings.dictationHotkeysEnabled)
        #expect(!settings.meetingDetectionEnabled)
        #expect(!settings.calendarSuggestionsEnabled)
        #expect(settings.openAIKey.isEmpty)
        #expect(settings.anthropicKey.isEmpty)
        #expect(settings.customKey.isEmpty)

        let official = AppSettings(environment: production)
        #expect(official.dictationHotkeysEnabled)
        #expect(official.meetingDetectionEnabled)
    }

    @Test("Opt-in dos atalhos e detecção no Dev sobrevive à persistência")
    func developmentOptInIsPersisted() throws {
        var settings = AppSettings(environment: development)
        settings.dictationHotkeysEnabled = true
        settings.meetingDetectionEnabled = true

        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(reopened == settings)
        #expect(reopened.dictationHotkeysEnabled)
        #expect(reopened.meetingDetectionEnabled)
    }

    @Test("Escolha desligada permanece desligada ao reabrir")
    func disabledChoicesArePersisted() throws {
        let settings = AppSettings(environment: development)
        let reopened = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!reopened.dictationHotkeysEnabled)
        #expect(!reopened.meetingDetectionEnabled)
    }

    @Test("Settings sem os campos novos usam os defaults do ambiente atual")
    func missingFieldsUseRuntimeDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        let fresh = AppSettings(environment: .current)
        #expect(decoded.dictationHotkeysEnabled == fresh.dictationHotkeysEnabled)
        #expect(decoded.meetingDetectionEnabled == fresh.meetingDetectionEnabled)
    }

    @Test("Origem do build identifica branch, revisão, modificações e worktree")
    func buildProvenance() {
        let environment = AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev", info: [
            "VoizBuildBranch": " codex/profile ",
            "VoizBuildCommit": "1234567890abcdef",
            "VoizBuildDirty": "YES",
            "VoizBuildSourcePath": "/Users/test/Voiz Development"
        ])
        #expect(environment.buildSourceDescription == "codex/profile · 1234567890ab *")
        #expect(environment.buildSourcePath == "/Users/test/Voiz Development")
    }

    @Test("Metadados ausentes ou não expandidos não viram caminhos ou textos na UI")
    func unavailableBuildProvenance() {
        let environment = AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev", info: [
            "VoizBuildBranch": "$(VOIZ_BUILD_BRANCH)",
            "VoizBuildCommit": " ",
            "VoizBuildDirty": "$(VOIZ_BUILD_DIRTY)",
            "VoizBuildSourcePath": "$(VOIZ_BUILD_SOURCE_PATH)"
        ])
        #expect(environment.buildSourceDescription == "Voiz Dev")
        #expect(environment.buildSourcePath == nil)
        #expect(AppEnvironment(bundleIdentifier: nil).buildSourceDescription == "Voiz")

        let relative = AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev", info: [
            "VoizBuildSourcePath": "relative/worktree"
        ])
        #expect(relative.buildSourcePath == nil)
    }

    @Test("Build limpo não recebe marca de modificações")
    func cleanBuildProvenance() {
        let environment = AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev", info: [
            "VoizBuildCommit": "1234567890abcdef",
            "VoizBuildDirty": "NO"
        ])
        #expect(environment.buildSourceDescription == "1234567890ab")
    }
}
