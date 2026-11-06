import SwiftUI
import AVFoundation
import Combine

private enum VoizMainWindowLayout {
    /// A navegação recolhe na janela estreita; o conteúdo usa a largura disponível.
    static let minimumWidth: CGFloat = 640
    static let minimumHeight: CGFloat = 560
}

@main
struct VoizApp: App {
    @NSApplicationDelegateAdaptor(VoizApplicationDelegate.self) private var applicationDelegate
    #if DEBUG
    /// Modo CLI do runner T3.2: não sobe ContentView / TranscriptionViewModel / Accessibility.
    private static let isBenchmarkHeadless =
        ProcessInfo.processInfo.arguments.contains("--voiz-bench-run") || DictationProbe.isRequested

    /// Sonda de cadência da tradução: mesma ideia do modo CLI acima — sem UI, para medir o custo
    /// de um trecho sem a tela nem os aquecimentos dos outros view models no meio.
    private static let isTranslationProbeHeadless =
        TranslationCadenceProbeOptions.parse() != nil

    /// Sonda de streaming do SpeechAnalyzer (spike modo leve): headless como as demais.
    private static let isStreamProbeHeadless =
        AppleSpeechStreamingProbe.isRequested

    /// Sonda headless da PRÉVIA da reunião: roda o serviço real com áudio de arquivo.
    private static let isPreviewProbeHeadless = PreviewProbeOptions.isRequested

    /// Sonda headless do motor Apple streaming do modo Granola — não sobe a UI nem os view models.
    private static let isGranolaProbeHeadless =
        GranolaProbeOptions.parse() != nil

    #endif

    // One shared runtime for every window, created only after the local profile is ready.
    @StateObject private var transcriptionViewModelHolder: OptionalTranscriptionViewModel

    init() {
        #if DEBUG
        if DictationProbe.isRequested {
            _transcriptionViewModelHolder = StateObject(wrappedValue: OptionalTranscriptionViewModel(create: false))
            DispatchQueue.main.async { Task { @MainActor in await DictationProbe.run() } }
            return
        }
        if Self.isBenchmarkHeadless {
            _transcriptionViewModelHolder = StateObject(
                wrappedValue: OptionalTranscriptionViewModel(create: false)
            )
            fputs("[bench] headless mode: UI stack suppressed\n", stderr)
            // Não depende de View.task (janela pode não aparecer em CLI).
            DispatchQueue.main.async {
                Task { @MainActor in
                    await BenchmarkDebugSupport.runHeadlessIfConfigured()
                }
            }
            return
        }
        if Self.isPreviewProbeHeadless {
            _transcriptionViewModelHolder = StateObject(
                wrappedValue: OptionalTranscriptionViewModel(create: false)
            )
            fputs("[preview-probe] headless mode: UI stack suppressed\n", stderr)
            DispatchQueue.main.async {
                Task { @MainActor in await PreviewProbe.runIfRequested() }
            }
            return
        }
        if Self.isTranslationProbeHeadless {
            _transcriptionViewModelHolder = StateObject(
                wrappedValue: OptionalTranscriptionViewModel(create: false)
            )
            fputs("[sonda-cadência] headless mode: UI stack suppressed\n", stderr)
            DispatchQueue.main.async {
                TranslationCadenceProbe.runIfRequested()
            }
            return
        }
        if Self.isStreamProbeHeadless {
            _transcriptionViewModelHolder = StateObject(
                wrappedValue: OptionalTranscriptionViewModel(create: false)
            )
            DispatchQueue.main.async {
                AppleSpeechStreamingProbe.runIfRequested()
            }
            return
        }
        if Self.isGranolaProbeHeadless {
            _transcriptionViewModelHolder = StateObject(
                wrappedValue: OptionalTranscriptionViewModel(create: false)
            )
            fputs("[sonda-granola] headless mode: UI stack suppressed\n", stderr)
            DispatchQueue.main.async {
                GranolaProbe.runIfRequested()
            }
            return
        }
        #endif
        _transcriptionViewModelHolder = StateObject(
            wrappedValue: OptionalTranscriptionViewModel(create: false)
        )
        print("🚀 VoizApp init started")
    }

