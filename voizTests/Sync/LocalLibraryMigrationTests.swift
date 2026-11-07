import Foundation
import SQLite3
import Testing

@MainActor
@Suite("Local library migration and recovery")
struct LocalLibraryMigrationTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Local-Migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func context(_ root: URL, id: UUID = UUID()) -> SyncLibraryContext {
        SyncLibraryContext(libraryID: id, ownerAccountID: nil, collectionGeneration: nil, rootURL: root, journal: nil, localOnly: true)
    }
    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try DurableLocalFile.write(encoder.encode(value), to: url)
    }

    @Test func cleanInstallCreatesWritableLocalLibraryWithoutAccountOrJournal() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let runtime = LocalLibraryRuntime(rootURL: root)
        #expect(runtime.canStartNewWorkInLibrary)
        #expect(runtime.context?.localOnly == true)
        #expect(runtime.context?.ownerAccountID == nil)
        #expect(runtime.context?.journal == nil)
        let persistence = try #require(runtime.persistence)
        let session = MeetingSession(title: "Synthetic local recording")
        try persistence.saveMeeting(session)
        #expect(FileManager.default.fileExists(atPath: persistence.meetingURL(session.id).path))
        #expect(try Data(contentsOf: root.appendingPathComponent("Local/pending-write.plist")).isEmpty)
        }
    }

    @Test func legacyLogProbabilityConfidenceDoesNotBlockLocalLibrary() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        var meeting = MeetingSession(title: "Synthetic Whisper legacy")
        meeting.turns = [MeetingTurn(source: .microphone, speakerName: "Speaker", text: "Synthetic", startTime: 0, endTime: 1, confidence: -0.25)]
        let meetingURL = root.appendingPathComponent("Meetings/\(meeting.id.uuidString)/session.json")
        try write(meeting, to: meetingURL)
        let original = try Data(contentsOf: meetingURL)
        let runtime = LocalLibraryRuntime(rootURL: root)
        #expect(runtime.canStartNewWorkInLibrary)
        #expect(runtime.lastError == nil)
        #expect(try Data(contentsOf: meetingURL) == original)
        let persistence = try #require(runtime.persistence)
        #expect(try persistence.index.entity(type: .transcript, id: meeting.id.uuidString.lowercased()) != nil)
        try persistence.saveMeeting(meeting)
        }
    }

    @Test(arguments: [false, true])
    func legacyMeetingAndChatKeepIDsAudioAndSourceBytesOnRepeatedMigration(missingAudio: Bool) throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let meeting = MeetingSession(title: "Synthetic legacy", audioFiles: [.microphone: "microphone.caf"])
        let meetingURL = root.appendingPathComponent("Meetings/\(meeting.id.uuidString)/session.json")
        try write(meeting, to: meetingURL)
        let audioURL = meetingURL.deletingLastPathComponent().appendingPathComponent("microphone.caf")
        if !missingAudio { try DurableLocalFile.write(Data([0, 1, 2, 3]), to: audioURL) }
        let chat = ChatSession(messages: [ChatMessage(role: .user, content: "Synthetic preserved chat")])
        let chatURL = root.appendingPathComponent("Chat/sessions.json")
        try write([chat], to: chatURL)
        let originalMeeting = try Data(contentsOf: meetingURL), originalChat = try Data(contentsOf: chatURL)
        let library = context(root)
        for _ in 0..<2 {
            let persistence = try SyncLibraryPersistence(context: library)
            try persistence.prepareLocalLibrary()
            #expect(try persistence.index.entity(type: .meeting, id: meeting.id.uuidString.lowercased())?.document.entityID == meeting.id.uuidString.lowercased())
            #expect(try persistence.index.children(type: .message, parentID: chat.id.uuidString.lowercased()).first?.entityID == chat.messages[0].id.uuidString.lowercased())
            #expect(try Data(contentsOf: meetingURL) == originalMeeting)
            #expect(try Data(contentsOf: chatURL) == originalChat)
            #expect(FileManager.default.fileExists(atPath: audioURL.path) == !missingAudio)
        }
        }
    }

    @Test func interruptedInventoryRetainsSourceAndCanRetryWithoutDuplicates() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let folder = MeetingFolder(name: "Synthetic retained folder")
        try write([folder], to: root.appendingPathComponent("Meetings/folders.json"))
        let corruptURL = root.appendingPathComponent("Chat/sessions.json")
        try DurableLocalFile.write(Data("invalid synthetic json".utf8), to: corruptURL)
        let library = context(root)
        let persistence = try SyncLibraryPersistence(context: library)
        #expect(throws: (any Error).self) { try persistence.prepareLocalLibrary() }
        #expect(try Data(contentsOf: corruptURL) == Data("invalid synthetic json".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Local/library-v1.json").path))
        try write([ChatSession](), to: corruptURL)
        try persistence.prepareLocalLibrary()
        try persistence.prepareLocalLibrary()
        #expect(try persistence.index.page().filter { $0.document.entityType == .folder }.count == 1)
        }
    }

    @Test func localWriteInterruptionReplaysAndCompletionDoesNotReplayAgain() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let library = context(root)
        let writer = SyncLocalChangeWriter(context: library)
        enum Interruption: Error { case simulated }
        let bytes = Data("synthetic recoverable write".utf8)
        #expect(throws: Interruption.simulated) {
            try writer.write(documents: [], localReplayData: bytes) { throw Interruption.simulated }
        }
        var recovered: [Data] = []
        let reopened = SyncLocalChangeWriter(context: library)
        try reopened.recoverPendingLocal { recovered.append($0) }
        try reopened.recoverPendingLocal { recovered.append($0) }
        #expect(recovered == [bytes])
        }
    }

    @Test func downloadedLibrariesStaySeparateAndNewWritesNeverEnterLegacyOutbox() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let registry = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root)
        let a = try registry.activate(accountID: "synthetic-A", collectionGeneration: UUID().uuidString.lowercased(),
            claimInitialLocalLibrary: true, syncConsentConfirmed: true, hasActiveWork: false)
        let b = try registry.activate(accountID: "synthetic-B", collectionGeneration: UUID().uuidString.lowercased(),
            claimInitialLocalLibrary: false, syncConsentConfirmed: true, hasActiveWork: false)
        let meeting = MeetingSession(title: "Only A")
        try write(meeting, to: a.rootURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)/session.json"))
        let local = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root, localOnly: true)
        let selected = try local.selectArchivedLibrary(id: a.libraryID, hasActiveWork: false)
        let persistence = try SyncLibraryPersistence(context: selected)
        try persistence.prepareLocalLibrary()
        let count = try #require(selected.journal).pendingWorkCount()
        try persistence.saveMeeting(MeetingSession(title: "New local work"))
        #expect(try selected.journal?.pendingWorkCount() == count)
        #expect(try selected.journal?.isSuspended() == true)
        #expect(selected.libraryID == a.libraryID)
        #expect(selected.ownerAccountID == "synthetic-A")
        #expect(!FileManager.default.fileExists(atPath: b.rootURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)/session.json").path))
        #expect(throws: SyncLibraryRegistryError.activeWork) { _ = try local.selectArchivedLibrary(id: b.libraryID, hasActiveWork: true) }
        #expect(try local.currentLocalLibrary().libraryID == a.libraryID)
        }
    }

    @Test func localTrashRestoreKeepsMessagesAndDoesNotRestoreIndependentDeletion() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let persistence = try SyncLibraryPersistence(context: context(root))
        let hidden = ChatMessage(role: .user, content: "Independently removed")
        let kept = ChatMessage(role: .assistant, content: "Restore with parent")
        let chat = ChatSession(messages: [hidden, kept])
        try persistence.saveChats([chat], changed: [chat], removed: [])
        try persistence.trash(type: .message, id: hidden.id)
        try persistence.trash(type: .conversation, id: chat.id)
        try persistence.restore(type: .conversation, id: chat.id)
        #expect(try !persistence.index.isVisible(type: .message, id: hidden.id))
        #expect(try persistence.index.isVisible(type: .message, id: kept.id))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode([ChatSession].self, from: Data(contentsOf: persistence.chatURL))
        #expect(restored.first?.messages.map(\.id) == [kept.id])
        }
    }

    @Test func incompleteInventoryStillAllowsReadingAndExportButBlocksNewWork() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let folder = MeetingFolder(name: "Recoverable synthetic folder")
        try write([folder], to: root.appendingPathComponent("Meetings/folders.json"))
        try DurableLocalFile.write(Data("broken".utf8), to: root.appendingPathComponent("Chat/sessions.json"))
        let runtime = LocalLibraryRuntime(rootURL: root)
        #expect(!runtime.canStartNewWorkInLibrary)
        #expect(runtime.lastError != nil)
        #expect(runtime.persistence != nil)
        let count = try await runtime.exportDownloadedTexts(to: root.appendingPathComponent("Synthetic-export"))
        #expect(count == 1)
        }
    }
    @Test func interruptedLegacyWriteIsRecoveredLocallyWithoutNewUpload() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let registry = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root)
        let old = try registry.activate(accountID: "synthetic", collectionGeneration: UUID().uuidString.lowercased(),
            claimInitialLocalLibrary: true, syncConsentConfirmed: true, hasActiveWork: false)
        let legacy = try SyncLibraryPersistence(context: old)
        let blocked = root.appendingPathComponent("Meetings")
        try Data("synthetic write interruption".utf8).write(to: blocked)
        let folder = MeetingFolder(name: "Interrupted legacy folder")
        #expect(throws: (any Error).self) { try legacy.saveFolders([folder], changed: [folder]) }
        #expect(try old.journal?.pendingLocalReplays().count == 1)
        try FileManager.default.removeItem(at: blocked)
        let localRegistry = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root, localOnly: true)
        let local = try localRegistry.currentLocalLibrary()
        let reopened = try SyncLibraryPersistence(context: local)
        try reopened.prepareLocalLibrary()
        #expect(try local.journal?.pendingLocalReplays().isEmpty == true)
        #expect(try local.journal?.pendingUploads().isEmpty == true)
        #expect(try reopened.index.entity(type: .folder, id: folder.id.uuidString.lowercased())?.document == SyncDTOAdapter.folder(folder))
        try reopened.prepareLocalLibrary()
        #expect(try reopened.index.page().count == 1)
        }
    }

    @Test func failedLibrarySwitchKeepsPreviousLibrarySelectedAndWritable() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let registry = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root)
        let a = try registry.activate(accountID: "synthetic-A", collectionGeneration: UUID().uuidString.lowercased(),
            claimInitialLocalLibrary: true, syncConsentConfirmed: true, hasActiveWork: false)
        let b = try registry.activate(accountID: "synthetic-B", collectionGeneration: UUID().uuidString.lowercased(),
            claimInitialLocalLibrary: false, syncConsentConfirmed: true, hasActiveWork: false)
        try DurableLocalFile.write(Data("invalid".utf8), to: b.rootURL.appendingPathComponent("Chat/sessions.json"))
        _ = try registry.selectArchivedLibrary(id: a.libraryID, hasActiveWork: false)
        let runtime = LocalLibraryRuntime(rootURL: root)
        await runtime.selectLibrary(id: b.libraryID)
        #expect(runtime.context?.libraryID == a.libraryID)
        #expect(runtime.canStartNewWorkInLibrary)
        #expect(runtime.lastError != nil)
        #expect(try registry.currentLocalLibrary().libraryID == a.libraryID)
        }
    }

    @Test func inventoryCannotResurrectLegacyTombstones() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        let folder = MeetingFolder(name: "Synthetic deleted folder")
        let url = root.appendingPathComponent("Meetings/folders.json")
        try write([folder], to: url)
        let persistence = try SyncLibraryPersistence(context: context(root))
        try persistence.index.hide(type: .folder, id: folder.id.uuidString.lowercased(), as: .purged)
        let original = try Data(contentsOf: url)
        try persistence.prepareLocalLibrary()
        #expect(try !persistence.index.isVisible(type: .folder, id: folder.id))
        #expect(try persistence.index.page().isEmpty)
        #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func newLocalRootCannotImportOriginalHistoryPreferences() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Voiz.Local.Import.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let dictation = TranscriptionEntry(text: "Original private library", language: .english)
            let translation = TranslationEntry(sourceText: "Original", translatedText: "Original", sourceLanguage: .english, targetLanguage: .portuguese)
            defaults.set(try JSONEncoder().encode([dictation]), forKey: "transcriptionHistory")
            defaults.set(try JSONEncoder().encode([translation]), forKey: "translationHistory")
            let persistence = try SyncLibraryPersistence(context: context(root))
            try persistence.prepareLocalLibrary()
            let dictations = TranscriptionHistoryStore(defaults: defaults, sync: persistence)
            let translations = TranslationHistoryStore(defaults: defaults, watchChanges: false, sync: persistence)
            #expect(dictations.entries.isEmpty)
            #expect(translations.entries.isEmpty)
            #expect(try persistence.index.page().isEmpty)
            #expect(defaults.data(forKey: "transcriptionHistory") != nil)
            #expect(defaults.data(forKey: "translationHistory") != nil)
        }
    }

    @Test func scopedLegacyHistoryIsIndexedAfterLibraryInventory() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Voiz.Local.Index.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let library = context(root)
            let dictation = TranscriptionEntry(text: "Scoped legacy dictation", language: .english)
            let translation = TranslationEntry(sourceText: "Scoped", translatedText: "Local", sourceLanguage: .english, targetLanguage: .portuguese)
            defaults.set(try JSONEncoder().encode([dictation]), forKey: "transcriptionHistory." + library.libraryID.uuidString)
            defaults.set(try JSONEncoder().encode([translation]), forKey: "translationHistory." + library.libraryID.uuidString)
            let persistence = try SyncLibraryPersistence(context: library)
            try persistence.prepareLocalLibrary()
            let dictations = TranscriptionHistoryStore(defaults: defaults, sync: persistence)
            let translations = TranslationHistoryStore(defaults: defaults, watchChanges: false, sync: persistence)
            #expect(dictations.entries.first?.id == dictation.id)
            #expect(translations.entries.first?.id == translation.id)
            #expect(try persistence.index.entity(type: .dictation, id: dictation.id.uuidString.lowercased()) != nil)
            #expect(try persistence.index.entity(type: .translation, id: translation.id.uuidString.lowercased()) != nil)
            try persistence.trash(type: .dictation, id: dictation.id)
            try persistence.restore(type: .dictation, id: dictation.id)
            #expect(try persistence.index.isVisible(type: .dictation, id: dictation.id))
        }
    }

    @Test(arguments: [false, true])
    func corruptArchiveSelectionIsIsolatedAndRecoverable(initiallySelected: Bool) async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            let archived: SyncLibraryContext
            let originalID: UUID
            do {
                let registry = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root)
                let original = try registry.currentLocalLibrary()
                originalID = original.libraryID
                archived = try registry.activate(accountID: "synthetic-unselected", collectionGeneration: UUID().uuidString.lowercased(),
                    claimInitialLocalLibrary: false, syncConsentConfirmed: true, hasActiveWork: false)
                if !initiallySelected { _ = try registry.selectArchivedLibrary(id: original.libraryID, hasActiveWork: false) }
            }
            // Use SQLite itself to damage the schema while the captured context retains
            // its connection; never unlink a live database file during this test.
            let journalURL = archived.rootURL.appendingPathComponent("Sync/journals/" + archived.collectionGeneration! + ".sqlite")
            var connection: OpaquePointer?
            #expect(sqlite3_open(journalURL.path, &connection) == SQLITE_OK)
            let database = try #require(connection)
            #expect(sqlite3_exec(database, "DROP TABLE sync_outbox", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(database)
            let runtime = LocalLibraryRuntime(rootURL: root)
            #expect(runtime.canStartNewWorkInLibrary == !initiallySelected)
            #expect(runtime.availableLibraries.count == 2)
            if initiallySelected {
                await runtime.selectLibrary(id: originalID)
                #expect(runtime.canStartNewWorkInLibrary)
                #expect(runtime.lastError == nil)
            } else {
                await runtime.selectLibrary(id: archived.libraryID)
                #expect(runtime.lastError != nil)
                #expect(runtime.canStartNewWorkInLibrary)
            }
            #expect(runtime.context?.libraryID == originalID)
            let reopened = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("Libraries"), initialLocalRoot: root, localOnly: true)
            #expect(try reopened.currentLocalLibrary().libraryID == originalID)
        }
    }

    @Test func preparingAnArchiveNeverAppliesItsHistoricalPreferences() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Voiz.Local.Preferences.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let library = context(root)
            let settings = SettingsStore(defaults: defaults)
            let original = AppSettings()
            #expect(settings.save(original))
            let before = defaults.data(forKey: SettingsStore.preferencesKey)
            var historical = original
            historical.showConfidence.toggle()
            let index = try SyncLocalDocumentStore(url: root.appendingPathComponent("Sync/local-index.sqlite"))
            try index.put(SyncDTOAdapter.preferences(SyncPreferences(snapshot: historical), id: SyncLibraryPersistence.preferencesID))
            try DurableLocalFile.write(Data("invalid".utf8), to: root.appendingPathComponent("Chat/sessions.json"))
            let persistence = try SyncLibraryPersistence(context: library, settingsStore: settings)
            #expect(throws: (any Error).self) { try persistence.prepareLocalLibrary() }
            #expect(defaults.data(forKey: SettingsStore.preferencesKey) == before)
            #expect(settings.load().showConfidence == original.showConfidence)
        }
    }

}
