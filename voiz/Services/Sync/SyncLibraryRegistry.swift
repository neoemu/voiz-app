import Foundation
import SQLite3

nonisolated enum SyncLibraryRegistryError: Error, Equatable, Sendable {
    case database(Int32)
    case corruptRegistry
    case consentRequired
    case activeWork
    case initialLibraryAlreadyOwned
    case generationResetRequiresConfirmation
    case invalidAccount
}

/// Capture this value when local work starts. Never resolve the current account again when
/// that work finishes: a suspended journal still accepts durable local edits for its owner.
nonisolated struct SyncLibraryContext: Sendable {
    let libraryID: UUID
    let ownerAccountID: String?
    let collectionGeneration: String?
    let rootURL: URL
    let journal: SyncJournal?
    var localOnly: Bool = false
}

/// Durable association between a local library and its one immutable owner. Auth sessions are
/// deliberately not persisted here. Reopening the registry suspends network use until activate.
@MainActor
final class SyncLibraryRegistry {
    private let baseURL: URL
    private let initialLocalRoot: URL
    private let localOnly: Bool
    private var database: OpaquePointer?
    private var journals: [String: SyncJournal] = [:]

    init(baseURL: URL, initialLocalRoot: URL, localOnly: Bool = false) throws {
        self.localOnly = localOnly
        guard baseURL.isFileURL, initialLocalRoot.isFileURL else { throw SyncLibraryRegistryError.corruptRegistry }
        self.baseURL = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        self.initialLocalRoot = initialLocalRoot.standardizedFileURL.resolvingSymlinksInPath()
        try SyncDurableBlobStore.createDirectoryDurably(self.baseURL)
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(self.baseURL.appendingPathComponent("libraries.sqlite").path, &opened,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw SyncLibraryRegistryError.database(code)
        }
        database = opened
        do {
            sqlite3_busy_timeout(opened, 5_000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS library_metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)")
                if let version = try metadata("schema_version") {
                    guard version == "1", try metadata("base_root") == self.baseURL.path,
                          try metadata("initial_root") == self.initialLocalRoot.path else { throw SyncLibraryRegistryError.corruptRegistry }
                    _ = try records()
                    guard try metadata("initial_library_id") != nil, try metadata("active_library_id") != nil else { throw SyncLibraryRegistryError.corruptRegistry }
                } else {
                    guard try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='libraries'").isEmpty else { throw SyncLibraryRegistryError.corruptRegistry }
                    try execute("""
                        CREATE TABLE libraries (
                            id TEXT PRIMARY KEY,
                            owner TEXT UNIQUE,
                            root TEXT NOT NULL UNIQUE,
                            generation TEXT,
                            CHECK ((owner IS NULL AND generation IS NULL) OR (owner IS NOT NULL AND generation IS NOT NULL))
                        )
                        """)
                    try execute("""
                        CREATE TRIGGER library_owner_is_immutable BEFORE UPDATE OF owner ON libraries
                        WHEN OLD.owner IS NOT NULL AND (NEW.owner IS NULL OR NEW.owner != OLD.owner)
                        BEGIN SELECT RAISE(ABORT, 'immutable library owner'); END
                        """)
                    let initialID = UUID().uuidString.lowercased()
                    try execute("INSERT INTO libraries(id,owner,root,generation) VALUES(?,NULL,?,NULL)", [initialID, self.initialLocalRoot.path])
                    try setMetadata("schema_version", "1")
                    try setMetadata("base_root", self.baseURL.path)
                    try setMetadata("initial_root", self.initialLocalRoot.path)
                    try setMetadata("initial_library_id", initialID)
                    try setMetadata("active_library_id", initialID)
                }
                // An app restart never restores an authenticated network session by itself.
                try setMetadata("network_active", "0")
            }
            if localOnly { _ = try activeRecord() }
            else { _ = try currentLocalLibrary() }
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Returns the persisted active library even while logged out/offline, including its
    /// owner and journal. This preserves the destination of recording/processing already begun.
    func currentLocalLibrary() throws -> SyncLibraryContext {
        let record = try activeRecord()
        return try context(for: record, networkActive: metadata("network_active") == "1")
    }

    /// A first association and every account/root/generation change wait until local work is
    /// idle. A different collection generation is never accepted as an implicit server refresh.
    func activate(accountID: String, collectionGeneration: String, claimInitialLocalLibrary: Bool,
                  syncConsentConfirmed: Bool, hasActiveWork: Bool,
                  confirmedGenerationReset: Bool = false) throws -> SyncLibraryContext {
        guard !localOnly else { throw SyncLibraryRegistryError.invalidAccount }
        try Self.validateAccount(accountID)
        try SyncIdentifier.validate(collectionGeneration)
        guard syncConsentConfirmed else { throw SyncLibraryRegistryError.consentRequired }
        let current = try activeRecord()
        let all = try records()
        let initialID = try requiredMetadata("initial_library_id")
        guard all.contains(where: { $0.id.uuidString.lowercased() == initialID }) else { throw SyncLibraryRegistryError.corruptRegistry }
        let existing = all.first { $0.owner == accountID }
        let target: Record
        if let existing { target = existing }
        else if claimInitialLocalLibrary {
            // A separately selected Local library can also be associated once. Previously
            // owned libraries never qualify, including the original installation library.
            guard current.owner == nil else { throw SyncLibraryRegistryError.initialLibraryAlreadyOwned }
            target = current
        } else {
            let id = UUID()
            target = Record(id: id, owner: nil, root: baseURL.appendingPathComponent("libraries", isDirectory: true)
                .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true), generation: nil)
        }
        let changesContext = current.id != target.id || target.owner != accountID || target.generation != collectionGeneration
        guard !changesContext || !hasActiveWork else { throw SyncLibraryRegistryError.activeWork }
        if let previous = target.generation, previous != collectionGeneration {
            guard confirmedGenerationReset else { throw SyncLibraryRegistryError.generationResetRequiresConfirmation }
        }
        if changesContext, let oldJournal = try context(for: current, networkActive: false).journal {
            try oldJournal.setSuspended(true)
        }
        let activated = Record(id: target.id, owner: accountID, root: target.root, generation: collectionGeneration)
        // Opening first detects a corrupt/incompatible journal without changing registry ownership.
        let prepared = try context(for: activated, networkActive: false)
        try transaction {
            if all.contains(where: { $0.id == target.id }) {
                try execute("UPDATE libraries SET owner=?,generation=? WHERE id=?", [accountID, collectionGeneration, target.id.uuidString.lowercased()])
            } else {
                try execute("INSERT INTO libraries(id,owner,root,generation) VALUES(?,?,?,?)", [target.id.uuidString.lowercased(), accountID, target.root.path, collectionGeneration])
            }
            try setMetadata("active_library_id", target.id.uuidString.lowercased())
            try setMetadata("network_active", "1")
        }
        try prepared.journal?.setSuspended(false)
        return prepared
    }

