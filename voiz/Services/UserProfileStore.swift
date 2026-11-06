import Foundation
import Combine

/// Device-local identity, kept separate from AppSettings and future authenticated entitlements.
/// Choosing Sync here only records interest: no network, account creation or provider changes.
@MainActor
final class UserProfileStore: ObservableObject {
    static let shared = UserProfileStore()
    static let storageKey = "voiz.user.profile"

    @Published private(set) var profile: VoizUserProfile
    private let defaults: UserDefaults

    var needsOnboarding: Bool { !profile.hasCompletedOnboarding }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(VoizUserProfile.self, from: data) {
            profile = saved
        } else {
            profile = VoizUserProfile()
        }
    }

    func completeOnboarding(name: String, usagePreference: VoizUsagePreference) throws {
        var updated = profile
        updated.displayName = try VoizUserProfile.validatedName(name)
        updated.usagePreference = usagePreference
        updated.onboardingVersion = VoizUserProfile.currentOnboardingVersion
        try save(updated)
    }

    func updateName(_ name: String) throws {
        var updated = profile
        updated.displayName = try VoizUserProfile.validatedName(name)
        try save(updated)
    }

    func updateUsagePreference(_ preference: VoizUsagePreference) throws {
        var updated = profile
        updated.usagePreference = preference
        try save(updated)
    }

    private func save(_ updated: VoizUserProfile) throws {
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.storageKey)
        profile = updated
    }
}
