#if DEBUG
import AppKit
import SwiftUI

/// UI mínima DEBUG do runner de benchmark. Strings sem i18n de propósito (DEBUG-only).
struct BenchmarkView: View {
    @State private var corpusURL: URL?
    @State private var outputURL: URL?
    @State private var selected: Set<String> = [
        BenchmarkEngineTarget.whisperKitSmall.slug,
        BenchmarkEngineTarget.applePTBR.slug,
    ]
    @State private var logLines: [String] = []
    @State private var isRunning = false
    @State private var progressFraction: Double = 0
    @State private var runner: BenchmarkRunner?

    private let targets = BenchmarkEngineTarget.allSelectable

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription Benchmark (DEBUG)")
                .font(.title2.weight(.semibold))

            Text("STRICT · 2 warm-ups · métricas sem transcript · hipóteses só no mock_map · sandbox via bookmark")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Pastas") {
                VStack(alignment: .leading, spacing: 8) {
                    pathRow(
                        title: "Corpus (manifesto JSONL + WAVs)",
                        url: corpusURL,
                        action: pickCorpus
                    )
                    pathRow(
                        title: "Saída (JSONL + hipóteses)",
                        url: outputURL,
                        action: pickOutput
                    )
                }
                .padding(4)
            }

            GroupBox("Motores (STRICT — sem fallback)") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading) {
                    ForEach(targets) { target in
                        Toggle(isOn: Binding(
                            get: { selected.contains(target.slug) },
                            set: { on in
                                if on { selected.insert(target.slug) }
                                else { selected.remove(target.slug) }
                            }
                        )) {
                            Text(target.displayName)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(4)
            }

            HStack {
                Button(isRunning ? "Rodando…" : "Rodar benchmark") {
                    Task { await run() }
                }
                .disabled(isRunning || corpusURL == nil || outputURL == nil || selected.isEmpty)
                .keyboardShortcut(.defaultAction)

                if isRunning {
                    Button("Cancelar") {
                        Task { await runner?.cancel() }
                    }
                }

                Spacer()
                ProgressView(value: progressFraction)
                    .frame(width: 160)
            }

            GroupBox("Log (sem transcript)") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 320)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            if corpusURL == nil { corpusURL = BenchmarkSecurityScopedBookmarks.loadCorpus() }
            if outputURL == nil { outputURL = BenchmarkSecurityScopedBookmarks.loadOutput() }
            let commit = BenchmarkHardwareInfo.resolveAppCommit(override: nil)
            appendLog("app_commit resolvido: \(commit)")
        }
    }

    private func pathRow(title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(url?.path ?? "— não selecionado —")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Escolher…", action: action)
        }
    }

    private func pickCorpus() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Selecione a pasta raiz do corpus (com manifests/ e audio/)"
        panel.prompt = "Usar corpus"
        if panel.runModal() == .OK, let url = panel.url {
            corpusURL = url
            BenchmarkSecurityScopedBookmarks.saveCorpus(url)
            appendLog("Corpus (bookmark gravado): \(url.path)")
        }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Selecione a pasta de saída dos JSONL / hipóteses"
        panel.prompt = "Usar pasta"
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
            BenchmarkSecurityScopedBookmarks.saveOutput(url)
            appendLog("Saída (bookmark gravado): \(url.path)")
        }
    }

    @MainActor
    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    @MainActor
    private func run() async {
        guard let corpusURL, let outputURL else { return }
        let chosen = targets.filter { selected.contains($0.slug) }
        guard !chosen.isEmpty else { return }

        isRunning = true
        progressFraction = 0
        let commit = BenchmarkHardwareInfo.resolveAppCommit(override: nil)
        appendLog("Início — \(chosen.map(\.slug).joined(separator: ", ")) commit=\(commit)")

        let localRunner = BenchmarkRunner()
        runner = localRunner

        do {
            let urls = try await BenchmarkSecurityScopedBookmarks.withAccess(
                to: [corpusURL, outputURL]
            ) {
                try await localRunner.run(
                    corpusRoot: corpusURL,
                    outputDirectory: outputURL,
                    targets: chosen,
                    commitOverride: commit == "unknown" ? nil : commit,
                    onProgress: { progress in
                        Task { @MainActor in
                            appendLog(progress.message)
                            if let f = progress.fraction {
                                progressFraction = min(1, max(0, f))
                            }
                        }
                    }
                )
            }
            for url in urls {
                appendLog("arquivo: \(url.lastPathComponent)")
            }
        } catch {
            appendLog("FALHA: \(error.localizedDescription)")
        }

        isRunning = false
        runner = nil
    }
}

