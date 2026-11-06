import Foundation
import Testing

@MainActor
@Suite("Sync local prepare and replay")
struct SyncLocalChangeWriterTests {
    private enum SimulatedFailure: Error { case disk }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Sync-Writer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func context(_ directory: URL) throws -> SyncLibraryContext {
        SyncLibraryContext(libraryID: UUID(), ownerAccountID: "synthetic-account", collectionGeneration: SyncTestFixtures.generation,
            rootURL: directory, journal: try SyncJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"),
                accountID: "synthetic-account", collectionGeneration: SyncTestFixtures.generation))
    }

    @Test func completeBatchIsPreparedBeforePersistenceAndReplaysOnceAfterFailure() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try context(directory)
        let writer = SyncLocalChangeWriter(context: context)
        let journal = try #require(context.journal)
        let documents = try [SyncTestFixtures.folder(), SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000004")]
        let localFile = directory.appendingPathComponent("local.bin")
        let replay = Data("PRIVATE_LOCAL_SNAPSHOT".utf8)
        do {
            try writer.write(documents: documents, localReplayData: replay) {
                #expect(try journal.pendingLocalReplays().count == 2)
                #expect(try journal.pendingUploads().isEmpty)
                try replay.write(to: localFile, options: .atomic)
                throw SimulatedFailure.disk
            }
            Issue.record("Expected persistence failure")
        } catch SimulatedFailure.disk {}
        let oldIDs = try journal.pendingLocalReplays().map(\.mutation.operationID)
        #expect(throws: SyncJournalError.invalidTransition) {
            try writer.write(documents: [SyncTestFixtures.folder(name: "newer")], localReplayData: Data([2])) {
                throw SimulatedFailure.disk
            }
        }
        var applyCount = 0
        try SyncLocalChangeWriter(context: context).recoverPendingLocal {
            applyCount += 1
            #expect($0 == replay)
            try $0.write(to: localFile, options: .atomic)
        }
        #expect(applyCount == 1)
        #expect(try Data(contentsOf: localFile) == replay)
        #expect(try journal.pendingLocalReplays().isEmpty)
        #expect(try journal.pendingUploads().map(\.mutation.operationID) == oldIDs)
        try writer.recoverPendingLocal { _ in Issue.record("Already applied snapshot replayed") }
    }

    @Test func failedReplayKeepsEveryMemberPrepared() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try context(directory)
        let writer = SyncLocalChangeWriter(context: context)
        let documents = try [SyncTestFixtures.folder(), SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000004")]
        #expect(throws: SimulatedFailure.self) { try writer.write(documents: documents, localReplayData: Data([1])) { throw SimulatedFailure.disk } }
        #expect(throws: SimulatedFailure.self) { try writer.recoverPendingLocal { _ in throw SimulatedFailure.disk } }
        let journal = try #require(context.journal)
        #expect(try journal.pendingLocalReplays().count == 2)
        #expect(try journal.pendingUploads().isEmpty)
    }

    @Test func exportsNeedNoLocalReplayAndLifecycleUsesTheCausalRevision() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try context(directory)
        let writer = SyncLocalChangeWriter(context: context)
        let journal = try #require(context.journal)
        let document = try SyncTestFixtures.folder()
        try writer.enqueueExisting([document])
        let pendingExports = try journal.pendingUploads()
        let export = try #require(pendingExports.first)
        try writer.applyReplay(export) { _ in Issue.record("Export-only intent attempted a local write") }
        try writer.write(mutations: [.trash(.folder, document.entityID)], localReplayData: Data([1])) {}
        let chain = try journal.unresolvedMutations(entityKey: "folder/" + document.entityID)
        #expect(chain.map(\.mutation.baseRevision) == [0, 1])
        #expect(chain.last?.mutation.mutation == .trash)
        #expect(chain.last?.mutation.document == nil)
        #expect(try journal.pendingUploads().count == 1)
    }

    @Test func anotherLibraryCannotReplayPrivateBytes() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try context(directory)
        let writer = SyncLocalChangeWriter(context: context)
        #expect(throws: SimulatedFailure.self) { try writer.write(documents: [SyncTestFixtures.folder()], localReplayData: Data([1])) { throw SimulatedFailure.disk } }
        let journal = try #require(context.journal)
        let pendingReplays = try journal.pendingLocalReplays()
        let entry = try #require(pendingReplays.first)
        let other = SyncLibraryContext(libraryID: UUID(), ownerAccountID: context.ownerAccountID,
                                      collectionGeneration: context.collectionGeneration, rootURL: directory, journal: journal)
        #expect(throws: SyncLocalChangeWriterError.wrongContext) {
            try SyncLocalChangeWriter(context: other).applyReplay(entry) { _ in Issue.record("Cross-library replay") }
        }
        #expect(try journal.pendingLocalReplays().count == 1)
    }

    @Test func invalidBatchNeverReachesPersistenceAndLocalWithoutSyncHasNoWireLimit() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let synced = try context(directory)
        let writer = SyncLocalChangeWriter(context: synced)
        let document = try SyncTestFixtures.folder()
        #expect(throws: SyncLocalChangeWriterError.duplicateEntity) {
            try writer.write(documents: [document, document], localReplayData: Data()) { Issue.record("Invalid batch persisted") }
        }
        let local = SyncLibraryContext(libraryID: UUID(), ownerAccountID: nil, collectionGeneration: nil, rootURL: directory, journal: nil)
        var persisted = false
        try SyncLocalChangeWriter(context: local).write(mutations: [.trash(.folder, "not-a-wire-id")], localReplayData: Data()) { persisted = true }
        #expect(persisted)
        let journal = try #require(synced.journal)
        #expect(try journal.pendingLocalReplays().isEmpty)
    }
}
