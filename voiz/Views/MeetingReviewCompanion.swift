import AppKit
import SwiftUI

private struct VoizCompanionOverlayWindowHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var voizCompanionOverlayWindowHosted: Bool {
        get { self[VoizCompanionOverlayWindowHostedKey.self] }
        set { self[VoizCompanionOverlayWindowHostedKey.self] = newValue }
    }
}

enum MeetingReviewCompanionChrome {
    case inline
    case overlay
    case windowOverlay
}

/// Compact, fixed-position controls shared by the window title bar and source previews.
struct MeetingReviewToolbar: View {
    @ObservedObject var presentation: MeetingReviewCompanionPresentation

    var body: some View {
        HStack(spacing: 6) {
            MeetingReviewToolbarButton(symbol: "doc.text", title: "Transcrição", selected: presentation.tab == 1) {
                presentation.toggle(tab: 1)
            }
            MeetingReviewToolbarButton(symbol: "sparkles", title: "Perguntar à IA", selected: presentation.tab == 2) {
                presentation.toggle(tab: 2)
            }
        }
    }
}

private struct MeetingReviewToolbarButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? VoizTheme.accentBright : VoizTheme.mutedText)
                .frame(width: 30, height: VoizWindowChrome.titleBarHeight)
                .background(selected ? VoizTheme.accent.opacity(0.15)
                            : (hovering ? VoizTheme.hoverBackground : .clear), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? VoizTheme.accent.opacity(0.25) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MeetingReviewCompanion: View {
    @ObservedObject private var workspace = MeetingWorkspaceStore.shared
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    let player: MeetingAudioPlayer
    @Binding var tab: Int
    var chrome: MeetingReviewCompanionChrome = .inline
    @State private var query = ""
    @State private var question = ""
    @State private var answer = ""
    @State private var error: String?
    @State private var running = false
    @State private var request: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Consulta", selection: $tab) {
                Text("Transcrição").tag(1)
                Text("Perguntar").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            if tab == 1 {
                TextField("Buscar na transcrição…", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(session.turns.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.speakerName.localizedCaseInsensitiveContains(query) }) { turn in
                            VStack(alignment: .leading, spacing: 4) {
                                Button {
                                    if player.isAvailable { player.playFrom(turn.startTime) }
                                } label: {
                                    Text("\(String(format: "%02d:%02d", Int(max(0, turn.startTime)) / 60, Int(max(0, turn.startTime)) % 60)) · \(turn.speakerName)")
                                        .font(.caption).foregroundStyle(VoizTheme.accent)
                                }.buttonStyle(.plain).disabled(!player.isAvailable)
                                Text(turn.text).font(.system(size: 13)).textSelection(.enabled)
                            }
                            Divider()
                        }
                    }
                }
            } else {
                Text("Pergunte sobre esta reunião.").font(.caption).foregroundStyle(.secondary)
                MeetingRecipeMenu { question = $0 }
                ScrollView {
                    if answer.isEmpty && !running {
                        Text("Quais decisões foram tomadas? O que ficou pendente?").foregroundStyle(.secondary).padding(.vertical, 20)
                    } else {
                        MeetingLinkedText(text: answer, allowedSessionIDs: [session.id])
                    }
                }
                if running { ProgressView().controlSize(.small) }
                if let error { Text(error).foregroundStyle(.orange).font(.caption) }
                HStack(alignment: .bottom) {
                    TextField("Pergunte…", text: $question, axis: .vertical).lineLimit(1...4)
                        .textFieldStyle(.roundedBorder).onSubmit(ask)
                    Button(action: ask) { Image(systemName: "arrow.up.circle.fill") }
                        .disabled(running || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, chrome == .windowOverlay ? VoizWindowChrome.sidebarContentTopInset : 16)
        .frame(maxHeight: .infinity)
        .background(chrome == .inline ? VoizTheme.surfaceBackground : VoizTheme.sidebarBackground)
        .onAppear {
            if let saved = workspace.assistantAnswers["meeting/" + session.id.uuidString + "/review"] {
                answer = saved.text; question = saved.question
            }
        }
        .onDisappear { cancelRequest() }
        .onChange(of: session.id) { _, _ in cancelRequest(); answer = ""; question = ""; error = nil }
    }

    private func cancelRequest() {
        request?.cancel()
        request = nil
        requestID = nil
        running = false
    }

    private func ask() {
        guard !running, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID()
        let target = session
        let submittedQuestion = question
        requestID = token
        running = true
        error = nil
        request = Task { @MainActor in
            defer {
                if requestID == token { running = false; request = nil; requestID = nil }
            }
            guard !Task.isCancelled, requestID == token else { return }
            guard await VoizAccessStore.shared.authorizeNewOperation(kind: .ai, workID: token) else {
                if !Task.isCancelled, requestID == token {
                    error = VoizAccessStore.shared.lastError ?? VoizAccessMessages.libraryUnavailable
                }
                return
            }
            guard !Task.isCancelled, requestID == token, session.id == target.id else { return }
            let workActivity = VoizWorkTracker.shared.beginActivity()
            defer { workActivity.finish() }
            let settings: AppSettings
            do {
                settings = try await SettingsStore().settingsForAIUse()
            } catch {
                if !Task.isCancelled, requestID == token, session.id == target.id {
                    self.error = SettingsCredentialError.unavailable.localizedDescription
                }
                return
            }
            guard !Task.isCancelled, requestID == token, session.id == target.id else { return }
            let prompt = MeetingAIRecipe.expanded(submittedQuestion, recipes: workspace.recipes)
            let service = MeetingLiveAssistService(settings: settings)
            let context = MeetingProductivity.context(sessions: [target], selectedIDs: [target.id])
            answer = ""
            do {
                for try await delta in service.respondStream(action: nil, question: prompt, transcript: target.transcriptText, context: context) {
                    try Task.checkCancellation()
                    guard requestID == token, session.id == target.id else { return }
                    answer += delta
                }
                guard workspace.saveAssistantAnswer(scope: "meeting/" + target.id.uuidString + "/review", question: submittedQuestion, text: answer) else { throw CocoaError(.fileWriteUnknown) }
            } catch {
                if !Task.isCancelled, requestID == token { self.error = error.localizedDescription }
            }
        }
    }
}

