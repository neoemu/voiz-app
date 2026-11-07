import Foundation
import Combine

final class MeetingSessionStore: ObservableObject {
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var folders: [MeetingFolder] = []

    @Published private(set) var storageError: String?
    private let sync: SyncLibraryPersistence?
    private var remoteObserver: NSObjectProtocol?

    private let fileManager: FileManager
    private let baseURL: URL

    init(fileManager: FileManager = .default, sync: SyncLibraryPersistence? = nil, baseURL: URL? = nil) {
        self.fileManager = fileManager
        self.sync = sync ?? (baseURL == nil ? SyncLibraryRuntime.shared.persistence : nil)

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.baseURL = self.sync?.meetingsURL ?? baseURL ?? (SyncLibraryRuntime.shared.context?.rootURL
            ?? appSupport.appendingPathComponent("Voiz", isDirectory: true)).appendingPathComponent("Meetings", isDirectory: true)

        ensureBaseDirectory()
        loadSessions()
        loadFolders()
        if let sync = self.sync {
            remoteObserver = NotificationCenter.default.addObserver(forName: .voizSyncRemoteApplied, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? UUID == sync.context.libraryID else { return }
                Task { @MainActor in self?.loadSessions(); self?.loadFolders() }
            }
        }
    }

    deinit { if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) } }

    func createSession(type: MeetingSessionType) -> MeetingSession {
        let session = MeetingSession(
            title: defaultTitle(for: type),
            sessionType: type,
            startedAt: Date()
        )
        ensureSessionDirectory(for: session.id)
        save(session)
        return session
    }

    @discardableResult
    func save(_ session: MeetingSession) -> Bool {
        var session = session
        session.reconcileSpeakers()
        ensureSessionDirectory(for: session.id)
        let url = sessionFileURL(for: session.id)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(session)
            if let sync { try sync.saveMeeting(session) }
            else { try DurableLocalFile.write(data, to: url, fileManager: fileManager) }
            storageError = nil
            upsertInMemory(session)
            return true
        } catch {
            storageError = String(localized: "Não foi possível salvar a reunião. Os arquivos e a fila foram preservados.")
            return false
        }
    }

    /// A reunião existe nesta biblioteca, ainda que na lixeira do Sync, onde `save` a recusaria.
    func hasRecord(forSession id: UUID) -> Bool {
        if sessions.contains(where: { $0.id == id }) { return true }
        guard let sync else { return false }
        return (try? sync.index.entity(type: .meeting, id: id.uuidString.lowercased())) != nil
    }

    func delete(_ session: MeetingSession) {
        if let sync {
            do { try sync.trash(type: .meeting, id: session.id); sessions.removeAll { $0.id == session.id }; storageError = nil }
            catch { storageError = String(localized: "Não foi possível mover a reunião para a lixeira.") }
            return
        }
        let directory = sessionDirectoryURL(for: session.id)
        do {
            if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
            sessions.removeAll { $0.id == session.id }
            storageError = nil
        } catch { storageError = String(localized: "Não foi possível excluir a reunião deste Mac.") }
    }

    // MARK: - Pastas

    @discardableResult
    func createFolder(name: String, details: String = "") -> MeetingFolder {
        let folder = MeetingFolder(name: name, details: details)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveFolders(changed: [folder])
        return folder
    }

    func updateFolder(_ folder: MeetingFolder, basedOn original: MeetingFolder? = nil) {
        if let sync, let original {
            do {
                if try sync.preserveStaleFolderEdit(folder, basedOn: original) {
                    loadFolders()
                    storageError = nil
                    return
                }
            } catch {
                storageError = String(localized: "Não foi possível salvar as pastas. Os arquivos foram preservados.")
                return
            }
        }
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveFolders(changed: [folder])
    }

    /// Apaga a pasta e desassocia as sessões que estavam nela (as reuniões continuam existindo).
    func deleteFolder(_ folder: MeetingFolder) {
        folders.removeAll { $0.id == folder.id }
        saveFolders(changed: [], removed: [folder.id])
        for session in sessions where session.folderId == folder.id {
            var updated = session
            updated.folderId = nil
            save(updated)
        }
    }

    func folder(withId id: UUID?) -> MeetingFolder? {
        guard let id else { return nil }
        return folders.first(where: { $0.id == id })
    }

    func sessionDirectoryURL(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioFileName(for source: MeetingCaptureSource) -> String {
        switch source {
        case .microphone:
            return "microphone.caf"
        case .systemAudio:
            return "system-audio.caf"
        }
    }

    private func loadSessions() {
        guard let sessionDirectories = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            sessions = []
            return
        }

        let decodedSessions = sessionDirectories.compactMap { directory -> MeetingSession? in
            let url = directory.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var session = try? decoder.decode(MeetingSession.self, from: data) else { return nil }
            session.reconcileSpeakers()
            if let sync, (try? sync.index.isVisible(type: .meeting, id: session.id)) != true { return nil }
            return session
        }

        sessions = decodedSessions.sorted { $0.startedAt > $1.startedAt }
    }

    private func upsertInMemory(_ session: MeetingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
    }

    private func loadFolders() {
        guard let data = try? Data(contentsOf: foldersFileURL) else {
            folders = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([MeetingFolder].self, from: data)) ?? []
        folders = decoded.filter { folder in
            guard let sync else { return true }
            return (try? sync.index.isVisible(type: .folder, id: folder.id)) == true
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func saveFolders(changed: [MeetingFolder], removed: [UUID] = []) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(folders)
            if let sync { try sync.saveFolders(folders, changed: changed, removed: removed) }
            else { try DurableLocalFile.write(data, to: foldersFileURL, fileManager: fileManager) }
            storageError = nil
        } catch {
            storageError = String(localized: "Não foi possível salvar as pastas. Os arquivos foram preservados.")
            loadFolders()
        }
    }

    private var foldersFileURL: URL {
        baseURL.appendingPathComponent("folders.json")
    }

    private func sessionFileURL(for id: UUID) -> URL {
        sessionDirectoryURL(for: id).appendingPathComponent("session.json")
    }

    private func ensureBaseDirectory() {
        do {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create meetings directory: \(error)")
        }
    }

    private func ensureSessionDirectory(for id: UUID) {
        do {
            try fileManager.createDirectory(at: sessionDirectoryURL(for: id), withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create meeting session directory: \(error)")
        }
    }

    private func defaultTitle(for type: MeetingSessionType) -> String {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(type.displayName) \(formatter.string(from: Date()))"
    }
}
