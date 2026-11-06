import Foundation

nonisolated struct SyncResolutionRecord: Equatable, Sendable {
    let resolutionID: String
    let remote: SyncEntitySnapshot
    let choice: SyncConflictResolutionChoice
    let operationIDs: [String]
    let replacement: SyncMutationEnvelope?
    let localReplayData: Data
    let applied: Bool
    let resetsRemoteRevision: Bool
}

extension SyncJournal {
    func createResolutionSchema() throws {
        try execute("CREATE TABLE sync_cancellations (operation_id TEXT PRIMARY KEY, proof BLOB NOT NULL)")
        try execute("CREATE TABLE sync_resolutions (sequence INTEGER PRIMARY KEY AUTOINCREMENT,resolution_id TEXT UNIQUE NOT NULL,entity_key TEXT NOT NULL,remote BLOB NOT NULL,choice TEXT NOT NULL,operation_ids BLOB NOT NULL,replacement BLOB,local_replay BLOB NOT NULL,applied INTEGER NOT NULL DEFAULT 0 CHECK(applied IN (0,1)))")
        try execute("CREATE TABLE sync_resolution_members (resolution_id TEXT NOT NULL,operation_id TEXT NOT NULL,PRIMARY KEY(resolution_id,operation_id))")
    }

    func migrateResolutionSchema() throws {
        try execute("ALTER TABLE sync_outbox RENAME TO sync_outbox_v2")
        try execute("DROP INDEX sync_outbox_entity")
        try execute("CREATE TABLE sync_outbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE,entity_key TEXT NOT NULL,envelope BLOB NOT NULL,local_replay BLOB NOT NULL,state TEXT NOT NULL CHECK(state IN ('prepared','pending','confirmed','superseded')),blocked_reason TEXT,remote_revision INTEGER,remote_cursor INTEGER)")
        try execute("INSERT INTO sync_outbox SELECT * FROM sync_outbox_v2")
        try execute("DROP TABLE sync_outbox_v2")
        try execute("CREATE INDEX sync_outbox_entity ON sync_outbox(entity_key,sequence)")
        try createResolutionSchema()
    }

    /// Persist terminal proof before another asynchronous boundary. Cancelled operations
    /// remain visible as pending resolution, but can no longer be offered to the uploader.
    func recordCancellation(_ result: SyncCancellationResult, for mutation: SyncMutationEnvelope) throws {
        try synchronized {
            try result.validate(for: mutation)
            guard let row = try rows("SELECT envelope,state FROM sync_outbox WHERE operation_id=?", [.text(mutation.operationID)]).first,
                  let bytes = row[0].data, try SyncMutationEnvelope.decode(bytes) == mutation,
                  ["pending", "confirmed"].contains(row[1].text ?? "") else { throw SyncJournalError.invalidTransition }
            let proof = try SyncCanonicalJSON.encode(result.value)
            if let existing = try rows("SELECT proof FROM sync_cancellations WHERE operation_id=?", [.text(mutation.operationID)]).first {
                guard existing[0].data == proof else { throw SyncJournalError.idempotencyConflict }
            }
            if let receipt = result.receipt {
                try confirmUploaded(operationID: receipt.operationID, revision: receipt.revision, cursor: receipt.cursor, payloadHash: receipt.payloadSHA256)
            }
            try transaction {
                if let existing = try rows("SELECT proof FROM sync_cancellations WHERE operation_id=?", [.text(mutation.operationID)]).first {
                    guard existing[0].data == proof else { throw SyncJournalError.idempotencyConflict }
                } else {
                    try execute("INSERT INTO sync_cancellations(operation_id,proof) VALUES(?,?)", [.text(mutation.operationID), .blob(proof)])
                }
                if result.receipt == nil {
                    guard row[1].text == "pending" else { throw SyncJournalError.invalidTransition }
                    try execute("UPDATE sync_outbox SET blocked_reason='resolution_pending' WHERE operation_id=?", [.text(mutation.operationID)])
                }
            }
        }
    }

    func hasPendingResolution() throws -> Bool {
        try synchronized { try !rows("SELECT resolution_id FROM sync_resolutions WHERE applied=0 LIMIT 1").isEmpty }
    }

