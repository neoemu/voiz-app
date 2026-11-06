import SwiftUI
import AppKit

/// Ações marcadas com "Acompanhar" nas reuniões. Abre pelo card de hoje da Home, como tela de
/// detalhe. Sem busca nem filtros de propósito: para cortar por responsável ou período existe o
/// comando /pendencias no chat, e o que a pessoa quer aqui é ver o que ainda não caiu.
struct HomeTrackedActionsView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let onBack: () -> Void
    @State private var editing: MeetingTaskReference?
    @State private var source: MeetingSession?

    /// Pendentes primeiro, concluídas depois, numa lista só. Duas `ForEach` (uma por grupo) faziam
    /// a ação concluída "pular" de grupo sem a linha se redesenhar: o círculo continuava vazio até
    /// sair e voltar da tela.
    private var tasks: [MeetingTaskReference] {
        let all = MeetingProductivity.tasks(in: viewModel.sessions)
        return all.filter { !$0.item.done } + all.filter { $0.item.done }
    }
    private var firstDoneID: String? { tasks.first { $0.item.done }?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VoizBackButton(title: "Início", action: onBack)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text("Em acompanhamento")
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundColor(VoizTheme.primaryText)
            }

            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("Você escolhe o que acompanhar", systemImage: "bookmark")
                } description: {
                    Text("Marque ações com Acompanhar nas reuniões.")
                } actions: {
                    Button("Ver reuniões") {
                        NotificationCenter.default.post(name: Notification.Name("VoizOpenMeetingsTab"), object: nil)
                    }.buttonStyle(GranolaPillButtonStyle(accented: true))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(tasks) { task in
                        if task.id == firstDoneID {
                            Text("Concluídas")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(VoizTheme.mutedText)
                                .textCase(.uppercase)
                                .padding(.top, task.id == tasks.first?.id ? 0 : 12)
                        }
                        row(task)
                            .opacity(task.item.done ? 0.6 : 1)
                    }
                }
            }
        }
        .sheet(item: $editing) { task in
            MeetingTaskEditor(task: task) { item in
                viewModel.updateTask(item, sessionID: task.sessionID, sectionID: task.sectionID)
            }
        }
        .sheet(item: $source) { session in
            MeetingSourcePreview(session: viewModel.sessions.first { $0.id == session.id } ?? session)
                .environmentObject(viewModel)
        }
    }

    private func row(_ task: MeetingTaskReference) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MeetingActionItemRow(sessionId: task.sessionID, sectionId: task.sectionID, item: task.item)
            HStack {
                Button {
                    source = viewModel.sessions.first { $0.id == task.sessionID }
                } label: {
                    Label(task.sessionTitle, systemImage: "arrow.up.right.square")
                        .lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(VoizTheme.accent)
                Spacer()
                Text(task.meetingDate, style: .date).foregroundStyle(.secondary)
                // Concluída não se edita: reabra pelo círculo se precisar mexer.
                if !task.item.done {
                    Button("Editar") { editing = task }.buttonStyle(.plain)
                }
            }.font(.caption)
        }
        .padding(16)
        .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Edita uma ação acompanhada. O prazo vem da extração como frase ("até sexta"), porque é assim
