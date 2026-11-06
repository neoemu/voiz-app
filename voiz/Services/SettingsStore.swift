import Foundation

/// Preferences and provider credentials have distinct write paths. A stale AppSettings
/// snapshot can never replace credentials just by saving a meeting or UI preference.
nonisolated final class SettingsStore: @unchecked Sendable {
    private static let lock = NSRecursiveLock()
    private static let credentialWorkQueue = DispatchQueue(label: "voiz.settings.credentials.work", qos: .userInitiated)
    static let legacyKey = "voiz.app.settings"
    static let preferencesKey = "voiz.app.preferences.v2"
    private let defaults: UserDefaults
    private let credentials: any SettingsCredentialsPersisting
    private let cache: SettingsCredentialCache
    private static let sharedCache = SettingsCredentialCache()

    var credentialError: String? { cache.snapshot().error }
    var credentialsAreReady: Bool { cache.snapshot().ready }

    /// Work that may consume provider credentials must await an initial verified read.
    /// A missing record is a confirmed empty configuration; a read error is not.
    func loadCredentialsForWork() async -> Bool {
        if credentialsAreReady { return true }
        return await withCheckedContinuation { continuation in
            Self.credentialWorkQueue.async {
                if !self.credentialsAreReady { _ = self.reloadCredentials() }
                continuation.resume(returning: self.credentialsAreReady)
            }
        }
    }

    /// Credential consumers must obtain a verified snapshot before checking keys,
    /// resolving provider choices or admitting work that sends user content.
    func settingsForCredentialUse() async throws -> AppSettings {
        try Task.checkCancellation()
        let ready = await loadCredentialsForWork()
        try Task.checkCancellation()
        let snapshot = cache.snapshot()
        guard ready, snapshot.ready, let record = snapshot.record else {
            throw SettingsCredentialError.unavailable
        }
        var settings = decodePreferences()
        Self.apply(record, to: &settings)
        return settings
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, credentials: SettingsCredentialsStore(), cache: Self.sharedCache)
    }

    init(defaults: UserDefaults, credentials: any SettingsCredentialsPersisting) {
        self.defaults = defaults
        self.credentials = credentials
        cache = SettingsCredentialCache()
    }

    private init(defaults: UserDefaults, credentials: any SettingsCredentialsPersisting,
                 cache: SettingsCredentialCache) {
        self.defaults = defaults
        self.credentials = credentials
        self.cache = cache
    }

    /// UI/read-only consumers never wait on Security or the storage operation lock.
    func load() -> AppSettings {
        var settings = decodePreferences()
        if let record = cache.snapshot().record {
            Self.apply(record, to: &settings)
        } else if let data = defaults.data(forKey: Self.legacyKey),
                  let legacy = try? JSONDecoder().decode(AppSettings.self, from: data) {
            Self.apply(Self.record(from: legacy), to: &settings)
        }
        return settings
    }

    /// Explicit startup/retry work, called off the UI thread. An access failure retains
    /// the last known in-memory snapshot and the only legacy copy, never an empty vault.
    func reloadCredentials() -> AppSettings {
        Self.lock.withLock {
            do {
                cache.update(record: try migrateCredentials(), error: nil, ready: true)
            } catch {
                cache.update(error: SettingsCredentialError.unavailable.errorDescription)
            }
        }
        return load()
    }

    /// UI mutations journal portable fields before committing their normal local settings.
    /// Nonportable settings and credentials never enter this replay or its network DTO.
    @MainActor
    @discardableResult
    func saveWithSync(_ settings: AppSettings) -> Bool {
        if let persistence = SyncLibraryRuntime.shared.persistence {
            do { try persistence.savePreferences(SyncPreferences(snapshot: settings)) }
            catch { return false }
        }
        return save(settings)
    }

    @discardableResult
    func save(_ settings: AppSettings) -> Bool {
        guard let data = try? Self.preferenceData(settings) else { return false }
        // A separate key allows preferences to remain writable while migration is pending,
        // without copying new secrets or deleting the recovery source. No vault lock/IO.
        defaults.set(data, forKey: Self.preferencesKey)
        return true
    }

    /// The only credential mutation API. Call from the explicit provider field action,
    /// on a serial background queue, never from a general settings persistence observer.
    func setCredential(_ field: SettingsCredentialField, value: String) throws {
        try Self.lock.withLock {
            do {
                var record = try migrateCredentials()
                cache.update(record: record, error: nil)
                record.values[field.rawValue] = value
                try writeVerified(record)
                cache.update(record: record, error: nil, ready: true)
            } catch {
                cache.update(error: SettingsCredentialError.unavailable.errorDescription)
                throw SettingsCredentialError.unavailable
            }
        }
    }

    private func decodePreferences() -> AppSettings {
        for key in [Self.preferencesKey, Self.legacyKey] {
            if let data = defaults.data(forKey: key),
               let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
                return settings
            }
        }
        return AppSettings()
    }

    /// Called under the shared lock, including across separate SettingsStore instances.
    private func migrateCredentials() throws -> SettingsCredentialRecord {
        let existing = try credentials.read()
        try existing?.validate()
        if let existing { cache.update(record: existing, error: nil) }
        guard let legacyData = defaults.data(forKey: Self.legacyKey) else {
            return existing ?? SettingsCredentialRecord()
        }
        guard let legacy = try? JSONDecoder().decode(AppSettings.self, from: legacyData),
              var object = try? JSONSerialization.jsonObject(with: legacyData) as? [String: Any] else {
            // The verified secure record is already authoritative. Damaged legacy
            // preferences must not block explicit credential edits forever; retain
            // their original bytes for recovery instead of trying to scrub them.
            if let existing { return existing }
            throw SettingsCredentialError.unavailable
        }
        let hasLegacyFields = SettingsCredentialField.allCases.contains { object[$0.rawValue] != nil }
        guard hasLegacyFields else { return existing ?? SettingsCredentialRecord() }
        let record = existing ?? Self.record(from: legacy)
        // An existing complete record is authoritative, including explicit empty values.
        // A crash after the verified write but before scrubbing cannot restore old secrets.
        if existing == nil { try writeVerified(record) }
        cache.update(record: record, error: nil)
        for field in SettingsCredentialField.allCases { object.removeValue(forKey: field.rawValue) }
        let sanitized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        defaults.set(sanitized, forKey: Self.legacyKey)
        return record
    }

    private func writeVerified(_ record: SettingsCredentialRecord) throws {
        try credentials.write(record)
        guard try credentials.read() == record else { throw SettingsCredentialError.unavailable }
    }

    private static func preferenceData(_ settings: AppSettings) throws -> Data {
        let encoded = try JSONEncoder().encode(settings)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SettingsCredentialError.unavailable
        }
        for field in SettingsCredentialField.allCases { object.removeValue(forKey: field.rawValue) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func record(from settings: AppSettings) -> SettingsCredentialRecord {
        SettingsCredentialRecord(values: [.openAIKey: settings.openAIKey, .anthropicKey: settings.anthropicKey,
                                           .xaiKey: settings.xaiKey, .geminiKey: settings.geminiKey,
                                           .customKey: settings.customKey])
    }

    private static func apply(_ record: SettingsCredentialRecord, to settings: inout AppSettings) {
        settings.openAIKey = record.values[SettingsCredentialField.openAIKey.rawValue] ?? ""
        settings.anthropicKey = record.values[SettingsCredentialField.anthropicKey.rawValue] ?? ""
        settings.xaiKey = record.values[SettingsCredentialField.xaiKey.rawValue] ?? ""
        settings.geminiKey = record.values[SettingsCredentialField.geminiKey.rawValue] ?? ""
        settings.customKey = record.values[SettingsCredentialField.customKey.rawValue] ?? ""
    }
}

/// The live app's stores share a credential snapshot; injected test stores own theirs.
/// This lock is never held while reading/writing Keychain.
nonisolated private final class SettingsCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var record: SettingsCredentialRecord?
    private var error: String?
    private var ready = false

    func snapshot() -> (record: SettingsCredentialRecord?, error: String?, ready: Bool) {
        lock.withLock { (record, error, ready) }
    }

    func update(record: SettingsCredentialRecord? = nil, error: String?, ready: Bool? = nil) {
        lock.withLock {
            if let record { self.record = record }
            self.error = error
            if let ready { self.ready = ready }
            if error != nil { self.ready = false }
        }
    }
}
