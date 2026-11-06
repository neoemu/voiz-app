import Foundation
import Combine

@MainActor
final class TranscriptionHistoryStore: ObservableObject {
    @Published private(set) var entries: [TranscriptionEntry] = []
    @Published private(set) var storageError: String?
    @Published private(set) var totalCount = 0
    var hasMoreEntries: Bool { entries.count < totalCount }

    private let userDefaultsKey: String
    private let sync: SyncLibraryPersistence?
    private var remoteObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private var archive: TextHistoryArchive<TranscriptionEntry>?
    private var visibleLimit = 100
    private var revealedEntryID: UUID?
    let audioStore: DictationAudioStore

    init(defaults: UserDefaults = .standard, audioStore: DictationAudioStore? = nil,
         archiveURL: URL? = nil, sync: SyncLibraryPersistence? = nil) {
        self.defaults = defaults
        self.sync = sync ?? (defaults === UserDefaults.standard && archiveURL == nil ? SyncLibraryRuntime.shared.persistence : nil)
        let context = self.sync?.context ?? (defaults === UserDefaults.standard && archiveURL == nil ? SyncLibraryRuntime.shared.context : nil)
        let originalRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voiz").standardizedFileURL.resolvingSymlinksInPath()
        let isOriginalLocal = context.map { $0.ownerAccountID == nil && $0.rootURL.standardizedFileURL.resolvingSymlinksInPath() == originalRoot } ?? true
        userDefaultsKey = "transcriptionHistory" + (isOriginalLocal ? "" : "." + context!.libraryID.uuidString)
        self.audioStore = audioStore ?? DictationAudioStore(directory: context?.rootURL.appendingPathComponent("DictationAudio"))
        // Injected defaults remain isolated in memory unless a test supplies a temporary database.
        let url = self.sync?.historyURL ?? archiveURL ?? context?.rootURL.appendingPathComponent("History/text-history.sqlite") ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Voiz/History/text-history.sqlite") : nil)
        do {
            let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: url, kind: "dictation")
            let legacy = defaults.data(forKey: userDefaultsKey)
            try archive.migrate(legacy, timestamp: \.timestamp)
            if let legacy, defaults.data(forKey: userDefaultsKey + ".beforeArchive.v1") == nil {
                defaults.set(legacy, forKey: userDefaultsKey + ".beforeArchive.v1")
            }
            self.archive = archive
            try self.sync?.prepareLocalHistory()
            try reload()
        } catch { reportStorageFailure() }
        remoteObserver = NotificationCenter.default.addObserver(forName: .voizSyncRemoteApplied, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in do { try self?.reload() } catch { self?.reportStorageFailure() } }
        }
    }
    deinit { if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) } }

    func loadMore() {
        guard hasMoreEntries else { return }
        visibleLimit += 100
        do { try reload() } catch { reportStorageFailure() }
    }

    func page(limit: Int = 100, offset: Int = 0) throws -> [TranscriptionEntry] {
        guard let archive else { throw TextHistoryArchiveError.corruptRecord }
        return try archive.page(limit: limit, offset: offset)
    }

    func entry(id: UUID) -> TranscriptionEntry? { try? archive?.entry(id: id) }

    /// Searches the retained archive rather than the presentation cache.
    func page(afterID: String, limit: Int = 100) throws -> [TranscriptionEntry] {
        guard let archive else { throw TextHistoryArchiveError.corruptRecord }
        return try archive.page(afterID: afterID, limit: limit)
    }
    func visibleEntry(id: UUID) -> TranscriptionEntry? { try? archive?.entry(id: id, visibleOnly: true) }


    /// Opening an old search/citation result pins just that entry alongside the cache.
    /// A later deletion still hides it; consultation never unhides an archive row.
    @discardableResult
    func revealEntry(id: UUID) -> Bool {
        do {
            guard let archive else { throw TextHistoryArchiveError.corruptRecord }
            guard try archive.entry(id: id, visibleOnly: true) != nil else {
                if revealedEntryID == id { revealedEntryID = nil }
                try reload()
                return false
            }
            revealedEntryID = id
            try reload(ensureVisible: id)
            return true
        } catch { reportStorageFailure(); return false }
    }

    func addEntry(_ entry: TranscriptionEntry) {
        do {
            guard let archive else { throw TextHistoryArchiveError.corruptRecord }
            if let sync { try sync.saveDictation(entry) }
            else { try archive.upsert(entry, timestamp: entry.timestamp) }
            try reload(ensureVisible: entry.id)
        } catch { reportStorageFailure() }
    }

    func deleteEntry(_ entry: TranscriptionEntry) {
        storageError = nil
        if let sync {
            do { try sync.trash(type: .dictation, id: entry.id); try reload() } catch { reportStorageFailure() }
        } else {
            guard deleteAudio(for: entry) else { return }
            removeText(id: entry.id)
        }
    }

    /// Receiving a cloud tombstone must preserve local audio and never call deleteEntry.
    func removeSyncedText(id: UUID) { removeText(id: id) }

    private func removeText(id: UUID) {
        do {
            guard let archive else { throw TextHistoryArchiveError.corruptRecord }
            try archive.remove(id: id)
            try reload()
        } catch { reportStorageFailure() }
    }

    func renameEntry(_ entry: TranscriptionEntry, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(entry.id) { $0.title = trimmed.isEmpty ? nil : trimmed }
    }

    func clearAll() {
        storageError = nil
        do {
            guard let archive else { throw TextHistoryArchiveError.corruptRecord }
            var offset = 0
            while true {
                let page = try archive.page(limit: 100, offset: offset)
                if page.isEmpty { break }
                for entry in page {
                    if let sync { try sync.trash(type: .dictation, id: entry.id) }
                    else if deleteAudio(for: entry) { try archive.remove(id: entry.id) }
                    else { offset += 1 }
                }
            }
            try reload(clearError: storageError == nil)
        } catch { reportStorageFailure() }
    }

    func update(_ id: UUID, change: (inout TranscriptionEntry) -> Void) {
        do {
            guard let archive else { throw TextHistoryArchiveError.corruptRecord }
            if let sync {
                guard var entry = try archive.entry(id: id) else { return }
                change(&entry)
                try sync.saveDictation(entry)
            } else { try archive.update(id: id, timestamp: \.timestamp, change: change) }
            try reload(ensureVisible: id)
        } catch { reportStorageFailure() }
    }

    func complete(_ id: UUID, raw: String, text: String, provenance: TranscriptionProvenance, message: String?) {
        update(id) { entry in
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !entry.text.isEmpty, entry.text != text { entry.previousText = entry.text }
                entry.text = text
                entry.rawText = raw
                entry.provenance = provenance
            }
            entry.processingMessage = message
        }
    }

    private func deleteAudio(for entry: TranscriptionEntry) -> Bool {
        guard let audioID = entry.audioID else { return true }
        do { try audioStore.remove(audioID); return true }
        catch {
            storageError = String(localized: "Não foi possível excluir o áudio. Tente novamente.")
            return false
        }
    }

    private func reload(ensureVisible id: UUID? = nil, clearError: Bool = true) throws {
        guard let archive else { throw TextHistoryArchiveError.corruptRecord }
        // Bounded pages on disk; only pages requested by the user enter the visible cache.
        var loaded: [TranscriptionEntry] = []
        for offset in stride(from: 0, to: visibleLimit, by: 100) {
            let page = try archive.page(limit: 100, offset: offset)
            loaded += page
            if page.count < 100 { break }
        }
        if let id = id ?? revealedEntryID, !loaded.contains(where: { $0.id == id }), let value = try archive.entry(id: id, visibleOnly: true) {
            loaded.insert(value, at: 0)
        }
        totalCount = try archive.count
        entries = loaded
        // Compatibility cache only. Shrinking it never deletes archive rows or audio.
        defaults.set(try JSONEncoder().encode(Array(loaded.prefix(100))), forKey: userDefaultsKey)
        if clearError { storageError = nil }
    }

    private func reportStorageFailure() {
        storageError = String(localized: "Não foi possível salvar ou ler o histórico.")
    }
}
