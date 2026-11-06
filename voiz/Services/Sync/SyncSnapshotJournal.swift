import Foundation

nonisolated struct SyncSnapshotProgress: Equatable, Sendable {
    let snapshotID: String
    let cursor: Int64
    let nextPage: String?
    var isRecovery = false
    var isComplete: Bool { nextPage == nil }
}

extension SyncJournal {
    func createSnapshotSchema() throws {
        try execute("CREATE TABLE sync_snapshot (sequence INTEGER PRIMARY KEY AUTOINCREMENT, entity_key TEXT NOT NULL UNIQUE, change BLOB NOT NULL, applied INTEGER NOT NULL CHECK(applied IN (0,1)))")
    }

    func snapshotProgress() throws -> SyncSnapshotProgress? {
        try synchronized {
            guard let id = try metadata("snapshot_id") else { return nil }
            guard let rawCursor = try metadata("snapshot_cursor"), let cursor = Int64(rawCursor), cursor >= 0,
                  let next = try metadata("snapshot_next_page") else { throw SyncJournalError.corruptRecord }
            return SyncSnapshotProgress(snapshotID: id, cursor: cursor, nextPage: next.isEmpty ? nil : next,
                isRecovery: try metadata("snapshot_recovery") == "1")
        }
    }

    /// Called only in response to an authenticated snapshot_required. Persist before
    /// fetching so a crash or expired snapshot does not erase the recovery authorization.
    func authorizeSnapshotRecovery() throws {
        try synchronized { try setMetadata("snapshot_recovery_authorized", "1") }
    }

    /// Each page is staged atomically. Nothing can be applied until a complete snapshot from
    /// one immutable server generation/cursor has arrived. Local outbox entries are untouched.
    func receiveSnapshotPage(_ page: SyncSnapshotPage, requestedPage: String?) throws {
        try synchronized {
            try requireActive()
            guard page.collectionGeneration == collectionGeneration else { throw SyncJournalError.generationMismatch }
            try transaction {
                guard try metadata("inbox_page_end") == nil else { throw SyncJournalError.cursorMismatch }
                if let existing = try snapshotProgress() {
                    guard existing.snapshotID == page.snapshotID, existing.cursor == page.cursor,
                          existing.nextPage != nil, existing.nextPage == requestedPage else { throw SyncJournalError.cursorMismatch }
                } else {
                    guard requestedPage == nil else { throw SyncJournalError.cursorMismatch }
                    let receiptCursor = try rows("SELECT MAX(remote_cursor) FROM sync_outbox").first?[0].integer ?? 0
                    let observed = max(try currentCursor(), receiptCursor)
                    let rollback = page.cursor < observed
                    let recoveryAuthorized = try metadata("snapshot_recovery_authorized") == "1"
                    guard !rollback || recoveryAuthorized else { throw SyncJournalError.cursorMismatch }
                    guard try rows("SELECT sequence FROM sync_snapshot LIMIT 1").isEmpty else { throw SyncJournalError.corruptRecord }
                    try setMetadata("snapshot_recovery", rollback ? "1" : "0")
                    try setMetadata("snapshot_id", page.snapshotID)
                    try setMetadata("snapshot_cursor", String(page.cursor))
                }
                guard page.nextPage != requestedPage || page.nextPage == nil else { throw SyncJournalError.cursorMismatch }
                for change in page.entities {
                    guard change.collectionGeneration == collectionGeneration, change.cursor <= page.cursor else { throw SyncJournalError.generationMismatch }
                    let key = change.entityKey
                    try execute("INSERT INTO sync_snapshot(entity_key,change,applied) VALUES(?,?,0)", [.text(key), .blob(change.bytes)])
                }
                try setMetadata("snapshot_next_page", page.nextPage ?? "")
            }
        }
    }

    func pendingSnapshotApplications(limit: Int = 100) throws -> [SyncRemoteChange] {
        try synchronized {
            guard let progress = try snapshotProgress(), progress.isComplete else { return [] }
            return try rows("SELECT change FROM sync_snapshot WHERE applied=0 ORDER BY sequence LIMIT ?", [.integer(Int64(max(0, min(limit, 200))))]).map { row in
                guard let data = row[0].data else { throw SyncJournalError.corruptRecord }
                return try SyncRemoteChange.decode(data)
            }
        }
    }

    func snapshotContains(entityKey: String) throws -> Bool {
        try synchronized {
            guard let progress = try snapshotProgress(), progress.isComplete else { throw SyncJournalError.invalidTransition }
            return try !rows("SELECT sequence FROM sync_snapshot WHERE entity_key=? LIMIT 1", [.text(entityKey)]).isEmpty
        }
    }

    func markSnapshotApplied(entityKey: String) throws {
        try synchronized {
            try transaction {
                guard let progress = try snapshotProgress(), progress.isComplete else { throw SyncJournalError.invalidTransition }
                guard let row = try rows("SELECT change FROM sync_snapshot WHERE entity_key=?", [.text(entityKey)]).first,
                      let data = row[0].data else { throw SyncJournalError.invalidTransition }
                let header = try SyncRemoteChange.storedMetadata(data)
                guard header.entityKey == entityKey else { throw SyncJournalError.corruptRecord }
                let key = "revision:" + entityKey
                let known = Int64(try metadata(key) ?? "0") ?? 0
                try setMetadata(key, String(max(known, header.revision)))
                try execute("UPDATE sync_snapshot SET applied=1 WHERE entity_key=?", [.text(entityKey)])
            }
        }
    }

    /// Caller reconciles absence against snapshotContains before finishing. Absence is not a
    /// request to upload an old local copy or to delete audio from the local file system.
    func finishSnapshot() throws {
        try synchronized {
            try transaction {
                guard let progress = try snapshotProgress(), progress.isComplete,
                      try rows("SELECT sequence FROM sync_snapshot WHERE applied=0 LIMIT 1").isEmpty else { throw SyncJournalError.invalidTransition }
                try setMetadata("cursor", String(progress.cursor))
                try execute("DELETE FROM sync_inbox WHERE applied=1")
                try execute("DELETE FROM sync_snapshot")
                try execute("DELETE FROM sync_metadata WHERE key IN ('snapshot_id','snapshot_cursor','snapshot_next_page','snapshot_recovery','snapshot_recovery_authorized')")
            }
        }
    }

    /// An expired server snapshot can be discarded only before applying any of its entities.
    /// Once application starts it must finish or be reconciled explicitly, never silently reset.
    func discardUnappliedSnapshot() throws {
        try synchronized {
            try transaction {
                guard try rows("SELECT sequence FROM sync_snapshot WHERE applied=1 LIMIT 1").isEmpty else { throw SyncJournalError.invalidTransition }
                try execute("DELETE FROM sync_snapshot")
                try execute("DELETE FROM sync_metadata WHERE key IN ('snapshot_id','snapshot_cursor','snapshot_next_page','snapshot_recovery')")
            }
        }
    }
}