    /// Logging out does not retarget a local task or strip library ownership. It can happen
    /// during active work; only network use is suspended. Switching roots is a separate action.
    func deactivate(hasActiveWork: Bool) throws -> SyncLibraryContext {
        try setMetadata("network_active", "0")
        return try context(for: activeRecord(), networkActive: false)
    }

    /// Listing roots must not open journals belonging to unselected libraries. A
    /// damaged archive cannot disable the healthy library the user is working in.
    func libraryDescriptors() throws -> [SyncLibraryContext] {
        try records().map { record in
            SyncLibraryContext(libraryID: record.id, ownerAccountID: record.owner,
                collectionGeneration: record.generation, rootURL: record.root, journal: nil, localOnly: localOnly)
        }
    }

    func libraries() throws -> [SyncLibraryContext] {
        let activeID = try requiredMetadata("active_library_id")
        let networkActive = try metadata("network_active") == "1"
        return try records().map { try context(for: $0, networkActive: networkActive && $0.id.uuidString.lowercased() == activeID) }
    }

    /// Explicit browsing changes only the selected local root, never its account owner.
    func selectArchivedLibrary(id: UUID, hasActiveWork: Bool) throws -> SyncLibraryContext {
        guard !hasActiveWork else { throw SyncLibraryRegistryError.activeWork }
        guard let selected = try records().first(where: { $0.id == id }) else { throw SyncLibraryRegistryError.corruptRegistry }
        let prepared = try context(for: selected, networkActive: false)
        if !localOnly { _ = try deactivate(hasActiveWork: false) }
        try transaction {
            try setMetadata("active_library_id", id.uuidString.lowercased())
            try setMetadata("network_active", "0")
        }
        return prepared
    }

