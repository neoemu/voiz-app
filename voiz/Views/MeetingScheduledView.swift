import SwiftUI

/// Shared by Home and Meetings so both entry points have the same click and hover behavior.
struct MeetingCalendarEventRow: View {
    let event: CalendarEvent
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(verbatim: "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(VoizTheme.mutedText)
                    .frame(width: 112, alignment: .leading)
                RoundedRectangle(cornerRadius: 2)
                    .fill(event.color?.swiftUIColor ?? VoizTheme.accent)
                    .frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VoizTheme.primaryText).lineLimit(2)
                    if !event.sourceLabel.isEmpty {
                        Text(event.sourceLabel).font(.caption)
                            .foregroundStyle(VoizTheme.mutedText).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if event.hasVideoLink {
                    Image(systemName: "video").foregroundStyle(VoizTheme.mutedText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? VoizTheme.primaryText : VoizTheme.mutedText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? VoizTheme.primaryText.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Abrir reunião")
    }
}

struct MeetingScheduledView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @ObservedObject private var workspace = MeetingWorkspaceStore.shared
    @StateObject private var model: ScheduledMeetingModel
    let event: CalendarEvent
    @State private var companionTab = 0
    @State private var question = ""
    @State private var showPreparation = false

    init(event: CalendarEvent) {
        self.event = event
        _model = StateObject(wrappedValue: ScheduledMeetingModel(eventID: event.id))
    }

    private var currentEvent: CalendarEvent {
        viewModel.upcomingEvents.first { $0.id == event.id } ?? event
    }

    private var preparation: MeetingPreparation? { workspace.preparations[event.id] }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 20) {
                header
                let layout = geometry.size.width < 760
                    ? AnyLayout(VStackLayout(spacing: 16))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                layout {
                    notes
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    companion
                        .frame(maxWidth: geometry.size.width < 760 ? .infinity : 380, maxHeight: .infinity)
                }
                Button { companionTab = 1 } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(VoizTheme.accent)
                        scheduleLabel
                        Image(systemName: "chevron.up").font(.caption)
                    }
                }
                .buttonStyle(GranolaPillButtonStyle())
                .help("Abrir transcrição")
            }
            .padding(28)
            .frame(maxWidth: 1_180)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                navigation.calendarEvent = nil
            } label: { Label("Reuniões", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(VoizTheme.mutedText)
            Text(currentEvent.title).font(.system(size: 32, design: .serif))
                .foregroundStyle(VoizTheme.primaryText).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { eventDate; source }
                VStack(alignment: .leading, spacing: 6) { eventDate; source }
            }
            .font(.subheadline).foregroundStyle(VoizTheme.mutedText)
        }
    }

    private var eventDate: some View {
        Label {
            Text(verbatim: "\(currentEvent.startDate.formatted(date: .abbreviated, time: .shortened)) – \(currentEvent.endDate.formatted(date: .omitted, time: .shortened))")
        } icon: { Image(systemName: "calendar") }
    }

    private var source: some View {
        HStack(spacing: 6) {
            Circle().fill(currentEvent.color?.swiftUIColor ?? VoizTheme.accent).frame(width: 6, height: 6)
            Text(currentEvent.sourceLabel)
        }
    }

    private var notes: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Notas").font(.headline)
                        Spacer()
                    }
                    ZStack(alignment: .topLeading) {
                        if model.draft.notes.isEmpty {
                            Text("Anote a pauta e o que você quer discutir…")
                                .foregroundStyle(VoizTheme.mutedText).padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $model.draft.notes)
                            .font(.system(size: 15)).scrollContentBackground(.hidden)
                            .frame(minHeight: 200).accessibilityLabel("Notas da reunião")
                            .disabled(viewModel.isStartingMeeting)
                    }
                    Divider()
                    MeetingPreparationSection(event: currentEvent, model: model, isExpanded: $showPreparation)
                        .id("meeting-preparation")
                }
                .padding(20)
            }
            .onChange(of: showPreparation) { _, expanded in
                if expanded {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("meeting-preparation", anchor: .top) }
                }
            }
            .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var companion: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Consulta", selection: $companionTab) {
                Text("Chat").tag(0)
                Text("Transcrição").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if companionTab == 0 { chat } else { transcript }
        }
        .padding(18)
        .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 14))
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.draft.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.title2)
                                Text("Prepare a conversa").font(.headline)
                                Text("Pergunte sobre a pauta ou retome reuniões anteriores.")
                                    .font(.subheadline).foregroundStyle(VoizTheme.mutedText)
                            }.padding(.vertical, 20)
                        }
                        ForEach(model.draft.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == .user ? String(localized: "Você") : "Voiz")
                                    .font(.caption.weight(.semibold)).foregroundStyle(VoizTheme.mutedText)
                                MeetingLinkedText(text: message.content,
                                    allowedSessionIDs: Set(message.sourceSessionIDs ?? preparation?.selectedSessionIDs ?? []))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.running { ProgressView().controlSize(.small) }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                }
                .onChange(of: model.draft.messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !model.running, let pending = model.draft.messages.last, pending.role == .user {
                Button("Tentar novamente") {
                    model.ask(pending.content, event: currentEvent, sessions: viewModel.sessions)
                }.buttonStyle(GranolaPillButtonStyle())
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Pergunte sobre esta reunião…", text: $question, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).onSubmit(ask)
                Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(VoizTheme.accent)
                    .disabled(model.running || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Enviar")
            }
            .padding(12)
            .background(VoizTheme.appBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(VoizTheme.mutedText)
                Text("A gravação ainda não começou.").font(.headline)
                Text("Inicie quando estiver pronto.").font(.subheadline).foregroundStyle(VoizTheme.mutedText)
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Spacer()
            Divider()
            scheduleLabel.font(.subheadline)
            if case .error(let message) = viewModel.state {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if viewModel.activeSession != nil {
                Text("Há outra gravação em andamento.").font(.caption).foregroundStyle(VoizTheme.mutedText)
            }
            Button {
                Task {
                    if await viewModel.recordCalendarEvent(currentEvent), navigation.calendarEvent?.id == event.id {
                        navigation.calendarEvent = nil
                    }
                }
            } label: {
                HStack {
                    if viewModel.isStartingMeeting { ProgressView().controlSize(.small) }
                    Label("Iniciar agora", systemImage: "record.circle")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(GranolaPillButtonStyle(accented: true))
            .disabled(!viewModel.canStartMeeting)
        }
    }

    private var scheduleLabel: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if currentEvent.startDate > context.date {
                Text("Começa às \(currentEvent.startDate.formatted(date: .omitted, time: .shortened))")
            } else if currentEvent.endDate > context.date {
                Text("Em andamento na agenda")
            } else {
                Text("Horário da reunião encerrado")
            }
        }
    }

    private func ask() {
        guard !model.running, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submitted = question
        // Consume the composer before publishing model changes or another submit callback.
        question = ""
        model.ask(submitted, event: currentEvent, sessions: viewModel.sessions)
    }
}
