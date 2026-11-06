import Foundation
import SQLite3

nonisolated enum SyncLocalVisibility: String, Codable, Sendable { case visible, trashed, purged, absent }
nonisolated struct SyncLocalEntity: Sendable, Identifiable {
    var id: String { document.entityType.rawValue + "/" + document.entityID }
    let document: SyncDocument
    let visibility: SyncLocalVisibility
    let remoteRevision: Int64
}

nonisolated struct SyncLocalConflict: Sendable, Identifiable {
    let id: String
    let document: SyncDocument
    let remoteCursor: Int64
    let payloadSHA256: String
}

/// Local projection/index only. Tombstones also exist for records whose content has never
/// reached this Mac. Files and local audio remain untouched by cloud lifecycle changes.
@MainActor
final class SyncLocalDocumentStore {
    private var database: OpaquePointer?
    private let blobStore: SyncDurableBlobStore
    private var usesBlobStorage = false
    private(set) var quotaRevision: UInt64 = 0
    init(url: URL) throws {
        blobStore = SyncDurableBlobStore(databaseURL: url)
        try SyncDurableBlobStore.createDirectoryDurably(url.deletingLastPathComponent())
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw TextHistoryArchiveError.database(code)
        }
        database = opened
        do {
            sqlite3_busy_timeout(opened, 5_000)
            try run("PRAGMA journal_mode=DELETE")
            try run("PRAGMA synchronous=FULL")
            try transaction {
                try run("CREATE TABLE IF NOT EXISTS sync_index_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                let format = try prepare("SELECT value FROM sync_index_metadata WHERE key='blob_storage_version'")
                let formatCode = sqlite3_step(format)
                if formatCode == SQLITE_ROW {
                    guard string(format, column: 0) == "1" else { sqlite3_finalize(format); throw SyncJournalError.incompatibleDatabase }
                    usesBlobStorage = true
                } else if formatCode != SQLITE_DONE { sqlite3_finalize(format); throw TextHistoryArchiveError.database(formatCode) }
                sqlite3_finalize(format)
                if usesBlobStorage {
                    // A version marker is evidence of a complete schema. Missing tables
                    // or columns indicate corruption, never permission to start empty.
                    for sql in [
                        "SELECT entity_key,entity_type,entity_id,document,visibility,revision,parent_id,position FROM entities LIMIT 0",
                        "SELECT entity_key,visibility,revision FROM tombstones LIMIT 0",
                        "SELECT entity_key,cursor,payload_sha256,document,resolved FROM conflict_versions LIMIT 0"
                    ] {
                        let check = try prepare(sql)
                        sqlite3_finalize(check)
                    }
                } else {
                    try run("CREATE TABLE IF NOT EXISTS entities (entity_key TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, document BLOB NOT NULL, visibility TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, parent_id TEXT, position INTEGER)")
                    try run("CREATE TABLE IF NOT EXISTS tombstones (entity_key TEXT PRIMARY KEY, visibility TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0)")
                    try run("CREATE TABLE IF NOT EXISTS conflict_versions (entity_key TEXT NOT NULL, cursor INTEGER NOT NULL, payload_sha256 TEXT NOT NULL, document BLOB NOT NULL, resolved INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(entity_key,cursor,payload_sha256))")
                    let columns = try prepare("PRAGMA table_info(conflict_versions)")
                    var hasResolved = false
                    while sqlite3_step(columns) == SQLITE_ROW { if string(columns, column: 1) == "resolved" { hasResolved = true } }
                    sqlite3_finalize(columns)
                    if !hasResolved { try run("ALTER TABLE conflict_versions ADD COLUMN resolved INTEGER NOT NULL DEFAULT 0") }
                }
                let legacy = try prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='conflicts'")
                let hasLegacy = sqlite3_step(legacy) == SQLITE_ROW
                sqlite3_finalize(legacy)
                if hasLegacy {
                    let statement = try prepare("SELECT entity_key,cursor,document FROM conflicts")
                    defer { sqlite3_finalize(statement) }
                    while true {
                        let code = sqlite3_step(statement)
                        if code == SQLITE_DONE { break }
                        guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
                        let data = try blob(statement, column: 2)
                        try insertConflict(key: string(statement, column: 0), cursor: sqlite3_column_int64(statement, 1), data: data)
                    }
                    // Keep the legacy table intact; repeated opening migrates idempotently.
                }
                try configureBlobStorage(hasLegacy: hasLegacy)
            }
            try SyncDurableBlobStore.synchronizeDirectory(url.deletingLastPathComponent())
        } catch { sqlite3_close(opened); database = nil; throw error }
    }
    deinit { if let database { sqlite3_close(database) } }

