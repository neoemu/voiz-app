#if DEBUG
import CryptoKit
import Darwin
import Foundation
import Security

/// Explicit Dev-only storage round trip. Never opens the regular credential namespace,
/// preferences, licenses or network; only synthetic values in one UUID-scoped item.
@MainActor
enum SettingsCredentialsProbe {
    private static let queue = DispatchQueue(label: "com.voiz.settings.storage-probe", qos: .userInitiated)

    nonisolated private struct Result: Sendable {
        var restored = false
        var cleared = false
        var removed = false
        var failedStage: String?
        var passed: Bool { restored && cleared && removed && failedStage == nil }
    }

    static func run() async {
        guard AppEnvironment.current.isDevelopment else {
            emit(["status": "wrongEnvironment"])
            exit(2)
        }
        let result: Result = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: exercise()) }
        }
        emit(["status": "providerCredentialsStorageProbe",
              "secureEnclaveAvailable": SecureEnclave.isAvailable,
              "roundTrip": result.passed, "restored": result.restored,
              "cleared": result.cleared, "removed": result.removed,
              "failedStage": result.failedStage.map { $0 as Any } ?? NSNull()])
        exit(result.passed ? 0 : 1)
    }

    nonisolated private static func exercise() -> Result {
        var storage: SettingsCredentialsStore?
        var result = Result()
        var stage = "initialize"
        do {
            let probe = try SettingsCredentialsStore(probeID: UUID())
            storage = probe
            stage = "initialRead"
            guard try probe.read() == nil else { throw SettingsCredentialError.unavailable }
            var expected = SettingsCredentialRecord(values: Dictionary(uniqueKeysWithValues:
                SettingsCredentialField.allCases.map { ($0, "SYNTHETIC_STORAGE_PROBE_" + $0.rawValue) }))
            stage = "write"
            try probe.write(expected)
            stage = "verifyWrite"
            guard try probe.read() == expected else { throw SettingsCredentialError.unavailable }
            result.restored = true
            expected.values[SettingsCredentialField.openAIKey.rawValue] = ""
            stage = "clearField"
            try probe.write(expected)
            stage = "verifyClear"
            guard try probe.read() == expected else { throw SettingsCredentialError.unavailable }
            result.cleared = true
        } catch {
            // Only a fixed operation category is reported, never an error description or payload.
            result.failedStage = stage
        }
        // Always attempt cleanup of this probe item, even after a partial write or failed readback.
        if let storage {
            do {
                try storage.deleteProbeOnly()
                result.removed = try storage.read() == nil
                if !result.removed { result.failedStage = "verifyRemoval" }
            } catch {
                result.failedStage = "cleanup"
            }
        }
        return result
    }

    private static func emit(_ result: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }
}

#endif