/// Menu DEBUG (strings sem i18n — ferramenta de medição).
struct BenchmarkDebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Diagnóstico Sync…") {
                let alert = NSAlert()
                alert.messageText = "Diagnóstico Sync (Dev)"
                do {
                    alert.informativeText = try SyncLibraryRuntime.shared.context?.journal?.pendingWorkDiagnostic() ?? "Sem biblioteca Sync aberta."
                    if alert.informativeText.isEmpty { alert.informativeText = "Nenhuma operação local pendente." }
                } catch { alert.informativeText = "Não foi possível ler os metadados da fila." }
                alert.addButton(withTitle: "Fechar")
                alert.runModal()
            }
            Button("Transcription Benchmark…") {
                openWindow(id: BenchmarkDebugSupport.windowID)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }
}

/// Âncora mínima do modo headless: sem ContentView, sem view models, sem Accessibility.
/// O runner em si é agendado em `VoizApp.init` (não aqui) — View.task pode não rodar se a
/// janela CLI nunca for apresentada.
struct BenchmarkHeadlessAnchorView: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
    }
}

/// Janela / CLI headless do benchmark DEBUG.
@MainActor
enum BenchmarkDebugSupport {
    static let windowID = "debug-transcription-benchmark"

    /// True quando o processo deve pular a stack interativa do app.
    static var isHeadlessMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--voiz-bench-run")
    }

    /// Executa o runner com resolução de bookmark/container; encerra se `--voiz-bench-exit`.
    static func runHeadlessIfConfigured() async {
        guard let config = BenchmarkCLIConfig.parse(
            arguments: ProcessInfo.processInfo.arguments
        ) else { return }

        let targets = config.resolvedTargets()
        guard !targets.isEmpty else {
            fputs("[bench] nenhum motor válido em --voiz-bench-engines\n", stderr)
            if config.shouldExit { exit(2) }
            return
        }

        let corpusURL: URL
        let outputURL: URL
        do {
            let pair = try BenchmarkSecurityScopedBookmarks.resolvePair(
                corpusFlag: config.corpusPath,
                outputFlag: config.outputPath
            )
            corpusURL = pair.corpus
            outputURL = pair.output
        } catch {
            fputs("[bench] FAIL path: \(error.localizedDescription)\n", stderr)
            if config.shouldExit { exit(2) }
            return
        }

        fputs(
            "[bench] headless corpus=\(corpusURL.path) out=\(outputURL.path) engines=\(targets.map(\.slug).joined(separator: ","))\n",
            stderr
        )

        let runner = BenchmarkRunner()
        do {
            let urls = try await BenchmarkSecurityScopedBookmarks.withAccess(
                to: [corpusURL, outputURL]
            ) {
                try await runner.run(
                    corpusRoot: corpusURL,
                    outputDirectory: outputURL,
                    targets: targets,
                    commitOverride: config.commitOverride,
                    onProgress: { p in
                        fputs("[bench] \(p.message)\n", stderr)
                    }
                )
            }
            for url in urls {
                fputs("[bench] wrote \(url.path)\n", stderr)
            }
            fputs("[bench] DONE\n", stderr)
            if config.shouldExit { exit(0) }
        } catch {
            fputs("[bench] FAIL \(error.localizedDescription)\n", stderr)
            if config.shouldExit { exit(1) }
        }
    }
}
#endif
