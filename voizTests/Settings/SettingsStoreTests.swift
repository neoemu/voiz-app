import Foundation
import Security
import LocalAuthentication
import Testing

/// All persistence tests use this in-memory backend, never the user's Keychain.
nonisolated final class MockSettingsCredentialsStore: SettingsCredentialsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    var record: SettingsCredentialRecord?
    var failReads = false
    var failWrites = false
    var failWriteNumber: Int?
    var failVerification = false
    var mismatchVerification = false
    private(set) var readCount = 0
    private(set) var writeCount = 0

    init(record: SettingsCredentialRecord? = nil) { self.record = record }

    func read() throws -> SettingsCredentialRecord? {
        try lock.withLock {
            readCount += 1
            if failReads || (failVerification && writeCount > 0) { throw SettingsCredentialError.unavailable }
            if mismatchVerification && writeCount > 0 { return SettingsCredentialRecord() }
            return record
        }
    }

    func write(_ record: SettingsCredentialRecord) throws {
        try lock.withLock {
            writeCount += 1
            if failWrites || writeCount == failWriteNumber { throw SettingsCredentialError.unavailable }
            self.record = record
        }
    }
}

/// Blocks only the storage worker, with an async signal for deterministic cold-start tests.
nonisolated private final class DelayedSettingsCredentialsStore: SettingsCredentialsPersisting, @unchecked Sendable {
    let reads: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    let release = DispatchSemaphore(value: 0)

    init() { (reads, started) = AsyncStream<Void>.makeStream() }

    func read() throws -> SettingsCredentialRecord? {
        started.yield(())
        guard release.wait(timeout: .now() + 10) == .success else { throw SettingsCredentialError.unavailable }
        return SettingsCredentialRecord(values: [.openAIKey: "SYNTHETIC_DELAYED"])
    }

    func write(_ record: SettingsCredentialRecord) throws { throw SettingsCredentialError.unavailable }
}

