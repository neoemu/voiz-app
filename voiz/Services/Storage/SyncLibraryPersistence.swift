import Foundation
import Darwin

/// This private replay format stays in the account's local journal. It is never a wire DTO:
/// its payload may include local audio references needed to recover a file write after a crash.
private struct SyncLocalReplay: Codable {
    enum Kind: String, Codable { case meeting, folders, chat, dictation, translation, preferences, hide, lifecycle, resolution, localResolution }
    struct Projection: Codable { let type: String; let payload: Data }
    struct Lifecycle: Codable { let type: String; let id: String; let mutation: String }
    struct Resolution: Codable { let remote: Data; let replacement: Projection?; let resetsRemoteRevision: Bool? }
    let kind: Kind
    let id: UUID?
    let data: Data?
    let projections: [Projection]
    let hidden: [String]
    let lifecycle: [Lifecycle]?
    let resolution: Resolution?
}

@MainActor
final class SyncLibraryPersistence {
    let context: SyncLibraryContext
    let index: SyncLocalDocumentStore
    private let writer: SyncLocalChangeWriter
    private let settingsStore: SettingsStore
    static let preferencesID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default

    init(context: SyncLibraryContext, settingsStore: SettingsStore = SettingsStore()) throws {
        self.context = context
        self.settingsStore = settingsStore
        writer = SyncLocalChangeWriter(context: context)
        index = try SyncLocalDocumentStore(url: context.rootURL.appendingPathComponent("Sync/local-index.sqlite"))
        if let account = context.ownerAccountID, let generation = context.collectionGeneration {
            try index.bind(accountID: account, collectionGeneration: generation)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try recover()
        if !context.localOnly, let preferences = try index.entity(type: .preferences, id: Self.preferencesID.uuidString.lowercased()), preferences.visibility == .visible {
            // The durable index repairs a preferences projection lost before UserDefaults
            // flushed; loading never accesses provider credentials or changes providers.
            try render(type: .preferences, id: Self.preferencesID.uuidString.lowercased())
        }
    }

    /// Reuses the existing disk formats in place; source JSON, audio, registry, journals,
    /// tombstones and conflicts are never moved or deleted. Repeating after interruption
    /// adds only missing index entries and never resurrects tombstones.
    func prepareLocalLibrary() throws {
        guard context.localOnly else { return }
        try recover()
        let marker = context.rootURL.appendingPathComponent("Local/library-v1.json")
        if fileManager.fileExists(atPath: marker.path) {
            let record = try JSONDecoder().decode(LocalMigrationRecord.self, from: Data(contentsOf: marker))
            guard record.version == 1, record.libraryID == context.libraryID else { throw SyncLocalChangeWriterError.wrongContext }
            return
        }
        if fileManager.fileExists(atPath: meetingsURL.path) {
            for directory in try fileManager.contentsOfDirectory(at: meetingsURL, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                if let meeting: MeetingSession = try readOptional(MeetingSession.self, from: directory.appendingPathComponent("session.json")) {
                    guard meeting.id == id else { throw SyncWireError.invalidIdentifier }
                    try indexMissingLocalDocuments(meetingDocuments(meeting))
                }
            }
        }
        for folder in try readOptional([MeetingFolder].self, from: meetingsURL.appendingPathComponent("folders.json")) ?? [] {
            try indexMissingLocalDocuments([SyncDTOAdapter.folder(folder)])
        }
        for chat in try readOptional([ChatSession].self, from: chatURL) ?? [] {
            try indexMissingLocalDocuments([SyncDTOAdapter.conversation(id: chat.id, title: chat.title, createdAt: chat.createdAt, updatedAt: chat.updatedAt, isPinned: chat.isPinned)])
            for (position, message) in chat.messages.enumerated() {
                try indexMissingLocalDocuments([SyncDTOAdapter.message(id: message.id, conversationID: chat.id, role: message.role.rawValue, content: message.content, position: position)])
            }
        }
        try prepareLocalHistory()
        try DurableLocalFile.write(JSONEncoder().encode(LocalMigrationRecord(version: 1, libraryID: context.libraryID)), to: marker)
    }
    private func indexMissingLocalDocuments(_ documents: [SyncDocument]) throws {
        for document in documents {
            guard let id = UUID(uuidString: document.entityID), try index.isVisible(type: document.entityType, id: id),
                  try index.entity(type: document.entityType, id: document.entityID) == nil else { continue }
            try index.put(document)
        }
    }
    /// Legacy UserDefaults migration runs when the history stores open, after the
    /// library inventory. Include its newly archived records without rewriting them.
    func prepareLocalHistory() throws {
        guard context.localOnly else { return }
        if fileManager.fileExists(atPath: historyURL.path) {
            let dictations = try TextHistoryArchive<TranscriptionEntry>(databaseURL: historyURL, kind: "dictation")
            var after = ""
            while true {
                let page = try dictations.page(afterID: after, limit: 100)
                guard !page.isEmpty else { break }
                for entry in page { try indexMissingLocalDocuments([SyncDTOAdapter.dictation(entry)]) }
                after = page.last!.id.uuidString.lowercased()
            }
            let translations = try TextHistoryArchive<TranslationEntry>(databaseURL: historyURL, kind: "translation")
            after = ""
            while true {
                let page = try translations.page(afterID: after, limit: 100)
                guard !page.isEmpty else { break }
                for entry in page { try indexMissingLocalDocuments([SyncDTOAdapter.translation(entry)]) }
                after = page.last!.id.uuidString.lowercased()
            }
        }
    }
    private struct LocalMigrationRecord: Codable { let version: Int; let libraryID: UUID }

    func resolveLocalConflict(_ conflict: SyncLocalConflict, choice: SyncConflictResolutionChoice) throws {
        guard context.localOnly else { throw SyncLocalChangeWriterError.wrongContext }
        try recover()
        let document = conflict.document
        guard let current = try index.entity(type: document.entityType, id: document.entityID), current.visibility == .visible else {
            throw SyncJournalError.invalidTransition
        }
        if choice == .keepRemote {
            try index.markConflictsResolved(type: document.entityType, id: document.entityID)
        } else {
            // Preserve the current projection before selecting the preserved version.
            try index.preserveConflict(current.document, cursor: current.remoteRevision)
            let replay = SyncLocalReplay(kind: .localResolution, id: UUID(uuidString: document.entityID), data: nil,
                projections: [.init(type: document.entityType.rawValue, payload: try document.canonicalData())],
                hidden: [], lifecycle: nil, resolution: nil)
            let bytes = try encoder.encode(replay)
            try writer.write(documents: [document], localReplayData: bytes) { try self.applyReplay(bytes) }
        }
        NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
    }

    func recover() throws {
        if let owner = context.ownerAccountID, let generation = context.collectionGeneration {
            try index.validateBinding(accountID: owner, collectionGeneration: generation)
        }
        try writer.recoverPendingLocal { try self.applyReplay($0) }
    }
    var meetingsURL: URL { context.rootURL.appendingPathComponent("Meetings", isDirectory: true) }
    var historyURL: URL { context.rootURL.appendingPathComponent("History/text-history.sqlite") }
    var chatURL: URL { context.rootURL.appendingPathComponent("Chat/sessions.json") }
    func meetingURL(_ id: UUID) -> URL { meetingsURL.appendingPathComponent(id.uuidString).appendingPathComponent("session.json") }

    func saveMeeting(_ meeting: MeetingSession) throws {
        try recover()
        try save(kind: .meeting, id: meeting.id, data: encoder.encode(meeting), documents: meetingDocuments(meeting))
    }
    private func meetingDocuments(_ meeting: MeetingSession) throws -> [SyncDocument] {
        var documents = [try SyncDTOAdapter.meeting(meeting)]
        let id = meeting.id.uuidString.lowercased()
        let previous = try index.entity(type: .transcript, id: id)?.document
        let priorGeneration = previous?.value.object?["generation_id"]?.string.flatMap(UUID.init(uuidString:))
        var generation = priorGeneration ?? UUID()
        var transcript = try SyncDTOAdapter.transcript(meeting, generationID: generation)
        if let previous, previous != transcript {
            generation = UUID()
            transcript = try SyncDTOAdapter.transcript(meeting, generationID: generation)
        }
        documents.append(transcript)
        let previousSummary = try index.entity(type: .summary, id: id)?.document
        let previousSummaryGeneration = previousSummary?.value.object?["transcript_generation_id"]?.string.flatMap(UUID.init(uuidString:))
        if let candidate = try SyncDTOAdapter.summary(meeting, transcriptGenerationID: previousSummaryGeneration), candidate == previousSummary {
            documents.append(candidate)
        } else if let summary = try SyncDTOAdapter.summary(meeting, transcriptGenerationID: generation) {
            documents.append(summary)
        }
        return documents
    }
    func saveFolders(_ folders: [MeetingFolder], changed: [MeetingFolder], removed: [UUID] = []) throws {
        try save(kind: .folders, id: nil, data: encoder.encode(folders), documents: changed.map(SyncDTOAdapter.folder),
                 removed: removed.map { (.folder, $0) })
    }
    /// A sheet can outlive a remote update (including while its save awaits an
    /// admission). Keep that draft for explicit resolution instead of assigning
    /// it the revision of a newer document that the editor never displayed.
    func preserveStaleFolderEdit(_ folder: MeetingFolder, basedOn original: MeetingFolder) throws -> Bool {
        try recover()
        let proposed = try SyncDTOAdapter.folder(folder)
        let baseline = try SyncDTOAdapter.folder(original)
        guard proposed.entityID == baseline.entityID else { throw SyncWireError.invalidSchema }
        let current = try index.entity(type: .folder, id: proposed.entityID)
        if current?.visibility == .visible && current?.document == baseline { return false }
        // Saving an unchanged draft, or the already received version, is a no-op.
        if proposed != baseline && !(current?.visibility == .visible && current?.document == proposed) {
            try index.preserveConflict(proposed, cursor: context.journal?.currentCursor() ?? 0)
            NotificationCenter.default.post(name: .voizSyncLocalWrite, object: context.libraryID)
        }
        return true
    }
    func saveChats(_ sessions: [ChatSession], changed: [ChatSession], removed: [UUID]) throws {
        var documents: [SyncDocument] = []
        for session in changed {
            documents.append(try SyncDTOAdapter.conversation(id: session.id, title: session.title,
                createdAt: session.createdAt, updatedAt: session.updatedAt, isPinned: session.isPinned))
            for (position, message) in session.messages.enumerated() {
                documents.append(try SyncDTOAdapter.message(id: message.id, conversationID: session.id,
                    role: message.role.rawValue, content: message.content, position: position))
            }
        }
        try save(kind: .chat, id: nil, data: encoder.encode(sessions), documents: documents,
                 removed: removed.map { (.conversation, $0) })
    }
    func saveDictation(_ entry: TranscriptionEntry) throws {
        // History archives use the existing default Date Codable representation.
        try save(kind: .dictation, id: entry.id, data: JSONEncoder().encode(entry), documents: [SyncDTOAdapter.dictation(entry)])
    }
    func saveTranslation(_ entry: TranslationEntry) throws {
        try save(kind: .translation, id: entry.id, data: JSONEncoder().encode(entry), documents: [SyncDTOAdapter.translation(entry)])
    }
    func savePreferences(_ preferences: SyncPreferences) throws {
        let document = try SyncDTOAdapter.preferences(preferences, id: Self.preferencesID)
        try save(kind: .preferences, id: Self.preferencesID, data: nil, documents: [document])
    }

    /// Inventory existing durable content without rewriting its model or removing invalid
    /// files. Journal receipts/pending intents make repeat scans and generation reset explicit.
    @discardableResult
    func exportExisting() async throws -> Int {
        try Task.checkCancellation()
        try recover()
        guard context.journal != nil else { return 0 }
        var count = 0
        if fileManager.fileExists(atPath: meetingsURL.path) {
            let entries = try fileManager.contentsOfDirectory(at: meetingsURL, includingPropertiesForKeys: [.isDirectoryKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in entries {
                guard let id = UUID(uuidString: url.lastPathComponent), try index.isVisible(type: .meeting, id: id) else { continue }
                guard let meeting: MeetingSession = try readOptional(MeetingSession.self, from: url.appendingPathComponent("session.json")) else { continue }
                guard meeting.id == id else { throw SyncWireError.invalidIdentifier }
                count += try enqueueUnsent(meetingDocuments(meeting))
                try await exportCheckpoint()
            }
        }
        let folders: [MeetingFolder] = try readOptional([MeetingFolder].self, from: meetingsURL.appendingPathComponent("folders.json")) ?? []
        for folder in folders where try index.isVisible(type: .folder, id: folder.id) {
            count += try enqueueUnsent([SyncDTOAdapter.folder(folder)])
            try await exportCheckpoint()
        }
        let chats: [ChatSession] = try readOptional([ChatSession].self, from: chatURL) ?? []
        for chat in chats where try index.isVisible(type: .conversation, id: chat.id) {
            var documents = [try SyncDTOAdapter.conversation(id: chat.id, title: chat.title, createdAt: chat.createdAt, updatedAt: chat.updatedAt, isPinned: chat.isPinned)]
            for (position, message) in chat.messages.enumerated() where try index.isVisible(type: .message, id: message.id) {
                documents.append(try SyncDTOAdapter.message(id: message.id, conversationID: chat.id, role: message.role.rawValue, content: message.content, position: position))
            }
            count += try enqueueUnsent(documents)
            try await exportCheckpoint()
        }
        if fileManager.fileExists(atPath: historyURL.path) {
            let dictations = try TextHistoryArchive<TranscriptionEntry>(databaseURL: historyURL, kind: "dictation")
            var afterID = ""
            while true {
                try Task.checkCancellation()
                let page = try dictations.page(afterID: afterID, limit: 100)
                if page.isEmpty { break }
                for entry in page where try index.isVisible(type: .dictation, id: entry.id) { count += try enqueueUnsent([SyncDTOAdapter.dictation(entry)]) }
                afterID = page.last!.id.uuidString.lowercased()
                try await exportCheckpoint()
            }
            let translations = try TextHistoryArchive<TranslationEntry>(databaseURL: historyURL, kind: "translation")
            afterID = ""
            while true {
                try Task.checkCancellation()
                let page = try translations.page(afterID: afterID, limit: 100)
                if page.isEmpty { break }
                for entry in page where try index.isVisible(type: .translation, id: entry.id) { count += try enqueueUnsent([SyncDTOAdapter.translation(entry)]) }
                afterID = page.last!.id.uuidString.lowercased()
                try await exportCheckpoint()
            }
        }
        if try index.isVisible(type: .preferences, id: Self.preferencesID) {
            let existing = try index.entity(type: .preferences, id: Self.preferencesID.uuidString.lowercased())?.document
            let document = try existing ?? SyncDTOAdapter.preferences(SyncPreferences(snapshot: settingsStore.load()), id: Self.preferencesID)
            count += try enqueueUnsent([document])
        }
        return count
    }

    private func exportCheckpoint() async throws {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }

    private func enqueueUnsent(_ documents: [SyncDocument]) throws -> Int {
        guard let journal = context.journal else { return 0 }
        var unsent: [SyncDocument] = []
        for document in documents {
            guard let id = UUID(uuidString: document.entityID), try index.isVisible(type: document.entityType, id: id) else { continue }
            let key = document.entityType.rawValue + "/" + document.entityID
            if try journal.nextBaseRevision(entityKey: key) == 0, try journal.unresolvedMutations(entityKey: key).isEmpty {
                // Validate the whole record before any journal intent. The original model
                // remains available if it exceeds the Sync document transport budget.
                _ = try document.canonicalData()
                unsent.append(document)
            }
        }
        for document in unsent { try index.put(document) }
        try writer.enqueueExisting(unsent)
        return unsent.count
    }

    func trash(type: SyncEntityType, id: UUID) throws {
        try save(kind: .hide, id: id, data: nil, documents: [], removed: [(type, id)])
    }
    func restore(type: SyncEntityType, id: UUID) throws { try changeLifecycle(type: type, id: id, mutation: .restore) }
    func purge(type: SyncEntityType, id: UUID) throws { try changeLifecycle(type: type, id: id, mutation: .purge) }

    private func changeLifecycle(type: SyncEntityType, id: UUID, mutation: SyncMutationKind) throws {
        try recover()
        let rawID = id.uuidString.lowercased()
        guard let entity = try index.entity(type: type, id: rawID), entity.visibility == .trashed,
              mutation == .restore || mutation == .purge else { throw SyncJournalError.invalidTransition }
        let action = SyncLocalReplay.Lifecycle(type: type.rawValue, id: rawID, mutation: mutation.rawValue)
        let replay = SyncLocalReplay(kind: .lifecycle, id: id, data: nil, projections: [], hidden: [], lifecycle: [action], resolution: nil)
        let bytes = try encoder.encode(replay)
        let intent: SyncLocalMutation = mutation == .restore ? .restore(type, rawID) : .purge(type, rawID)
        var intents = [intent]
        if mutation == .purge, let journal = context.journal {
            // The server cascades published children. A child still in this Mac's outbox
            // also needs durable explicit purge intent, so cancelling an unpublished
            // parent cannot strand a child upload that later recreates detached text.
            for child in try index.ownedChildren(type: type, id: rawID) {
                if try !journal.unresolvedMutations(entityKey: child.id).isEmpty {
                    intents.append(.purge(child.document.entityType, child.document.entityID))
                }
            }
        }
        try writer.write(mutations: intents, localReplayData: bytes) { try self.applyReplay(bytes) }
        NotificationCenter.default.post(name: .voizSyncLocalWrite, object: context.libraryID)
        NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
    }

    private func save(kind: SyncLocalReplay.Kind, id: UUID?, data: Data?, documents: [SyncDocument],
                      removed: [(SyncEntityType, UUID)] = []) throws {
        try recover()
        // Unchanged portable fields need no new cloud revision (e.g. local capture status).
        var changed: [SyncDocument] = []
        for document in documents {
            let previous = try index.entity(type: document.entityType, id: document.entityID)
            guard let id = UUID(uuidString: document.entityID), try index.isVisible(type: document.entityType, id: id) else { throw SyncWireError.invalidSchema }
            if previous?.document != document { changed.append(document) }
        }
        let hidden = removed.map { $0.0.rawValue + "/" + $0.1.uuidString.lowercased() }
        let replay = SyncLocalReplay(kind: kind, id: id, data: data,
            projections: try documents.map { .init(type: $0.entityType.rawValue, payload: try $0.canonicalData()) }, hidden: hidden, lifecycle: nil, resolution: nil)
        let bytes = try encoder.encode(replay)
        let mutations = changed.map(SyncLocalMutation.upsert) + removed.map { SyncLocalMutation.trash($0.0, $0.1.uuidString.lowercased()) }
        if mutations.isEmpty && !context.localOnly { try applyReplay(bytes) }
        else { try writer.write(mutations: mutations, localReplayData: bytes) { try self.applyReplay(bytes) } }
        NotificationCenter.default.post(name: .voizSyncLocalWrite, object: context.libraryID)
    }

    func replay(_ entry: SyncJournalEntry) throws { try writer.applyReplay(entry) { try self.applyReplay($0) } }
    func replay(_ resolution: SyncResolutionRecord) throws { try writer.applyReplay(resolution) { try self.applyReplay($0) } }

    func resolve(remote: SyncEntitySnapshot, choice: SyncConflictResolutionChoice, operationIDs: [String],
                 replacement: SyncDocument?, allowRevisionRegression: Bool = false) throws -> SyncResolutionRecord {
        try recover()
        guard remote.collectionGeneration == context.collectionGeneration else { throw SyncJournalError.generationMismatch }
        let projection = try replacement.map { SyncLocalReplay.Projection(type: $0.entityType.rawValue, payload: try $0.canonicalData()) }
        let resolution = SyncLocalReplay.Resolution(remote: try remote.canonicalData(), replacement: projection, resetsRemoteRevision: allowRevisionRegression)
        let replay = SyncLocalReplay(kind: .resolution, id: UUID(uuidString: remote.entityID), data: nil,
            projections: [], hidden: [], lifecycle: nil, resolution: resolution)
        let bytes = try encoder.encode(replay)
        let record = try writer.writeResolution(remote: remote, choice: choice, operationIDs: operationIDs,
            replacement: replacement, localReplayData: bytes, allowRevisionRegression: allowRevisionRegression) { try self.applyReplay(bytes) }
        NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
        NotificationCenter.default.post(name: .voizSyncLocalWrite, object: context.libraryID)
        return record
    }
    private func applyReplay(_ data: Data) throws {
        let replay = try decoder.decode(SyncLocalReplay.self, from: data)
        switch replay.kind {
        case .meeting:
            guard let id = replay.id, let data = replay.data,
                  try decoder.decode(MeetingSession.self, from: data).id == id else { throw SyncWireError.invalidSchema }
            try write(data, to: meetingURL(id))
        case .folders:
            guard let data = replay.data else { throw SyncWireError.invalidSchema }
            _ = try decoder.decode([MeetingFolder].self, from: data)
            try write(data, to: meetingsURL.appendingPathComponent("folders.json"))
        case .chat:
            guard let data = replay.data else { throw SyncWireError.invalidSchema }
            _ = try decoder.decode([ChatSession].self, from: data)
            try write(data, to: chatURL)
        case .dictation:
            guard let data = replay.data else { throw SyncWireError.invalidSchema }
            let entry = try JSONDecoder().decode(TranscriptionEntry.self, from: data)
            let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: historyURL, kind: "dictation")
            try archive.upsert(entry, timestamp: entry.timestamp)
        case .translation:
            guard let data = replay.data else { throw SyncWireError.invalidSchema }
            let entry = try JSONDecoder().decode(TranslationEntry.self, from: data)
            let archive = try TextHistoryArchive<TranslationEntry>(databaseURL: historyURL, kind: "translation")
            try archive.upsert(entry, timestamp: entry.timestamp)
        case .preferences, .hide, .lifecycle, .resolution, .localResolution: break
        }
        if let resolution = replay.resolution {
            let remote = try SyncEntitySnapshot(value: SyncCanonicalJSON.decode(resolution.remote, maximumBytes: Int.max))
            guard remote.collectionGeneration == context.collectionGeneration else { throw SyncJournalError.generationMismatch }
            let document: SyncDocument?
            let visibility: SyncLocalVisibility
            if let replacement = resolution.replacement {
                guard remote.state == "active" || (resolution.resetsRemoteRevision == true && remote.state == "gone" && remote.revision == 0), let type = SyncEntityType(rawValue: replacement.type) else { throw SyncJournalError.invalidTransition }
                let selected = try SyncDocument(entityType: type, data: replacement.payload)
                guard selected.entityType == remote.entityType, selected.entityID == remote.entityID else { throw SyncWireError.invalidIdentifier }
                document = selected
                visibility = .visible
            } else {
                document = remote.document
                visibility = remote.state == "active" ? .visible : remote.state == "trash" ? .trashed : .purged
            }
            if let document { try index.put(document, visibility: visibility, remoteRevision: remote.revision) }
            else { try index.hide(type: remote.entityType, id: remote.entityID, as: visibility, revision: remote.revision) }
            if resolution.resetsRemoteRevision == true {
                try index.setAuthoritativeRevision(type: remote.entityType, id: remote.entityID, revision: remote.revision)
            }
            try setHistoryHidden(type: remote.entityType, id: remote.entityID, hidden: visibility != .visible)
            if visibility == .visible || remote.entityType == .message { try render(type: remote.entityType, id: remote.entityID) }
            try index.markConflictsResolved(type: remote.entityType, id: remote.entityID)
        }
        for projection in replay.projections {
            guard let type = SyncEntityType(rawValue: projection.type) else { throw SyncWireError.invalidSchema }
            try index.put(SyncDocument(entityType: type, data: projection.payload))
        }
        if replay.kind == .localResolution {
            for projection in replay.projections {
                guard let type = SyncEntityType(rawValue: projection.type) else { throw SyncWireError.invalidSchema }
                let document = try SyncDocument(entityType: type, data: projection.payload)
                try render(type: type, id: document.entityID)
                try index.markConflictsResolved(type: type, id: document.entityID)
            }
        }
        if replay.kind == .preferences { try render(type: .preferences, id: Self.preferencesID.uuidString.lowercased()) }
        for key in replay.hidden {
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let type = SyncEntityType(rawValue: String(parts[0])) else { throw SyncWireError.invalidSchema }
            try SyncIdentifier.validate(String(parts[1]))
            try applyLifecycle(type: type, id: String(parts[1]), mutation: .trash)
        }
        for action in replay.lifecycle ?? [] {
            guard let type = SyncEntityType(rawValue: action.type), let mutation = SyncMutationKind(rawValue: action.mutation),
                  mutation != .upsert else { throw SyncWireError.invalidSchema }
            try applyLifecycle(type: type, id: action.id, mutation: mutation)
        }
    }

    private func applyLifecycle(type: SyncEntityType, id: String, mutation: SyncMutationKind) throws {
        try SyncIdentifier.validate(id)
        if mutation == .restore {
            guard let entity = try index.entity(type: type, id: id), [.trashed, .visible].contains(entity.visibility) else { throw SyncJournalError.invalidTransition }
            try index.put(entity.document)
            try setHistoryHidden(type: type, id: id, hidden: false)
            if context.localOnly {
                for child in try index.ownedChildren(type: type, id: id) where child.visibility == .trashed {
                    guard try index.hasLocalTrashParent(type.rawValue + "/" + id, child: child.id) else { continue }
                    try index.put(child.document)
                    try setHistoryHidden(type: child.document.entityType, id: child.document.entityID, hidden: false)
                }
            }
            try render(type: type, id: id)
            if context.localOnly { try index.clearLocalTrashChildren(parent: type.rawValue + "/" + id) }
        } else {
            let visibility: SyncLocalVisibility = mutation == .trash ? .trashed : .purged
            for child in try index.ownedChildren(type: type, id: id) where mutation == .purge || child.visibility == .visible {
                if context.localOnly && mutation == .trash {
                    try index.recordLocalTrashChild(parent: type.rawValue + "/" + id, child: child.id)
                }
                try index.hide(type: child.document.entityType, id: child.document.entityID, as: visibility)
                try setHistoryHidden(type: child.document.entityType, id: child.document.entityID, hidden: true)
            }
            try index.hide(type: type, id: id, as: visibility)
            try setHistoryHidden(type: type, id: id, hidden: true)
            if type == .message { try render(type: type, id: id) }
        }
    }

    func applyRemote(_ change: SyncRemoteChange, pending suppliedPending: [SyncJournalEntry]) throws {
        try recover()
        guard change.collectionGeneration == context.collectionGeneration else { throw SyncWireError.invalidSchema }
        let key = change.entityType.rawValue + "/" + change.entityID
        let pending = try context.journal?.unresolvedMutations(entityKey: key) ?? suppliedPending
        if try index.remoteRevision(type: change.entityType, id: change.entityID) > change.revision {
            if try context.journal?.snapshotProgress()?.isRecovery == true,
               let current = try index.entity(type: change.entityType, id: change.entityID),
               current.visibility == .visible || current.visibility == .trashed {
                try index.preserveConflict(current.document, cursor: change.cursor)
                for entry in pending { try context.journal?.blockUpload(operationID: entry.mutation.operationID, reason: "revision_conflict") }
                NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
            }
            return
        }
        let ancestral = pending.first.map { $0.mutation.baseRevision >= change.revision } == true
            || pending.contains { $0.mutation.baseRevision + 1 == change.revision && $0.mutation.mutation == change.mutation
                && ($0.mutation.mutation != .upsert || $0.mutation.payloadSHA256 == change.payloadSHA256) }
        if ancestral {
            try index.observeRevision(type: change.entityType, id: change.entityID, revision: change.revision)
            return
        }
        let visibility: SyncLocalVisibility = change.mutation == .trash ? .trashed : change.mutation == .purge ? .purged : .visible
        if let current = try index.entity(type: change.entityType, id: change.entityID),
           current.remoteRevision == change.revision,
           current.document != change.document || current.visibility != visibility {
            // A restored backup can reuse a revision already observed by this Mac. Keep
            // the confirmed local copy exportable before accepting a divergent projection.
            if current.visibility == .visible || current.visibility == .trashed {
                try index.preserveConflict(current.document, cursor: change.cursor)
            }
            if current.visibility != .visible, visibility == .visible {
                // Equal-revision data is not evidence of an explicit restore. Never make
                // a local tombstone visible again because a backup reused its revision.
                if let document = change.document { try index.preserveConflict(document, cursor: change.cursor) }
                NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
                return
            }
        }
        // Preserve every divergent local version before replacing the visible projection.
        for entry in pending where entry.mutation.payloadSHA256 != change.payloadSHA256 {
            if let document = entry.mutation.document { try index.preserveConflict(document, cursor: change.cursor) }
            try context.journal?.blockUpload(operationID: entry.mutation.operationID, reason: "revision_conflict")
        }
        if let document = change.document { try index.put(document, visibility: visibility, remoteRevision: change.revision) }
        else { try index.hide(type: change.entityType, id: change.entityID, as: visibility, revision: change.revision) }
        try setHistoryHidden(type: change.entityType, id: change.entityID, hidden: visibility != .visible)
        if visibility == .visible || change.entityType == .message { try render(type: change.entityType, id: change.entityID) }
        NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
    }

    /// The authoritative snapshot can hide a previously synced entity, but cannot erase
    /// its local recording or silently turn a stale outbox operation into a new creation.
    func reconcileAbsence(_ progress: SyncSnapshotProgress, journal: SyncJournal) throws {
        try recover()
        var key = ""
        while true {
            let page = try index.page(after: key)
            if page.isEmpty { break }
            for entity in page {
                let document = entity.document
                key = document.entityType.rawValue + "/" + document.entityID
                guard try !journal.snapshotContains(entityKey: key) else { continue }
                let pending = try journal.unresolvedMutations(entityKey: key)
                // A local first creation has no remote base and is allowed to upload.
                // Anything previously confirmed (including pending edits) needs resolution.
                let knownRevision = try journal.knownRemoteRevision(entityKey: key)
                if entity.remoteRevision > 0 || knownRevision > 0 {
                    if entity.visibility == .purged { continue }
                    if entity.visibility == .visible || entity.visibility == .trashed {
                        // Absence can mean the confirmed version postdated a restored
                        // backup, not an explicit request to destroy this Mac's copy.
                        try index.preserveConflict(document, cursor: progress.cursor)
                    }
                    for entry in pending {
                        if let document = entry.mutation.document { try index.preserveConflict(document, cursor: progress.cursor) }
                        try journal.blockUpload(operationID: entry.mutation.operationID, reason: "revision_conflict")
                    }
                    try index.hide(type: document.entityType, id: document.entityID, as: .absent)
                    try setHistoryHidden(type: document.entityType, id: document.entityID, hidden: true)
                }
            }
        }
        NotificationCenter.default.post(name: .voizSyncRemoteApplied, object: context.libraryID)
    }

    private func setHistoryHidden(type: SyncEntityType, id: String, hidden: Bool) throws {
        guard let id = UUID(uuidString: id) else { throw SyncWireError.invalidIdentifier }
        if type == .dictation {
            try TextHistoryArchive<TranscriptionEntry>(databaseURL: historyURL, kind: "dictation").setHidden(id: id, hidden)
        } else if type == .translation {
            try TextHistoryArchive<TranslationEntry>(databaseURL: historyURL, kind: "translation").setHidden(id: id, hidden)
        }
    }

    private func render(type: SyncEntityType, id: String) throws {
        guard let uuid = UUID(uuidString: id) else { throw SyncWireError.invalidIdentifier }
        // A purge can arrive before this Mac ever received the entity's content. Its
        // tombstone is still durable; there is simply no local projection to render.
        guard let entity = try index.entity(type: type, id: id) else { return }
        switch type {
        case .meeting, .transcript, .summary:
            guard let metadata = try index.entity(type: .meeting, id: id), metadata.visibility == .visible else { return }
            let existing: MeetingSession? = try readOptional(MeetingSession.self, from: meetingURL(uuid))
            var meeting = try SyncDTOAdapter.applyingMeeting(metadata.document, to: existing)
            if let transcript = try index.entity(type: .transcript, id: id), transcript.visibility == .visible {
                meeting = try SyncDTOAdapter.applyingTranscript(transcript.document, to: meeting)
                // A summary stays on the transcript generation it was written from (meetingDocuments)
                // while later edits, such as a speaker rename, move the transcript on. It is still this
                // meeting's summary; hiding it on a mismatch erased summary and chapters at the next echo.
                if let summary = try index.entity(type: .summary, id: id), summary.visibility == .visible {
                    meeting = try SyncDTOAdapter.applyingSummary(summary.document, to: meeting)
                } else { meeting.summary = nil; meeting.chapters = nil }
            } else {
                meeting.turns = []
                meeting.summary = nil
                meeting.chapters = nil
            }
            try write(encoder.encode(meeting), to: meetingURL(uuid))
        case .folder:
            var folders: [MeetingFolder] = try readOptional([MeetingFolder].self, from: meetingsURL.appendingPathComponent("folders.json")) ?? []
            let folder = try SyncDTOAdapter.folderValue(entity.document)
            folders.removeAll { $0.id == uuid }; folders.append(folder)
            try write(encoder.encode(folders), to: meetingsURL.appendingPathComponent("folders.json"))
        case .dictation:
            let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: historyURL, kind: "dictation")
            let entry = try SyncDTOAdapter.dictationEntry(entity.document, preserving: archive.entry(id: uuid))
            try archive.upsert(entry, timestamp: entry.timestamp)
        case .translation:
            let archive = try TextHistoryArchive<TranslationEntry>(databaseURL: historyURL, kind: "translation")
            let entry = try SyncDTOAdapter.translationEntry(entity.document)
            try archive.upsert(entry, timestamp: entry.timestamp)
        case .conversation, .message:
            let conversationID = type == .conversation ? id : entity.document.value.object?["conversation_id"]?.string
            guard let conversationID, let metadata = try index.entity(type: .conversation, id: conversationID),
                  metadata.visibility == .visible, let fields = metadata.document.value.object else { return }
            let messages = try index.children(type: .message, parentID: conversationID).map { message in
                let fields = message.value.object!
                return ChatMessage(id: UUID(uuidString: message.entityID)!, role: ChatMessage.Role(rawValue: fields["role"]!.string!)!, content: fields["content"]!.string!)
            }
            let pinned: Bool = if case .bool(let value) = fields["is_pinned"]! { value } else { false }
            let conversation = ChatSession(id: UUID(uuidString: conversationID)!, title: fields["title"]!.string!, messages: messages,
                createdAt: Date(timeIntervalSince1970: Double(fields["created_at_ms"]!.integer!) / 1_000),
                updatedAt: Date(timeIntervalSince1970: Double(fields["updated_at_ms"]!.integer!) / 1_000), isPinned: pinned)
            var sessions: [ChatSession] = try readOptional([ChatSession].self, from: chatURL) ?? []
            sessions.removeAll { $0.id == conversation.id }; sessions.append(conversation)
            try write(encoder.encode(sessions), to: chatURL)
        case .preferences:
            // In the standalone app these are historical library metadata. Selecting
            // or recovering an archive must never replace the user's current settings.
            guard !context.localOnly else { return }
            guard uuid == Self.preferencesID else { throw SyncWireError.invalidIdentifier }
            var settings = settingsStore.load()
            try SyncDTOAdapter.applyingPreferences(entity.document, to: &settings)
            guard settingsStore.save(settings) else { throw SyncWireError.invalidSchema }
            NotificationCenter.default.post(name: Notification.Name("SettingsChanged"), object: nil)
        case .note: break
        }
    }
    private func readOptional<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // New meeting directories must also survive a power interruption before the
        // journal marks the intent applied. Synchronize their parent entries up to root.
        var parent = url.deletingLastPathComponent().standardizedFileURL
        let root = context.rootURL.standardizedFileURL.path
        while parent.path == root || parent.path.hasPrefix(root + "/") {
            let directory = Darwin.open(parent.path, O_RDONLY)
            guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let result = fsync(directory)
            let failure = errno
            Darwin.close(directory)
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
            if parent.path == root { break }
            parent = parent.deletingLastPathComponent()
        }
    }
}

extension Notification.Name {
    static let voizSyncLocalWrite = Notification.Name("VoizSyncLocalWrite")
    static let voizSyncRemoteApplied = Notification.Name("VoizSyncRemoteApplied")
}