    var body: some Scene {
        #if DEBUG
        debugScenes
        #else
        WindowGroup {
            VoizRootView(runtime: transcriptionViewModelHolder)
                .frame(
                    minWidth: VoizMainWindowLayout.minimumWidth,
                    minHeight: VoizMainWindowLayout.minimumHeight
                )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            HotKeyCommands()
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }

            CommandGroup(after: .appSettings) {
                Button("Configurações…") {
                    NotificationCenter.default.post(name: Notification.Name("OpenVoizSettings"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // O ⌘K em si é registrado na `ContentView`, para funcionar com o foco em qualquer
            // campo; aqui a busca ganha um item de menu descobrível.
            CommandGroup(after: .toolbar) {
                Button("Buscar…") {
                    NotificationCenter.default.post(name: Notification.Name("VoizOpenSearch"), object: nil)
                }
            }
        }

        Window("Atalho do teclado", id: "hotkey-config") {
            if let viewModel = transcriptionViewModelHolder.wrapped {
                HotKeyConfigView()
                    .environmentObject(viewModel)
            }
        }
        .windowResizability(.contentSize)
        #endif
    }

    #if DEBUG
    @SceneBuilder
    private var debugScenes: some Scene {
        WindowGroup {
            if Self.isBenchmarkHeadless || Self.isStreamProbeHeadless {
                BenchmarkHeadlessAnchorView()
                    .frame(width: 1, height: 1)
            } else if !Self.isGranolaProbeHeadless,
                      !Self.isPreviewProbeHeadless,
                      !Self.isTranslationProbeHeadless {
                VoizRootView(runtime: transcriptionViewModelHolder)
                    .frame(
                        minWidth: VoizMainWindowLayout.minimumWidth,
                        minHeight: VoizMainWindowLayout.minimumHeight
                    )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            if !Self.isBenchmarkHeadless && !Self.isGranolaProbeHeadless {
                CommandGroup(replacing: .newItem) {}
                HotKeyCommands()
                CommandGroup(after: .appInfo) { CheckForUpdatesButton() }

                CommandGroup(after: .appSettings) {
                    Button("Configurações…") {
                        NotificationCenter.default.post(
                            name: Notification.Name("OpenVoizSettings"),
                            object: nil
                        )
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }

                CommandGroup(after: .toolbar) {
                    Button("Buscar…") {
                        NotificationCenter.default.post(
                            name: Notification.Name("VoizOpenSearch"),
                            object: nil
                        )
                    }
                }

                BenchmarkDebugCommands()
            }
        }

        Window("Atalho do teclado", id: "hotkey-config") {
            if !Self.isBenchmarkHeadless,
               !Self.isGranolaProbeHeadless,
               let vm = transcriptionViewModelHolder.wrapped {
                HotKeyConfigView()
                    .environmentObject(vm)
            }
        }
        .windowResizability(.contentSize)

        Window("Transcription Benchmark (DEBUG)", id: BenchmarkDebugSupport.windowID) {
            if !Self.isBenchmarkHeadless && !Self.isGranolaProbeHeadless {
                BenchmarkView()
            }
        }
        .defaultSize(width: 720, height: 640)
    }
    #endif
}

/// Keeps engines, hotkeys and permission prompts out of onboarding and DEBUG headless runs.
@MainActor
final class OptionalTranscriptionViewModel: ObservableObject {
    @Published private(set) var wrapped: TranscriptionViewModel?
    private let activityID = UUID()
    private var libraryRevision: UUID?

    init(create: Bool) {
        wrapped = create ? TranscriptionViewModel() : nil
        observeDevelopmentActivity()
    }

    func activate(libraryRevision: UUID? = nil) {
        guard wrapped == nil || self.libraryRevision != libraryRevision else { return }
        guard !VoizWorkTracker.shared.hasActiveWork else { return }
        self.libraryRevision = libraryRevision
        wrapped = TranscriptionViewModel()
        observeDevelopmentActivity()
    }

    private func observeDevelopmentActivity() {
        guard AppEnvironment.current.isDevelopment, let wrapped else { return }
        VoizDevelopmentLifecycle.shared.registerActivity(id: activityID) { [weak wrapped] in
            guard let wrapped else { return nil }
            return wrapped.state == .listening || wrapped.state == .processing || wrapped.processingEntryID != nil
        }
    }
}

private struct VoizRootView: View {
    @ObservedObject var runtime: OptionalTranscriptionViewModel
    @ObservedObject private var profileStore = UserProfileStore.shared
    @ObservedObject private var localLibrary = LocalLibraryRuntime.shared

    var body: some View {
        Group {
            if profileStore.needsOnboarding {
                VoizOnboardingView(profileStore: profileStore)
            } else if let viewModel = runtime.wrapped {
                ContentView()
                    .id(localLibrary.revision)
                    .environmentObject(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(VoizTheme.appBackground)
            }
        }
        .environment(\.locale, .voizInterface)
        .safeAreaInset(edge: .top, spacing: 0) {
            // ContentView owns its title bar; introduction/loading need their own unobscured strip.
            if AppEnvironment.current.isDevelopment && (profileStore.needsOnboarding || runtime.wrapped == nil) {
                HStack {
                    Spacer()
                    DevelopmentBuildBadge()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(VoizTheme.appBackground)
            }
        }
        .task(id: profileStore.needsOnboarding) {
            guard !profileStore.needsOnboarding else { return }
            localLibrary.start()
            runtime.activate(libraryRevision: localLibrary.revision)
        }
        .onChange(of: localLibrary.revision) { _, revision in
            runtime.activate(libraryRevision: revision)
        }
    }
}

/// The development CLI requests a normal macOS quit. Active work must explicitly finish first.
@MainActor
final class VoizApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppEnvironment.current.isDevelopment, VoizDevelopmentLifecycle.shared.hasActiveWork {
            if sender.modalWindow == nil {
                let alert = NSAlert()
                alert.messageText = String(localized: "Voiz Dev está em uso.")
                alert.informativeText = String(localized: "Conclua a gravação, o processamento ou a resposta de IA antes de encerrar.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
            }
            return .terminateCancel
        }
        return .terminateNow
    }
}
