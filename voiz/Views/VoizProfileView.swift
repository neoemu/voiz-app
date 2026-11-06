import SwiftUI
import AppKit

/// Local identity and explicit selection of isolated libraries.
struct VoizProfileView: View {
    @Environment(\.voizCompactLayout) private var compactLayout
    @ObservedObject private var profileStore: UserProfileStore
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isHoveringName = false
    @FocusState private var nameFocused: Bool

    init(profileStore: UserProfileStore? = nil) {
        let resolvedStore = profileStore ?? .shared
        self.profileStore = resolvedStore
        _name = State(initialValue: resolvedStore.profile.displayName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                LocalLibrarySettingsView()
                Spacer(minLength: 40)
            }
            .foregroundStyle(VoizTheme.primaryText)
            .frame(maxWidth: 680)
            .padding(.horizontal, compactLayout ? 24 : 56)
            .padding(.top, 36)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: name) { _, _ in errorMessage = nil }
        .onChange(of: profileStore.profile.displayName) { oldName, newName in
            // Preserve an unsaved draft if another window updates the shared profile.
            if name == oldName { name = newName }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            VoizProfileAvatar(name: profileStore.profile.displayName)
            TextField("Seu nome", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(nameFocused ? VoizTheme.elevatedBackground : isHoveringName ? VoizTheme.hoverBackground : .clear)
                )
                .frame(maxWidth: 360)
                .onHover { isHoveringName = $0 }
                .accessibilityLabel(Text("Nome"))
                .onSubmit(save)
                .onExitCommand(perform: revert)
                .onChange(of: nameFocused) { _, focused in if !focused { save() } }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Text("Este perfil fica somente neste Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(VoizTheme.mutedText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        guard name != profileStore.profile.displayName else { return }
        do {
            try profileStore.updateName(name)
            name = profileStore.profile.displayName
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revert() {
        name = profileStore.profile.displayName
        errorMessage = nil
        nameFocused = false
    }
}

private struct LocalLibrarySettingsView: View {
    @ObservedObject private var library = LocalLibraryRuntime.shared
    @State private var showsHistory = false
    @State private var isExporting = false
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(title: "Bibliotecas neste Mac") {
                ForEach(Array(library.availableLibraries.enumerated()), id: \.element.libraryID) { index, item in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(icon: "folder", title: Text(verbatim: label(item)),
                                subtitle: Text(verbatim: item.rootURL.path)) {
                        if library.context?.libraryID == item.libraryID {
                            Text("Em uso").font(.caption).foregroundStyle(VoizTheme.mutedText)
                        } else {
                            Button("Abrir") { Task { await library.selectLibrary(id: item.libraryID) } }
                                .buttonStyle(GranolaPillButtonStyle())
                                .disabled(isExporting)
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(icon: "folder.badge.plus", title: "Biblioteca local independente") {
                    Button("Abrir ou criar") { Task { await library.selectLocalLibrary() } }
                        .buttonStyle(GranolaPillButtonStyle())
                        .disabled(isExporting)
                }
                if library.persistence != nil {
                    SettingsDivider()
                    SettingsRow(icon: "trash", title: "Lixeira e conflitos") {
                        Button("Consultar…") { showsHistory = true }
                            .buttonStyle(GranolaPillButtonStyle())
                    }
                    SettingsDivider()
                    SettingsRow(icon: "square.and.arrow.up", title: "Exportar textos disponíveis neste Mac") {
                        Button("Exportar…", action: exportTexts)
                            .buttonStyle(GranolaPillButtonStyle())
                            .disabled(isExporting)
                    }
                }
            }
            Text("As bibliotecas permanecem separadas. Aguarde a gravação, o processamento ou a edição terminar antes de trocar.")
                .font(.system(size: 12)).foregroundStyle(VoizTheme.mutedText)
            if library.context?.ownerAccountID != nil {
                Text("Esta biblioteca contém o que já foi baixado de uma conta anterior. Conteúdo que só existe na nuvem deve ser exportado pelo app anterior antes do encerramento do serviço. Áudios e versões locais permanecem neste Mac.")
                    .font(.system(size: 12)).foregroundStyle(VoizTheme.mutedText)
            }
            if let message = library.lastError ?? exportMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(VoizTheme.mutedText)
                    .textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showsHistory) { LocalLibraryDataView() }
    }

    private func label(_ item: SyncLibraryContext) -> String {
        let prefix = item.ownerAccountID == nil
            ? String(localized: "Biblioteca local") : String(localized: "Biblioteca de conta anterior")
        return prefix + " · " + String(item.libraryID.uuidString.prefix(8))
    }

    private func exportTexts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let scope = destination.startAccessingSecurityScopedResource()
        let output = destination.appendingPathComponent("Voiz-export-" + UUID().uuidString, isDirectory: true)
        isExporting = true
        exportMessage = nil
        Task { @MainActor in
            defer {
                isExporting = false
                if scope { destination.stopAccessingSecurityScopedResource() }
            }
            do {
                let count = try await library.exportDownloadedTexts(to: output)
                exportMessage = String(localized: "Textos exportados: \(count)")
            } catch {
                exportMessage = String(localized: "Não foi possível concluir a exportação. Os arquivos originais foram preservados.")
            }
        }
    }
}
