import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// All fields are public metadata or ciphertext. The enclave blob is hardware-sealed, never a raw key.
nonisolated struct SettingsCredentialEnvelope: Codable {
    let version: Int
    let algorithm: String
    let enclaveKeyBlob: Data
    let peerPublicKey: Data
    let salt: Data
    let sealedRecord: Data
}

/// Explicit Secure Enclave + AES-GCM backend, independent of Data Protection Keychain entitlements.
/// Only this Mac's enclave can restore the P-256 wrapping key. Ed25519 remains inside the envelope.
nonisolated enum SettingsCredentialSealer {
    static let algorithm = "P256-HKDF-SHA256-AES256-GCM"

    static func seal(_ plaintext: Data, namespace: String,
                     existingKeyBlob: Data? = nil) throws -> SettingsCredentialEnvelope {
        guard SecureEnclave.isAvailable else { throw SettingsCredentialError.unavailable }
        let context = LAContext()
        context.interactionNotAllowed = true
        let recipient: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let existingKeyBlob {
            recipient = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: existingKeyBlob, authenticationContext: context
            )
        } else {
            // CryptoKit's default access control is AfterFirstUnlockThisDeviceOnly.
            recipient = try SecureEnclave.P256.KeyAgreement.PrivateKey(authenticationContext: context)
        }
        return try seal(plaintext, namespace: namespace, recipientPublicKey: recipient.publicKey,
                        enclaveKeyBlob: recipient.dataRepresentation)
    }

    static func open(_ envelope: SettingsCredentialEnvelope, namespace: String) throws -> Data {
        try validate(envelope)
        guard SecureEnclave.isAvailable else { throw SettingsCredentialError.unavailable }
        let context = LAContext()
        context.interactionNotAllowed = true
        let recipient = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: envelope.enclaveKeyBlob, authenticationContext: context
        )
        return try open(envelope, namespace: namespace) { peer in
            try recipient.sharedSecretFromKeyAgreement(with: peer)
        }
    }

    /// Crypto primitives have a separate seam for deterministic tests without touching hardware or Keychain.
    static func seal(_ plaintext: Data, namespace: String, recipientPublicKey: P256.KeyAgreement.PublicKey,
                     enclaveKeyBlob: Data) throws -> SettingsCredentialEnvelope {
        guard plaintext.count <= 65_536 else { throw SettingsCredentialError.unavailable }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var salt = Data(count: 32)
        let randomStatus = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw SettingsCredentialError.unavailable }
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let aad = associatedData(namespace: namespace, enclaveKeyBlob: enclaveKeyBlob,
                                 peerPublicKey: ephemeral.publicKey.x963Representation, salt: salt)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: aad, outputByteCount: 32)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw SettingsCredentialError.unavailable }
        return SettingsCredentialEnvelope(version: 1, algorithm: algorithm, enclaveKeyBlob: enclaveKeyBlob,
                                         peerPublicKey: ephemeral.publicKey.x963Representation,
                                         salt: salt, sealedRecord: combined)
    }

    static func open(_ envelope: SettingsCredentialEnvelope, namespace: String,
                     agreement: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> Data {
        try validate(envelope)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.peerPublicKey)
        let secret = try agreement(peer)
        let aad = associatedData(namespace: namespace, enclaveKeyBlob: envelope.enclaveKeyBlob,
                                 peerPublicKey: envelope.peerPublicKey, salt: envelope.salt)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: envelope.salt,
                                                 sharedInfo: aad, outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealedRecord),
                                using: key, authenticating: aad)
    }

    private static func validate(_ envelope: SettingsCredentialEnvelope) throws {
        guard envelope.version == 1, envelope.algorithm == algorithm,
              !envelope.enclaveKeyBlob.isEmpty, envelope.enclaveKeyBlob.count <= 16_384,
              envelope.peerPublicKey.count == 65, envelope.salt.count == 32,
              (28...65_564).contains(envelope.sealedRecord.count) else {
            throw SettingsCredentialError.unavailable
        }
    }

    private static func associatedData(namespace: String, enclaveKeyBlob: Data,
                                       peerPublicKey: Data, salt: Data) -> Data {
        // Preserve the v1 AAD bytes used by existing provider-credential envelopes.
        // The historical label is part of encryption compatibility, not a license gate.
        Data("Voiz License Credentials v1\0".utf8) + Data(namespace.utf8) + Data([0]) +
            Data(SHA256.hash(data: enclaveKeyBlob)) + peerPublicKey + salt
    }
}