    /// The registry is the authority for a generation change (including its explicit
    /// confirmation). Revisions belong to one generation; visibility and local copies do not.
    func bind(accountID: String, collectionGeneration: String) throws {
        try SyncIdentifier.validate(collectionGeneration)
        try transaction {
            @MainActor func metadata(_ key: String) throws -> String? {
                let statement = try prepare("SELECT value FROM sync_index_metadata WHERE key=?", text: [key])
                defer { sqlite3_finalize(statement) }
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return nil }
                guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
                return string(statement, column: 0)
            }
            if let owner = try metadata("account_id"), owner != accountID { throw SyncJournalError.accountMismatch }
            let previous = try metadata("collection_generation")
            if previous != collectionGeneration {
                try run("UPDATE entities SET revision=0")
                try run("UPDATE tombstones SET revision=0")
            }
            for (key, value) in [("account_id", accountID), ("collection_generation", collectionGeneration)] {
                try run("INSERT INTO sync_index_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", text: [key, value])
            }
        }
    }

    func validateBinding(accountID: String, collectionGeneration: String) throws {
        let statement = try prepare("SELECT key,value FROM sync_index_metadata WHERE key IN ('account_id','collection_generation')")
        defer { sqlite3_finalize(statement) }
        var metadata: [String: String] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
            metadata[string(statement, column: 0)] = string(statement, column: 1)
        }
        guard metadata["account_id"] == accountID else { throw SyncJournalError.accountMismatch }
        guard metadata["collection_generation"] == collectionGeneration else { throw SyncJournalError.generationMismatch }
    }

    func remoteRevision(type: SyncEntityType, id: String) throws -> Int64 {
        let key = type.rawValue + "/" + id
        let statement = try prepare("SELECT MAX(revision) FROM (SELECT revision FROM entities WHERE entity_key=? UNION ALL SELECT revision FROM tombstones WHERE entity_key=?)", text: [key, key])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TextHistoryArchiveError.corruptRecord }
        return sqlite3_column_int64(statement, 0)
    }

    func entity(type: SyncEntityType, id: String) throws -> SyncLocalEntity? {
        let statement = try prepare("SELECT document,visibility,revision FROM entities WHERE entity_key=?", text: [type.rawValue + "/" + id])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
        let document = try SyncDocument(entityType: type, data: blob(statement, column: 0))
        guard let visibility = SyncLocalVisibility(rawValue: string(statement, column: 1)), document.entityID == id else { throw TextHistoryArchiveError.corruptRecord }
        return SyncLocalEntity(document: document, visibility: visibility, remoteRevision: sqlite3_column_int64(statement, 2))
    }
    func put(_ document: SyncDocument, visibility: SyncLocalVisibility = .visible, remoteRevision: Int64? = nil) throws {
        try transaction {
            let statement = try prepare("INSERT INTO entities(entity_key,entity_type,entity_id,document,visibility,revision,parent_id,position) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(entity_key) DO UPDATE SET document=excluded.document,visibility=excluded.visibility,parent_id=excluded.parent_id,position=excluded.position,revision=CASE WHEN ? THEN MAX(entities.revision,excluded.revision) ELSE entities.revision END", text: [document.entityType.rawValue + "/" + document.entityID, document.entityType.rawValue, document.entityID])
            defer { sqlite3_finalize(statement) }
            try bind(try document.canonicalData(), to: statement, at: 4)
            try bind(visibility.rawValue, to: statement, at: 5)
            sqlite3_bind_int64(statement, 6, remoteRevision ?? 0)
            if let parent = document.parentID { try bind(parent, to: statement, at: 7) } else { sqlite3_bind_null(statement, 7) }
            if let position = document.value.object?["position"]?.integer { sqlite3_bind_int64(statement, 8, position) } else { sqlite3_bind_null(statement, 8) }
            sqlite3_bind_int(statement, 9, remoteRevision == nil ? 0 : 1)
            try finish(statement)
            try run("DELETE FROM tombstones WHERE entity_key=?", text: [document.entityType.rawValue + "/" + document.entityID])
        }
        quotaRevision &+= 1
    }
    func hide(type: SyncEntityType, id: String, as visibility: SyncLocalVisibility, revision: Int64? = nil) throws {
        try SyncIdentifier.validate(id)
        guard visibility != .visible else { throw SyncWireError.invalidSchema }
        try transaction {
            let key = type.rawValue + "/" + id
            let statement = try prepare("INSERT INTO tombstones(entity_key,visibility,revision) VALUES(?,?,?) ON CONFLICT(entity_key) DO UPDATE SET visibility=excluded.visibility,revision=MAX(tombstones.revision,excluded.revision)", text: [key, visibility.rawValue])
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 3, revision ?? 0)
            try finish(statement)
            let update = try prepare("UPDATE entities SET visibility=?,revision=CASE WHEN ? THEN MAX(revision,?) ELSE revision END WHERE entity_key=?")
            defer { sqlite3_finalize(update) }
            try bind(visibility.rawValue, to: update, at: 1)
            sqlite3_bind_int(update, 2, revision == nil ? 0 : 1)
            sqlite3_bind_int64(update, 3, revision ?? 0)
            try bind(key, to: update, at: 4)
            try finish(update)
        }
        quotaRevision &+= 1
    }
    /// Only an explicit conflict resolution with a fresh authoritative read may lower
    /// a baseline after disaster recovery. Feed/snapshot projection still uses MAX.
    func setAuthoritativeRevision(type: SyncEntityType, id: String, revision: Int64) throws {
        guard revision >= 0 else { throw SyncJournalError.invalidTransition }
        try transaction {
            for table in ["entities", "tombstones"] {
                let statement = try prepare("UPDATE \(table) SET revision=? WHERE entity_key=?")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, revision)
                try bind(type.rawValue + "/" + id, to: statement, at: 2)
                try finish(statement)
            }
        }
    }

    func observeRevision(type: SyncEntityType, id: String, revision: Int64) throws {
        try transaction {
            for table in ["entities", "tombstones"] {
                let statement = try prepare("UPDATE \(table) SET revision=MAX(revision,?) WHERE entity_key=?")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, revision)
                try bind(type.rawValue + "/" + id, to: statement, at: 2)
                try finish(statement)
            }
        }
    }
    func isVisible(type: SyncEntityType, id: UUID) throws -> Bool {
        let statement = try prepare("SELECT visibility FROM tombstones WHERE entity_key=?", text: [type.rawValue + "/" + id.uuidString.lowercased()])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return false }
        guard code == SQLITE_DONE else { throw TextHistoryArchiveError.database(code) }
        return try entity(type: type, id: id.uuidString.lowercased()).map { $0.visibility == .visible } ?? true
    }
    func page(visibility: SyncLocalVisibility? = nil, after key: String = "", limit: Int = 100) throws -> [SyncLocalEntity] {
        guard (1...1_000).contains(limit) else { throw SyncWireError.invalidNumber }
        let filter = visibility == nil ? "" : " AND visibility=?"
        let bindings = [key] + (visibility.map { [$0.rawValue] } ?? [])
        let statement = try prepare("SELECT entity_type,document,visibility,revision FROM entities WHERE entity_key>?" + filter + " ORDER BY entity_key LIMIT ?", text: bindings)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, Int32(bindings.count + 1), Int32(limit))
        var result: [SyncLocalEntity] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let type = SyncEntityType(rawValue: string(statement, column: 0)),
                  let visibility = SyncLocalVisibility(rawValue: string(statement, column: 2)) else { throw TextHistoryArchiveError.corruptRecord }
            result.append(SyncLocalEntity(document: try SyncDocument(entityType: type, data: blob(statement, column: 1)),
                                          visibility: visibility, remoteRevision: sqlite3_column_int64(statement, 3)))
        }
    }
    /// SQLite increments data_version when another connection commits. Local revision
    /// covers this connection's writes, which PRAGMA data_version intentionally excludes.
    func quotaRevisionToken() throws -> String {
        let statement = try prepare("PRAGMA data_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SyncJournalError.corruptRecord }
        return String(quotaRevision) + ":" + String(sqlite3_column_int64(statement, 0))
    }

    /// Count canonical payload bytes without loading content. Large immutable blobs
    /// carry their exact byte length in the SQLite reference; inline bytes use SQL length.
    func quotaPage(after key: String = "", limit: Int = 100) throws -> [(key: String, bytes: Int64)] {
        guard (1...1_000).contains(limit), usesBlobStorage else { throw SyncJournalError.invalidTransition }
        let statement = try prepare("SELECT entity_key,substr(document,1,96),length(document) FROM entities WHERE entity_key>? AND visibility IN ('visible','trashed') ORDER BY entity_key LIMIT ?", text: [key])
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 2, Int32(limit))
        var result: [(key: String, bytes: Int64)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 1) else { throw SyncJournalError.corruptRecord }
            let prefix = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 1)))
            let storedCount = sqlite3_column_int64(statement, 2)
            let count: Int64
            if prefix.first == 0 {
                guard storedCount > 1 else { throw SyncJournalError.corruptRecord }
                count = storedCount - 1
            } else {
                guard storedCount == prefix.count else { throw SyncJournalError.corruptRecord }
                count = try blobStore.referencedByteCount(prefix)
            }
            result.append((string(statement, column: 0), count))
        }
    }

    func hasUnresolvedConflicts() throws -> Bool {
        let statement = try prepare("SELECT 1 FROM conflict_versions WHERE resolved=0 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw TextHistoryArchiveError.database(code) }
        return code == SQLITE_ROW
    }

    func preserveConflict(_ document: SyncDocument, cursor: Int64) throws {
        try insertConflict(key: document.entityType.rawValue + "/" + document.entityID, cursor: cursor, data: document.canonicalData(), reopen: true)
    }
    func conflicts(type: SyncEntityType, id: String) throws -> [SyncDocument] {
        let statement = try prepare("SELECT document FROM conflict_versions WHERE entity_key=? ORDER BY cursor,payload_sha256", text: [type.rawValue + "/" + id])
        defer { sqlite3_finalize(statement) }
        var result: [SyncDocument] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
            result.append(try SyncDocument(entityType: type, data: blob(statement, column: 0)))
        }
    }
    func conflictPage(after key: String = "", limit: Int = 100, includeResolved: Bool = false) throws -> [SyncLocalConflict] {
        guard (1...1_000).contains(limit) else { throw SyncWireError.invalidNumber }
        let filter = includeResolved ? "" : " AND resolved=0"
        let statement = try prepare("SELECT entity_key,cursor,payload_sha256,document,entity_key || '/' || printf('%016d',cursor) || '/' || payload_sha256 AS version_id FROM conflict_versions WHERE version_id>?" + filter + " ORDER BY version_id LIMIT ?", text: [key])
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 2, Int32(limit))
        var result: [SyncLocalConflict] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let rawType = string(statement, column: 0).split(separator: "/").first,
                  let type = SyncEntityType(rawValue: String(rawType)) else { throw TextHistoryArchiveError.corruptRecord }
            result.append(SyncLocalConflict(id: string(statement, column: 4),
                document: try SyncDocument(entityType: type, data: blob(statement, column: 3)),
                remoteCursor: sqlite3_column_int64(statement, 1), payloadSHA256: string(statement, column: 2)))
        }
    }

    func markConflictsResolved(type: SyncEntityType, id: String) throws {
        try run("UPDATE conflict_versions SET resolved=1 WHERE entity_key=?", text: [type.rawValue + "/" + id])
    }

    /// Local cascade provenance prevents restoring independently deleted children.
    func recordLocalTrashChild(parent: String, child: String) throws {
        try run("CREATE TABLE IF NOT EXISTS local_trash_children(parent TEXT NOT NULL, child TEXT PRIMARY KEY)")
        try run("INSERT INTO local_trash_children(parent,child) VALUES(?,?) ON CONFLICT(child) DO UPDATE SET parent=excluded.parent", text: [parent, child])
    }
    func hasLocalTrashParent(_ parent: String, child: String) throws -> Bool {
        try run("CREATE TABLE IF NOT EXISTS local_trash_children(parent TEXT NOT NULL, child TEXT PRIMARY KEY)")
        let statement = try prepare("SELECT child FROM local_trash_children WHERE parent=? AND child=?", text: [parent, child])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw TextHistoryArchiveError.database(code) }
        return code == SQLITE_ROW
    }
    func clearLocalTrashChildren(parent: String) throws {
        try run("CREATE TABLE IF NOT EXISTS local_trash_children(parent TEXT NOT NULL, child TEXT PRIMARY KEY)")
        try run("DELETE FROM local_trash_children WHERE parent=?", text: [parent])
    }

    /// Ownership only: meeting transcript/summary and conversation messages. Contextual
    /// references (notes, linked conversations) do not make a record an owned child.
    func ownedChildren(type: SyncEntityType, id: String) throws -> [SyncLocalEntity] {
        let filter: String
        switch type {
        case .meeting: filter = "entity_type IN ('transcript','summary') AND parent_id=?"
        case .conversation: filter = "entity_type='message' AND parent_id=?"
        default: return []
        }
        let statement = try prepare("SELECT entity_type,document,visibility,revision FROM entities WHERE " + filter + " ORDER BY entity_key", text: [id])
        defer { sqlite3_finalize(statement) }
        var result: [SyncLocalEntity] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let type = SyncEntityType(rawValue: string(statement, column: 0)),
                  let visibility = SyncLocalVisibility(rawValue: string(statement, column: 2)) else { throw TextHistoryArchiveError.corruptRecord }
            result.append(SyncLocalEntity(document: try SyncDocument(entityType: type, data: blob(statement, column: 1)), visibility: visibility,
                                          remoteRevision: sqlite3_column_int64(statement, 3)))
        }
    }

    private func insertConflict(key: String, cursor: Int64, data: Data, reopen: Bool = false) throws {
        // A new generation can reuse a cursor/hash. An observed divergence reopens that
        // preserved content; repeated legacy migration must not reopen resolved versions.
        let collision = reopen ? " DO UPDATE SET resolved=0" : " DO NOTHING"
        let statement = try prepare("INSERT INTO conflict_versions(entity_key,cursor,payload_sha256,document) VALUES(?,?,?,?) ON CONFLICT(entity_key,cursor,payload_sha256)" + collision, text: [key])
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 2, cursor)
        try bind(SyncCanonicalJSON.sha256(data), to: statement, at: 3)
        try bind(data, to: statement, at: 4)
        try finish(statement)
    }
    func children(type: SyncEntityType, parentID: String) throws -> [SyncDocument] {
        let statement = try prepare("SELECT document FROM entities WHERE entity_type=? AND visibility='visible' AND parent_id=? ORDER BY position,entity_id", text: [type.rawValue, parentID])
        defer { sqlite3_finalize(statement) }
        var values: [SyncDocument] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return values }
            guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
            values.append(try SyncDocument(entityType: type, data: blob(statement, column: 0)))
        }
    }
    private func configureBlobStorage(hasLegacy: Bool) throws {
        let statement = try prepare("PRAGMA table_info(entities)")
        var names = Set<String>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { sqlite3_finalize(statement); throw TextHistoryArchiveError.database(code) }
            names.insert(string(statement, column: 1))
        }
        sqlite3_finalize(statement)
        for (name, type) in [("parent_id", "TEXT"), ("position", "INTEGER")] where !names.contains(name) {
            guard !usesBlobStorage else { throw SyncJournalError.corruptRecord }
            try run("ALTER TABLE entities ADD COLUMN " + name + " " + type)
        }
        if !usesBlobStorage {
            for table in ["entities", "conflict_versions"] + (hasLegacy ? ["conflicts"] : []) {
                var after: Int64 = 0
                while true {
                    let read = try prepare("SELECT rowid,document" + (table == "entities" ? ",entity_type" : "") + " FROM " + table + " WHERE rowid>? ORDER BY rowid LIMIT 1")
                    sqlite3_bind_int64(read, 1, after)
                    let code = sqlite3_step(read)
                    if code == SQLITE_DONE { sqlite3_finalize(read); break }
                    guard code == SQLITE_ROW else { sqlite3_finalize(read); throw TextHistoryArchiveError.database(code) }
                    let rowID = sqlite3_column_int64(read, 0)
                    let data: Data
                    let type: SyncEntityType?
                    do { data = try blob(read, column: 1); type = table == "entities" ? SyncEntityType(rawValue: string(read, column: 2)) : nil }
                    catch { sqlite3_finalize(read); throw error }
                    sqlite3_finalize(read)
                    let update = try prepare("UPDATE " + table + " SET document=? WHERE rowid=?")
                    do {
                        try bind(blobStore.store(data), to: update, at: 1)
                        sqlite3_bind_int64(update, 2, rowID)
                        try finish(update)
                    } catch { sqlite3_finalize(update); throw error }
                    sqlite3_finalize(update)
                    if table == "entities" {
                        guard let type else { throw SyncJournalError.corruptRecord }
                        let document = try SyncDocument(entityType: type, data: data)
                        let fields = try prepare("UPDATE entities SET parent_id=?,position=? WHERE rowid=?")
                        do {
                            if let parent = document.parentID { try bind(parent, to: fields, at: 1) } else { sqlite3_bind_null(fields, 1) }
                            if let position = document.value.object?["position"]?.integer { sqlite3_bind_int64(fields, 2, position) } else { sqlite3_bind_null(fields, 2) }
                            sqlite3_bind_int64(fields, 3, rowID)
                            try finish(fields)
                        } catch { sqlite3_finalize(fields); throw error }
                        sqlite3_finalize(fields)
                    }
                    after = rowID
                }
            }
            try run("INSERT INTO sync_index_metadata(key,value) VALUES('blob_storage_version','1')")
            usesBlobStorage = true
        }
        try run("CREATE INDEX IF NOT EXISTS entities_parent ON entities(entity_type,parent_id,position)")
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do { let result = try operation(); try run("COMMIT"); return result }
        catch { try? run("ROLLBACK"); throw error }
    }
    private func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { throw TextHistoryArchiveError.corruptRecord }
        let stored = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        return usesBlobStorage ? try blobStore.load(stored) : stored
    }
    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func bind(_ original: Data, to statement: OpaquePointer, at index: Int32) throws {
        let data = usesBlobStorage ? try blobStore.store(original) : original
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        guard code == SQLITE_OK else { throw TextHistoryArchiveError.database(code) }
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard code == SQLITE_OK else { throw TextHistoryArchiveError.database(code) }
    }
    private func prepare(_ sql: String, text: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw TextHistoryArchiveError.database(code) }
        do { for (offset, value) in text.enumerated() { try bind(value, to: statement, at: Int32(offset + 1)) } }
        catch { sqlite3_finalize(statement); throw error }
        return statement
    }
    private func finish(_ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
    }
    private func run(_ sql: String, text: [String] = []) throws {
        let statement = try prepare(sql, text: text)
        defer { sqlite3_finalize(statement) }
        try finish(statement)
    }
}
