import Foundation

/// A preference captured locally, never a license, subscription or permission to upload.
enum VoizUsagePreference: String, Codable, CaseIterable {
    case local
    case syncInterest
}

struct VoizUserProfile: Codable, Equatable {
    static let currentOnboardingVersion = 1
    static let maximumNameLength = 80

    var displayName: String = ""
    var usagePreference: VoizUsagePreference = .local
    var onboardingVersion: Int = 0

    var hasCompletedOnboarding: Bool {
        onboardingVersion >= Self.currentOnboardingVersion &&
        (try? Self.validatedName(displayName)) != nil
    }

    /// Preserve Unicode names while rejecting empty/control-only input and normalizing spacing.
    static func validatedName(_ input: String) throws -> String {
        let name = input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty,
              name.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) &&
                  !CharacterSet.illegalCharacters.contains($0) && $0.properties.generalCategory != .format }) else {
            throw UserProfileError.emptyName
        }
        guard name.count <= maximumNameLength else { throw UserProfileError.nameTooLong }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) ||
            CharacterSet.illegalCharacters.contains($0) }) else { throw UserProfileError.invalidName }
        return name
    }

    init(displayName: String = "", usagePreference: VoizUsagePreference = .local, onboardingVersion: Int = 0) {
        self.displayName = displayName
        self.usagePreference = usagePreference
        self.onboardingVersion = onboardingVersion
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, usagePreference, onboardingVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        let preference = try values.decodeIfPresent(String.self, forKey: .usagePreference)
        usagePreference = preference.flatMap(VoizUsagePreference.init(rawValue:)) ?? .local
        onboardingVersion = try values.decodeIfPresent(Int.self, forKey: .onboardingVersion) ?? 0
    }
}

enum UserProfileError: LocalizedError {
    case emptyName, nameTooLong, invalidName

    var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "Digite seu nome para continuar.")
        case .nameTooLong: return String(localized: "Use até 80 caracteres no nome.")
        case .invalidName: return String(localized: "O nome contém caracteres inválidos.")
        }
    }
}
