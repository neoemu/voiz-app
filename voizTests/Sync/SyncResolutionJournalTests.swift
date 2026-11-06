import Foundation
import Testing

@Suite("Sync terminal conflict resolution journal")
struct SyncResolutionJournalTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Sync-Resolution-" + UUID().uuidString) }
    private func journal(_ directory: URL) throws -> SyncJournal {
        try SyncJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"), accountID: "synthetic", collectionGeneration: SyncTestFixtures.generation)
    }
    private func prepare(_ journal: SyncJournal, name: String = "Local") throws -> SyncMutationEnvelope {
        let mutation = try SyncTestFixtures.mutation(SyncTestFixtures.folder(name: name))
        try journal.prepare(mutation, localReplayData: Data("PRIVATE_REPLAY".utf8))
        try journal.markLocalApplied(operationID: mutation.operationID)
        return mutation
    }

    @Test func uncertainOperationCannotBeSupersededWithoutTerminalCancellation() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let mutation = try prepare(store)
        let remote = try SyncResolutionFixtures.snapshot(SyncTestFixtures.folder(name: "Remote"))
        #expect(throws: SyncJournalError.invalidTransition) {
            _ = try store.prepareResolution(remote: remote, choice: .keepRemote, operationIDs: [mutation.operationID], replacement: nil, localReplayData: Data())
        }
        #expect(try store.pendingWorkCount() == 1)
        #expect(try store.pendingResolutions().isEmpty)
        #expect(try store.pendingUploads().first?.mutation.operationID == mutation.operationID)
    }

    @Test func crashRecoveryKeepsOneReplacementIDAndDistinguishesSupersededFromConfirmed() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let original = try prepare(store)
        try store.recordCancellation(SyncResolutionFixtures.cancelled(original), for: original)
        let selected = try SyncTestFixtures.folder(name: "Selected local version")
        let remote = try SyncResolutionFixtures.snapshot(SyncTestFixtures.folder(name: "Remote"), revision: 3)
        let resolution = try store.prepareResolution(remote: remote, choice: .keepLocal, operationIDs: [original.operationID], replacement: selected, localReplayData: Data([7]))
        #expect(try store.pendingUploads().isEmpty)
        let newer = try SyncTestFixtures.mutation(SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000005"))
        #expect(throws: SyncJournalError.invalidTransition) { try store.prepare(newer, localReplayData: Data()) }
        let reopened = try journal(directory)
        #expect(try reopened.pendingResolutions().first == resolution)
        try reopened.finalizeResolution(resolutionID: resolution.resolutionID)
        try reopened.finalizeResolution(resolutionID: resolution.resolutionID)
        let replacement = try #require(resolution.replacement)
        #expect(replacement.baseRevision == 3)
        #expect(replacement.operationID != original.operationID)
        #expect(try reopened.pendingUploads().map(\.mutation.operationID) == [replacement.operationID])
        #expect(try reopened.supersededOperationIDs(resolutionID: resolution.resolutionID) == [original.operationID])
        #expect(try reopened.knownRemoteRevision(entityKey: original.entityKey) == 3)
        #expect(try reopened.pendingResolutions().isEmpty)
        #expect(throws: SyncJournalError.invalidTransition) {
            try reopened.confirmUploaded(operationID: original.operationID, revision: 1, cursor: 1, payloadHash: original.payloadSHA256)
        }
    }

    @Test func keepRemoteCreatesNoUploadAndContradictoryTerminalProofChangesNothing() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let mutation = try prepare(store)
        let cancelled = try SyncResolutionFixtures.cancelled(mutation)
        try store.recordCancellation(cancelled, for: mutation)
        let committed = try SyncResolutionFixtures.committed(mutation)
        #expect(throws: SyncJournalError.idempotencyConflict) { try store.recordCancellation(committed, for: mutation) }
        #expect(try store.unresolvedMutations(entityKey: mutation.entityKey).count == 1)
        let remote = try SyncResolutionFixtures.snapshot(SyncTestFixtures.folder(name: "Remote"))
        let resolution = try store.prepareResolution(remote: remote, choice: .keepRemote, operationIDs: [mutation.operationID], replacement: nil, localReplayData: Data())
        try store.finalizeResolution(resolutionID: resolution.resolutionID)
        #expect(try store.pendingWorkCount() == 0)
        #expect(try store.pendingUploads().isEmpty)
        #expect(try store.supersededOperationIDs(resolutionID: resolution.resolutionID) == [mutation.operationID])
    }

    @Test func alreadyCommittedProofConfirmsOriginalInsteadOfCallingItSuperseded() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let mutation = try prepare(store)
        try store.recordCancellation(SyncResolutionFixtures.committed(mutation), for: mutation)
        #expect(try store.unresolvedMutations(entityKey: mutation.entityKey).isEmpty)
        let remote = try SyncResolutionFixtures.snapshot(mutation.document!)
        let resolution = try store.prepareResolution(remote: remote, choice: .keepRemote, operationIDs: [], replacement: nil, localReplayData: Data())
        try store.finalizeResolution(resolutionID: resolution.resolutionID)
        #expect(try store.supersededOperationIDs(resolutionID: resolution.resolutionID).isEmpty)
        #expect(try store.knownRemoteRevision(entityKey: mutation.entityKey) == 1)
    }

    @Test func versionTwoMigrationPreservesSequenceStatesAndReplayBytes() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let mutation = try prepare(store)
        try store.transaction {
            try store.execute("ALTER TABLE sync_outbox RENAME TO old_outbox")
            try store.execute("DROP INDEX sync_outbox_entity")
            try store.execute("CREATE TABLE sync_outbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE,entity_key TEXT NOT NULL,envelope BLOB NOT NULL,local_replay BLOB NOT NULL,state TEXT NOT NULL CHECK(state IN ('prepared','pending','confirmed')),blocked_reason TEXT,remote_revision INTEGER,remote_cursor INTEGER)")
            try store.execute("INSERT INTO sync_outbox SELECT * FROM old_outbox")
            try store.execute("DROP TABLE old_outbox")
            try store.execute("CREATE INDEX sync_outbox_entity ON sync_outbox(entity_key,sequence)")
            for table in ["sync_cancellations", "sync_resolutions", "sync_resolution_members"] { try store.execute("DROP TABLE " + table) }
            try store.setMetadata("schema_version", "2")
        }
        // A genuine v2 database stores raw bytes (without the v4 blob tag).
        let envelopeHex = try mutation.canonicalData().map { String(format: "%02x", $0) }.joined()
        let replayHex = Data("PRIVATE_REPLAY".utf8).map { String(format: "%02x", $0) }.joined()
        try store.execute("UPDATE sync_outbox SET envelope=X'" + envelopeHex + "',local_replay=X'" + replayHex + "'")
        let reopened = try journal(directory)
        let entries = try reopened.pendingUploads()
        #expect(entries.first?.sequence == 1)
        #expect(entries.first?.mutation == mutation)
        #expect(entries.first?.localReplayData == Data("PRIVATE_REPLAY".utf8))
        #expect(try reopened.metadata("schema_version") == "4")
        #expect(try reopened.pendingResolutions().isEmpty)
    }
}

