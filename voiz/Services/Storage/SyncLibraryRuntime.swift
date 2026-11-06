import Foundation
import Combine

/// Selects immutable local library roots. Former account ownership is compatibility
/// metadata only: this runtime has no authentication, transport or background sync.
@MainActor
final class LocalLibraryRuntime: ObservableObject {
    static let shared = LocalLibraryRuntime()
    @Published private(set) var revision = UUID()
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    @Published private(set) var availableLibraries: [SyncLibraryContext] = []
    private var storageReady = false
    var canStartNewWorkInLibrary: Bool { context != nil && persistence != nil && storageReady }
    private(set) var context: SyncLibraryContext?
    private(set) var persistence: SyncLibraryPersistence?
    private var registry: SyncLibraryRegistry?
    private var meetingWorkspaces: [URL: MeetingWorkspaceStore] = [:]
    private lazy var unavailableMeetingWorkspace = MeetingWorkspaceStore(context: nil)
    var meetingWorkspace: MeetingWorkspaceStore {
        guard let context else { return unavailableMeetingWorkspace }
        let root = context.rootURL.standardizedFileURL
        if let cached = meetingWorkspaces[root] { return cached }
        let store = MeetingWorkspaceStore(context: context)
        meetingWorkspaces[root] = store
        return store
    }

    convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voiz", isDirectory: true)
        self.init(rootURL: root)
    }

    /// Explicit roots also allow synthetic tests without reading personal libraries.
    init(rootURL: URL) {
        do {
            let registry = try SyncLibraryRegistry(baseURL: rootURL.appendingPathComponent("Libraries"),
                initialLocalRoot: rootURL, localOnly: true)
            self.registry = registry
            availableLibraries = try registry.libraryDescriptors()
            let selected = try registry.currentLocalLibrary()
            context = selected
            do { try open(selected) }
            catch {
                // Keep the validated index available for reading/export after an
                // incomplete inventory; writes stay blocked until retry succeeds.
                persistence = try? SyncLibraryPersistence(context: selected)
                throw error
            }
        } catch {
            lastError = String(localized: "Não foi possível abrir a biblioteca local. Seus arquivos foram preservados.")
        }
    }

    init(context: SyncLibraryContext, persistence: SyncLibraryPersistence) throws {
        guard context.libraryID == persistence.context.libraryID, context.rootURL == persistence.context.rootURL,
              context.ownerAccountID == persistence.context.ownerAccountID,
              context.collectionGeneration == persistence.context.collectionGeneration else { throw SyncLocalChangeWriterError.wrongContext }
        self.context = context
        self.persistence = persistence
        self.availableLibraries = [context]
        self.storageReady = true
    }

    // Kept for startup callers: opening a library schedules no network work.
    func start() {}
    func retry() {
        guard let context else { return }
        do { try open(context); revision = UUID() }
        catch { lastError = String(localized: "Não foi possível abrir a biblioteca local. Seus arquivos foram preservados.") }
    }

    func selectLocalLibrary() async { await select(nil) }
    func selectLibrary(id: UUID) async { await select(id) }
    func browseArchive(_ id: UUID) async { await select(id) }
    private func select(_ id: UUID?) async {
        guard let registry else { return }
        guard !VoizWorkTracker.shared.hasActiveWork else {
            lastError = String(localized: "Termine a gravação ou o processamento antes de trocar de biblioteca.")
            return
        }
        do {
            // Validate and recover before committing selection. A failed open never
            // retargets the live stores or permits writes into a fallback library.
            let previous = context?.libraryID
            let selected = try id.map { try registry.selectArchivedLibrary(id: $0, hasActiveWork: false) }
                ?? registry.selectLocalLibrary(hasActiveWork: false)
            do { try open(selected) }
            catch {
                if let previous { _ = try? registry.selectArchivedLibrary(id: previous, hasActiveWork: false) }
                throw error
            }
            availableLibraries = try registry.libraryDescriptors()
            revision = UUID()
        } catch {
            lastError = String(localized: "Não foi possível abrir a biblioteca. Os arquivos foram preservados.")
        }
    }

    private func open(_ selected: SyncLibraryContext) throws {
        let next = try SyncLibraryPersistence(context: selected)
        try next.prepareLocalLibrary()
        context = selected
        persistence = next
        storageReady = true
        lastError = nil
        status = selected.ownerAccountID == nil
            ? String(localized: "Usando a biblioteca local")
            : String(localized: "Usando os dados já baixados desta biblioteca. Itens somente na nuvem não estão incluídos.")
    }

    func restoreFromTrash(_ item: SyncLocalEntity) async { await changeTrash(item, purge: false) }
    func purgeFromTrash(_ item: SyncLocalEntity) async { await changeTrash(item, purge: true) }
    private func changeTrash(_ item: SyncLocalEntity, purge: Bool) async {
        guard let captured = persistence, let id = UUID(uuidString: item.document.entityID),
              let activity = await VoizEditingGate.shared.begin() else { return }
        defer { activity.finish() }
        guard captured.context.libraryID == context?.libraryID else { return }
        do {
            if purge { try captured.purge(type: item.document.entityType, id: id) }
            else { try captured.restore(type: item.document.entityType, id: id) }
            lastError = nil
        } catch { lastError = String(localized: "Não foi possível alterar a lixeira. O histórico foi preservado.") }
    }

    func resolveConflict(_ conflict: SyncLocalConflict, choice: SyncConflictResolutionChoice) async {
        guard let captured = persistence, let activity = await VoizEditingGate.shared.begin() else { return }
        defer { activity.finish() }
        guard captured.context.libraryID == context?.libraryID else { return }
        do {
            try captured.resolveLocalConflict(conflict, choice: choice)
            lastError = nil
        } catch { lastError = String(localized: "Não foi possível resolver o conflito. As versões foram preservadas para uma nova tentativa.") }
    }

    /// Exports downloaded texts only. Audio and cloud-only content are never implied.
    /// A fresh destination prevents partial exports from overwriting an earlier backup.
    func exportDownloadedTexts(to directory: URL) async throws -> Int {
        guard let context, let persistence else { throw SyncLocalChangeWriterError.wrongContext }
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        let libraryID = context.libraryID
        try SyncDurableBlobStore.createDirectoryDurably(directory)
        var after = "", count = 0
        while true {
            guard self.context?.libraryID == libraryID else { throw SyncLocalChangeWriterError.wrongContext }
            let page = try persistence.index.page(after: after, limit: 1)
            guard let item = page.first else { break }
            if item.visibility == .visible || item.visibility == .trashed {
                let name = item.document.entityType.rawValue + "-" + item.document.entityID + ".json"
                try DurableLocalFile.write(item.document.canonicalData(), to: directory.appendingPathComponent(name))
                count += 1
            }
            after = item.id
            await Task.yield()
        }
        after = ""
        while true {
            guard self.context?.libraryID == libraryID else { throw SyncLocalChangeWriterError.wrongContext }
            let page = try persistence.index.conflictPage(after: after, limit: 1, includeResolved: true)
            guard let item = page.first else { break }
            try DurableLocalFile.write(item.document.canonicalData(), to: directory.appendingPathComponent("conflict-" + SyncCanonicalJSON.sha256(Data(item.id.utf8)) + ".json"))
            count += 1; after = item.id
            await Task.yield()
        }
        let note = "Cópia dos textos disponíveis neste Mac. Inclui itens ativos, lixeira e conflitos preservados. Não inclui áudios nem itens que existam apenas na nuvem. Arquivos JSON em UTF-8.\n"
        try DurableLocalFile.write(Data(note.utf8), to: directory.appendingPathComponent("LEIA-ME.txt"))
        return count
    }
}

// Existing stores keep their source API while on-disk formats remain readable.
typealias SyncLibraryRuntime = LocalLibraryRuntime