struct MeetingReviewCompanionDrawer: View {
    let session: MeetingSession
    let player: MeetingAudioPlayer
    @ObservedObject var presentation: MeetingReviewCompanionPresentation
    var chrome: MeetingReviewCompanionChrome = .overlay
    var dimsBackground: Bool = true
    private var width: CGFloat { presentation.overlayWidth }

    var body: some View {
        // Keep the companion at the same position in the view tree across size changes so a
        // draft question, transcript search and in-flight answer survive docking/undocking.
        ZStack(alignment: .trailing) {
            if dimsBackground {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { presentation.closePanel() }
                    .accessibilityLabel(Text("Recolher painel"))
                    .accessibilityAddTraits(.isButton)
            }
            panel
                .shadow(color: .black.opacity(dimsBackground ? 0.22 : 0), radius: 18, x: -8)
        }
        .frame(maxWidth: dimsBackground ? .infinity : width, maxHeight: .infinity)
        .transition(.opacity)
    }

    private var panel: some View {
        MeetingReviewCompanion(session: session, player: player, tab: presentation.tabBinding, chrome: chrome)
            .id(session.id)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(VoizTheme.sidebarBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(VoizTheme.sidebarHairline)
                    .frame(width: 1)
            }
            .overlay(alignment: .leading) {
                MeetingCompanionResizeHandle(presentation: presentation)
            }
    }
}

private struct MeetingCompanionResizeHandle: View {
    @ObservedObject var presentation: MeetingReviewCompanionPresentation
    @State private var startWidth: CGFloat?
    @State private var hovering = false
    @State private var cursorPushed = false
    @State private var visible = false
    @GestureState private var dragging = false

    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 2)
                .fill(hovering || dragging ? VoizTheme.accent.opacity(0.75) : .clear)
                .frame(width: 2, height: 42)
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear { visible = true }
        .onHover { hovering = $0; updateCursor() }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    if startWidth == nil { startWidth = presentation.overlayWidth }
                    // The right edge stays fixed: dragging left makes the panel wider.
                    presentation.resize(to: (startWidth ?? presentation.overlayWidth) - value.translation.width)
                    updateCursor()
                }
                .onEnded { _ in finishResize() }
        )
        .onChange(of: dragging) { _, active in
            if !active { finishResize() }
        }
        .onDisappear {
            visible = false
            finishResize()
            if cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .help("Arraste para redimensionar")
        .accessibilityElement()
        .accessibilityLabel("Largura do painel")
        .accessibilityValue(Text("\(Int(presentation.overlayWidth)) pontos"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: presentation.resize(to: presentation.overlayWidth + 20)
            case .decrement: presentation.resize(to: presentation.overlayWidth - 20)
            @unknown default: return
            }
            presentation.saveWidth()
        }
    }

    private func finishResize() {
        if startWidth != nil { presentation.saveWidth(); startWidth = nil }
        updateCursor()
    }

    private func updateCursor() {
        let active = visible && (hovering || dragging || startWidth != nil)
        if active && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        else if !active && cursorPushed { NSCursor.pop(); cursorPushed = false }
    }
}
