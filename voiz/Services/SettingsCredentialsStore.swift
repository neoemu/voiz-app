import Foundation
import Security
import LocalAuthentication

nonisolated enum SettingsCredentialField: String, CaseIterable, Sendable {
    case openAIKey, anthropicKey, xaiKey, geminiKey, customKey
}

nonisolated enum SettingsCredentialError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? {
        String(localized: "Não foi possível acessar as chaves de API. Tente novamente em Configurações → IA & Tradução.")
    }
}

/// One complete record makes migration atomic; empty values are intentional removals,
/// not missing entries that a stale legacy snapshot may resurrect.
nonisolated struct SettingsCredentialRecord: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var values: [String: String]

    init(values: [SettingsCredentialField: String] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: SettingsCredentialField.allCases.map {
            ($0.rawValue, values[$0] ?? "")
        })
    }

    func validate() throws {
        guard schemaVersion == 1,
              Set(values.keys) == Set(SettingsCredentialField.allCases.map(\.rawValue)) else {
            throw SettingsCredentialError.unavailable
        }
    }
}

nonisolated protocol SettingsCredentialsPersisting: Sendable {
    func read() throws -> SettingsCredentialRecord?
    func write(_ record: SettingsCredentialRecord) throws
}

/// Login-Keychain ciphertext sealed to this Mac's Secure Enclave. Reuses the reviewed
/// local envelope implementation, with a separate authenticated namespace and item.
/// This works with Voiz Dev signing without Data Protection Keychain entitlements.
nonisolated struct SettingsCredentialsStore: SettingsCredentialsPersisting {
    let service: String
    private let isProbe: Bool

    init(environment: AppEnvironment = .current) {
        service = environment.keychainService(suffix: "provider-credentials")
        isProbe = false
    }

    #if DEBUG
    init(probeID: UUID) throws {
        guard AppEnvironment.current.isDevelopment else { throw SettingsCredentialError.unavailable }
        service = AppEnvironment.current.keychainService(suffix: "provider-probe." + probeID.uuidString.lowercased())
        isProbe = true
    }

    func deleteProbeOnly() throws {
        guard isProbe, AppEnvironment.current.isDevelopment else { throw SettingsCredentialError.unavailable }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsCredentialError.unavailable }
    }
    #endif

    var baseQuery: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "providers-se-v1",
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> SettingsCredentialRecord? {
        do {
            guard let envelope = try readEnvelope() else { return nil }
            return try open(envelope)
        } catch { throw SettingsCredentialError.unavailable }
    }

    func write(_ record: SettingsCredentialRecord) throws {
        do {
            try record.validate()
            let existing = try readEnvelope()
            // Never overwrite an inaccessible, corrupt or transplanted envelope.
            if let existing { _ = try open(existing) }
            let envelope = try SettingsCredentialSealer.seal(JSONEncoder().encode(record), namespace: service,
                                                           existingKeyBlob: existing?.enclaveKeyBlob)
            let data = try JSONEncoder().encode(envelope)
            let update = [kSecValueData as String: data]
            var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var query = baseQuery
                query[kSecValueData as String] = data
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw SettingsCredentialError.unavailable }
        } catch { throw SettingsCredentialError.unavailable }
    }

    private func readEnvelope() throws -> SettingsCredentialEnvelope? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 131_072 else {
            throw SettingsCredentialError.unavailable
        }
        return try JSONDecoder().decode(SettingsCredentialEnvelope.self, from: data)
    }

    private func open(_ envelope: SettingsCredentialEnvelope) throws -> SettingsCredentialRecord {
        let data = try SettingsCredentialSealer.open(envelope, namespace: service)
        let record = try JSONDecoder().decode(SettingsCredentialRecord.self, from: data)
        try record.validate()
        return record
    }
}
