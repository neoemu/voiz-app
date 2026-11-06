import Foundation
import Combine

@MainActor
final class TranslationHistoryStore: ObservableObject {
    @Published private(set) var entries: [TranslationEntry] = []
    @Published private(set) var storageError: String?
    @Published private(set) var totalCount = 0
    var hasMoreEntries: Bool { entries.count < totalCount }

    private let userDefaultsKey: String
    private let sync: SyncLibraryPersistence?
    private var remoteObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private var archive: TextHistoryArchive<TranslationEntry>?
    private var visibleLimit = 100
    private var watchdog: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, archiveURL: URL? = nil, watchChanges: Bool = true, sync: SyncLibraryPersistence? = nil) {
        self.defaults = defaults
        self.sync = sync ?? (defaults === UserDefaults.standard && archiveURL == nil ? SyncLibraryRuntime.shared.persistence : nil)
        let context = self.sync?.context ?? (defaults === UserDefaults.standard && archiveURL == nil ? SyncLibraryRuntime.shared.context : nil)
        let originalRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voiz").standardizedFileURL.resolvingSymlinksInPath()
        let isOriginalLocal = context.map { $0.ownerAccountID == nil && $0.rootURL.standardizedFileURL.resolvingSymlinksInPath() == originalRoot } ?? true
        userDefaultsKey = "translationHistory" + (isOriginalLocal ? "" : "." + context!.libraryID.uuidString)
        let url = self.sync?.historyURL ?? archiveURL ?? context?.rootURL.appendingPathComponent("History/text-history.sqlite") ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Voiz/History/text-history.sqlite") : nil)
        do {
            let archive = try TextHistoryArchive<TranslationEntry>(databaseURL: url, kind: "translation")
            let legacy = defaults.data(forKey: userDefaultsKey)
            try archive.migrate(legacy, timestamp: \.timestamp)
            if let legacy, defaults.data(forKey: userDefaultsKey + ".beforeArchive.v1") == nil {
                defaults.set(legacy, forKey: userDefaultsKey + ".beforeArchive.v1")
            }
            self.archive = archive
            try self.sync?.prepareLocalHistory()
            try reload()
        } catch { reportStorageFailure() }
        if watchChanges {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard !Task.isCancelled else { return }
                    do { try self?.reload() } catch { self?.reportStorageFailure() }
                }
            }
        }
    }

    deinit { watchdog?.cancel() }

    func loadMore() {
        guard hasMoreEntries else { return }
        visibleLimit += 100
        do { try reload() } catch { reportStorageFailure() }
    }
    func page(limit: Int = 100, offset: Int = 0) throws -> [TranslationEntry] {
        guard let archive else { throw TextHistoryArchiveError.corruptRecord }
        return try archive.page(limit: limit, offset: offset)
    }
    func entry(id: UUID) -> TranslationEntry? { try? archive?.entry(id: id) }

    /// Searches the retained archive rather than the presentation cache.
    func page(afterID: String, limit: Int = 100) throws -> [TranslationEntry] {
        guard let archive else { throw TextHistoryArchiveError.corruptRecord }
        return try archive.page(afterID: afterID, limit: limit)
    }
    func visibleEntry(id: UUID) -> TranslationEntry? { try? archive?.entry(id: id, visibleOnly: true) }


    @discardableResult
    func addEntry(_ entry: TranslationEntry) -> Bool {
        mutate {
            if let sync { try sync.saveTranslation(entry) }
            else { try $0.upsert(entry, timestamp: entry.timestamp) }
            try reload(ensureVisible: entry.id)
        }
    }
    @discardableResult
    func deleteEntry(_ entry: TranslationEntry) -> Bool {
        guard let sync else { return removeSyncedText(id: entry.id) }
        return mutate { _ in try sync.trash(type: .translation, id: entry.id); try reload() }
    }

    @discardableResult
    func removeSyncedText(id: UUID) -> Bool {
        mutate { try $0.remove(id: id); try reload() }
    }
    @discardableResult
    func renameEntry(_ entry: TranslationEntry, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return mutate {
            if let sync {
                guard var current = try $0.entry(id: entry.id) else { return }
                current.title = trimmed.isEmpty ? nil : trimmed
                try sync.saveTranslation(current)
            } else { try $0.update(id: entry.id, timestamp: \.timestamp) { $0.title = trimmed.isEmpty ? nil : trimmed } }
            try reload(ensureVisible: entry.id)
        }
    }
    @discardableResult
    func clearAll() -> Bool {
        mutate { archive in
            while true {
                let page = try archive.page()
                if page.isEmpty { break }
                for entry in page {
                    if let sync { try sync.trash(type: .translation, id: entry.id) }
                    else { try archive.remove(id: entry.id) }
                }
            }
            try reload()
        }
    }
    private func mutate(_ body: (TextHistoryArchive<TranslationEntry>) throws -> Void) -> Bool {
        do {
            guard let archive else { throw TextHistoryArchiveError.corruptRecord }
            try body(archive)
            storageError = nil
            return true
        } catch { reportStorageFailure(); return false }
    }
    private func reload(ensureVisible id: UUID? = nil) throws {
        guard let archive else { throw TextHistoryArchiveError.corruptRecord }
        var loaded: [TranslationEntry] = []
        for offset in stride(from: 0, to: visibleLimit, by: 100) {
            let page = try archive.page(limit: 100, offset: offset)
            loaded += page
            if page.count < 100 { break }
        }
        if let id, !loaded.contains(where: { $0.id == id }), let entry = try archive.entry(id: id) {
            loaded.insert(entry, at: 0)
        }
        totalCount = try archive.count
        if loaded != entries { entries = loaded }
        defaults.set(try JSONEncoder().encode(Array(loaded.prefix(100))), forKey: userDefaultsKey)
    }
    private func reportStorageFailure() {
        storageError = String(localized: "Não foi possível salvar ou ler o histórico.")
    }
}