@Suite("SettingsStore — migração privada e gravação explícita de credenciais")
struct SettingsStoreTests {
    @Test("Cold consumers await the vault; cancellation prevents dispatch after the read", arguments: [false, true])
    @concurrent
    nonisolated func credentialConsumerWaitsForStorage(cancel: Bool) async throws {
        let suite = "voiz-tests-consumer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = DelayedSettingsCredentialsStore()
        let store = SettingsStore(defaults: defaults, credentials: backend)
        let request = Task.detached { try await store.settingsForCredentialUse() }
        var starts = backend.reads.makeAsyncIterator()
        await starts.next()
        #expect(!store.credentialsAreReady)
        #expect(store.load().openAIKey.isEmpty) // UI remains nonblocking while storage waits.
        var preferences = AppSettings()
        preferences.translationProvider = .anthropic
        #expect(store.save(preferences))
        if cancel { request.cancel() }
        backend.release.signal()
        if cancel {
            do { _ = try await request.value; Issue.record("Canceled request admitted") }
            catch { #expect(error is CancellationError) }
        } else {
            let settings = try await request.value
            #expect(settings.openAIKey == "SYNTHETIC_DELAYED")
            #expect(settings.translationProvider == .anthropic)
        }
    }

    @Test("Consumer rejects unavailable cached credentials, then retries; empty vault is distinct")
    func credentialConsumerFailureAndRetry() async throws {
        let suite = "voiz-tests-consumer-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MockSettingsCredentialsStore(record: legacyRecord)
        let store = SettingsStore(defaults: defaults, credentials: backend)
        #expect(credentialValues(try await store.settingsForCredentialUse()) == legacyRecord.values)
        let reads = backend.readCount
        _ = try await store.settingsForCredentialUse()
        #expect(backend.readCount == reads)
        backend.failReads = true
        _ = store.reloadCredentials()
        do { _ = try await store.settingsForCredentialUse(); Issue.record("Stale cache admitted") }
        catch { #expect(error is SettingsCredentialError) }
        backend.failReads = false
        backend.record = SettingsCredentialRecord(values: [.openAIKey: "SYNTHETIC_RETRY"])
        #expect(try await store.settingsForCredentialUse().openAIKey == "SYNTHETIC_RETRY")
        let empty = SettingsStore(defaults: defaults, credentials: MockSettingsCredentialsStore())
        #expect(try await empty.settingsForCredentialUse().openAIKey.isEmpty)
        #expect(empty.credentialsAreReady)
    }

    private func legacyData() throws -> Data {
        let data = try JSONEncoder().encode(AppSettings.fullyCustomizedForTests)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in SettingsCredentialField.allCases { object[field.rawValue] = "SYNTHETIC_LEGACY_" + field.rawValue }
        object["futureLocalPreference"] = ["preserve": true]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private var legacyRecord: SettingsCredentialRecord {
        SettingsCredentialRecord(values: Dictionary(uniqueKeysWithValues: SettingsCredentialField.allCases.map {
            ($0, "SYNTHETIC_LEGACY_" + $0.rawValue)
        }))
    }

    private func credentialValues(_ settings: AppSettings) -> [String: String] {
        ["openAIKey": settings.openAIKey, "anthropicKey": settings.anthropicKey,
         "xaiKey": settings.xaiKey, "geminiKey": settings.geminiKey, "customKey": settings.customKey]
    }

    private func assertSanitized(_ data: Data) throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in SettingsCredentialField.allCases { #expect(object[field.rawValue] == nil) }
        #expect(!String(decoding: data, as: UTF8.self).contains("SYNTHETIC_"))
    }

    @Test("Cinco chaves migradas são verificadas antes de remover os campos legados")
    func verifiedMigrationPreservesPreferences() throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = try legacyData()
        defaults.set(raw, forKey: SettingsStore.legacyKey)
        let credentials = MockSettingsCredentialsStore()
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        let settings = store.reloadCredentials()
        #expect(credentialValues(settings) == legacyRecord.values)
        #expect(credentials.record == legacyRecord)
        #expect(credentials.readCount >= 2)
        #expect(credentials.writeCount == 1)
        #expect(store.credentialError == nil)
        let sanitized = try #require(defaults.data(forKey: SettingsStore.legacyKey))
        try assertSanitized(sanitized)
        var expected = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        for field in SettingsCredentialField.allCases { expected.removeValue(forKey: field.rawValue) }
        let actual = try #require(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        #expect(settings.customBaseURL == AppSettings.fullyCustomizedForTests.customBaseURL)
        #expect(settings.calendarSelection == AppSettings.fullyCustomizedForTests.calendarSelection)

        let reopened = SettingsStore(defaults: defaults, credentials: credentials).reloadCredentials()
        #expect(reopened == settings)
        #expect(credentials.writeCount == 1)
    }

    @Test("Falhas mantêm cópia legada exata e permitem salvar preferências sem segredos",
          arguments: ["read", "write", "verification", "mismatch"])
    func failedMigrationRetainsRecoveryAndCanRetry(failure: String) throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = try legacyData()
        defaults.set(raw, forKey: SettingsStore.legacyKey)
        let credentials = MockSettingsCredentialsStore()
        credentials.failReads = failure == "read"
        credentials.failWrites = failure == "write"
        credentials.failVerification = failure == "verification"
        credentials.mismatchVerification = failure == "mismatch"
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        var settings = store.reloadCredentials()
        #expect(store.credentialError != nil)
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
        #expect(credentialValues(settings) == legacyRecord.values)
        settings.appearance = .system
        settings.interfaceLanguage = .french
        settings.openAIKey = "SYNTHETIC_UNAUTHORIZED_GENERAL_SAVE"
        #expect(store.save(settings))
        try assertSanitized(#require(defaults.data(forKey: SettingsStore.preferencesKey)))
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)

        credentials.failReads = false
        credentials.failWrites = false
        credentials.failVerification = false
        credentials.mismatchVerification = false
        let restarted = SettingsStore(defaults: defaults, credentials: credentials)
        let restored = restarted.reloadCredentials()
        #expect(restored.appearance == .system)
        #expect(restored.interfaceLanguage == .french)
        #expect(credentialValues(restored) == legacyRecord.values)
        #expect(restarted.credentialError == nil)
        try assertSanitized(#require(defaults.data(forKey: SettingsStore.legacyKey)))
    }

    @Test("Registro existente inclusive vazio prevalece sobre cópia legada obsoleta")
    func existingRecordWinsIncludingDeletion() throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try legacyData(), forKey: SettingsStore.legacyKey)
        let existing = SettingsCredentialRecord(values: [.anthropicKey: "SYNTHETIC_NEW_ANTHROPIC"])
        let credentials = MockSettingsCredentialsStore(record: existing)
        let settings = SettingsStore(defaults: defaults, credentials: credentials).reloadCredentials()
        #expect(credentialValues(settings) == existing.values)
        #expect(settings.openAIKey.isEmpty)
        #expect(credentials.writeCount == 0)
        try assertSanitized(#require(defaults.data(forKey: SettingsStore.legacyKey)))
    }

    @Test("Alteração e exclusão explícitas persistem; save geral obsoleto não sobrescreve chaves")
    func explicitCredentialChangesSurviveStaleSaveAndRestart() throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MockSettingsCredentialsStore(record: legacyRecord)
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        var stale = store.reloadCredentials()
        for field in SettingsCredentialField.allCases {
            try store.setCredential(field, value: "SYNTHETIC_UPDATED_" + field.rawValue)
        }
        try store.setCredential(.customKey, value: "")
        let record = try #require(credentials.record)
        #expect(record.values["customKey"] == "")
        #expect(record.values["geminiKey"] == "SYNTHETIC_UPDATED_geminiKey")
        stale.appearance = .light
        stale.openAIKey = "SYNTHETIC_STALE"
        #expect(store.save(stale))
        #expect(credentials.record == record)
        try assertSanitized(#require(defaults.data(forKey: SettingsStore.preferencesKey)))
        let restarted = SettingsStore(defaults: defaults, credentials: credentials).reloadCredentials()
        #expect(credentialValues(restarted) == record.values)
        #expect(restarted.appearance == .light)
    }

    @Test("Load e save gerais não fazem I/O no Keychain")
    func ordinaryPreferencesNeverReadCredentialBackend() throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MockSettingsCredentialsStore(record: legacyRecord)
        credentials.failReads = true
        credentials.failWrites = true
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        var settings = store.load()
        settings.showConfidence = false
        #expect(store.save(settings))
        #expect(store.load().showConfidence == false)
        #expect(credentials.readCount == 0)
        #expect(credentials.writeCount == 0)
    }