    /// After the first library belongs to Sync, Local work gets a separate unowned library.
    /// No text, audio, credentials or outbox is copied from any account.
    func selectLocalLibrary(hasActiveWork: Bool) throws -> SyncLibraryContext {
        guard !hasActiveWork else { throw SyncLibraryRegistryError.activeWork }
        let all = try records()
        if let existing = all.first(where: { $0.owner == nil }) {
            return try selectArchivedLibrary(id: existing.id, hasActiveWork: false)
        }
        let id = UUID()
        let root = baseURL.appendingPathComponent("libraries", isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try SyncDurableBlobStore.createDirectoryDurably(root)
        if !localOnly { _ = try deactivate(hasActiveWork: false) }
        try transaction {
            try execute("INSERT INTO libraries(id,owner,root,generation) VALUES(?,NULL,?,NULL)", [id.uuidString.lowercased(), root.path])
            try setMetadata("active_library_id", id.uuidString.lowercased())
        }
        return try context(for: Record(id: id, owner: nil, root: root, generation: nil), networkActive: false)
    }

    private struct Record {
        let id: UUID
        let owner: String?
        let root: URL
        let generation: String?
    }

    private func context(for record: Record, networkActive: Bool) throws -> SyncLibraryContext {
        let journal: SyncJournal?
        if let owner = record.owner, let generation = record.generation {
            let key = record.id.uuidString.lowercased() + "/" + generation
            if let cached = journals[key] { journal = cached }
            else {
                let url = record.root.appendingPathComponent("Sync/journals", isDirectory: true).appendingPathComponent(generation + ".sqlite")
                let opened = try SyncJournal(databaseURL: url, accountID: owner, collectionGeneration: generation)
                journals[key] = opened
                journal = opened
            }
            try journal?.setSuspended(!networkActive)
        } else {
            guard record.owner == nil, record.generation == nil else { throw SyncLibraryRegistryError.corruptRegistry }
            journal = nil
        }
        return SyncLibraryContext(libraryID: record.id, ownerAccountID: record.owner, collectionGeneration: record.generation,
                                  rootURL: record.root, journal: journal, localOnly: localOnly)
    }

    private func activeRecord() throws -> Record {
        let id = try requiredMetadata("active_library_id")
        guard let record = try records().first(where: { $0.id.uuidString.lowercased() == id }) else { throw SyncLibraryRegistryError.corruptRegistry }
        return record
    }

    private func records() throws -> [Record] {
        try rows("SELECT id,owner,root,generation FROM libraries ORDER BY id").map { row in
            guard row.count == 4, let rawID = row[0], let id = UUID(uuidString: rawID), id.uuidString.lowercased() == rawID,
                  let path = row[2], path.hasPrefix("/") else { throw SyncLibraryRegistryError.corruptRegistry }
            if let owner = row[1], let generation = row[3] {
                try Self.validateAccount(owner)
                try SyncIdentifier.validate(generation)
            } else if row[1] != nil || row[3] != nil { throw SyncLibraryRegistryError.corruptRegistry }
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let expected = baseURL.appendingPathComponent("libraries", isDirectory: true).appendingPathComponent(rawID, isDirectory: true)
            guard root.path == path, path == initialLocalRoot.path || path == expected.path else { throw SyncLibraryRegistryError.corruptRegistry }
            return Record(id: id, owner: row[1], root: root, generation: row[3])
        }
    }

    private static func validateAccount(_ account: String) throws {
        guard !account.isEmpty, account.utf8.count <= 512,
              !account.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SyncLibraryRegistryError.invalidAccount }
    }

    private func requiredMetadata(_ key: String) throws -> String {
        guard let value = try metadata(key) else { throw SyncLibraryRegistryError.corruptRegistry }
        return value
    }
    private func metadata(_ key: String) throws -> String? { try rows("SELECT value FROM library_metadata WHERE key=?", [key]).first?[0] }
    private func setMetadata(_ key: String, _ value: String) throws {
        try execute("INSERT INTO library_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func statement(_ sql: String, _ bindings: [String?]) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else { throw SyncLibraryRegistryError.database(code) }
        do {
            guard sqlite3_bind_parameter_count(handle) == bindings.count else { throw SyncLibraryRegistryError.corruptRegistry }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in bindings.enumerated() {
                let code = value.map { sqlite3_bind_text(handle, Int32(index + 1), $0, -1, transient) }
                    ?? sqlite3_bind_null(handle, Int32(index + 1))
                guard code == SQLITE_OK else { throw SyncLibraryRegistryError.database(code) }
            }
            return handle
        } catch { sqlite3_finalize(handle); throw error }
    }
    private func execute(_ sql: String, _ bindings: [String?] = []) throws {
        let handle = try statement(sql, bindings)
        defer { sqlite3_finalize(handle) }
        var code = sqlite3_step(handle)
        while code == SQLITE_ROW { code = sqlite3_step(handle) }
        guard code == SQLITE_DONE else { throw SyncLibraryRegistryError.database(code) }
    }
    private func rows(_ sql: String, _ bindings: [String?] = []) throws -> [[String?]] {
        let handle = try statement(sql, bindings)
        defer { sqlite3_finalize(handle) }
        var values: [[String?]] = []
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw SyncLibraryRegistryError.database(code) }
            var row: [String?] = []
            for column in 0..<sqlite3_column_count(handle) {
                if sqlite3_column_type(handle, column) == SQLITE_NULL { row.append(nil) }
                else {
                    guard sqlite3_column_type(handle, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(handle, column),
                          let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(handle, column))), encoding: .utf8) else { throw SyncLibraryRegistryError.corruptRegistry }
                    row.append(value)
                }
            }
            values.append(row)
        }
    }
}