    func prepareResolution(remote: SyncEntitySnapshot, choice: SyncConflictResolutionChoice, operationIDs: [String],
                           replacement: SyncDocument?, localReplayData: Data, allowRevisionRegression: Bool = false) throws -> SyncResolutionRecord {
        try synchronized {
            guard remote.collectionGeneration == collectionGeneration else { throw SyncJournalError.generationMismatch }
            guard operationIDs.count == Set(operationIDs).count else { throw SyncJournalError.invalidTransition }
            let mutation: SyncMutationEnvelope?
            if choice == .keepLocal {
                guard remote.state == "active" || (allowRevisionRegression && remote.state == "gone" && remote.revision == 0), let replacement, replacement.entityType == remote.entityType,
                      replacement.entityID == remote.entityID else { throw SyncJournalError.invalidTransition }
                mutation = try SyncMutationEnvelope(collectionGeneration: collectionGeneration, entityType: remote.entityType,
                    entityID: remote.entityID, baseRevision: remote.revision, mutation: .upsert, document: replacement)
            } else {
                guard replacement == nil else { throw SyncJournalError.invalidTransition }
                mutation = nil
            }
            let record = SyncResolutionRecord(resolutionID: UUID().uuidString.lowercased(), remote: remote, choice: choice,
                                              operationIDs: operationIDs.sorted(), replacement: mutation, localReplayData: localReplayData, applied: false,
                                              resetsRemoteRevision: allowRevisionRegression)
            try transaction {
                let known = try knownRemoteRevision(entityKey: remote.entityKey)
                guard try pendingLocalReplays().isEmpty, try !hasPendingResolution(),
                      allowRevisionRegression || known <= remote.revision else { throw SyncJournalError.invalidTransition }
                let pending = try unresolvedMutations(entityKey: remote.entityKey)
                guard pending.map(\.mutation.operationID).sorted() == record.operationIDs else { throw SyncJournalError.invalidTransition }
                for entry in pending {
                    guard entry.state == .pending, let proof = try rows("SELECT proof FROM sync_cancellations WHERE operation_id=?", [.text(entry.mutation.operationID)]).first?[0].data else { throw SyncJournalError.invalidTransition }
                    let cancelled = try SyncCancellationResult(value: SyncCanonicalJSON.decode(proof))
                    try cancelled.validate(for: entry.mutation)
                    guard cancelled.receipt == nil else { throw SyncJournalError.invalidTransition }
                }
                let ids = try SyncCanonicalJSON.encode(.array(record.operationIDs.map(SyncJSONValue.string)))
                try execute("INSERT INTO sync_resolutions(resolution_id,entity_key,remote,choice,operation_ids,replacement,local_replay) VALUES(?,?,?,?,?,?,?)", [
                    .text(record.resolutionID), .text(remote.entityKey), .blob(try remote.canonicalData()), .text(choice.rawValue), .blob(ids),
                    try mutation.map { .blob(try $0.canonicalData()) } ?? .null, .blob(localReplayData)
                ])
                if allowRevisionRegression { try setMetadata("resolution_regression:" + record.resolutionID, "1") }
                for id in record.operationIDs { try execute("INSERT INTO sync_resolution_members(resolution_id,operation_id) VALUES(?,?)", [.text(record.resolutionID), .text(id)]) }
            }
            return record
        }
    }

    func pendingResolutions() throws -> [SyncResolutionRecord] {
        try synchronized { try resolutionRows("WHERE applied=0 ORDER BY sequence") }
    }

    /// Called only after the local replay succeeds. Superseded means explicitly replaced
    /// after terminal cancellation; it is never confused with a verified remote commit.
    func finalizeResolution(resolutionID: String) throws {
        try synchronized {
            try transaction {
                guard let record = try resolutionRows("WHERE resolution_id=?", bindings: [.text(resolutionID)]).first else { throw SyncJournalError.invalidTransition }
                if record.applied { return }
                guard try unresolvedMutations(entityKey: record.remote.entityKey).map(\.mutation.operationID).sorted() == record.operationIDs else { throw SyncJournalError.invalidTransition }
                for id in record.operationIDs {
                    try execute("UPDATE sync_outbox SET state='superseded',blocked_reason=NULL WHERE operation_id=? AND state='pending'", [.text(id)])
                }
                if let replacement = record.replacement {
                    try execute("INSERT INTO sync_outbox(operation_id,entity_key,envelope,local_replay,state) VALUES(?,?,?,?,'pending')", [
                        .text(replacement.operationID), .text(replacement.entityKey), .blob(try replacement.canonicalData()), .blob(record.localReplayData)
                    ])
                }
                let known = try knownRemoteRevision(entityKey: record.remote.entityKey)
                try setMetadata("revision:" + record.remote.entityKey, String(record.resetsRemoteRevision ? record.remote.revision : max(known, record.remote.revision)))
                try execute("UPDATE sync_resolutions SET applied=1 WHERE resolution_id=?", [.text(resolutionID)])
                try execute("DELETE FROM sync_metadata WHERE key=?", [.text("retry:" + record.remote.entityKey)])
            }
        }
    }

    func supersededOperationIDs(resolutionID: String) throws -> [String] {
        try synchronized {
            try rows("SELECT o.operation_id FROM sync_outbox o JOIN sync_resolution_members m ON m.operation_id=o.operation_id WHERE m.resolution_id=? AND o.state='superseded' ORDER BY o.sequence", [.text(resolutionID)]).compactMap { $0[0].text }
        }
    }

    private func resolutionRows(_ suffix: String, bindings: [Value] = []) throws -> [SyncResolutionRecord] {
        try rows("SELECT resolution_id,remote,choice,operation_ids,replacement,local_replay,applied FROM sync_resolutions " + suffix, bindings).map { row in
            guard let id = row[0].text, let remote = row[1].data, let choiceText = row[2].text,
                  let choice = SyncConflictResolutionChoice(rawValue: choiceText), let idsData = row[3].data,
                  case .array(let ids) = try SyncCanonicalJSON.decode(idsData), let replay = row[5].data, let applied = row[6].integer else { throw SyncJournalError.corruptRecord }
            let operationIDs = try ids.map { value -> String in guard let id = value.string else { throw SyncJournalError.corruptRecord }; try SyncIdentifier.validate(id); return id }
            return SyncResolutionRecord(resolutionID: id, remote: try SyncEntitySnapshot(value: SyncCanonicalJSON.decode(remote, maximumBytes: Int.max)),
                choice: choice, operationIDs: operationIDs, replacement: try row[4].data.map(SyncMutationEnvelope.decode), localReplayData: replay, applied: applied == 1,
                resetsRemoteRevision: try metadata("resolution_regression:" + id) == "1")
        }
    }
}