    @Test("Falha na edição depois da primeira migração preserva as credenciais verificadas")
    func failedFirstEditKeepsMigratedSnapshot() throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try legacyData(), forKey: SettingsStore.legacyKey)
        let credentials = MockSettingsCredentialsStore()
        credentials.failWriteNumber = 2 // Migration commits; the explicit field edit fails.
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        #expect(throws: SettingsCredentialError.self) {
            try store.setCredential(.openAIKey, value: "SYNTHETIC_FAILED_EDIT")
        }
        #expect(credentials.record == legacyRecord)
        try assertSanitized(#require(defaults.data(forKey: SettingsStore.legacyKey)))
        #expect(credentialValues(store.load()) == legacyRecord.values)
        #expect(store.credentialError != nil)
        credentials.failWriteNumber = nil
        try store.setCredential(.openAIKey, value: "SYNTHETIC_RETRY")
        #expect(store.load().openAIKey == "SYNTHETIC_RETRY")
        #expect(store.credentialError == nil)
    }

    @Test("Erro de leitura ou edição não substitui o último snapshot confirmado")
    func failuresPreserveConfirmedMemorySnapshot() throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MockSettingsCredentialsStore(record: legacyRecord)
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        let original = store.reloadCredentials()
        credentials.failReads = true
        #expect(credentialValues(store.reloadCredentials()) == credentialValues(original))
        #expect(store.credentialError != nil)
        credentials.failReads = false
        credentials.failWrites = true
        #expect(throws: SettingsCredentialError.self) {
            try store.setCredential(.geminiKey, value: "SYNTHETIC_FAILED_EDIT")
        }
        #expect(credentialValues(store.load()) == credentialValues(original))
        credentials.failWrites = false
        _ = store.reloadCredentials()
        #expect(store.credentialError == nil)
    }

    @Test("Registros incompletos ou desconhecidos não apagam a recuperação legada",
          arguments: ["version", "missing", "extra"])
    func malformedCredentialRecordIsNotAbsence(corruption: String) throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = try legacyData()
        defaults.set(raw, forKey: SettingsStore.legacyKey)
        var invalid = legacyRecord
        switch corruption {
        case "version": invalid.schemaVersion = 2
        case "missing": invalid.values.removeValue(forKey: "openAIKey")
        default: invalid.values["unexpected"] = "SYNTHETIC_EXTRA"
        }
        #expect(throws: SettingsCredentialError.self) { try invalid.validate() }
        let credentials = MockSettingsCredentialsStore(record: invalid)
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        _ = store.reloadCredentials()
        #expect(store.credentialError != nil)
        #expect(credentials.writeCount == 0)
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
        #expect(throws: SettingsCredentialError.self) { try store.setCredential(.openAIKey, value: "replacement") }
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
        #expect(credentials.writeCount == 0)
    }

    @Test("Namespaces separados e política local não sincronizável são inspecionáveis sem Keychain")
    func keychainPolicyAndNamespaces() {
        let dev = SettingsCredentialsStore(environment: AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev"))
        let production = SettingsCredentialsStore(environment: AppEnvironment(bundleIdentifier: "com.rmb.voiz"))
        #expect(dev.service == "com.rmb.voiz.dev.provider-credentials")
        #expect(production.service == "com.rmb.voiz.provider-credentials")
        for store in [dev, production] {
            let query = store.baseQuery
            #expect(query[kSecAttrService as String] as? String == store.service)
            #expect(query[kSecAttrAccount as String] as? String == "providers-se-v1")
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecUseDataProtectionKeychain as String] == nil)
            #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        }
    }

    @Test("Legado danificado não bloqueia edição/exclusão de credenciais válidas",
          arguments: ["{\"openAIKey\":\"SYNTHETIC_TRUNCATED", "{\"showConfidence\":[]}", "[]"])
    func damagedLegacyPreservesHealthyCredentialRecord(legacyJSON: String) throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = Data(legacyJSON.utf8)
        defaults.set(raw, forKey: SettingsStore.legacyKey)
        let credentials = MockSettingsCredentialsStore(record: legacyRecord)
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        #expect(credentialValues(store.reloadCredentials()) == legacyRecord.values)
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
        #expect(store.credentialError == nil)
        #expect(credentials.writeCount == 0)

        var expected = legacyRecord
        for field in SettingsCredentialField.allCases {
            let value = "SYNTHETIC_REPLACEMENT_" + field.rawValue
            try store.setCredential(field, value: value)
            expected.values[field.rawValue] = value
            #expect(credentials.record == expected)
            #expect(credentialValues(store.load()) == expected.values)
            #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
        }
        try store.setCredential(.customKey, value: "")
        expected.values["customKey"] = ""
        let reopened = SettingsStore(defaults: defaults, credentials: credentials)
        #expect(credentialValues(reopened.reloadCredentials()) == expected.values)
        #expect(reopened.credentialError == nil)
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
    }

    @Test("Legado danificado sem registro seguro validado não permite substituir credenciais",
          arguments: ["absent", "unavailable", "invalid"])
    func damagedLegacyRequiresVerifiedSecureRecord(state: String) throws {
        let suite = "voiz-tests-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = Data("{\"openAIKey\":\"SYNTHETIC_TRUNCATED".utf8)
        defaults.set(raw, forKey: SettingsStore.legacyKey)
        let credentials = MockSettingsCredentialsStore(record: state == "absent" ? nil : legacyRecord)
        credentials.failReads = state == "unavailable"
        if state == "invalid" { credentials.record?.values.removeValue(forKey: "geminiKey") }
        let originalRecord = credentials.record
        let store = SettingsStore(defaults: defaults, credentials: credentials)
        _ = store.reloadCredentials()
        #expect(store.credentialError != nil)
        #expect(throws: SettingsCredentialError.self) {
            try store.setCredential(.openAIKey, value: "SYNTHETIC_REPLACEMENT")
        }
        #expect(credentials.writeCount == 0)
        #expect(credentials.record == originalRecord)
        #expect(defaults.data(forKey: SettingsStore.legacyKey) == raw)
    }
}
