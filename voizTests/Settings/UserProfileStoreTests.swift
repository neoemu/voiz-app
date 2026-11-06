import Foundation
import Testing

@Suite("Perfil local e onboarding")
@MainActor
struct UserProfileStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "voiz.profile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("Instalação nova começa local e ainda requer nome e tour")
    func freshInstall() throws {
        try withDefaults { defaults in
            let store = UserProfileStore(defaults: defaults)
            #expect(store.needsOnboarding)
            #expect(store.profile.usagePreference == .local)
            #expect(defaults.data(forKey: UserProfileStore.storageKey) == nil)
        }
    }

    @Test("Concluir persiste nome Unicode normalizado e interesse sem ativar serviços")
    func completeAndReopen() throws {
        try withDefaults { defaults in
            let store = UserProfileStore(defaults: defaults)
            try store.completeOnboarding(name: "  João   山田  ", usagePreference: .syncInterest)
            let reopened = UserProfileStore(defaults: defaults)
            #expect(!reopened.needsOnboarding)
            #expect(reopened.profile.displayName == "João 山田")
            #expect(reopened.profile.usagePreference == .syncInterest)
        }
    }

    @Test("Nome inválido não conclui nem sobrescreve o perfil", arguments: ["", " \n\t", "\u{200B}", "A\u{0000}B", String(repeating: "a", count: 81)])
    func rejectInvalidName(name: String) throws {
        try withDefaults { defaults in
            let store = UserProfileStore(defaults: defaults)
            #expect(throws: UserProfileError.self) {
                try store.completeOnboarding(name: name, usagePreference: .syncInterest)
            }
            #expect(store.needsOnboarding)
            #expect(store.profile == VoizUserProfile())
            #expect(defaults.data(forKey: UserProfileStore.storageKey) == nil)
        }
    }

    @Test("Edição inválida preserva perfil concluído")
    func invalidEditPreservesProfile() throws {
        try withDefaults { defaults in
            let store = UserProfileStore(defaults: defaults)
            try store.completeOnboarding(name: "Renata", usagePreference: .local)
            #expect(throws: UserProfileError.self) { try store.updateName("  ") }
            #expect(UserProfileStore(defaults: defaults).profile.displayName == "Renata")
            #expect(!store.needsOnboarding)
        }
    }

    @Test("Perfil e preferências não alteram provedores, chaves e outras configurações")
    func preservesExistingSettings() throws {
        try withDefaults { defaults in
            let existing = Data("existing settings bytes".utf8)
            defaults.set(existing, forKey: "voiz.app.settings")
            let store = UserProfileStore(defaults: defaults)
            try store.completeOnboarding(name: "Maria", usagePreference: .local)
            try store.updateUsagePreference(.syncInterest)
            try store.updateName("Maria Silva")
            #expect(defaults.data(forKey: "voiz.app.settings") == existing)
            let reopened = UserProfileStore(defaults: defaults)
            #expect(reopened.profile.displayName == "Maria Silva")
            #expect(reopened.profile.usagePreference == .syncInterest)
            #expect(!reopened.needsOnboarding)
        }
    }

    @Test("Perfil legado sem versão requer onboarding e preserva nome")
    func legacyProfile() throws {
        let profile = try JSONDecoder().decode(VoizUserProfile.self, from: Data(#"{"displayName":"Ana"}"#.utf8))
        #expect(profile.displayName == "Ana")
        #expect(profile.usagePreference == .local)
        #expect(!profile.hasCompletedOnboarding)
    }

    @Test("Preferência futura desconhecida volta ao local sem apagar nome")
    func futurePreference() throws {
        let profile = try JSONDecoder().decode(VoizUserProfile.self, from: Data(#"{"displayName":"Ana","usagePreference":"team","onboardingVersion":1}"#.utf8))
        #expect(profile.displayName == "Ana")
        #expect(profile.usagePreference == .local)
        #expect(profile.hasCompletedOnboarding)
    }

    @Test("Dados corrompidos não marcam onboarding como concluído nem são apagados ao ler")
    func corruptedProfile() throws {
        try withDefaults { defaults in
            let invalid = Data("not json".utf8)
            defaults.set(invalid, forKey: UserProfileStore.storageKey)
            #expect(UserProfileStore(defaults: defaults).needsOnboarding)
            #expect(defaults.data(forKey: UserProfileStore.storageKey) == invalid)
        }
    }
}