nonisolated enum SyncResolutionFixtures {
    static func snapshot(_ document: SyncDocument, revision: Int64 = 1) throws -> SyncEntitySnapshot {
        try SyncEntitySnapshot(value: .object([
            "schema_version": .integer(1), "collection_generation": .string(SyncTestFixtures.generation),
            "entity_type": .string(document.entityType.rawValue), "entity_id": .string(document.entityID),
            "cursor": .integer(revision), "revision": .integer(revision), "state": .string("active"),
            "payload": document.value, "payload_sha256": .string(try document.sha256), "trash_expires_at_ms": .null
        ]))
    }
    static func cancelled(_ mutation: SyncMutationEnvelope) throws -> SyncCancellationResult {
        try SyncCancellationResult(value: .object([
            "schema_version": .integer(1), "collection_generation": .string(mutation.collectionGeneration),
            "operation_id": .string(mutation.operationID), "state": .string("cancelled"), "receipt": .null
        ]))
    }
    static func committed(_ mutation: SyncMutationEnvelope) throws -> SyncCancellationResult {
        try SyncCancellationResult(value: .object([
            "schema_version": .integer(1), "collection_generation": .string(mutation.collectionGeneration),
            "operation_id": .string(mutation.operationID), "state": .string("committed"), "receipt": .object([
                "schema_version": .integer(1), "collection_generation": .string(mutation.collectionGeneration),
                "operation_id": .string(mutation.operationID), "entity_type": .string(mutation.entityType.rawValue), "entity_id": .string(mutation.entityID),
                "revision": .integer(mutation.baseRevision + 1), "cursor": .integer(mutation.baseRevision + 1),
                "payload_sha256": .string(mutation.payloadSHA256), "logical_bytes": .integer(Int64(try mutation.document!.quotaBytes)), "state": .string("active")
            ])
        ]))
    }
}
