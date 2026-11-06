import AppKit
import SwiftUI

/// Context selection and briefing live inside the notes pane; the chat remains available beside it.
struct MeetingPreparationSection: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @ObservedObject private var workspace = MeetingWorkspaceStore.shared
    @ObservedObject var model: ScheduledMeetingModel
    @StateObject private var preparationModel = MeetingPreparationModel()
    let event: CalendarEvent
    @Binding var isExpanded: Bool
    @State private var query = ""
    @State private var folderID: UUID?

    init(event: CalendarEvent, model: ScheduledMeetingModel, isExpanded: Binding<Bool>) {
        self.event = event
        self.model = model
        _isExpanded = isExpanded
    }

    private var selected: Set<UUID> { model.selectedSessionIDs }
    private var preparation: MeetingPreparation? { workspace.preparations[event.id] }
    private var hasBriefing: Bool { preparation?.text.isEmpty == false }
    private var stale: Bool { hasBriefing && Set(preparation?.selectedSessionIDs ?? []) != selected }
    private var selectedSessions: [MeetingSession] {
        viewModel.sessions.filter { selected.contains($0.id) }.sorted { $0.startedAt > $1.startedAt }
    }
    private var filtered: [MeetingSession] {
        viewModel.sessions.filter {
            (folderID == nil || $0.folderId == folderID)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Label("Preparação", systemImage: "sparkles").font(.headline)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? String(localized: "Concluir seleção")
                             : (selected.isEmpty ? String(localized: "Adicionar contexto") : String(localized: "Editar contexto")))
                        Image(systemName: isExpanded ? "chevron.up" : "plus").font(.caption)
                    }
                }.buttonStyle(GranolaPillButtonStyle()).disabled(preparationModel.running)
            }
            if selected.isEmpty {
                Text("Adicione reuniões anteriores como contexto.")
                    .font(.subheadline).foregroundStyle(VoizTheme.mutedText)
            } else {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(selectedSessions) { session in
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text").foregroundStyle(VoizTheme.accent)
                            Text(session.title).lineLimit(1).frame(maxWidth: 200)
                            Button { toggle(session.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            }.buttonStyle(.plain).help("Remover do contexto")
                                .accessibilityLabel("Remover do contexto")
                                .disabled(preparationModel.running)
                        }
                        .font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(VoizTheme.accent.opacity(0.09), in: Capsule())
                        .overlay(Capsule().stroke(VoizTheme.accent.opacity(0.18)))
                    }
                }
            }
            if isExpanded { sourcePicker }
            if !selected.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        preparationModel.generate(event: event, sessions: viewModel.sessions, selectedIDs: selected,
                                                  notes: model.draft.notes)
                    } label: {
                        Label(hasBriefing ? String(localized: "Atualizar preparação") : String(localized: "Gerar preparação"),
                              systemImage: "sparkles")
                    }
                    .buttonStyle(GranolaPillButtonStyle(accented: true))
                    .disabled(preparationModel.running)
                    if preparationModel.running { ProgressView().controlSize(.small) }
                }
            }
            if let error = preparationModel.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let preparation, !preparation.text.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Pontos principais").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(preparation.text, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(VoizTheme.mutedText)
                            .help("Copiar").accessibilityLabel("Copiar")
                    }
                    if stale {
                        Label("Contexto alterado. Atualize a preparação.", systemImage: "arrow.clockwise")
                            .font(.caption).foregroundStyle(VoizTheme.mutedText)
                    }
                    MeetingLinkedText(text: preparation.text, allowedSessionIDs: Set(preparation.selectedSessionIDs))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VoizTheme.appBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: preparationModel.running) { wasRunning, running in
            if wasRunning, !running, preparationModel.error == nil, hasBriefing {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded = false }
            }
        }
        .onChange(of: viewModel.sessions.map(\.id), initial: true) { _, ids in
            let available = selected.intersection(Set(ids))
            if available != selected { model.setContext(available) }
        }
        .onDisappear { preparationModel.cancel() }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { search; folders }
                VStack(alignment: .leading, spacing: 10) { search; folders }
            }
            HStack {
                Text("Reuniões de contexto").font(.caption.weight(.medium))
                Spacer()
                Text("\(selected.count)/8 selecionadas").font(.caption.monospacedDigit())
            }.foregroundStyle(VoizTheme.mutedText)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filtered) { session in
                        MeetingContextSelectionRow(session: session, selected: selected.contains(session.id),
                            folder: viewModel.folders.first { $0.id == session.folderId }?.name) {
                            toggle(session.id)
                        }
                        .disabled(!selected.contains(session.id) && selected.count >= 8)
                    }
                    if filtered.isEmpty {
                        Text("Nenhuma reunião encontrada.").font(.subheadline)
                            .foregroundStyle(VoizTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                    }
                }
            }
            .frame(height: min(CGFloat(max(filtered.count, 1)) * 65, 260))
        }
        .padding(14)
        .background(VoizTheme.appBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .disabled(preparationModel.running)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VoizTheme.mutedText)
            TextField("Buscar reuniões…", text: $query).textFieldStyle(.plain)
        }
        .font(.subheadline).padding(10)
        .frame(minWidth: 140)
        .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var folders: some View {
        Menu {
            Button("Todas as pastas") { folderID = nil }
            ForEach(viewModel.folders) { folder in
                Button(folder.name) { folderID = folder.id }
            }
        } label: {
            Label(viewModel.folders.first { $0.id == folderID }?.name ?? String(localized: "Todas as pastas"), systemImage: "folder")
                .font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 180, alignment: .leading)
    }

    private func toggle(_ id: UUID) {
        var ids = selected
        if ids.contains(id) { ids.remove(id) }
        else if ids.count < 8 { ids.insert(id) }
        model.setContext(ids)
    }
}

private struct MeetingContextSelectionRow: View {
    let session: MeetingSession
    let selected: Bool
    let folder: String?
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).foregroundStyle(selected ? VoizTheme.accent : VoizTheme.mutedText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.subheadline).foregroundStyle(VoizTheme.primaryText).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        if let folder { Label(folder, systemImage: "folder") }
                    }.font(.caption).foregroundStyle(VoizTheme.mutedText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? VoizTheme.accent.opacity(0.09)
                        : (hovering ? VoizTheme.hoverBackground : .clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
