import Foundation
import Security

/// Capability usada pelo transporte HTTP local. Fica no Keychain e nunca entra em UserDefaults,
/// URL, logs ou mensagens de erro. Os clientes a enviam em `Authorization: Bearer`.
nonisolated struct MCPCredentialsStore: Sendable {
    static let shared = MCPCredentialsStore(service: AppEnvironment.current.keychainService(suffix: "mcp"))

    /// O account versionado separa definitivamente este backend do antigo `bearer-token`.
    /// Assim, uma capability revogada que tenha ficado no slot anterior nunca volta a valer.
    private static let canonicalAccount = "bearer-token-v2"

    var service: String

    func token() -> String? {
        switch readCanonical() {
        case .value(let existing) where !existing.isEmpty:
            return existing
        case .value:
            return createCanonicalToken()
        case .notFound:
            return createCanonicalToken()
        case .failure:
            // Falha de acesso não significa ausência. Gerar outra capability aqui poderia deixar
            // duas credenciais concorrentes; o servidor deve permanecer fechado.
            return nil
        }
    }

    @discardableResult
    func rotateToken() -> String? {
        guard let generated = generateToken() else { return nil }
        return commitCanonicalToken(generated)
    }

    private func createCanonicalToken() -> String? {
        guard let generated = generateToken() else { return nil }
        guard let data = generated.data(using: .utf8) else { return nil }
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess:
            return readBackExact(generated)
        case errSecDuplicateItem:
            // Outra instância venceu a criação entre o read e o add. Adotar o valor canônico,
            // em vez de sobrescrevê-lo, evita invalidar uma configuração recém-copiada.
            if case .value(let existing) = readCanonical(), !existing.isEmpty {
                return existing
            }
            return nil
        default:
            return nil
        }
    }

    private func commitCanonicalToken(_ proposed: String) -> String? {
        guard !proposed.isEmpty, writeCanonical(proposed) else { return nil }
        return readBackExact(proposed)
    }

    private func readBackExact(_ proposed: String) -> String? {
        guard case .value(let stored) = readCanonical(), stored == proposed else {
            // O write do Security é atômico, mas o valor só é anunciado depois de readback exato.
            // Qualquer estado ambíguo faz o servidor permanecer fechado.
            return nil
        }
        return stored
    }

    private func generateToken() -> String? {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { return nil }
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func writeCanonical(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecSuccess { return true }
        guard added == errSecDuplicateItem else { return false }

        // Outro caller pode ter criado o item entre update e add. Repetir o update mantém a
        // operação idempotente no mesmo slot canônico.
        query.removeValue(forKey: kSecValueData as String)
        query.removeValue(forKey: kSecAttrAccessible as String)
        return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
    }

    private func readCanonical() -> ReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failure(errSecDecode)
            }
            return .value(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failure(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.canonicalAccount
        ]
    }

    private enum ReadResult {
        case value(String)
        case notFound
        case failure(OSStatus)
    }
}
