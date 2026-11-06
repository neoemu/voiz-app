import Foundation

nonisolated enum SyncLocalMutation: Sendable {
    case upsert(SyncDocument)
    case trash(SyncEntityType, String)
    case restore(SyncEntityType, String)
    case purge(SyncEntityType, String)

    fileprivate var entity: (type: SyncEntityType, id: String) {
        switch self {
        case .upsert(let document): (document.entityType, document.entityID)
        case .trash(let type, let id), .restore(let type, let id), .purge(let type, let id): (type, id)
        }
    }
    fileprivate func envelope(generation: String, baseRevision: Int64) throws -> SyncMutationEnvelope {
        let type: SyncMutationKind
        let document: SyncDocument?
        switch self {
        case .upsert(let value): type = .upsert; document = value
        case .trash: type = .trash; document = nil
        case .restore: type = .restore; document = nil
        case .purge: type = .purge; document = nil
        }
        return try SyncMutationEnvelope(collectionGeneration: generation, entityType: entity.type, entityID: entity.id,
                                        baseRevision: baseRevision, mutation: type, document: document)
    }
}

nonisolated enum SyncLocalChangeWriterError: Error, Equatable, Sendable {
    case corruptReplay
    case duplicateEntity
    case wrongContext
}

/// Main-actor serialization matches the file-backed stores. The immutable context, not the
/// currently authenticated user, owns every save. Persist must be idempotent and durable.
@MainActor
final class SyncLocalChangeWriter {
    let context: SyncLibraryContext

    init(context: SyncLibraryContext) { self.context = context }

    func write(documents: [SyncDocument], localReplayData: Data, persist: () throws -> Void) throws {
        try write(mutations: documents.map(SyncLocalMutation.upsert), localReplayData: localReplayData, persist: persist)
    }

    /// Prepare the complete intent before any file changes. A failure of persist leaves the
    /// exact batch replayable and blocks a newer save until recoverPendingLocal succeeds.
    func write(mutations: [SyncLocalMutation], localReplayData: Data, persist: () throws -> Void) throws {
        if context.localOnly {
            guard try pendingLocalData() == nil else { throw SyncJournalError.invalidTransition }
            // This local write-ahead record is independent of accounts and cloud revisions.
            // Empty completion is durable too, so an acknowledged write never replays later.
            try DurableLocalFile.write(encodeReplay(kind: .storeWrite, payload: localReplayData), to: localReplayURL)
            try persist()
            try DurableLocalFile.write(Data(), to: localReplayURL)
            return
        }
        guard let journal = context.journal else { try persist(); return }
        try validate(journal)
        guard try journal.pendingLocalReplays().isEmpty, try !journal.hasPendingResolution() else { throw SyncJournalError.invalidTransition }
        guard !mutations.isEmpty else { try persist(); return }
        let replay = try encodeReplay(kind: .storeWrite, payload: localReplayData)
        let envelopes = try prepare(mutations, journal: journal, replay: replay)
        try persist()
        try journal.markLocalAppliedBatch(operationIDs: envelopes.map(\.operationID))
    }

    /// Already durable records still pass through the same outbox prepare barrier. No local
    /// file write is needed when replaying an interrupted export, so this intent has its own kind.
    func enqueueExisting(_ documents: [SyncDocument]) throws {
        guard !context.localOnly, let journal = context.journal, !documents.isEmpty else { return }
        try validate(journal)
        let replay = try encodeReplay(kind: .exportOnly, payload: Data())
        let envelopes = try prepare(documents.map(SyncLocalMutation.upsert), journal: journal, replay: replay)
        try journal.markLocalAppliedBatch(operationIDs: envelopes.map(\.operationID))
    }

