import Foundation

/// Runtime namespace follows the app identity, not DEBUG: production Debug builds and tests
/// keep their established defaults. The Development configuration uses a separate sandbox,
/// so UserDefaults and Application Support stay inside com.rmb.voiz.dev without migration.
nonisolated struct AppEnvironment: Equatable, Sendable {
    static let productionBundleIdentifier = "com.rmb.voiz"
    static let developmentBundleIdentifier = "com.rmb.voiz.dev"
    static let current = AppEnvironment(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        info: Bundle.main.infoDictionary ?? [:]
    )

    let isDevelopment: Bool
    let buildSourcePath: String?
    private let buildBranch: String?
    private let buildCommit: String?
    private let buildIsDirty: Bool

    init(bundleIdentifier: String?, info: [String: Any] = [:]) {
        isDevelopment = bundleIdentifier == Self.developmentBundleIdentifier
        buildBranch = Self.metadataString(info["VoizBuildBranch"])
        buildCommit = Self.metadataString(info["VoizBuildCommit"])
        let path = Self.metadataString(info["VoizBuildSourcePath"])
        buildSourcePath = path?.hasPrefix("/") == true ? path : nil
        let dirty = Self.metadataString(info["VoizBuildDirty"])?.lowercased()
        buildIsDirty = (info["VoizBuildDirty"] as? Bool) == true ||
            ["yes", "true", "1"].contains(dirty ?? "")
    }

    var bundleIdentifier: String {
        isDevelopment ? Self.developmentBundleIdentifier : Self.productionBundleIdentifier
    }

    /// Keychain items are outside the app's sandbox container, so they need their own namespace.
    func keychainService(suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }

    var localMCPPort: UInt16 { isDevelopment ? 39_762 : 39_761 }
    var mcpServerName: String { isDevelopment ? "voiz-dev" : "voiz" }

    var buildSourceDescription: String {
        let revision = buildCommit.map { String($0.prefix(12)) }
        let source = [buildBranch, revision].compactMap { $0 }.joined(separator: " · ")
        let description = source.isEmpty ? (isDevelopment ? "Voiz Dev" : "Voiz") : source
        return description + (buildIsDirty ? " *" : "")
    }

    /// Missing or unexpanded Xcode metadata must not appear as a literal build-setting token.
    private static func metadataString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("$(") else { return nil }
        return clean
    }
}
