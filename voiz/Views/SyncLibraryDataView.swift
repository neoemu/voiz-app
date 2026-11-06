import SwiftUI
import AppKit

struct LocalLibraryDataView: View {
    @ObservedObject private var library = LocalLibraryRuntime.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SyncLocalEntity] = []
    @State private var conflicts: [SyncLocalConflict] = []
    @State private var moreTrash = false
    @State private var moreConflicts = false
    @State private var lastTrashKey = ""
    @State private var lastConflictKey = ""
    @State private var itemToPurge: SyncLocalEntity?
    @State private var error: String?
    @State private var busy = false
    @State private var showResolvedConflicts = false
    @State private var conflictToResolve: SyncLocalConflict?
    @State private var resolutionChoice: SyncConflictResolutionChoice = .keepLocal

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Lixeira e conflitos").font(.system(size: 20, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    trashSection
                    conflictsSection
                }
            }
            .disabled(busy)
            if let error = error ?? library.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 360, idealHeight: 460)
        .background(VoizTheme.appBackground)
        .foregroundStyle(VoizTheme.primaryText)
        .task { reload() }
        .onChange(of: library.revision) { _, _ in reload() }
        .onChange(of: showResolvedConflicts) { _, _ in reload() }
        .confirmationDialog("Resolver este conflito?", isPresented: Binding(
            get: { conflictToResolve != nil }, set: { if !$0 { conflictToResolve = nil } }
        ), titleVisibility: .visible) {
            Button(resolutionChoice == .keepLocal ? "Restaurar a versão preservada" : "Usar a versão atual") {
                if let conflict = conflictToResolve {
                    let choice = resolutionChoice
                    Task { busy = true; await library.resolveConflict(conflict, choice: choice); busy = false; reload() }
                }
                conflictToResolve = nil
            }
            Button("Cancelar", role: .cancel) { conflictToResolve = nil }
        } message: { Text("A escolha altera apenas esta biblioteca local. As versões preservadas continuam disponíveis para exportação.") }
        .onReceive(NotificationCenter.default.publisher(for: .voizSyncRemoteApplied)) { _ in reload() }
        .alert("Apagar este texto definitivamente?", isPresented: Binding(
            get: { itemToPurge != nil }, set: { if !$0 { itemToPurge = nil } }
        )) {
            Button("Cancelar", role: .cancel) { itemToPurge = nil }
            Button("Apagar definitivamente", role: .destructive) {
                if let item = itemToPurge {
                    Task { busy = true; await library.purgeFromTrash(item); busy = false; reload() }
                }
                itemToPurge = nil
            }
        } message: { Text("Ele será removido desta biblioteca local. Os áudios deste Mac não são afetados.") }
    }

    private var trashSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(title: "Lixeira") {
                if items.isEmpty {
                    SettingsRow(icon: "trash", title: "A lixeira está vazia") { EmptyView() }
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(icon: icon(item.document.entityType), title: Text(verbatim: title(item.document)),
                                subtitle: Text(verbatim: typeLabel(item.document.entityType))) {
                        HStack(spacing: 6) {
                            Button("Restaurar") {
                                Task { busy = true; await library.restoreFromTrash(item); busy = false; reload() }
                            }
                            .buttonStyle(GranolaPillButtonStyle())
                            Button("Apagar…", role: .destructive) { itemToPurge = item }
                                .buttonStyle(GranolaPillButtonStyle(destructive: true))
                        }
                    }
                }
                if moreTrash {
                    SettingsDivider()
                    Button("Carregar mais") { loadTrash() }
                        .buttonStyle(GranolaPillButtonStyle())
                        .padding(12)
                }
            }
            Text("Os textos na lixeira ficam disponíveis para consulta e restauração neste Mac.")
                .font(.system(size: 12))
                .foregroundStyle(VoizTheme.mutedText)
                .padding(.horizontal, 4)
        }
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(title: "Conflitos") {
                if conflicts.isEmpty {
                    SettingsRow(icon: "checkmark.circle", title: "Nenhum conflito") { EmptyView() }
                }
                ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 { SettingsDivider() }
                    conflictRow(conflict)
                }
                if moreConflicts {
                    SettingsDivider()
                    Button("Carregar mais") { loadConflicts() }
                        .buttonStyle(GranolaPillButtonStyle())
                        .padding(12)
                }
            }
            Toggle("Mostrar conflitos resolvidos", isOn: $showResolvedConflicts)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.horizontal, 4)
        }
    }

    private func conflictRow(_ conflict: SyncLocalConflict) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                version(Text("Versão preservada"), preview(conflict.document))
                if let current = try? library.persistence?.index.entity(type: conflict.document.entityType, id: conflict.document.entityID) {
                    version(Text("Versão atual"), current.visibility == .visible
                            ? preview(current.document) : String(localized: "Removido do histórico ativo."))
                }
                HStack(spacing: 8) {
                    Button("Exportar…") { export(conflict.document) }
                        .buttonStyle(GranolaPillButtonStyle())
                    Spacer()
                    if !showResolvedConflicts {
                        Button("Restaurar a preservada…") { resolutionChoice = .keepLocal; conflictToResolve = conflict }
                            .buttonStyle(GranolaPillButtonStyle())
                        Button("Usar a atual…") { resolutionChoice = .keepRemote; conflictToResolve = conflict }
                            .buttonStyle(GranolaPillButtonStyle())
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(conflict.document.entityType))
                    .foregroundStyle(VoizTheme.mutedText)
                    .frame(width: 18)
                Text(verbatim: title(conflict.document))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func version(_ label: Text, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VoizTheme.mutedText)
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding(12)
        .background(VoizTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private func reload() {
        items = []; conflicts = []; lastTrashKey = ""; lastConflictKey = ""; error = nil
        loadTrash(); loadConflicts()
    }
    private func loadTrash() {
        do {
            let page = try library.persistence?.index.page(visibility: .trashed, after: lastTrashKey) ?? []
            items += page
            moreTrash = page.count == 100
            lastTrashKey = page.last?.id ?? lastTrashKey
        } catch { self.error = String(localized: "Não foi possível ler a lixeira. Os arquivos foram preservados.") }
    }
    private func loadConflicts() {
        do {
            let page = try library.persistence?.index.conflictPage(after: lastConflictKey, includeResolved: showResolvedConflicts) ?? []
            conflicts += page
            moreConflicts = page.count == 100
            lastConflictKey = page.last?.id ?? lastConflictKey
        } catch { self.error = String(localized: "Não foi possível ler os conflitos. Os arquivos foram preservados.") }
    }
    private func title(_ document: SyncDocument) -> String {
        let fields = document.value.object ?? [:]
        let candidate = ["title", "name", "text", "translated_text", "source_text", "content"].compactMap { fields[$0]?.string }.first { !$0.isEmpty }
        return candidate.map { String($0.prefix(100)) } ?? String(localized: "Texto da biblioteca")
    }
    private func preview(_ document: SyncDocument) -> String {
        let fields = document.value.object ?? [:]
        switch document.entityType {
        case .transcript:
            guard case .array(let turns) = fields["turns"] else { return "" }
            return turns.map { value in
                let turn = value.object ?? [:]
                return (turn["speaker_name"]?.string ?? "") + ": " + (turn["text"]?.string ?? "")
            }.joined(separator: "\n\n")
        case .summary:
            guard case .array(let sections) = fields["sections"] else { return title(document) }
            return sections.map { value in
                let section = value.object ?? [:]
                var parts = [section["title"]?.string, section["paragraph"]?.string].compactMap { $0 }
                if case .array(let bullets) = section["bullets"] { parts += bullets.compactMap(\.string) }
                if case .array(let actions) = section["action_items"] { parts += actions.compactMap { $0.object?["text"]?.string } }
                return parts.joined(separator: "\n")
            }.joined(separator: "\n\n")
        default:
            let values = ["title", "name", "details", "notes", "text", "source_text", "translated_text", "content"]
                .compactMap { fields[$0]?.string }.filter { !$0.isEmpty }
            return values.isEmpty ? String(localized: "Esta versão pode ser exportada para consulta.") : values.joined(separator: "\n\n")
        }
    }
    private func typeLabel(_ type: SyncEntityType) -> String {
        switch type {
        case .meeting: return String(localized: "Reunião")
        case .transcript: return String(localized: "Transcrição")
        case .summary: return String(localized: "Resumo")
        case .conversation: return String(localized: "Conversa")
        case .message: return String(localized: "Mensagem")
        case .dictation: return String(localized: "Ditado")
        case .translation: return String(localized: "Tradução")
        case .folder: return String(localized: "Pasta")
        case .note: return String(localized: "Nota")
        case .preferences: return String(localized: "Preferências")
        }
    }
    private func icon(_ type: SyncEntityType) -> String {
        switch type {
        case .meeting: return "person.2"
        case .transcript: return "text.alignleft"
        case .summary: return "doc.text"
        case .conversation: return "bubble.left.and.bubble.right"
        case .message: return "bubble.left"
        case .dictation: return "mic"
        case .translation: return "globe"
        case .folder: return "folder"
        case .note: return "note.text"
        case .preferences: return "gearshape"
        }
    }
    private func export(_ document: SyncDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voiz-versao-" + document.entityID + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do { try document.canonicalData().write(to: url, options: .atomic) }
        catch { self.error = String(localized: "Não foi possível exportar esta versão. O original foi preservado.") }
    }
}
