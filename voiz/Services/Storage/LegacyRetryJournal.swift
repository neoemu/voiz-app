import Foundation

nonisolated enum SyncRetryResult: Sendable { case completed, remoteChanged }

extension SyncJournal {
    /// Metadata pages keep an old blocked operation reachable behind a large inventory.
    func retryEntityKeys(after key: String = "", limit: Int = 50) throws -> [String] {
        try synchronized {
            try rows("""
                SELECT entity_key FROM sync_outbox WHERE entity_key>? AND state='pending'
                GROUP BY entity_key HAVING
                    SUM(CASE WHEN blocked_reason IN ('unauthenticated','entitlement_required','consent_required','quota_exceeded','rate_limited','temporarily_unavailable','gone','revision_conflict') THEN 1 ELSE 0 END)>0
                    OR COUNT(*)>1 OR EXISTS(SELECT 1 FROM sync_metadata WHERE key='retry:'||entity_key)
                ORDER BY entity_key LIMIT ?
                """, [.text(key), .integer(Int64(max(1, min(limit, 100))))]).compactMap { $0[0].text }
        }
    }

    func isAutomaticRetryPending(entityKey: String) throws -> Bool {
        try synchronized { try metadata("retry:" + entityKey) == "1" }
    }

    func beginAutomaticRetry(entityKey: String) throws {
        try synchronized {
            guard try pendingLocalReplays().isEmpty, try !hasPendingResolution() else { throw SyncJournalError.invalidTransition }
            try setMetadata("retry:" + entityKey, "1")
        }
    }

    func hasTerminalCancellation(_ mutation: SyncMutationEnvelope) throws -> Bool {
        try synchronized {
            guard let data = try rows("SELECT proof FROM sync_cancellations WHERE operation_id=?", [.text(mutation.operationID)]).first?[0].data else { return false }
            let result = try SyncCancellationResult(value: SyncCanonicalJSON.decode(data))
            try result.validate(for: mutation)
            return result.receipt == nil
        }
    }

    /// Queue-only recovery: private model writes already completed before these pending
    /// operations existed. One FULL SQLite transaction replaces the queue; no model replay
    /// or cursor advancement is invented. Old payload/replay bytes remain exportable.
    func finishAutomaticRetry(remote: SyncEntitySnapshot, originalOperationIDs: Set<String>) throws -> SyncRetryResult {
        try synchronized {
            guard remote.collectionGeneration == collectionGeneration else { throw SyncJournalError.generationMismatch }
            return try transaction {
                guard try metadata("retry:" + remote.entityKey) == "1", try pendingLocalReplays().isEmpty,
                      try !hasPendingResolution() else { throw SyncJournalError.invalidTransition }
                let pending = try unresolvedMutations(entityKey: remote.entityKey)
                guard Set(pending.map(\.mutation.operationID)).isSubset(of: originalOperationIDs) else { throw SyncJournalError.invalidTransition }
                for entry in pending {
                    guard entry.state == .pending, try hasTerminalCancellation(entry.mutation) else { throw SyncJournalError.invalidTransition }
                }
                guard let first = pending.first else {
                    try execute("DELETE FROM sync_metadata WHERE key=?", [.text("retry:" + remote.entityKey)])
                    return .completed
                }
                // Two installations may independently enqueue identical initial settings.
                // Only terminal cancellation proofs plus a fresh active remote document
                // can retire those edits; lifecycle transitions are never folded here.
                let knownRevision = try knownRemoteRevision(entityKey: remote.entityKey)
                let alreadyEquivalent = remote.state == "active" && remote.revision >= knownRevision && remote.revision > first.mutation.baseRevision &&
                    pending.allSatisfy { $0.mutation.mutation == .upsert } &&
                    pending.last?.mutation.document == remote.document
                let alreadyPurged = remote.state == "gone" && pending.last?.mutation.mutation == .purge
                guard alreadyEquivalent || alreadyPurged || (remote.revision == first.mutation.baseRevision &&
                      (remote.state != "gone" || remote.revision == 0)) else {
                    for entry in pending { try blockUpload(operationID: entry.mutation.operationID, reason: "revision_conflict") }
                    try execute("DELETE FROM sync_metadata WHERE key=?", [.text("retry:" + remote.entityKey)])
                    return .remoteChanged
                }
                // Collapse only consecutive edits, or an explicitly requested final purge.
                // Lifecycle boundaries remain ordered; the superseded audit retains edits.
                var replacements: [SyncJournalEntry] = []
                if alreadyEquivalent {
                    replacements = []
                } else if pending.last?.mutation.mutation == .purge {
                    if remote.state != "gone" { replacements = [pending.last!] }
                } else {
                    for entry in pending {
                        if entry.mutation.mutation == .upsert, replacements.last?.mutation.mutation == .upsert { replacements.removeLast() }
                        replacements.append(entry)
                    }
                }
                var base = remote.revision
                for entry in pending {
                    try execute("UPDATE sync_outbox SET state='superseded',blocked_reason=NULL WHERE operation_id=? AND state='pending'", [.text(entry.mutation.operationID)])
                }
                for entry in replacements {
                    let previous = entry.mutation
                    let replacement = try SyncMutationEnvelope(collectionGeneration: collectionGeneration,
                        entityType: previous.entityType, entityID: previous.entityID, baseRevision: base,
                        mutation: previous.mutation, document: previous.document)
                    try execute("INSERT INTO sync_outbox(operation_id,entity_key,envelope,local_replay,state) VALUES(?,?,?,?,'pending')", [
                        .text(replacement.operationID), .text(replacement.entityKey), .blob(try replacement.canonicalData()), .blob(entry.localReplayData)
                    ])
                    base += 1
                }
                try setMetadata("revision:" + remote.entityKey, String(remote.revision))
                try execute("DELETE FROM sync_metadata WHERE key=?", [.text("retry:" + remote.entityKey)])
                return .completed
            }
        }
    }
}

/// Runs inside the engine's single-flight section, after remote catch-up and before uploads.
/// Cancellation timeouts leave the original IDs and durable retry marker for the next run.
