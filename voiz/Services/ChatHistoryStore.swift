import Foundation

/// Persiste as conversas do Chat em `Application Support/Voiz/Chat/sessions.json`.
///
/// Arquivo em disco, e não `UserDefaults` como os históricos de ditado e tradução: uma conversa
/// guarda respostas inteiras do modelo, e o `UserDefaults` é carregado inteiro na memória quando
/// qualquer chave do domínio é lida. Fica no mesmo lugar das reuniões (`MeetingSessionStore`),
/// só que num arquivo único — aqui são dezenas de conversas de texto, não sessões com áudio.
final class ChatHistoryStore {
    private let sync: SyncLibraryPersistence?
    private var baseline: [ChatSession] = []
    private var readable = true
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL

    init(fileManager: FileManager = .default, sync: SyncLibraryPersistence? = nil, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.sync = sync ?? (directoryURL == nil ? SyncLibraryRuntime.shared.persistence : nil)

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = self.sync?.context.rootURL.appendingPathComponent("Chat", isDirectory: true) ?? directoryURL
            ?? (SyncLibraryRuntime.shared.context?.rootURL ?? appSupport.appendingPathComponent("Voiz", isDirectory: true)).appendingPathComponent("Chat", isDirectory: true)
        self.fileURL = self.directoryURL.appendingPathComponent("sessions.json")

        ensureDirectory()
    }

    func load() -> [ChatSession] {
        do {
            let all = try read()
            baseline = try all.filter { value in try sync?.index.isVisible(type: .conversation, id: value.id) ?? true }
            readable = true
            return baseline
        } catch { readable = false; return baseline }
    }

    @discardableResult
    func save(_ sessions: [ChatSession]) -> Bool {
        guard readable else { return false }
        do {
            // A second window may have saved since load. Apply this window's delta only.
            let changed = sessions.filter { value in baseline.first(where: { $0.id == value.id }) != value }
            let removed = baseline.filter { old in !sessions.contains(where: { $0.id == old.id }) }.map(\.id)
            var latest = try read()
            latest.removeAll { removed.contains($0.id) }
            var mergedChanges: [ChatSession] = []
            for value in changed {
                let merged = try merge(value, base: baseline.first { $0.id == value.id }, disk: latest.first { $0.id == value.id })
                latest.removeAll { $0.id == value.id }
                latest.append(merged)
                mergedChanges.append(merged)
            }
            if let sync { try sync.saveChats(latest, changed: mergedChanges, removed: removed) }
            else {
                ensureDirectory()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try DurableLocalFile.write(encoder.encode(latest), to: fileURL, fileManager: fileManager)
            }
            baseline = sessions
            return true
        } catch { return false }
    }
    private enum SaveError: Error { case concurrentEdit }

    /// Preserve independent edits in other windows. A divergent change to the same field
    /// fails visibly instead of replacing data that this window has never displayed.
    private func merge(_ local: ChatSession, base: ChatSession?, disk: ChatSession?) throws -> ChatSession {
        guard let base else {
            guard disk == nil || disk == local else { throw SaveError.concurrentEdit }
            return local
        }
        guard var disk else { throw SaveError.concurrentEdit }
        if local.title != base.title {
            guard disk.title == base.title || disk.title == local.title else { throw SaveError.concurrentEdit }
            disk.title = local.title
        }
        if local.isPinned != base.isPinned {
            guard disk.isPinned == base.isPinned || disk.isPinned == local.isPinned else { throw SaveError.concurrentEdit }
            disk.isPinned = local.isPinned
        }
        let localIDs = Set(local.messages.map(\.id))
        for old in base.messages where !localIDs.contains(old.id) {
            if let current = disk.messages.first(where: { $0.id == old.id }), current != old { throw SaveError.concurrentEdit }
            disk.messages.removeAll { $0.id == old.id }
        }
        for message in local.messages {
            let old = base.messages.first { $0.id == message.id }
            guard old != message else { continue }
            if let index = disk.messages.firstIndex(where: { $0.id == message.id }) {
                guard disk.messages[index] == old || disk.messages[index] == message else { throw SaveError.concurrentEdit }
                disk.messages[index] = message
            } else {
                guard old == nil else { throw SaveError.concurrentEdit }
                disk.messages.append(message)
            }
        }
        disk.updatedAt = max(disk.updatedAt, local.updatedAt)
        return disk
    }

    private func read() throws -> [ChatSession] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ChatSession].self, from: Data(contentsOf: fileURL))
    }

    // MARK: - Modelo escolhido no seletor do Chat

    /// Vai para o `UserDefaults`, e não para o `AppSettings`: é preferência de uma tela, não
    /// configuração do app — gravar junto mudaria também o modelo das reuniões e da tradução.
    private let modelChoiceKey = "chatModelChoice"

    func loadModelChoice() -> AppSettings.ModelChoice? {
        guard let data = UserDefaults.standard.data(forKey: modelChoiceKey) else { return nil }
        return try? JSONDecoder().decode(AppSettings.ModelChoice.self, from: data)
    }

    func saveModelChoice(_ choice: AppSettings.ModelChoice?) {
        guard let choice else {
            UserDefaults.standard.removeObject(forKey: modelChoiceKey)
            return
        }
        if let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: modelChoiceKey)
        }
    }

    private func ensureDirectory() {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