    private var localReplayURL: URL { context.rootURL.appendingPathComponent("Local/pending-write.plist") }
    private func pendingLocalData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: localReplayURL.path) else { return nil }
        let bytes = try Data(contentsOf: localReplayURL)
        return bytes.isEmpty ? nil : bytes
    }

    func recoverPendingLocal(apply: (Data) throws -> Void) throws {
        // Finish legacy interrupted writes first. No upload is scheduled or acknowledged.
        if let journal = context.journal { try recoverLegacy(journal, apply: apply) }
        if context.localOnly, let bytes = try pendingLocalData() {
            try applyPrivateReplay(bytes, apply: apply)
            try DurableLocalFile.write(Data(), to: localReplayURL)
        }
    }
    private func recoverLegacy(_ journal: SyncJournal, apply: (Data) throws -> Void) throws {
        try validate(journal)
        for resolution in try journal.pendingResolutions() {
            try applyReplay(resolution, apply: apply)
            try journal.finalizeResolution(resolutionID: resolution.resolutionID)
        }
        let entries = try journal.pendingLocalReplays()
        // All members of one batch contain the same complete local replay. Decode/apply it
        // once, then mark the complete batch atomically. Repeating after a crash is safe.
        var replayed = Set<Data>()
        for entry in entries where replayed.insert(entry.localReplayData).inserted {
            try applyReplay(entry, apply: apply)
        }
        try journal.markLocalAppliedBatch(operationIDs: entries.map(\.mutation.operationID))
    }

    /// For SyncEngine.replayLocal. The engine owns marking the supplied entry applied.
    func applyReplay(_ entry: SyncJournalEntry, apply: (Data) throws -> Void) throws {
        guard let journal = context.journal else { throw SyncLocalChangeWriterError.wrongContext }
        try validate(journal)
        guard entry.mutation.collectionGeneration == journal.collectionGeneration else { throw SyncLocalChangeWriterError.wrongContext }
        try applyPrivateReplay(entry.localReplayData, apply: apply)
    }

    func applyReplay(_ resolution: SyncResolutionRecord, apply: (Data) throws -> Void) throws {
        guard let journal = context.journal else { throw SyncLocalChangeWriterError.wrongContext }
        try validate(journal)
        guard resolution.remote.collectionGeneration == journal.collectionGeneration else { throw SyncLocalChangeWriterError.wrongContext }
        try applyPrivateReplay(resolution.localReplayData, apply: apply)
    }

    func writeResolution(remote: SyncEntitySnapshot, choice: SyncConflictResolutionChoice, operationIDs: [String],
                         replacement: SyncDocument?, localReplayData: Data, allowRevisionRegression: Bool = false, persist: () throws -> Void) throws -> SyncResolutionRecord {
        guard let journal = context.journal else { throw SyncLocalChangeWriterError.wrongContext }
        try validate(journal)
        let bytes = try encodeReplay(kind: .storeWrite, payload: localReplayData)
        let resolution = try journal.prepareResolution(remote: remote, choice: choice, operationIDs: operationIDs,
            replacement: replacement, localReplayData: bytes, allowRevisionRegression: allowRevisionRegression)
        try persist()
        try journal.finalizeResolution(resolutionID: resolution.resolutionID)
        return resolution
    }

    private func applyPrivateReplay(_ bytes: Data, apply: (Data) throws -> Void) throws {
        let replay: Replay
        do { replay = try PropertyListDecoder().decode(Replay.self, from: bytes) }
        catch { throw SyncLocalChangeWriterError.corruptReplay }
        guard replay.schemaVersion == 1, replay.libraryID == context.libraryID,
              replay.accountID == context.ownerAccountID, replay.generation == context.collectionGeneration else {
            throw SyncLocalChangeWriterError.wrongContext
        }
        switch replay.kind {
        case .storeWrite: try apply(replay.payload)
        case .exportOnly:
            guard replay.payload.isEmpty else { throw SyncLocalChangeWriterError.corruptReplay }
        }
    }

    private func validate(_ journal: SyncJournal) throws {
        guard context.ownerAccountID == journal.accountID, context.collectionGeneration == journal.collectionGeneration else {
            throw SyncLocalChangeWriterError.wrongContext
        }
    }

    private func prepare(_ mutations: [SyncLocalMutation], journal: SyncJournal, replay: Data) throws -> [SyncMutationEnvelope] {
        var keys = Set<String>()
        let envelopes = try mutations.map { mutation in
            let key = mutation.entity.type.rawValue + "/" + mutation.entity.id
            guard keys.insert(key).inserted else { throw SyncLocalChangeWriterError.duplicateEntity }
            return try mutation.envelope(generation: journal.collectionGeneration, baseRevision: journal.nextBaseRevision(entityKey: key))
        }
        try journal.prepareBatch(envelopes.map { ($0, replay) })
        return envelopes
    }

    private struct Replay: Codable {
        enum Kind: String, Codable { case storeWrite, exportOnly }
        let schemaVersion: Int
        let libraryID: UUID
        let accountID: String?
        let generation: String?
        let kind: Kind
        let payload: Data
    }
    private func encodeReplay(kind: Replay.Kind, payload: Data) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(Replay(schemaVersion: 1, libraryID: context.libraryID, accountID: context.ownerAccountID,
                                        generation: context.collectionGeneration, kind: kind, payload: payload))
    }
}
