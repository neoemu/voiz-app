import Foundation
import SQLite3

nonisolated enum SyncJournalError: Error, Equatable, Sendable {
    case database(Int32)
    case incompatibleDatabase
    case accountMismatch
    case generationMismatch
    case idempotencyConflict
    case invalidTransition
    case cursorMismatch
    case suspended
    case corruptRecord
}

nonisolated struct SyncJournalEntry: Equatable, Sendable {
    let sequence: Int64
    let mutation: SyncMutationEnvelope
    /// Private local replay bytes. These are NEVER part of the upload envelope.
    let localReplayData: Data
    let state: State
    let blockedReason: String?

    enum State: String, Sendable { case prepared, pending, confirmed, superseded }
}

nonisolated struct SyncInboxEntry: Equatable, Sendable {
    let change: SyncRemoteChange
    let applied: Bool
}

/// One database is bound permanently to one account and collection generation. The caller
/// supplies its location explicitly: no fallback to a user's personal/default application data.
/// Transactions use FULL synchronization; every external file write is preceded by prepare().
nonisolated final class SyncJournal: @unchecked Sendable {
    let accountID: String
    let collectionGeneration: String
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private static let schemaVersion = "4"
    private let blobStore: SyncDurableBlobStore
    private var usesBlobStorage = false

    init(databaseURL: URL, accountID: String, collectionGeneration: String) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 512 else { throw SyncJournalError.accountMismatch }
        try SyncIdentifier.validate(collectionGeneration)
        self.blobStore = SyncDurableBlobStore(databaseURL: databaseURL)
        self.accountID = accountID
        self.collectionGeneration = collectionGeneration
        try SyncDurableBlobStore.createDirectoryDurably(databaseURL.deletingLastPathComponent())
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw SyncJournalError.database(result)
        }
        database = opened
        do {
            sqlite3_busy_timeout(opened, 5_000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS sync_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                if let version = try metadata("schema_version") {
                    guard ["1", "2", "3", Self.schemaVersion].contains(version) else { throw SyncJournalError.incompatibleDatabase }
                    guard try metadata("account_id") == accountID else { throw SyncJournalError.accountMismatch }
                    guard try metadata("collection_generation") == collectionGeneration else { throw SyncJournalError.generationMismatch }
                    // A marked but incomplete schema is corruption, never permission to rebuild.
                    _ = try rows("SELECT sequence, operation_id, envelope, local_replay, state, blocked_reason FROM sync_outbox LIMIT 0")
                    _ = try rows("SELECT cursor, change, applied FROM sync_inbox LIMIT 0")
                    if version == "1" {
                        try createSnapshotSchema()
                    } else {
                        _ = try rows("SELECT entity_key,sequence,change,applied FROM sync_snapshot LIMIT 0")
                    }
                    if version == "1" || version == "2" {
                        try migrateResolutionSchema()
                    } else {
                        _ = try rows("SELECT resolution_id,remote,local_replay FROM sync_resolutions LIMIT 0")
                        _ = try rows("SELECT operation_id,proof FROM sync_cancellations LIMIT 0")
                    }
                    if version != Self.schemaVersion { try migrateBlobStorage() }
                    usesBlobStorage = true
                    try setMetadata("schema_version", Self.schemaVersion)
                } else {
                    let existing = try rows("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sync_outbox','sync_inbox')")
                    guard existing.isEmpty else { throw SyncJournalError.incompatibleDatabase }
                    try execute("""
                        CREATE TABLE sync_outbox (
                            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                            operation_id TEXT NOT NULL UNIQUE,
                            entity_key TEXT NOT NULL,
                            envelope BLOB NOT NULL,
                            local_replay BLOB NOT NULL,
                            state TEXT NOT NULL CHECK(state IN ('prepared','pending','confirmed','superseded')),
                            blocked_reason TEXT,
                            remote_revision INTEGER,
                            remote_cursor INTEGER
                        )
                        """)
                    try execute("CREATE INDEX sync_outbox_entity ON sync_outbox(entity_key, sequence)")
                    try execute("CREATE TABLE sync_inbox (cursor INTEGER PRIMARY KEY, change BLOB NOT NULL, applied INTEGER NOT NULL CHECK(applied IN (0,1)))")
                    try createSnapshotSchema()
                    try createResolutionSchema()
                    try setMetadata("schema_version", Self.schemaVersion)
                    try setMetadata("account_id", accountID)
                    try setMetadata("collection_generation", collectionGeneration)
                    try setMetadata("cursor", "0")
                    try setMetadata("suspended", "0")
                    usesBlobStorage = true
                }
            }
            try SyncDurableBlobStore.synchronizeDirectory(databaseURL.deletingLastPathComponent())
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Upgrade old inline blobs atomically. While this runs the generic SQLite helper
    /// deliberately reads/writes raw bytes; the version marker changes in the same commit.
    private func migrateBlobStorage() throws {
        let tables: [(String, [String])] = [
            ("sync_outbox", ["envelope", "local_replay"]), ("sync_inbox", ["change"]),
            ("sync_snapshot", ["change"]), ("sync_cancellations", ["proof"]),
            ("sync_resolutions", ["remote", "operation_ids", "replacement", "local_replay"])
        ]
        for (table, columns) in tables {
            for column in columns {
                var after: Int64 = 0
                while let row = try rows("SELECT rowid," + column + " FROM " + table + " WHERE rowid>? ORDER BY rowid LIMIT 1", [.integer(after)]).first {
                    guard let rowID = row[0].integer else { throw SyncJournalError.corruptRecord }
                    if let data = row[1].data {
                        try execute("UPDATE " + table + " SET " + column + "=? WHERE rowid=?", [.blob(try blobStore.store(data)), .integer(rowID)])
                    }
                    after = rowID
                }
            }
        }
    }

    /// A repeated operation must have exactly the same wire and local replay bytes.
    func prepare(_ mutation: SyncMutationEnvelope, localReplayData: Data) throws {
        try prepareBatch([(mutation, localReplayData)])
    }

    /// Atomic preparation for a logical save spanning several portable entities. If any
    /// envelope conflicts, no member of the batch becomes visible to replay or upload.
    func prepareBatch(_ values: [(mutation: SyncMutationEnvelope, localReplayData: Data)]) throws {
        try synchronized {
            let encoded = try values.map { item -> (SyncMutationEnvelope, Data, Data) in
                guard item.mutation.collectionGeneration == collectionGeneration else { throw SyncJournalError.generationMismatch }
                return (item.mutation, try item.mutation.canonicalData(), item.localReplayData)
            }
            try transaction {
                // A prepared snapshot may have reached the local file before a crash. Do
                // not let a newer save overtake it and later be overwritten by its replay.
                guard try !hasPendingResolution() else { throw SyncJournalError.invalidTransition }
                let incomingIDs = Set(encoded.map { $0.0.operationID })
                let preparedIDs = try rows("SELECT operation_id FROM sync_outbox WHERE state='prepared'").compactMap { $0[0].text }
                if !preparedIDs.isEmpty {
                    guard Set(preparedIDs).isSubset(of: incomingIDs) else { throw SyncJournalError.invalidTransition }
                    for (mutation, _, _) in encoded {
                        guard try !rows("SELECT operation_id FROM sync_outbox WHERE operation_id=?", [.text(mutation.operationID)]).isEmpty else { throw SyncJournalError.invalidTransition }
                    }
                }
                for (mutation, bytes, replay) in encoded {
                    let existing = try rows("SELECT envelope, local_replay FROM sync_outbox WHERE operation_id=?", [.text(mutation.operationID)])
                    if let row = existing.first {
                        guard row[0].data == bytes, row[1].data == replay else { throw SyncJournalError.idempotencyConflict }
                        continue
                    }
                    try execute("INSERT INTO sync_outbox(operation_id,entity_key,envelope,local_replay,state) VALUES(?,?,?,?, 'prepared')", [
                        .text(mutation.operationID), .text(mutation.entityKey), .blob(bytes), .blob(replay)
                    ])
                }
            }
        }
    }

    /// Call only after an idempotent, durable write to the local store. A crash before this
    /// transition leaves prepare() replayable, and replay uses the same operation ID.
    func markLocalApplied(operationID: String) throws {
        try markLocalAppliedBatch(operationIDs: [operationID])
    }

    func markLocalAppliedBatch(operationIDs: [String]) throws {
        try synchronized {
            try transaction {
                for operationID in operationIDs {
                    let row = try rows("SELECT state FROM sync_outbox WHERE operation_id=?", [.text(operationID)]).first
                    guard let row else { throw SyncJournalError.invalidTransition }
                    guard let state = row[0].text, ["prepared", "pending", "confirmed"].contains(state) else { throw SyncJournalError.corruptRecord }
                    if state == "prepared" {
                        try execute("UPDATE sync_outbox SET state='pending' WHERE operation_id=?", [.text(operationID)])
                    }
                }
            }
        }
    }

    /// Pending edits form a causal chain. A successor uses the expected revision of its
    /// predecessor; the upload queue never sends it until that predecessor was confirmed.
    func nextBaseRevision(entityKey: String) throws -> Int64 {
        try synchronized {
            if let row = try rows("SELECT envelope FROM sync_outbox WHERE entity_key=? AND state IN ('prepared','pending') ORDER BY sequence DESC LIMIT 1", [.text(entityKey)]).first {
                guard let data = row[0].data else { throw SyncJournalError.corruptRecord }
                let revision = try SyncMutationEnvelope.decode(data).baseRevision
                guard revision < SyncCanonicalJSON.maximumInteger else { throw SyncWireError.invalidNumber }
                return revision + 1
            }
            return try knownRemoteRevision(entityKey: entityKey)
        }
    }

    /// Revision observed in a verified receipt/feed/snapshot. Unlike nextBaseRevision,
    /// this excludes the predicted revisions of queued local edits.
    func knownRemoteRevision(entityKey: String) throws -> Int64 {
        try synchronized {
            guard let raw = try metadata("revision:" + entityKey) else { return 0 }
            guard let revision = Int64(raw), (0...SyncCanonicalJSON.maximumInteger).contains(revision) else { throw SyncJournalError.corruptRecord }
            return revision
        }
    }

    func pendingLocalReplays() throws -> [SyncJournalEntry] {
        try synchronized { try entries(whereClause: "state='prepared'") }
    }

    /// Only the first unresolved operation for an entity may be sent. This preserves causal
    /// ordering even when a later local edit was saved before an earlier network response.
    func pendingUploads(limit: Int = 100, onlyPurges: Bool = false) throws -> [SyncJournalEntry] {
        try synchronized {
            guard try metadata("suspended") == "0", try !hasPendingResolution() else { return [] }
            let capped = max(0, min(limit, 200))
            if !onlyPurges {
                return try entries(whereClause: "state='pending' AND blocked_reason IS NULL AND NOT EXISTS (SELECT 1 FROM sync_outbox earlier WHERE earlier.entity_key=sync_outbox.entity_key AND earlier.sequence<sync_outbox.sequence AND earlier.state IN ('prepared','pending'))", limit: capped)
            }
            // Page through metadata, loading one head at a time: a purge late in a large
            // initial import must remain reachable while content uploads are held.
            var after: Int64 = 0
            var result: [SyncJournalEntry] = []
            while result.count < capped {
                let page = try entries(whereClause: "sequence>? AND state='pending' AND blocked_reason IS NULL AND NOT EXISTS (SELECT 1 FROM sync_outbox earlier WHERE earlier.entity_key=sync_outbox.entity_key AND earlier.sequence<sync_outbox.sequence AND earlier.state IN ('prepared','pending'))", bindings: [.integer(after)], limit: 1)
                guard let entry = page.first else { break }
                if entry.mutation.mutation == .purge { result.append(entry) }
                after = entry.sequence
            }
            return result
        }
    }

    func unresolvedMutations(entityKey: String) throws -> [SyncJournalEntry] {
        try synchronized { try entries(whereClause: "entity_key=? AND state IN ('prepared','pending')", bindings: [.text(entityKey)]) }
    }

    func confirmUploaded(operationID: String, revision: Int64, cursor: Int64, payloadHash: String) throws {
        try synchronized {
            guard revision > 0, cursor > 0 else { throw SyncJournalError.invalidTransition }
            try transaction {
                guard let row = try rows("SELECT envelope,state,remote_revision,remote_cursor FROM sync_outbox WHERE operation_id=?", [.text(operationID)]).first,
                      let data = row[0].data, let state = row[1].text else { throw SyncJournalError.invalidTransition }
                let mutation = try SyncMutationEnvelope.decode(data)
                try SyncIdentifier.validateHash(payloadHash)
                if mutation.mutation == .upsert || mutation.mutation == .purge {
                    guard mutation.payloadSHA256 == payloadHash else { throw SyncWireError.invalidHash }
                }
                if state == "confirmed" {
                    guard row[2].integer == revision, row[3].integer == cursor else { throw SyncJournalError.idempotencyConflict }
                    return
                }
                guard state == "pending" else { throw SyncJournalError.invalidTransition }
                try execute("UPDATE sync_outbox SET state='confirmed',remote_revision=?,remote_cursor=?,blocked_reason=NULL WHERE operation_id=?", [.integer(revision), .integer(cursor), .text(operationID)])
                let known = Int64(try metadata("revision:" + mutation.entityKey) ?? "0") ?? 0
                try setMetadata("revision:" + mutation.entityKey, String(max(known, revision)))
            }
        }
    }

    func hasBlockedWork(reason: String) throws -> Bool {
        try synchronized {
            try !rows("SELECT operation_id FROM sync_outbox WHERE state IN ('prepared','pending') AND blocked_reason=? LIMIT 1", [.text(reason)]).isEmpty
        }
    }

    func blockUpload(operationID: String, reason: String?) throws {
        try synchronized {
            let allowed = ["unauthenticated", "entitlement_required", "consent_required", "quota_exceeded", "revision_conflict", "gone", "schema_unsupported", "rate_limited", "temporarily_unavailable", "resolution_pending", "invalid_local_identifiers"]
            guard reason == nil || allowed.contains(reason!) else { throw SyncJournalError.invalidTransition }
            guard let row = try rows("SELECT state FROM sync_outbox WHERE operation_id=?", [.text(operationID)]).first,
                  row[0].text == "pending" else { throw SyncJournalError.invalidTransition }
            try execute("UPDATE sync_outbox SET blocked_reason=? WHERE operation_id=?", [reason.map(Value.text) ?? .null, .text(operationID)])
        }
    }

    func setSuspended(_ suspended: Bool) throws {
        try synchronized { try setMetadata("suspended", suspended ? "1" : "0") }
    }

    func pendingWorkCount() throws -> Int {
        try synchronized {
            guard let count = try rows("SELECT (SELECT count(*) FROM sync_outbox WHERE state IN ('prepared','pending')) + (SELECT count(*) FROM sync_resolutions WHERE applied=0)").first?[0].integer else { throw SyncJournalError.corruptRecord }
            return Int(count)
        }
    }

    func blockedWorkCount() throws -> Int {
        try synchronized {
            guard let count = try rows("SELECT count(*) FROM sync_outbox WHERE state IN ('prepared','pending') AND blocked_reason IS NOT NULL").first?[0].integer else { throw SyncJournalError.corruptRecord }
            return Int(count)
        }
    }

    #if DEBUG
    /// Explicit local diagnostics: metadata only, never payload, replay, or credentials.
    func pendingWorkDiagnostic() throws -> String {
        try synchronized {
            let summary = try rows("SELECT state,COALESCE(blocked_reason,'ready'),count(*) FROM sync_outbox WHERE state IN ('prepared','pending') GROUP BY state,blocked_reason")
                .map { "\($0[0].text ?? "?") / \($0[1].text ?? "?"): \($0[2].integer ?? 0)" }
            let details = try entries(whereClause: "state IN ('prepared','pending')", limit: 12).map { entry in
                let mutation = entry.mutation
                return "\(mutation.entityKey)\n\(mutation.mutation.rawValue) base=\(mutation.baseRevision) remote=\((try? knownRemoteRevision(entityKey: mutation.entityKey)) ?? 0) \(entry.blockedReason ?? "ready")\nop=\(mutation.operationID)"
            }
            return (summary + details).joined(separator: "\n\n")
        }
    }
    #endif

    func isSuspended() throws -> Bool {
        try synchronized {
            guard let state = try metadata("suspended"), ["0", "1"].contains(state) else { throw SyncJournalError.corruptRecord }
            return state == "1"
        }
    }

    func currentCursor() throws -> Int64 {
        try synchronized {
            guard let text = try metadata("cursor"), let cursor = Int64(text), cursor >= 0 else { throw SyncJournalError.corruptRecord }
            return cursor
        }
    }

    /// Persists an entire page before exposing it for local application. A second page cannot
    /// overtake a partially applied first page. Empty pages can safely advance their cursor.
    func receive(_ changes: [SyncRemoteChange], afterCursor: Int64, nextCursor: Int64) throws {
        try receiveStaged(changes.map { try SyncStagedChange($0) }, afterCursor: afterCursor, nextCursor: nextCursor)
    }

    func receiveStaged(_ changes: [SyncStagedChange], afterCursor: Int64, nextCursor: Int64) throws {
        try synchronized {
            try requireActive()
            guard nextCursor >= afterCursor else { throw SyncJournalError.cursorMismatch }
            try transaction {
                guard try metadata("snapshot_id") == nil else { throw SyncJournalError.cursorMismatch }
                let current = try currentCursor()
                guard current == afterCursor else { throw SyncJournalError.cursorMismatch }
                let pendingEnd = try metadata("inbox_page_end")
                if pendingEnd != nil {
                    guard pendingEnd == String(nextCursor), try metadata("inbox_page_start") == String(afterCursor) else { throw SyncJournalError.cursorMismatch }
                    let stored = try rows("SELECT change FROM sync_inbox WHERE cursor>? AND cursor<=? ORDER BY cursor", [.integer(afterCursor), .integer(nextCursor)]).compactMap { $0[0].data }
                    guard stored == changes.map(\.bytes) else { throw SyncJournalError.idempotencyConflict }
                    return
                }
                var previous = afterCursor
                for change in changes {
                    guard change.collectionGeneration == collectionGeneration else { throw SyncJournalError.generationMismatch }
                    guard change.cursor > previous, change.cursor <= nextCursor else { throw SyncJournalError.cursorMismatch }
                    previous = change.cursor
                    try execute("INSERT INTO sync_inbox(cursor,change,applied) VALUES(?,?,0)", [.integer(change.cursor), .blob(change.bytes)])
                }
                if changes.isEmpty {
                    try setMetadata("cursor", String(nextCursor))
                } else {
                    try setMetadata("inbox_page_start", String(afterCursor))
                    try setMetadata("inbox_page_end", String(nextCursor))
                }
            }
        }
    }

    func pendingRemoteApplications(limit: Int = 200) throws -> [SyncInboxEntry] {
        try synchronized {
            try rows("SELECT change,applied FROM sync_inbox WHERE applied=0 ORDER BY cursor LIMIT ?", [.integer(Int64(max(0, min(limit, 200))))]).map { row in
                guard let data = row[0].data else { throw SyncJournalError.corruptRecord }
                return SyncInboxEntry(change: try SyncRemoteChange.decode(data), applied: false)
            }
        }
    }

    /// Apply remote bytes idempotently to the local store before calling this. Cursor moves
    /// only when every item of the persisted page has been durably applied.
    func markRemoteApplied(cursor: Int64) throws {
        try synchronized {
            try transaction {
                if let row = try rows("SELECT applied FROM sync_inbox WHERE cursor=?", [.integer(cursor)]).first, row[0].integer == 1 { return }
                guard let first = try rows("SELECT cursor FROM sync_inbox WHERE applied=0 ORDER BY cursor LIMIT 1").first,
                      first[0].integer == cursor else { throw SyncJournalError.invalidTransition }
                guard let changeData = try rows("SELECT change FROM sync_inbox WHERE cursor=?", [.integer(cursor)]).first?[0].data else { throw SyncJournalError.corruptRecord }
                let header = try SyncRemoteChange.storedMetadata(changeData)
                guard header.cursor == cursor else { throw SyncJournalError.corruptRecord }
                let key = "revision:" + header.entityKey
                let known = Int64(try metadata(key) ?? "0") ?? 0
                try setMetadata(key, String(max(known, header.revision)))
                try execute("UPDATE sync_inbox SET applied=1 WHERE cursor=?", [.integer(cursor)])
                if try rows("SELECT cursor FROM sync_inbox WHERE applied=0 LIMIT 1").isEmpty {
                    guard let next = try metadata("inbox_page_end") else { throw SyncJournalError.corruptRecord }
                    try setMetadata("cursor", next)
                    try execute("DELETE FROM sync_metadata WHERE key IN ('inbox_page_start','inbox_page_end')")
                }
            }
        }
    }

    func entries(whereClause: String, bindings: [Value] = [], limit: Int? = nil) throws -> [SyncJournalEntry] {
        let limitSQL = limit.map { " LIMIT \($0)" } ?? ""
        return try rows("SELECT sequence,envelope,local_replay,state,blocked_reason FROM sync_outbox WHERE \(whereClause) ORDER BY sequence\(limitSQL)", bindings).map { row in
            guard let sequence = row[0].integer, let data = row[1].data, let replay = row[2].data,
                  let rawState = row[3].text, let state = SyncJournalEntry.State(rawValue: rawState) else { throw SyncJournalError.corruptRecord }
            return SyncJournalEntry(sequence: sequence, mutation: try SyncMutationEnvelope.decode(data), localReplayData: replay, state: state, blockedReason: row[4].text)
        }
    }

    func requireActive() throws {
        guard try metadata("suspended") == "0" else { throw SyncJournalError.suspended }
    }

    func metadata(_ key: String) throws -> String? {
        try rows("SELECT value FROM sync_metadata WHERE key=?", [.text(key)]).first?[0].text
    }

    func setMetadata(_ key: String, _ value: String) throws {
        try execute("INSERT INTO sync_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    enum Value {
        case text(String), blob(Data), integer(Int64), null
        var text: String? { if case .text(let value) = self { return value }; return nil }
        var data: Data? { if case .blob(let value) = self { return value }; return nil }
        var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    }

    private func statement(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else { throw SyncJournalError.database(code) }
        do {
            guard sqlite3_bind_parameter_count(handle) == bindings.count else { throw SyncJournalError.corruptRecord }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in bindings.enumerated() {
                let position = Int32(index + 1)
                let result: Int32
                switch value {
                case .null: result = sqlite3_bind_null(handle, position)
                case .integer(let integer): result = sqlite3_bind_int64(handle, position, integer)
                case .text(let text): result = sqlite3_bind_text(handle, position, text, -1, transient)
                case .blob(let original):
                    let data = usesBlobStorage ? try blobStore.store(original) : original
                    if data.isEmpty { result = sqlite3_bind_zeroblob(handle, position, 0) }
                    else { result = data.withUnsafeBytes { sqlite3_bind_blob(handle, position, $0.baseAddress, Int32(data.count), transient) } }
                }
                guard result == SQLITE_OK else { throw SyncJournalError.database(result) }
            }
            return handle
        } catch {
            sqlite3_finalize(handle)
            throw error
        }
    }

    func execute(_ sql: String, _ bindings: [Value] = []) throws {
        let handle = try statement(sql, bindings)
        defer { sqlite3_finalize(handle) }
        var result = sqlite3_step(handle)
        while result == SQLITE_ROW { result = sqlite3_step(handle) }
        guard result == SQLITE_DONE else { throw SyncJournalError.database(result) }
    }

    func rows(_ sql: String, _ bindings: [Value] = []) throws -> [[Value]] {
        let handle = try statement(sql, bindings)
        defer { sqlite3_finalize(handle) }
        var output = [[Value]]()
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else { throw SyncJournalError.database(code) }
            var row = [Value]()
            for column in 0..<sqlite3_column_count(handle) {
                switch sqlite3_column_type(handle, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(handle, column)))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(handle, column))
                    guard let bytes = sqlite3_column_text(handle, column),
                          let text = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else { throw SyncJournalError.corruptRecord }
                    row.append(.text(text))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(handle, column))
                    if count == 0 { row.append(.blob(Data())) }
                    else {
                        guard let bytes = sqlite3_column_blob(handle, column) else { throw SyncJournalError.corruptRecord }
                        let stored = Data(bytes: bytes, count: count)
                        row.append(.blob(usesBlobStorage ? try blobStore.load(stored) : stored))
                    }
                case SQLITE_NULL: row.append(.null)
                default: throw SyncJournalError.corruptRecord
                }
            }
            output.append(row)
        }
    }
}
