import Foundation
import Testing

@Suite("Sync snapshot staging and crash recovery")
struct SyncSnapshotJournalTests {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Sync-Snapshot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func open(_ directory: URL) throws -> SyncJournal {
        try SyncJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"), accountID: "synthetic", collectionGeneration: SyncTestFixtures.generation)
    }
    private func change(_ document: SyncDocument, cursor: Int64) throws -> SyncRemoteChange {
        try SyncRemoteChange(collectionGeneration: SyncTestFixtures.generation, cursor: cursor, revision: 1, entityType: .folder, entityID: document.entityID, mutation: .upsert, document: document)
    }
    private func page(id: String, changes: [SyncRemoteChange], next: String?) throws -> SyncSnapshotPage {
        try SyncSnapshotPage(value: .object([
            "schema_version": .integer(1), "collection_generation": .string(SyncTestFixtures.generation), "snapshot_id": .string(id),
            "cursor": .integer(50), "entities": .array(try changes.map { try SyncCanonicalJSON.decode($0.canonicalData()) }),
            "next_page": next.map(SyncJSONValue.string) ?? .null
        ]))
    }

    @Test func cursorRollbackRequiresDurableServerAuthorizationAndSurvivesReopen() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try open(path)
        try store.receive([], afterCursor: 0, nextCursor: 150)
        let snapshot = try page(id: UUID().uuidString.lowercased(), changes: [], next: nil)
        #expect(throws: SyncJournalError.cursorMismatch) { try store.receiveSnapshotPage(snapshot, requestedPage: nil) }
        try store.authorizeSnapshotRecovery()
        let reopened = try open(path)
        try reopened.receiveSnapshotPage(snapshot, requestedPage: nil)
        #expect(try reopened.snapshotProgress()?.isRecovery == true)
        #expect(try reopened.currentCursor() == 150)
        let crashed = try open(path)
        #expect(try crashed.snapshotProgress()?.isRecovery == true)
        try crashed.finishSnapshot()
        #expect(try crashed.currentCursor() == 50)
        #expect(try crashed.metadata("snapshot_recovery_authorized") == nil)
    }

    @Test func pagesAndApplicationResumeWithoutMovingCursorOrDiscardingOutbox() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let first = try change(SyncTestFixtures.folder(), cursor: 20)
        let second = try change(SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000003"), cursor: 30)
        let snapshotID = UUID().uuidString.lowercased()
        let local = try SyncTestFixtures.mutation(SyncTestFixtures.folder(name: "Unsynced local text"))
        do {
            let store = try open(path)
            try store.prepare(local, localReplayData: Data("local".utf8))
            try store.receiveSnapshotPage(page(id: snapshotID, changes: [first], next: "page2"), requestedPage: nil)
            #expect(try store.pendingSnapshotApplications().isEmpty)
            #expect(try store.currentCursor() == 0)
            #expect(throws: SyncJournalError.invalidTransition) { try store.finishSnapshot() }
        }
        do {
            let store = try open(path)
            #expect(try store.snapshotProgress()?.nextPage == "page2")
            try store.receiveSnapshotPage(page(id: snapshotID, changes: [second], next: nil), requestedPage: "page2")
            #expect(try store.pendingSnapshotApplications().count == 2)
            #expect(try store.snapshotContains(entityKey: "folder/" + first.entityID))
            try store.markSnapshotApplied(entityKey: "folder/" + first.entityID)
            #expect(try store.currentCursor() == 0)
            #expect(throws: SyncJournalError.invalidTransition) { try store.discardUnappliedSnapshot() }
        }
        let store = try open(path)
        #expect(try store.pendingSnapshotApplications().map(\.entityID) == [second.entityID])
        try store.markSnapshotApplied(entityKey: "folder/" + second.entityID)
        try store.finishSnapshot()
        #expect(try store.currentCursor() == 50)
        #expect(try store.snapshotProgress() == nil)
        #expect(try store.pendingLocalReplays().first?.mutation == local)
    }

    @Test func mixedSnapshotsAndRepeatedEntityPagesRollback() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try open(path)
        let item = try change(SyncTestFixtures.folder(), cursor: 20)
        let snapshotID = UUID().uuidString.lowercased()
        try store.receiveSnapshotPage(page(id: snapshotID, changes: [item], next: "page2"), requestedPage: nil)
        #expect(throws: SyncJournalError.cursorMismatch) {
            try store.receiveSnapshotPage(page(id: UUID().uuidString.lowercased(), changes: [], next: nil), requestedPage: "page2")
        }
        #expect(throws: (any Error).self) {
            try store.receiveSnapshotPage(page(id: snapshotID, changes: [item], next: nil), requestedPage: "page2")
        }
        #expect(try store.snapshotProgress()?.nextPage == "page2")
        #expect(try store.currentCursor() == 0)
        try store.discardUnappliedSnapshot()
        #expect(try store.snapshotProgress() == nil)
    }
}
