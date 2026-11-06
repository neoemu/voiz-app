import CryptoKit
import Foundation
import Testing

@Suite("Credenciais — envelope cifrado vinculado ao dispositivo")
struct SettingsCredentialSealerTests {
    private let namespace = "com.rmb.voiz.dev.provider-credentials"

    @Test("Envelope preserva o registro e nunca serializa chaves de provedor em claro")
    func sealedRecordRoundTrip() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let record = SettingsCredentialRecord(values: [.openAIKey: "synthetic-provider-token"])
        let plaintext = try JSONEncoder().encode(record)
        let envelope = try SettingsCredentialSealer.seal(
            plaintext, namespace: namespace, recipientPublicKey: recipient.publicKey,
            enclaveKeyBlob: Data(repeating: 5, count: 64)
        )
        let serialized = try JSONEncoder().encode(envelope)
        #expect(serialized.range(of: Data("synthetic-provider-token".utf8)) == nil)
        let decoded = try JSONDecoder().decode(SettingsCredentialEnvelope.self, from: serialized)
        let opened = try SettingsCredentialSealer.open(decoded, namespace: namespace) {
            try recipient.sharedSecretFromKeyAgreement(with: $0)
        }
        #expect(try JSONDecoder().decode(SettingsCredentialRecord.self, from: opened) == record)
    }

    @Test("Envelope Dev não abre no namespace oficial nem com outra chave")
    func rejectsOtherEnvironmentAndKey() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let other = P256.KeyAgreement.PrivateKey()
        let envelope = try SettingsCredentialSealer.seal(
            Data("record".utf8), namespace: namespace, recipientPublicKey: recipient.publicKey,
            enclaveKeyBlob: Data(repeating: 5, count: 64)
        )
        #expect(throws: (any Error).self) {
            try SettingsCredentialSealer.open(envelope, namespace: "com.rmb.voiz.provider-credentials") {
                try recipient.sharedSecretFromKeyAgreement(with: $0)
            }
        }
        #expect(throws: (any Error).self) {
            try SettingsCredentialSealer.open(envelope, namespace: namespace) {
                try other.sharedSecretFromKeyAgreement(with: $0)
            }
        }
    }

    @Test("Alterações em ciphertext, salt, peer ou blob selado são recusadas",
          arguments: ["sealedRecord", "salt", "peerPublicKey", "enclaveKeyBlob"])
    func tamperingIsRejected(field: String) throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let envelope = try SettingsCredentialSealer.seal(
            Data("record".utf8), namespace: namespace, recipientPublicKey: recipient.publicKey,
            enclaveKeyBlob: Data(repeating: 5, count: 64)
        )
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let encodedField = try #require(fields[field] as? String)
        var data = try #require(Data(base64Encoded: encodedField))
        data[data.count - 1] ^= 1
        fields[field] = data.base64EncodedString()
        let damaged = try JSONDecoder().decode(SettingsCredentialEnvelope.self,
                                               from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) {
            try SettingsCredentialSealer.open(damaged, namespace: namespace) {
                try recipient.sharedSecretFromKeyAgreement(with: $0)
            }
        }
    }

    @Test("Formato desconhecido falha antes de consultar a chave")
    func unknownFormatIsRejectedBeforeKeyUse() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let original = try SettingsCredentialSealer.seal(
            Data("record".utf8), namespace: namespace, recipientPublicKey: recipient.publicKey,
            enclaveKeyBlob: Data(repeating: 5, count: 64)
        )
        let unknown = SettingsCredentialEnvelope(
            version: 2, algorithm: original.algorithm, enclaveKeyBlob: original.enclaveKeyBlob,
            peerPublicKey: original.peerPublicKey, salt: original.salt, sealedRecord: original.sealedRecord
        )
        var usedKey = false
        #expect(throws: SettingsCredentialError.unavailable) {
            try SettingsCredentialSealer.open(unknown, namespace: namespace) {
                usedKey = true
                return try recipient.sharedSecretFromKeyAgreement(with: $0)
            }
        }
        #expect(!usedKey)
    }

    @Test("Gravar o mesmo registro usa novo material efêmero e nonce")
    func repeatedSealsAreDistinct() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let blob = Data(repeating: 5, count: 64)
        let first = try SettingsCredentialSealer.seal(
            Data("record".utf8), namespace: namespace, recipientPublicKey: recipient.publicKey, enclaveKeyBlob: blob
        )
        let second = try SettingsCredentialSealer.seal(
            Data("record".utf8), namespace: namespace, recipientPublicKey: recipient.publicKey, enclaveKeyBlob: blob
        )
        #expect(first.peerPublicKey != second.peerPublicKey)
        #expect(first.salt != second.salt)
        #expect(first.sealedRecord != second.sealedRecord)
    }
}
