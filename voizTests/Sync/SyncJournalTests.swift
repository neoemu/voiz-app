import Foundation
import Testing

@Suite("Sync durable account journal")
struct SyncJournalTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Sync-Journal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func journal(_ directory: URL, account: String = "synthetic-account") throws -> SyncJournal {
        try SyncJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"), accountID: account, collectionGeneration: SyncTestFixtures.generation)
    }

    @Test func crashBeforeAndAfterLocalWriteRetainsReplayAndStableOperation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutation = try SyncTestFixtures.mutation(SyncTestFixtures.folder())
        let replay = Data("PRIVATE_LOCAL_REPLAY".utf8)
        do {
            let store = try journal(directory)
            try store.prepare(mutation, localReplayData: replay)
            #expect(try store.pendingUploads().isEmpty)
        }
        let reopened = try journal(directory)
        let pending = try reopened.pendingLocalReplays()
        #expect(pending.count == 1)
        #expect(pending.first?.mutation.operationID == mutation.operationID)
        #expect(pending.first?.localReplayData == replay)
        #expect(!String(data: try mutation.canonicalData(), encoding: .utf8)!.contains("PRIVATE_LOCAL_REPLAY"))
        try reopened.markLocalApplied(operationID: mutation.operationID)
        try reopened.markLocalApplied(operationID: mutation.operationID)
        #expect(try reopened.pendingLocalReplays().isEmpty)
        #expect(try reopened.pendingUploads().first?.mutation == mutation)
    }

    @Test func replayAndConfirmationAreIdempotentButConflictingBytesAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let mutation = try SyncTestFixtures.mutation(SyncTestFixtures.folder())
        try store.prepare(mutation, localReplayData: Data())
        try store.prepare(mutation, localReplayData: Data())
        #expect(try store.pendingLocalReplays().count == 1)
        #expect(throws: SyncJournalError.idempotencyConflict) { try store.prepare(mutation, localReplayData: Data([1])) }
        try store.markLocalApplied(operationID: mutation.operationID)
        try store.confirmUploaded(operationID: mutation.operationID, revision: 1, cursor: 2, payloadHash: mutation.payloadSHA256)
        try store.confirmUploaded(operationID: mutation.operationID, revision: 1, cursor: 2, payloadHash: mutation.payloadSHA256)
        #expect(throws: SyncJournalError.idempotencyConflict) {
            try store.confirmUploaded(operationID: mutation.operationID, revision: 1, cursor: 3, payloadHash: mutation.payloadSHA256)
        }
        #expect(try store.pendingUploads().isEmpty)
        #expect(try store.knownRemoteRevision(entityKey: mutation.entityKey) == 1)
    }

    @Test func orderingAndSuspensionPreserveAccountBoundaries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let first = try SyncTestFixtures.mutation(SyncTestFixtures.folder())
        let second = try SyncTestFixtures.mutation(SyncTestFixtures.folder(name: "Later"), baseRevision: 1)
        for operation in [first, second] {
            try store.prepare(operation, localReplayData: Data())
            try store.markLocalApplied(operationID: operation.operationID)
        }
        #expect(try store.pendingUploads().map(\.mutation.operationID) == [first.operationID])
        try store.setSuspended(true)
        #expect(try store.pendingUploads().isEmpty)
        #expect(throws: SyncJournalError.accountMismatch) { _ = try journal(directory, account: "other-account") }
        let reopened = try journal(directory)
        #expect(try reopened.pendingUploads().isEmpty)
        try reopened.setSuspended(false)
        try reopened.confirmUploaded(operationID: first.operationID, revision: 1, cursor: 1, payloadHash: first.payloadSHA256)
        #expect(try reopened.pendingUploads().map(\.mutation.operationID) == [second.operationID])
    }

    @Test func batchPreparationAndApplicationRollbackTogether() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let existing = try SyncTestFixtures.mutation(SyncTestFixtures.folder())
        let new = try SyncTestFixtures.mutation(SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000004"))
        try store.prepare(existing, localReplayData: Data([1]))
        try store.markLocalApplied(operationID: existing.operationID)
        #expect(throws: SyncJournalError.idempotencyConflict) {
            try store.prepareBatch([(new, Data()), (existing, Data([2]))])
        }
        #expect(try store.pendingLocalReplays().isEmpty)
        try store.prepareBatch([(new, Data()), (existing, Data([1]))])
        #expect(throws: SyncJournalError.invalidTransition) {
            try store.markLocalAppliedBatch(operationIDs: [new.operationID, UUID().uuidString.lowercased()])
        }
        #expect(try store.pendingLocalReplays().count == 1)
        try store.markLocalAppliedBatch(operationIDs: [new.operationID, existing.operationID])
        #expect(try store.pendingLocalReplays().isEmpty)
        #expect(try store.nextBaseRevision(entityKey: existing.entityKey) == 1)
    }

    @Test func preparedSnapshotCannotBeOvertakenAndSuspensionStillSavesLocalWork() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try journal(directory)
        let first = try SyncTestFixtures.mutation(SyncTestFixtures.folder())
        let later = try SyncTestFixtures.mutation(SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000004"))
        try store.prepare(first, localReplayData: Data([1]))
        #expect(throws: SyncJournalError.invalidTransition) { try store.prepare(later, localReplayData: Data([2])) }
        try store.markLocalApplied(operationID: first.operationID)
        try store.setSuspended(true)
        try store.prepare(later, localReplayData: Data([2]))
        try store.markLocalApplied(operationID: later.operationID)
        #expect(try store.pendingUploads().isEmpty)
        try store.setSuspended(false)
        #expect(try store.pendingUploads().count == 2)
    }

    @Test func inboxReplayDoesNotAdvanceCursorUntilEntirePageIsApplied() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try SyncTestFixtures.folder()
        let other = try SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000003")
        let changes = try [document, other].enumerated().map { index, item in
            try SyncRemoteChange(collectionGeneration: SyncTestFixtures.generation, cursor: Int64(index + 1), revision: 1,
                                 entityType: .folder, entityID: item.entityID, mutation: .upsert, document: item)
        }
        do {
            let store = try journal(directory)
            try store.receive(changes, afterCursor: 0, nextCursor: 2)
            try store.receive(changes, afterCursor: 0, nextCursor: 2)
            #expect(throws: SyncJournalError.invalidTransition) { try store.markRemoteApplied(cursor: 2) }
            try store.markRemoteApplied(cursor: 1)
            #expect(try store.currentCursor() == 0)
        }
        let reopened = try journal(directory)
        #expect(try reopened.pendingRemoteApplications().map(\.change.cursor) == [2])
        try reopened.markRemoteApplied(cursor: 2)
        #expect(try reopened.currentCursor() == 2)
        #expect(try reopened.pendingRemoteApplications().isEmpty)
        #expect(throws: SyncJournalError.cursorMismatch) { try reopened.receive(changes, afterCursor: 0, nextCursor: 2) }
    }
}