/// que se fala em reunião; aqui a pessoa pode trocar por uma data de verdade, e a frase original
/// fica visível como referência. Guardar a data resolvida em campo próprio é o passo seguinte.
private struct MeetingTaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    let task: MeetingTaskReference
    let onSave: (MeetingActionItem) -> Void
    @State private var text = ""
    @State private var assignee = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @FocusState private var textFocused: Bool

    /// Formato em que a data escolhida é gravada no campo de texto do prazo, e reconhecida de
    /// volta ao reabrir. Curto e no idioma da interface, porque a linha da ação mostra o texto cru.
    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .voizInterface
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// Frase original da reunião, quando o prazo salvo não é uma data que o app gravou.
    private var spokenDue: String? {
        guard let due = task.item.dueDate, Self.dueFormatter.date(from: due) == nil else { return nil }
        return due
    }

    private var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Editar tarefa")
                    .font(.system(size: 21, weight: .regular, design: .serif))
                    .foregroundColor(VoizTheme.primaryText)

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Tarefa")
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(VoizTheme.primaryText)
                        .lineLimit(2...4)
                        .focused($textFocused)
                        .modifier(FieldBox())
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Responsável")
                    TextField("", text: $assignee, prompt: Text("Ex.: Matheus"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(VoizTheme.primaryText)
                        .modifier(FieldBox())
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Prazo")
                    HStack(spacing: 14) {
                        Toggle("Definir prazo", isOn: $hasDueDate.animation(.easeOut(duration: 0.15)))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 13))
                            .foregroundColor(VoizTheme.primaryText)
                        if hasDueDate {
                            DatePicker("", selection: $dueDate, displayedComponents: .date)
                                .datePickerStyle(.field)
                                .labelsHidden()
                        }
                        Spacer(minLength: 0)
                    }
                    if let spokenDue {
                        Text("Dito na reunião: \(spokenDue)")
                            .font(.system(size: 11.5))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                }
            }
            .padding(24)

            Rectangle()
                .fill(VoizTheme.border)
                .frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .buttonStyle(VoizPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .background(VoizTheme.appBackground)
        .onAppear {
            text = task.item.text
            assignee = task.item.assignee ?? ""
            if let due = task.item.dueDate, let date = Self.dueFormatter.date(from: due) {
                hasDueDate = true
                dueDate = date
            }
        }
    }

    private func save() {
        var item = task.item
        item.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        item.assignee = assignee.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if hasDueDate {
            item.dueDate = Self.dueFormatter.string(from: dueDate)
        } else {
            // Sem data escolhida, a frase da reunião continua valendo; só some se ela não existia.
            item.dueDate = spokenDue
        }
        onSave(item)
        dismiss()
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(VoizTheme.mutedText)
            .textCase(.uppercase)
    }

    private struct FieldBox: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(VoizTheme.surfaceBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct MeetingTodayCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @EnvironmentObject var navigation: VoizNavigation
    let onTasks: () -> Void
    private var pending: Int { MeetingProductivity.tasks(in: viewModel.sessions).filter { !$0.item.done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Hoje", systemImage: "sun.max").font(.headline)
                Spacer()
                Button(action: onTasks) {
                    if pending > 0 {
                        Label("\(pending) em acompanhamento", systemImage: "bookmark")
                    } else {
                        Label("Acompanhamento", systemImage: "bookmark")
                    }
                }.buttonStyle(GranolaPillButtonStyle())
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let events = CalendarEvent.remainingToday(in: viewModel.upcomingEvents, now: context.date)
                if events.isEmpty {
                    Text(viewModel.calendarAuthorized ? String(localized: "Nenhuma reunião restante hoje.") : String(localized: "Ative o calendário em Reuniões para preparar suas próximas conversas."))
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(events) { event in
                            MeetingCalendarEventRow(event: event) { navigation.open(event) }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 14))
        .task { viewModel.refreshCalendarSuggestion() }
    }
}

struct MeetingContextPicker: View {
    let sessions: [MeetingSession]
    let folders: [MeetingFolder]
    @Binding var selected: Set<UUID>
    @State private var query = ""
    @State private var folderID: UUID?
    private var filtered: [MeetingSession] {
        sessions.filter { (folderID == nil || $0.folderId == folderID) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Buscar reuniões…", text: $query).textFieldStyle(.roundedBorder)
                Picker("Pasta", selection: $folderID) {
                    Text("Todas").tag(UUID?.none)
                    ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 200)
            }
            Text("\(selected.count)/8 selecionadas").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filtered) { session in
                        Toggle(isOn: Binding(get: { selected.contains(session.id) }, set: { enabled in
                            if enabled { if selected.count < 8 { selected.insert(session.id) } }
                            else { selected.remove(session.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(session.title).lineLimit(1)
                                Text(session.formattedDate).font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled(!selected.contains(session.id) && selected.count >= 8)
                    }
                    if filtered.isEmpty { Text("Nenhuma reunião encontrada.").foregroundStyle(.secondary) }
                }
            }.frame(height: 160)
        }.padding(.top, 8)
    }
}

struct MeetingLinkedText: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let text: String
    var allowedSessionIDs: Set<UUID> = []
    @State private var source: MeetingSession?
    var body: some View {
        MarkdownText(markdown: text, font: .system(size: 14))
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "voiz-meeting", let host = url.host, let id = UUID(uuidString: host),
                      allowedSessionIDs.contains(id), let session = viewModel.sessions.first(where: { $0.id == id }) else { return .discarded }
                source = session
                return .handled
            })
            .sheet(item: $source) { MeetingSourcePreview(session: $0).environmentObject(viewModel) }
    }
}

