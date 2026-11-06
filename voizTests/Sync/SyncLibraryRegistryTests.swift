import Foundation
import Testing

@MainActor
@Suite("Sync immutable library ownership")
struct SyncLibraryRegistryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Sync-Libraries-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func registry(_ directory: URL) throws -> SyncLibraryRegistry {
        try SyncLibraryRegistry(baseURL: directory.appendingPathComponent("registry"), initialLocalRoot: directory.appendingPathComponent("original"))
    }
    private func activate(_ registry: SyncLibraryRegistry, account: String, claim: Bool = false,
                          activeWork: Bool = false, generation: String = SyncTestFixtures.generation,
                          confirmedReset: Bool = false) throws -> SyncLibraryContext {
        try registry.activate(accountID: account, collectionGeneration: generation, claimInitialLocalLibrary: claim,
                              syncConsentConfirmed: true, hasActiveWork: activeWork, confirmedGenerationReset: confirmedReset)
    }

    @Test func initialLibraryRequiresConsentAndKeepsItsOneOwnerAfterRestart() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try registry(directory)
        let initial = try store.currentLocalLibrary()
        #expect(initial.ownerAccountID == nil)
        #expect(initial.journal == nil)
        #expect(throws: SyncLibraryRegistryError.consentRequired) {
            _ = try store.activate(accountID: "synthetic-A", collectionGeneration: SyncTestFixtures.generation,
                                   claimInitialLocalLibrary: true, syncConsentConfirmed: false, hasActiveWork: false)
        }
        #expect(try store.currentLocalLibrary().ownerAccountID == nil)
        let accountA = try activate(store, account: "synthetic-A", claim: true)
        #expect(accountA.libraryID == initial.libraryID)
        #expect(accountA.rootURL == initial.rootURL)
        let reopened = try registry(directory)
        let offline = try reopened.currentLocalLibrary()
        #expect(offline.libraryID == accountA.libraryID)
        #expect(offline.ownerAccountID == "synthetic-A")
        #expect(offline.journal != nil)
        #expect(throws: SyncLibraryRegistryError.initialLibraryAlreadyOwned) {
            _ = try activate(reopened, account: "synthetic-B", claim: true)
        }
    }

    @Test func switchingCreatesAnEmptyRootAndNeverRetargetsCapturedContext() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try registry(directory)
        let accountA = try activate(store, account: "synthetic-A", claim: true)
        let marker = accountA.rootURL.appendingPathComponent("private-to-A.txt")
        try Data("SYNTHETIC_A".utf8).write(to: marker)
        #expect(throws: SyncLibraryRegistryError.activeWork) { _ = try activate(store, account: "synthetic-B", activeWork: true) }
        #expect(try store.currentLocalLibrary().libraryID == accountA.libraryID)
        let accountB = try activate(store, account: "synthetic-B")
        #expect(accountB.libraryID != accountA.libraryID)
        #expect(accountB.rootURL != accountA.rootURL)
        #expect(!FileManager.default.fileExists(atPath: accountB.rootURL.appendingPathComponent("private-to-A.txt").path))
        #expect(accountA.ownerAccountID == "synthetic-A")
        #expect(try Data(contentsOf: marker) == Data("SYNTHETIC_A".utf8))
        let returned = try activate(store, account: "synthetic-A")
        #expect(returned.libraryID == accountA.libraryID)
        #expect(returned.rootURL == accountA.rootURL)
    }

    @Test func logoutDuringWorkKeepsOwnerAndDurablyQueuesItsCompletionOffline() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try registry(directory)
        let captured = try activate(store, account: "synthetic-A", claim: true)
        let writer = SyncLocalChangeWriter(context: captured)
        let offline = try store.deactivate(hasActiveWork: true)
        #expect(offline.libraryID == captured.libraryID)
        #expect(offline.ownerAccountID == "synthetic-A")
        try writer.write(documents: [SyncTestFixtures.folder()], localReplayData: Data([1])) {}
        let journal = try #require(captured.journal)
        #expect(try journal.pendingUploads().isEmpty)
        #expect(try journal.unresolvedMutations(entityKey: "folder/" + SyncTestFixtures.folder().entityID).count == 1)
        _ = try activate(store, account: "synthetic-A", activeWork: true)
        #expect(try journal.pendingUploads().count == 1)
        let reopened = try registry(directory)
        let reopenedContext = try reopened.currentLocalLibrary()
        let reopenedJournal = try #require(reopenedContext.journal)
        #expect(try reopenedJournal.pendingUploads().isEmpty)
    }

    @Test func generationChangesNeedExplicitConfirmationAndKeepTheOldJournal() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try registry(directory)
        let first = try activate(store, account: "synthetic-A", claim: true)
        try SyncLocalChangeWriter(context: first).write(documents: [SyncTestFixtures.folder()], localReplayData: Data([1])) {}
        let newGeneration = UUID().uuidString.lowercased()
        #expect(throws: SyncLibraryRegistryError.generationResetRequiresConfirmation) {
            _ = try activate(store, account: "synthetic-A", generation: newGeneration)
        }
        #expect(try store.currentLocalLibrary().collectionGeneration == first.collectionGeneration)
        #expect(throws: SyncLibraryRegistryError.activeWork) {
            _ = try activate(store, account: "synthetic-A", activeWork: true, generation: newGeneration, confirmedReset: true)
        }
        let second = try activate(store, account: "synthetic-A", generation: newGeneration, confirmedReset: true)
        #expect(first.libraryID == second.libraryID)
        #expect(first.rootURL == second.rootURL)
        #expect(second.collectionGeneration == newGeneration)
        let newJournal = try #require(second.journal)
        let oldJournal = try #require(first.journal)
        let key = "folder/" + (try SyncTestFixtures.folder().entityID)
        #expect(try newJournal.unresolvedMutations(entityKey: key).isEmpty)
        #expect(try oldJournal.unresolvedMutations(entityKey: key).count == 1)
        #expect(try oldJournal.pendingUploads().isEmpty)
    }
    @Test func explicitLocalAndArchiveSelectionNeverImportsAnAccountLibrary() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try registry(directory)
        let account = try activate(store, account: "synthetic-A", claim: true)
        let marker = account.rootURL.appendingPathComponent("only-A.txt")
        try Data("PRIVATE_A".utf8).write(to: marker)
        #expect(throws: SyncLibraryRegistryError.activeWork) { _ = try store.selectLocalLibrary(hasActiveWork: true) }
        let local = try store.selectLocalLibrary(hasActiveWork: false)
        #expect(local.ownerAccountID == nil && local.journal == nil)
        #expect(local.rootURL != account.rootURL)
        #expect(!FileManager.default.fileExists(atPath: local.rootURL.appendingPathComponent("only-A.txt").path))
        let archive = try store.selectArchivedLibrary(id: account.libraryID, hasActiveWork: false)
        #expect(archive.ownerAccountID == "synthetic-A")
        #expect(try archive.journal?.pendingUploads().isEmpty == true)
        #expect(try Data(contentsOf: marker) == Data("PRIVATE_A".utf8))
        #expect(try store.selectLocalLibrary(hasActiveWork: false).libraryID == local.libraryID)
    }

    @Test func aNewLocalLibraryCanBeAssociatedWithoutReusingThePreviousOwner() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try registry(directory)
        let accountA = try activate(store, account: "synthetic-A", claim: true)
        let local = try store.selectLocalLibrary(hasActiveWork: false)
        let accountB = try activate(store, account: "synthetic-B", claim: true)
        #expect(accountB.libraryID == local.libraryID)
        #expect(accountB.rootURL != accountA.rootURL)
        #expect(accountB.ownerAccountID == "synthetic-B")
        #expect(accountA.ownerAccountID == "synthetic-A")
        #expect(try store.libraries().count == 2)
    }

}
