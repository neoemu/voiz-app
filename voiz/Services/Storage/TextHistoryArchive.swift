import Foundation
import SQLite3

nonisolated enum TextHistoryArchiveError: Error, Equatable {
    case database(Int32), corruptRecord, unsupportedVersion
}

/// The visible history is a page, never the retained collection. Each mutation reads/writes
/// a single record in a FULL-synchronous SQLite transaction; cache eviction has no delete path.
@MainActor
final class TextHistoryArchive<Entry: Codable & Identifiable> where Entry.ID == UUID {
    private var database: OpaquePointer?
    private let kind: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL?, kind: String) throws {
        guard ["dictation", "translation"].contains(kind) else { throw TextHistoryArchiveError.unsupportedVersion }
        self.kind = kind
        if let databaseURL {
            try SyncDurableBlobStore.createDirectoryDurably(databaseURL.deletingLastPathComponent())
        }
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(databaseURL?.path ?? ":memory:", &opened,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw TextHistoryArchiveError.database(code)
        }
        database = opened
        do {
            sqlite3_busy_timeout(opened, 5_000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS history_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS text_history (kind TEXT NOT NULL, id TEXT NOT NULL, timestamp_ms INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
            try execute("CREATE INDEX IF NOT EXISTS text_history_time ON text_history(kind,timestamp_ms DESC,id DESC)")
            let version = try scalarText("SELECT value FROM history_metadata WHERE key='schema_version'")
            guard version == nil || version == "1" || version == "2" else { throw TextHistoryArchiveError.unsupportedVersion }
            if version != "2" {
                try transaction {
                    try execute("ALTER TABLE text_history ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0")
                    try execute("INSERT INTO history_metadata(key,value) VALUES('schema_version','2') ON CONFLICT(key) DO UPDATE SET value='2'")
                }
            }
            if let databaseURL { try SyncDurableBlobStore.synchronizeDirectory(databaseURL.deletingLastPathComponent()) }
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// A legacy blob is decoded before migration is recorded. Unreadable input stays intact.
    /// Existing rows win on repeated migration; the caller keeps the original blob as a backup.
    func migrate(_ data: Data?, timestamp: (Entry) -> Date) throws {
        let key = "migrated." + kind
        if try scalarText("SELECT value FROM history_metadata WHERE key=?", texts: [key]) != nil { return }
        let entries = try data.map { try decoder.decode([Entry].self, from: $0) } ?? []
        try transaction {
            for entry in entries { try write(entry, timestamp: timestamp(entry), replace: false) }
            try execute("INSERT INTO history_metadata(key,value) VALUES(?, '1')", texts: [key])
        }
    }

    func upsert(_ entry: Entry, timestamp: Date) throws {
        try transaction { try write(entry, timestamp: timestamp, replace: true) }
    }

    /// Read-modify-write under one write lock so another process cannot lose a rename/update.
    func update(id: UUID, timestamp: (Entry) -> Date, change: (inout Entry) -> Void) throws {
        try transaction {
            guard var value = try entry(id: id) else { return }
            change(&value)
            try write(value, timestamp: timestamp(value), replace: true)
        }
    }

    func entry(id: UUID, visibleOnly: Bool = false) throws -> Entry? {
        let statement = try prepare("SELECT payload FROM text_history WHERE kind=? AND id=?" + (visibleOnly ? " AND hidden=0" : ""),
                                    texts: [kind, id.uuidString.lowercased()])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
        return try decode(statement)
    }

    func page(limit: Int = 100, offset: Int = 0) throws -> [Entry] {
        guard limit > 0, limit <= 10_000, offset >= 0 else { throw TextHistoryArchiveError.corruptRecord }
        let statement = try prepare("SELECT payload FROM text_history WHERE kind=? AND hidden=0 ORDER BY timestamp_ms DESC,id DESC LIMIT ? OFFSET ?", texts: [kind])
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 2, Int64(limit))
        sqlite3_bind_int64(statement, 3, Int64(offset))
        var entries: [Entry] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return entries }
            guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
            entries.append(try decode(statement))
        }
    }

    /// Stable keyset pagination for inventory while newer entries are being appended.
    func page(afterID: String, limit: Int = 100) throws -> [Entry] {
        guard (1...10_000).contains(limit) else { throw TextHistoryArchiveError.corruptRecord }
        if !afterID.isEmpty { try SyncIdentifier.validate(afterID) }
        let statement = try prepare("SELECT payload FROM text_history WHERE kind=? AND hidden=0 AND id>? ORDER BY id LIMIT ?", texts: [kind, afterID])
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 3, Int64(limit))
        var entries: [Entry] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return entries }
            guard code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
            entries.append(try decode(statement))
        }
    }

    var count: Int {
        get throws {
            let statement = try prepare("SELECT count(*) FROM text_history WHERE kind=? AND hidden=0", texts: [kind])
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw TextHistoryArchiveError.corruptRecord }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func setHidden(id: UUID, _ hidden: Bool) throws {
        try transaction {
            try execute("UPDATE text_history SET hidden=" + (hidden ? "1" : "0") + " WHERE kind=? AND id=?", texts: [kind, id.uuidString.lowercased()])
        }
    }

    /// This method is only for an explicit deletion; it never owns or removes audio files.
    func remove(id: UUID) throws {
        try transaction { try execute("DELETE FROM text_history WHERE kind=? AND id=?", texts: [kind, id.uuidString.lowercased()]) }
    }

    private func decode(_ statement: OpaquePointer) throws -> Entry {
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, let pointer = sqlite3_column_blob(statement, 0) else { throw TextHistoryArchiveError.corruptRecord }
        do { return try decoder.decode(Entry.self, from: Data(bytes: pointer, count: length)) }
        catch { throw TextHistoryArchiveError.corruptRecord }
    }

    private func write(_ entry: Entry, timestamp: Date, replace: Bool) throws {
        let milliseconds = timestamp.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= Double(Int64.max - 1_024) else {
            throw TextHistoryArchiveError.corruptRecord
        }
        let data = try encoder.encode(entry)
        let sql = replace
            ? "INSERT INTO text_history(kind,id,timestamp_ms,payload) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET timestamp_ms=excluded.timestamp_ms,payload=excluded.payload,hidden=0"
            : "INSERT OR IGNORE INTO text_history(kind,id,timestamp_ms,payload) VALUES(?,?,?,?)"
        let statement = try prepare(sql, texts: [kind, entry.id.uuidString.lowercased()])
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 3, Int64(milliseconds.rounded()))
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bind = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
        guard bind == SQLITE_OK else { throw TextHistoryArchiveError.database(bind) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw TextHistoryArchiveError.database(code) }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, texts: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw TextHistoryArchiveError.database(code) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in texts.enumerated() {
            let bind = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            if bind != SQLITE_OK { sqlite3_finalize(statement); throw TextHistoryArchiveError.database(bind) }
        }
        return statement
    }
    private func execute(_ sql: String, texts: [String] = []) throws {
        let statement = try prepare(sql, texts: texts)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw TextHistoryArchiveError.database(code) }
    }
    private func scalarText(_ sql: String, texts: [String] = []) throws -> String? {
        let statement = try prepare(sql, texts: texts)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw TextHistoryArchiveError.corruptRecord }
        return String(cString: text)
    }
}
