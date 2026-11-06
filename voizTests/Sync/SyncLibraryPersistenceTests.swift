import Foundation
import SQLite3
import Testing

@MainActor
@Suite("Sync library persistence integration")
struct SyncLibraryPersistenceTests {
    private struct Harness {
        let directory: URL
        let context: SyncLibraryContext
        let settings: SettingsStore
        let defaults: UserDefaults
        let suite: String
        func close() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func persistence() throws -> SyncLibraryPersistence { try SyncLibraryPersistence(context: context, settingsStore: settings) }
    }
    private func harness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Sync-Persistence-" + UUID().uuidString)
        let journal = try SyncJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"), accountID: "synthetic", collectionGeneration: SyncTestFixtures.generation)
        let context = SyncLibraryContext(libraryID: UUID(), ownerAccountID: "synthetic", collectionGeneration: SyncTestFixtures.generation, rootURL: directory, journal: journal)
        let suite = "Voiz.Sync.Persistence.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        return Harness(directory: directory, context: context, settings: SettingsStore(defaults: defaults, credentials: NoCredentials()), defaults: defaults, suite: suite)
    }
    private func remote(_ document: SyncDocument, revision: Int64 = 1, cursor: Int64 = 1) throws -> SyncRemoteChange {
        try SyncRemoteChange(collectionGeneration: SyncTestFixtures.generation, cursor: cursor, revision: revision,
                             entityType: document.entityType, entityID: document.entityID, mutation: .upsert, document: document)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(value).write(to: url)
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    @Test(arguments: [false, true])
    func openFolderDraftCannotOverwriteRemoteEditOrRestoreDeletion(deleted: Bool) throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let original = MeetingFolder(name: "Synthetic shared folder", details: "Initial text")
        try persistence.applyRemote(remote(SyncDTOAdapter.folder(original)), pending: [])
        let store = MeetingSessionStore(sync: persistence)
        var local = original; local.details = "Draft from the first Mac"
        var other = original; other.details = "Saved on the second Mac"
        if deleted {
            let tombstone = try SyncRemoteChange(collectionGeneration: SyncTestFixtures.generation, cursor: 2, revision: 2,
                entityType: .folder, entityID: original.id.uuidString.lowercased(), mutation: .trash,
                document: SyncDTOAdapter.folder(original), trashExpiresAtMS: 2_000_000_000_000)
            try persistence.applyRemote(tombstone, pending: [])
        } else {
            try persistence.applyRemote(remote(SyncDTOAdapter.folder(other), revision: 2, cursor: 2), pending: [])
        }
        store.updateFolder(local, basedOn: original)
        #expect(store.storageError == nil)
        #expect(store.folder(withId: original.id)?.details == (deleted ? nil : other.details))
        #expect(try h.context.journal?.pendingWorkCount() == 0)
        // Reopening must retain the draft independently of the main projection.
        let reopened = try h.persistence()
        let drafts = try reopened.index.conflictPage()
        let expectedDraft = try SyncDTOAdapter.folder(local)
        #expect(drafts.count == 1)
        #expect(drafts.first?.document == expectedDraft)
        #expect(try reopened.index.remoteRevision(type: .folder, id: original.id.uuidString.lowercased()) == 2)
    }

    @Test func unchangedOrIdenticalFolderDraftCannotReplaceNewerText() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let original = MeetingFolder(name: "Synthetic shared folder", details: "Initial text")
        try persistence.applyRemote(remote(SyncDTOAdapter.folder(original)), pending: [])
        let store = MeetingSessionStore(sync: persistence)
        var other = original; other.details = "New remote text"
        try persistence.applyRemote(remote(SyncDTOAdapter.folder(other), revision: 2, cursor: 2), pending: [])
        store.updateFolder(original, basedOn: original)
        store.updateFolder(other, basedOn: original)
        #expect(store.folder(withId: original.id)?.details == other.details)
        #expect(try h.context.journal?.pendingWorkCount() == 0)
        #expect(try persistence.index.conflictPage().isEmpty)
        var next = other; next.details = "Deliberate edit of the current version"
        store.updateFolder(next, basedOn: other)
        #expect(store.folder(withId: original.id)?.details == next.details)
        #expect(try h.context.journal?.pendingWorkCount() == 1)
    }
    /// One SyncEngine upload pass followed by the next pull: every queued upload is confirmed and
    /// the server echoes it back. The feed carries only the current revision of each entity.
    private func echoUploads(_ persistence: SyncLibraryPersistence, _ journal: SyncJournal, cursor: inout Int64) throws {
        var echoes: [String: SyncRemoteChange] = [:]
        while let entry = try journal.pendingUploads(limit: 1).first {
            cursor += 1
            let revision = entry.mutation.baseRevision + 1
            try journal.confirmUploaded(operationID: entry.mutation.operationID, revision: revision, cursor: cursor, payloadHash: entry.mutation.payloadSHA256)
            echoes[entry.mutation.entityKey] = try remote(try #require(entry.mutation.document), revision: revision, cursor: cursor)
        }
        for echo in echoes.values.sorted(by: { $0.cursor < $1.cursor }) { try persistence.applyRemote(echo, pending: []) }
    }
    /// A diarized daily as the post-call leaves it in a Sync library: transcript first, then the
    /// summary and chapters, each save echoed back by the server.
    private func summarizedDaily(_ persistence: SyncLibraryPersistence, _ journal: SyncJournal, cursor: inout Int64) throws -> MeetingSession {
        let mic = MeetingSpeaker(source: .microphone)
        let status = MeetingTurn(source: .microphone, speakerId: mic.id, speakerName: mic.name, text: "Synthetic status", startTime: 0, endTime: 2, confidence: 0.91)
        let blocker = MeetingTurn(source: .systemAudio, speakerId: "S1", speakerName: "Participante 1", text: "Synthetic blocker", startTime: 2, endTime: 4, confidence: 0.87)
        var meeting = MeetingSession(title: "Synthetic daily", speakers: [mic, MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1")],
                                     turns: [status, blocker])
        try persistence.saveMeeting(meeting)
        try echoUploads(persistence, journal, cursor: &cursor)
        meeting = try read(MeetingSession.self, from: persistence.meetingURL(meeting.id))
        var section = MeetingSummarySection.bullets(id: "blockers", title: "Blockers", items: ["Synthetic blocker"])
        section.evidence = [MeetingSummaryEvidence(itemIndex: 0, turnIDs: [blocker.id])]
        meeting.summary = MeetingSummary(title: "Synthetic daily", sections: [section])
        meeting.summaryModel = "IA Voiz"
        meeting.chapters = [MeetingChapter(title: "Blockers", startTime: 2)]
        try persistence.saveMeeting(meeting)
        try echoUploads(persistence, journal, cursor: &cursor)
        return meeting
    }

    @Test func confirmedCopyMissingFromSnapshotRemainsExportableWithoutReupload() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let document = try SyncTestFixtures.folder(name: "Confirmed after the restored backup")
        try persistence.index.put(document, remoteRevision: 1)
        let journal = try #require(h.context.journal)
        let second = try SyncTestFixtures.folder(id: "00000000-0000-0000-0000-000000000088", name: "Newer than restored revision")
        let older = try SyncTestFixtures.folder(id: second.entityID, name: "Older backup")
        try persistence.index.put(second, remoteRevision: 3)
        let oldChange = try remote(older, revision: 1, cursor: 1)
        try journal.receive([], afterCursor: 0, nextCursor: 150)
        try journal.authorizeSnapshotRecovery()
        let page = try SyncSnapshotPage(value: .object([
            "schema_version": .integer(1), "collection_generation": .string(journal.collectionGeneration),
            "snapshot_id": .string(UUID().uuidString.lowercased()), "cursor": .integer(1),
            "entities": .array([try SyncCanonicalJSON.decode(oldChange.canonicalData())]), "next_page": .null
        ]))
        try journal.receiveSnapshotPage(page, requestedPage: nil)
        let optionalProgress = try journal.snapshotProgress()
        let progress = try #require(optionalProgress)
        try persistence.applyRemote(oldChange, pending: [])
        try journal.markSnapshotApplied(entityKey: "folder/" + second.entityID)
        try persistence.reconcileAbsence(progress, journal: journal)
        try journal.finishSnapshot()
        #expect(try persistence.index.entity(type: .folder, id: document.entityID)?.visibility == .absent)
        #expect(try persistence.index.entity(type: .folder, id: second.entityID)?.document == second)
        let conflicts = try persistence.index.conflictPage()
        #expect(conflicts.contains { $0.document == document })
        #expect(conflicts.contains { $0.document == second })
        #expect(try journal.pendingWorkCount() == 0)
        #expect(try journal.currentCursor() == 1)
    }

    @Test func equalRevisionCollisionPreservesLocalVersionAndCannotReopenPurge() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let local = try SyncTestFixtures.folder(name: "Newest confirmed local copy")
        let restored = try SyncTestFixtures.folder(name: "Different restored revision")
        try persistence.index.put(local, remoteRevision: 3)
        try persistence.applyRemote(remote(restored, revision: 3, cursor: 3), pending: [])
        #expect(try persistence.index.conflictPage().contains { $0.document == local })
        #expect(try persistence.index.entity(type: .folder, id: local.entityID)?.document == restored)
        try persistence.index.hide(type: .folder, id: local.entityID, as: .purged, revision: 4)
        try persistence.applyRemote(remote(local, revision: 4, cursor: 4), pending: [])
        #expect(try persistence.index.entity(type: .folder, id: local.entityID)?.visibility == .purged)
        #expect(try persistence.index.conflictPage().contains { $0.document == local && $0.remoteCursor == 4 })
    }


    @Test func purgingUnpublishedConversationAlsoFencesPendingMessageUploads() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let chat = ChatSession(messages: [ChatMessage(role: .user, content: "Local-only child before import")])
        try persistence.saveChats([chat], changed: [chat], removed: [])
        try persistence.trash(type: .conversation, id: chat.id)
        try persistence.purge(type: .conversation, id: chat.id)
        let journal = try #require(h.context.journal)
        let messageKey = "message/" + chat.messages[0].id.uuidString.lowercased()
        let pending = try journal.unresolvedMutations(entityKey: messageKey)
        #expect(pending.map(\.mutation.mutation) == [.upsert, .purge])
        #expect(try persistence.index.entity(type: .message, id: chat.messages[0].id.uuidString.lowercased())?.visibility == .purged)
    }


    @Test func unknownPurgeIsDurableAndCannotBeRecreatedByInventory() async throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let messageID = UUID()
        let purge = try SyncRemoteChange(collectionGeneration: SyncTestFixtures.generation, cursor: 1, revision: 2,
            entityType: .message, entityID: messageID.uuidString.lowercased(), mutation: .purge, document: nil)
        try persistence.applyRemote(purge, pending: [])
        let reopened = try h.persistence()
        #expect(try !reopened.index.isVisible(type: .message, id: messageID))
        let conversation = ChatSession(messages: [ChatMessage(id: messageID, role: .user, content: "Synthetic hidden message")])
        try write([conversation], to: reopened.chatURL)
        _ = try await reopened.exportExisting()
        let journal = try #require(h.context.journal)
        #expect(try journal.unresolvedMutations(entityKey: "message/" + messageID.uuidString.lowercased()).isEmpty)
        #expect(try !reopened.index.isVisible(type: .message, id: messageID))
    }

    @Test func allDivergentLocalVersionsSurviveOneRemoteRevisionIdempotently() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let first = MeetingFolder(name: "Local first")
        var second = first; second.name = "Local second"
        try persistence.saveFolders([first], changed: [first])
        try persistence.saveFolders([second], changed: [second])
        let journal = try #require(h.context.journal)
        let key = "folder/" + first.id.uuidString.lowercased()
        let pending = try journal.unresolvedMutations(entityKey: key)
        var remoteFolder = first; remoteFolder.name = "Remote competing edit"
        let change = try remote(SyncDTOAdapter.folder(remoteFolder))
        try persistence.applyRemote(change, pending: pending)
        try persistence.applyRemote(change, pending: pending)
        let conflicts = try persistence.index.conflicts(type: .folder, id: first.id.uuidString.lowercased())
        #expect(Set(conflicts.compactMap { $0.value.object?["name"]?.string }) == ["Local first", "Local second"])
        #expect(try journal.pendingWorkCount() == 2)
        #expect(try journal.blockedWorkCount() == 2)
        let stored = try read([MeetingFolder].self, from: persistence.meetingsURL.appendingPathComponent("folders.json"))
        #expect(stored.first?.name == "Remote competing edit")
    }

    @Test func confirmedAncestorDoesNotOverwriteOrBlockTheNextLocalEdit() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let first = MeetingFolder(name: "Confirmed first")
        try persistence.saveFolders([first], changed: [first])
        let journal = try #require(h.context.journal)
        let pending = try journal.pendingUploads()
        let uploaded = try #require(pending.first)
        try journal.confirmUploaded(operationID: uploaded.mutation.operationID, revision: 1, cursor: 1, payloadHash: uploaded.mutation.payloadSHA256)
        var second = first; second.name = "Unsent second"
        try persistence.saveFolders([second], changed: [second])
        let local = try journal.unresolvedMutations(entityKey: uploaded.mutation.entityKey)
        try persistence.applyRemote(remote(SyncDTOAdapter.folder(first)), pending: local)
        #expect(try journal.blockedWorkCount() == 0)
        #expect(try journal.pendingWorkCount() == 1)
        #expect(try persistence.index.entity(type: .folder, id: first.id.uuidString.lowercased())?.document.value.object?["name"]?.string == "Unsent second")
        let stored = try read([MeetingFolder].self, from: persistence.meetingsURL.appendingPathComponent("folders.json"))
        #expect(stored.first?.name == "Unsent second")
    }

    @Test func failedFileWriteReplaysCompleteMeetingBeforeOpeningTheLibrary() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        try Data("SYNTHETIC_BLOCKING_FILE".utf8).write(to: persistence.meetingsURL)
        var meeting = MeetingSession(title: "Replay this meeting", turns: [MeetingTurn(source: .microphone, speakerName: "Speaker", text: "Complete text", startTime: 0, endTime: 1)])
        meeting.audioFiles = [.microphone: "LOCAL_AUDIO_REFERENCE"]
        do { try persistence.saveMeeting(meeting); Issue.record("Expected blocked directory write") }
        catch { }
        let journal = try #require(h.context.journal)
        let prepared = try journal.pendingLocalReplays()
        #expect(prepared.count == 2)
        #expect(try journal.pendingUploads().isEmpty)
        try FileManager.default.removeItem(at: persistence.meetingsURL)
        let reopened = try h.persistence()
        let restored = try read(MeetingSession.self, from: reopened.meetingURL(meeting.id))
        #expect(restored.title == meeting.title)
        #expect(restored.turns == meeting.turns)
        #expect(restored.audioFiles == meeting.audioFiles)
        #expect(try journal.pendingLocalReplays().isEmpty)
        #expect(try journal.pendingUploads().map(\.mutation.operationID) == prepared.map(\.mutation.operationID))
        let wire = try journal.pendingUploads().map { String(data: try $0.mutation.canonicalData(), encoding: .utf8)! }.joined()
        #expect(!wire.contains("LOCAL_AUDIO_REFERENCE"))
    }

    @Test func inventoryIncludesEveryHistoryPageAndKeepsOriginalFilesUntouched() async throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: persistence.historyURL, kind: "dictation")
        var entries: [TranscriptionEntry] = []
        for position in 0..<120 {
            let entry = TranscriptionEntry(text: "Synthetic \(position)", language: .english, timestamp: Date(timeIntervalSince1970: Double(position + 1)), duration: 1, audioID: UUID())
            entries.append(entry)
            try archive.upsert(entry, timestamp: entry.timestamp)
        }
        try archive.setHidden(id: entries[0].id, true)
        try persistence.index.hide(type: .dictation, id: entries[1].id.uuidString.lowercased(), as: .trashed)
        let folder = MeetingFolder(name: "Inventory folder")
        try write([folder], to: persistence.meetingsURL.appendingPathComponent("folders.json"))
        let chat = ChatSession(messages: [ChatMessage(role: .user, content: "Inventory message")])
        try write([chat], to: persistence.chatURL)
        var meeting = MeetingSession(title: "Inventory meeting")
        meeting.audioFiles = [.microphone: "PRIVATE_INVENTORY_AUDIO"]
        try write(meeting, to: persistence.meetingURL(meeting.id))
        let before = try Data(contentsOf: persistence.meetingURL(meeting.id))
        let count = try await persistence.exportExisting()
        #expect(count == 124) // 118 dictations + folder + conversation/message + meeting/transcript + preferences
        #expect(try await persistence.exportExisting() == 0)
        #expect(try Data(contentsOf: persistence.meetingURL(meeting.id)) == before)
        let journal = try #require(h.context.journal)
        #expect(try journal.pendingWorkCount() == 124)
        #expect(try journal.unresolvedMutations(entityKey: "dictation/" + entries[0].id.uuidString.lowercased()).isEmpty)
        #expect(try journal.unresolvedMutations(entityKey: "dictation/" + entries[1].id.uuidString.lowercased()).isEmpty)
    }

    @Test func remotePreferencesChangeOnlyAllowlistWithoutCredentialIO() throws {
        let h = try harness(); defer { h.close() }
        let original = AppSettings.fullyCustomizedForTests
        h.defaults.set(try JSONEncoder().encode(original), forKey: SettingsStore.legacyKey)
        let persistence = try h.persistence()
        var preferences = SyncPreferences(snapshot: original)
        preferences.appearance = .dark
        preferences.showConfidence.toggle()
        let document = try SyncDTOAdapter.preferences(preferences, id: SyncLibraryPersistence.preferencesID)
        try persistence.applyRemote(remote(document), pending: [])
        let after = h.settings.load()
        #expect(after.appearance == .dark)
        #expect(after.showConfidence == preferences.showConfidence)
        #expect(after.customBaseURL == original.customBaseURL)
        #expect(after.openAIKey == original.openAIKey)
        let wire = String(data: try document.canonicalData(), encoding: .utf8)!
        #expect(!wire.contains(original.customBaseURL))
        #expect(!wire.contains(original.openAIKey))
    }

    @Test func parentRestoreWaitsForAuthoritativeChildrenAndPurgeKeepsLocalAudio() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        var meeting = MeetingSession(title: "Lifecycle meeting", turns: [MeetingTurn(source: .microphone, speakerName: "Speaker", text: "Original text", startTime: 0, endTime: 1)])
        meeting.audioFiles = [.microphone: "LOCAL_AUDIO_ONLY"]
        try persistence.saveMeeting(meeting)
        let journal = try #require(h.context.journal)
        for (offset, entry) in try journal.pendingUploads().enumerated() {
            try journal.confirmUploaded(operationID: entry.mutation.operationID, revision: 1, cursor: Int64(offset + 1), payloadHash: entry.mutation.payloadSHA256)
        }
        let originalTranscript = try persistence.index.entity(type: .transcript, id: meeting.id.uuidString.lowercased())
        let transcript = try #require(originalTranscript?.document)
        #expect(throws: SyncJournalError.invalidTransition) { try persistence.restore(type: .meeting, id: meeting.id) }
        try persistence.trash(type: .meeting, id: meeting.id)
        #expect(try !persistence.index.isVisible(type: .meeting, id: meeting.id))
        #expect(try !persistence.index.isVisible(type: .transcript, id: meeting.id))
        try persistence.restore(type: .meeting, id: meeting.id)
        let waiting = try read(MeetingSession.self, from: persistence.meetingURL(meeting.id))
        #expect(waiting.turns.isEmpty)
        #expect(waiting.summary == nil)
        #expect(waiting.audioFiles == meeting.audioFiles)
        #expect(try !persistence.index.isVisible(type: .transcript, id: meeting.id))
        let restored = try SyncRemoteChange(collectionGeneration: SyncTestFixtures.generation, cursor: 6, revision: 3,
            entityType: .transcript, entityID: transcript.entityID, mutation: .restore, document: transcript)
        try persistence.applyRemote(restored, pending: [])
        let restoredMeeting = try read(MeetingSession.self, from: persistence.meetingURL(meeting.id))
        #expect(restoredMeeting.turns == meeting.turns)
        try persistence.trash(type: .meeting, id: meeting.id)
        try persistence.purge(type: .meeting, id: meeting.id)
        #expect(try persistence.index.entity(type: .meeting, id: meeting.id.uuidString.lowercased())?.visibility == .purged)
        #expect(try persistence.index.entity(type: .transcript, id: meeting.id.uuidString.lowercased())?.visibility == .purged)
        let retained = try read(MeetingSession.self, from: persistence.meetingURL(meeting.id))
        #expect(retained.audioFiles == meeting.audioFiles)
        let pending = try journal.unresolvedMutations(entityKey: "meeting/" + meeting.id.uuidString.lowercased())
        #expect(pending.map(\.mutation.mutation) == [.trash, .restore, .trash, .purge])
        #expect(pending.map(\.mutation.baseRevision) == [1, 2, 3, 4])
    }

    /// The 12/10/2026 daily kept "IA Voiz" as its summary model and lost summary and chapters.
    /// Naming a participant after the summary moves the transcript to a new generation while the
    /// unchanged summary stays on the old one; the projection rebuilt from the echo dropped both.
    @Test func renamingASpeakerAfterTheSummaryKeepsSummaryAndChaptersThroughTheSyncEcho() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let journal = try #require(h.context.journal)
        var cursor: Int64 = 0
        let summarized = try summarizedDaily(persistence, journal, cursor: &cursor)
        var renamed = try read(MeetingSession.self, from: persistence.meetingURL(summarized.id))
        #expect(renamed.summary == summarized.summary)
        renamed.renameSpeaker(id: "S1", to: "Ana")
        try persistence.saveMeeting(renamed)
        try echoUploads(persistence, journal, cursor: &cursor)
        let projected = try read(MeetingSession.self, from: persistence.meetingURL(summarized.id))
        #expect(projected.turns.last?.speakerName == "Ana")
        #expect(projected.summaryModel == "IA Voiz")
        #expect(projected.summary == summarized.summary)
        #expect(projected.chapters == summarized.chapters)
    }

    /// Meetings an earlier build projected without their summary still hold it in the local index:
    /// a save without summary never removes the summary document. The next echo brings it back
    /// with no new AI call.
    @Test func summaryDroppedByAnEarlierProjectionReturnsAtTheNextSyncEcho() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let journal = try #require(h.context.journal)
        var cursor: Int64 = 0
        let summarized = try summarizedDaily(persistence, journal, cursor: &cursor)
        var dropped = try read(MeetingSession.self, from: persistence.meetingURL(summarized.id))
        dropped.renameSpeaker(id: "S1", to: "Ana")
        dropped.summary = nil
        dropped.chapters = nil
        try persistence.saveMeeting(dropped)
        #expect(try read(MeetingSession.self, from: persistence.meetingURL(summarized.id)).summary == nil)
        try echoUploads(persistence, journal, cursor: &cursor)
        let restored = try read(MeetingSession.self, from: persistence.meetingURL(summarized.id))
        #expect(restored.summary == summarized.summary)
        #expect(restored.chapters == summarized.chapters)
    }

    @Test func historyRestoreAndPurgeChangeVisibilityWithoutDeletingTheLocalRecord() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let entry = TranscriptionEntry(text: "Retained local text", language: .english, duration: 1, audioID: UUID())
        try persistence.saveDictation(entry)
        let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: persistence.historyURL, kind: "dictation")
        try persistence.trash(type: .dictation, id: entry.id)
        #expect(try archive.page().isEmpty)
        try persistence.restore(type: .dictation, id: entry.id)
        #expect(try archive.page().first?.audioID == entry.audioID)
        try persistence.trash(type: .dictation, id: entry.id)
        try persistence.purge(type: .dictation, id: entry.id)
        #expect(try archive.page().isEmpty)
        #expect(try archive.entry(id: entry.id)?.audioID == entry.audioID)
        #expect(try archive.entry(id: entry.id)?.text == entry.text)
    }

    @Test func trashAndConflictPagesHaveStableCursorsWithoutDroppingVersions() throws {
        let h = try harness(); defer { h.close() }
        let index = try h.persistence().index
        for position in 1...5 {
            let id = String(format: "00000000-0000-0000-0000-%012d", position)
            let first = try SyncTestFixtures.folder(id: id, name: "First \(position)")
            let second = try SyncTestFixtures.folder(id: id, name: "Second \(position)")
            try index.put(first)
            if position <= 3 { try index.hide(type: .folder, id: id, as: .trashed) }
            try index.preserveConflict(first, cursor: 5)
            try index.preserveConflict(second, cursor: 5)
        }
        var trash: [SyncLocalEntity] = []
        while true {
            let page = try index.page(visibility: .trashed, after: trash.last?.id ?? "", limit: 2)
            if page.isEmpty { break }
            trash += page
        }
        #expect(trash.count == 3)
        #expect(Set(trash.map(\.id)).count == 3)
        var conflicts: [SyncLocalConflict] = []
        while true {
            let page = try index.conflictPage(after: conflicts.last?.id ?? "", limit: 3)
            if page.isEmpty { break }
            conflicts += page
        }
        #expect(conflicts.count == 10)
        #expect(Set(conflicts.map(\.id)).count == 10)
        #expect(conflicts.map(\.id) == conflicts.map(\.id).sorted())
        #expect(conflicts.allSatisfy { $0.remoteCursor == 5 })
    }

    @Test func canceledInventoryDoesNotQueueEvenDefaultPreferences() async throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let task = Task { try await persistence.exportExisting() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled inventory completed") }
        catch is CancellationError { }
        let journal = try #require(h.context.journal)
        #expect(try journal.pendingWorkCount() == 0)
    }

    @Test func explicitGenerationResetKeepsUnsentEditsVisibleAndRetainsExclusions() async throws {
        let h = try harness(); defer { h.close() }
        let first = try h.persistence()
        let visible = MeetingFolder(name: "Reupload explicitly approved")
        let hidden = MeetingFolder(name: "Keep hidden")
        try first.saveFolders([visible, hidden], changed: [visible, hidden])
        let oldJournal = try #require(h.context.journal)
        for (offset, entry) in try oldJournal.pendingUploads().enumerated() {
            try oldJournal.confirmUploaded(operationID: entry.mutation.operationID, revision: 1, cursor: Int64(offset + 1), payloadHash: entry.mutation.payloadSHA256)
            try first.applyRemote(remote(entry.mutation.document!, cursor: Int64(offset + 1)), pending: [])
        }
        try first.trash(type: .folder, id: hidden.id)
        let generation = UUID().uuidString.lowercased()
        let newJournal = try SyncJournal(databaseURL: h.directory.appendingPathComponent("new-generation.sqlite"), accountID: "synthetic", collectionGeneration: generation)
        let newContext = SyncLibraryContext(libraryID: h.context.libraryID, ownerAccountID: "synthetic", collectionGeneration: generation,
                                            rootURL: h.directory, journal: newJournal)
        let next = try SyncLibraryPersistence(context: newContext, settingsStore: h.settings)
        #expect(try next.index.entity(type: .folder, id: visible.id.uuidString.lowercased())?.remoteRevision == 0)
        #expect(try await next.exportExisting() == 2) // visible folder and portable preferences only
        var edited = visible; edited.name = "Another unsent local edit"
        try next.saveFolders([edited, hidden], changed: [edited])
        let pending = try newJournal.unresolvedMutations(entityKey: "folder/" + visible.id.uuidString.lowercased())
        #expect(pending.map(\.mutation.baseRevision) == [0, 1])
        let snapshot = try SyncSnapshotPage(value: .object([
            "schema_version": .integer(1), "collection_generation": .string(generation),
            "snapshot_id": .string(UUID().uuidString.lowercased()), "cursor": .integer(0),
            "entities": .array([]), "next_page": .null
        ]))
        try newJournal.receiveSnapshotPage(snapshot, requestedPage: nil)
        let optionalProgress = try newJournal.snapshotProgress()
        let progress = try #require(optionalProgress)
        try next.reconcileAbsence(progress, journal: newJournal)
        try newJournal.finishSnapshot()
        #expect(try next.index.isVisible(type: .folder, id: visible.id))
        #expect(try !next.index.isVisible(type: .folder, id: hidden.id))
        #expect(try newJournal.blockedWorkCount() == 0)
        #expect(try newJournal.unresolvedMutations(entityKey: "folder/" + hidden.id.uuidString.lowercased()).isEmpty)
    }

    @Test func largeTranscriptReplaysAfterCrashAndLargeMessagesKeepIndexedParentOwnership() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let text = String(repeating: "x", count: SyncCanonicalJSON.maximumBytes + 257)
        var meeting = MeetingSession(title: "Large synthetic meeting", turns: [MeetingTurn(source: .microphone, speakerName: "Speaker", text: text, startTime: 0, endTime: 1)])
        meeting.audioFiles = [.microphone: "LOCAL_LARGE_AUDIO_REFERENCE"]
        try Data("SYNTHETIC_BLOCKING_FILE".utf8).write(to: persistence.meetingsURL)
        do { try persistence.saveMeeting(meeting); Issue.record("Expected blocked projection write") }
        catch { }
        let journal = try #require(h.context.journal)
        #expect(try journal.pendingLocalReplays().count == 2)
        #expect(try journal.pendingUploads().isEmpty)
        try FileManager.default.removeItem(at: persistence.meetingsURL)
        let recovered = try h.persistence()
        let restored = try read(MeetingSession.self, from: recovered.meetingURL(meeting.id))
        #expect(restored.turns.first?.text == text)
        #expect(restored.audioFiles == meeting.audioFiles)
        #expect(try journal.pendingLocalReplays().isEmpty)
        #expect(try recovered.index.ownedChildren(type: .meeting, id: meeting.id.uuidString.lowercased()).map(\.document.entityType) == [.transcript])
        let chat = ChatSession(messages: [ChatMessage(role: .user, content: text)])
        try recovered.saveChats([chat], changed: [chat], removed: [])
        let reopened = try h.persistence()
        let messages = try reopened.index.children(type: .message, parentID: chat.id.uuidString.lowercased())
        #expect(messages.count == 1)
        #expect(messages.first?.value.object?["content"]?.string == text)
        try reopened.trash(type: .conversation, id: chat.id)
        #expect(try !reopened.index.isVisible(type: .message, id: chat.messages[0].id))
    }

    @Test func versionedIndexCannotSilentlyRecreateMissingDataTables() throws {
        for table in ["entities", "tombstones", "conflict_versions"] {
            let h = try harness(); defer { h.close() }
            let persistence = try h.persistence()
            let folder = MeetingFolder(name: "Preserve existing index")
            try persistence.saveFolders([folder], changed: [folder])
            var connection: OpaquePointer?
            let url = h.context.rootURL.appendingPathComponent("Sync/local-index.sqlite")
            #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
            let database = try #require(connection)
            defer { sqlite3_close(database) }
            #expect(sqlite3_exec(database, "DROP TABLE " + table, nil, nil, nil) == SQLITE_OK)
            #expect(throws: (any Error).self) { _ = try h.persistence() }
            let existing = try read([MeetingFolder].self, from: persistence.meetingsURL.appendingPathComponent("folders.json"))
            #expect(existing.first?.name == folder.name)
        }
    }


    @Test func newGenerationConflictReopensTheSamePreservedVersion() throws {
        let h = try harness(); defer { h.close() }
        let persistence = try h.persistence()
        let document = try SyncTestFixtures.folder(name: "Preserved local content")
        try persistence.index.preserveConflict(document, cursor: 1)
        try persistence.index.markConflictsResolved(type: .folder, id: document.entityID)
        #expect(try persistence.index.conflictPage().isEmpty)
        try persistence.index.bind(accountID: "synthetic", collectionGeneration: UUID().uuidString.lowercased())
        try persistence.index.preserveConflict(document, cursor: 1)
        #expect(try persistence.index.conflictPage().first?.document == document)
        #expect(try persistence.index.conflictPage(includeResolved: true).count == 1)
    }

    nonisolated private struct NoCredentials: SettingsCredentialsPersisting {
        func read() throws -> SettingsCredentialRecord? { Issue.record("Unexpected credential read"); throw SettingsCredentialError.unavailable }
        func write(_ record: SettingsCredentialRecord) throws { Issue.record("Unexpected credential write"); throw SettingsCredentialError.unavailable }
    }
}
