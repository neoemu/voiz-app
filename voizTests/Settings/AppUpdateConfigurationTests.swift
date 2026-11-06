import Foundation
import Testing

@Suite("Atualizações — canal público e verificação de pacotes")
struct AppUpdateConfigurationTests {
    private var valid: [String: Any] {
        ["VoizUpdatesEnabled": "YES",
         "SUFeedURL": "https://voiz.dev/updates/appcast.xml",
         "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()]
    }

    @Test("Builds locais não consultam o canal público")
    func localBuildDoesNotStartUpdater() {
        var info = valid
        info["VoizUpdatesEnabled"] = "NO"
        #expect(AppUpdateConfiguration(info: info) == nil)
        info.removeValue(forKey: "VoizUpdatesEnabled")
        #expect(AppUpdateConfiguration(info: info) == nil)
    }

    @Test("Canal configurado usa HTTPS e a chave pública Ed25519")
    func officialChannel() throws {
        let config = try #require(AppUpdateConfiguration(info: valid))
        #expect(config.feedURL.absoluteString == "https://voiz.dev/updates/appcast.xml")
        #expect(Data(base64Encoded: config.publicKey)?.count == 32)
    }

    @Test("Rejeita configuração insegura ou incompleta", arguments: [
        "http://voiz.dev/updates/appcast.xml", "file:///tmp/appcast.xml", "",
        "https://user:password@voiz.dev/appcast.xml", "https://voiz.dev/appcast.xml#fragment"
    ])
    func invalidFeeds(_ feed: String) {
        var info = valid
        info["SUFeedURL"] = feed
        #expect(AppUpdateConfiguration(info: info) == nil)
    }

    @Test("Não habilita atualização sem uma chave válida", arguments: ["", "$(VOIZ_UPDATE_PUBLIC_KEY)", "invalid", "YWJj"])
    func invalidKeys(_ key: String) {
        var info = valid
        info["SUPublicEDKey"] = key
        #expect(AppUpdateConfiguration(info: info) == nil)
    }
}
