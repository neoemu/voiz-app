import SwiftUI
import AppKit

struct HotKeyRecorder: View {
    @Binding var shortcut: KeyboardShortcut

    @State private var isRecording = false
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    @State private var errorMessage: String?
    /// Maior conjunto de modificadores/Fn visto durante a gravação (pra commitar "Fn sozinho" no release).
    @State private var pendingFlags: NSEvent.ModifierFlags = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggleRecording) {
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "dot.radiowaves.left.and.right" : "keyboard")
                        .foregroundColor(isRecording ? .red : .accentColor)
                    if isRecording {
                        Text("Pressione o atalho…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        chips
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isRecording ? Color.accentColor.opacity(0.1) : Color.clear)
                        )
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Text(hintText)
                .font(.caption)
                .foregroundColor(errorMessage == nil ? .secondary : .red)
        }
        .onDisappear {
            stopRecording()
        }
    }

    /// Renderiza o atalho como "chips" (ex.: fn · Space), estilo Wispr.
    private var chips: some View {
        HStack(spacing: 4) {
            let parts = shortcut.chips
            if parts.isEmpty {
                Text("—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
            }
        }
    }

    /// A mensagem de erro já vem resolvida do gravador; a dica é literal e localiza pela chave.
    private var hintText: LocalizedStringKey {
        if let errorMessage { return LocalizedStringKey(errorMessage) }
        return "Clique e pressione o atalho (Fn/🌐, ⌘, ⌥, ⌃, ⇧ ou um combo)."
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        errorMessage = nil
        pendingFlags = []

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event: event)
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event: event)
        }
    }

    private func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        isRecording = false
        pendingFlags = []
    }

    private func handle(event: NSEvent) {
        guard isRecording else { return }

        switch event.type {
        case .keyDown:
            if event.isARepeat { return }
            guard let newShortcut = KeyboardShortcut(event: event) else {
                // Tecla pura sem Fn/modificador — não serve como atalho global.
                DispatchQueue.main.async {
                    self.errorMessage = String(localized: "Use Fn ou pelo menos um modificador (⌘, ⌥, ⌃, ⇧).")
                }
                NSSound.beep()
                return
            }
            commit(newShortcut)

        case .flagsChanged:
            let current = relevantFlags(event.modifierFlags)
            if current.isEmpty {
                // Tudo solto: commita o que foi segurado (ex.: Fn sozinho), se houver.
                commitPendingFlagsIfAny()
            } else {
                pendingFlags.formUnion(current)
            }

        default:
            break
        }
    }

    private func commitPendingFlagsIfAny() {
        let usesFn = pendingFlags.contains(.function)
        let carbon = pendingFlags.intersection(.deviceIndependentFlagsMask).carbonFlags
        pendingFlags = []
        guard usesFn || carbon != 0 else { return }
        commit(KeyboardShortcut(
            keyCode: KeyboardShortcut.noKeyCode,
            modifiers: carbon,
            keyDisplay: "",
            usesFn: usesFn
        ))
    }

    private func commit(_ newShortcut: KeyboardShortcut) {
        DispatchQueue.main.async {
            self.shortcut = newShortcut
            self.stopRecording()
        }
    }

    /// Só os bits que nos interessam: ⌘⌥⌃⇧ + Fn.
    private func relevantFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var result = flags.intersection([.command, .option, .control, .shift])
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}