struct MeetingSourcePreview: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var companionOverlay = MeetingReviewCompanionPresentation()
    let session: MeetingSession
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Reunião de origem").font(.headline)
                Spacer()
                if companionOverlay.hasReview {
                    MeetingReviewToolbar(presentation: companionOverlay)
                }
                Button("Concluir") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            MeetingReviewView(session: viewModel.sessions.first { $0.id == session.id } ?? session, onBack: { dismiss() })
                .environmentObject(viewModel)
                .environmentObject(companionOverlay)
                .environment(\.voizCompanionOverlayWindowHosted, false)
        }.frame(minWidth: 680, idealWidth: 820, minHeight: 600, idealHeight: 740)
    }
}

struct MeetingNotesUsageToggle: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Usar estas notas no resumo", isOn: Binding(get: { session.usesNotesInSummary }, set: {
                viewModel.setNotesIncluded($0, sessionID: session.id)
            })).toggleStyle(.checkbox).font(.caption)
            Text("Vale para o próximo resumo.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct MeetingRecipeMenu: View {
    @ObservedObject private var store = MeetingWorkspaceStore.shared
    let onSelect: (String) -> Void
    @State private var editing = false
    var body: some View {
        Menu {
            ForEach(store.recipes) { recipe in
                Button("/\(recipe.command) · \(recipe.title)") { onSelect("/" + recipe.command) }
            }
            Divider()
            Button("Editar comandos…") { editing = true }
        } label: { Label { Text("Comandos") } icon: { SlashCommandGlyph(size: 14) } }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $editing) { MeetingRecipeEditor() }
    }
}

struct MeetingLiveContextControl: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @State private var showing = false
    @State private var selected: Set<UUID> = []
    var body: some View {
        Button {
            selected = Set(viewModel.activeSession?.contextSessionIDs ?? [])
            showing = true
        } label: {
            Label("Contexto (\(viewModel.activeSession?.contextSessionIDs?.count ?? 0))", systemImage: "link")
        }
        .buttonStyle(.plain).font(.caption)
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Contexto de reuniões anteriores").font(.title2)
                MeetingContextPicker(sessions: viewModel.sessions.filter { $0.id != viewModel.activeSession?.id }, folders: viewModel.folders, selected: $selected)
                Text("O texto destas reuniões vai para o provedor de IA nas próximas perguntas.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancelar") { showing = false }
                    Spacer()
                    Button("Usar contexto") { viewModel.setContextSessions(selected); showing = false }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 570)
        }
    }
}

struct MeetingEvidenceLinks: View {
    let session: MeetingSession
    let section: MeetingSummarySection
    let itemIndex: Int
    var onRevealTurn: ((MeetingTurn) -> Void)?
    @State private var preview: MeetingTurn?
    private var turns: [MeetingTurn] {
        let ids = Set((section.evidence ?? []).filter { $0.itemIndex == itemIndex }.flatMap(\.turnIDs))
        return session.turns.filter { ids.contains($0.id) }
    }
    var body: some View {
        if !turns.isEmpty {
            HStack(spacing: 10) {
                ForEach(turns.prefix(4)) { turn in
                    Button {
                        if let onRevealTurn { onRevealTurn(turn) } else { preview = turn }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text(timeLabel(turn.startTime))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }.buttonStyle(.plain).foregroundStyle(VoizTheme.accent)
                        .help("Ir para a fala de origem")
                        .accessibilityLabel(Text("Ir para a fala de origem"))
                        .accessibilityValue(Text(timeLabel(turn.startTime)))
                }
            }
            .popover(item: $preview) { turn in
                VStack(alignment: .leading, spacing: 8) {
                    Text(turn.speakerName).font(.headline)
                    Text(turn.text).textSelection(.enabled)
                }.padding(18).frame(width: 360)
            }
        }
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
