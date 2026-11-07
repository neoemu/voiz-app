import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Entrada da importação nas Configurações. Biblioteca arquivada ou de outra conta não recebe nada.
struct GranolaImportSettingsGroup: View {
    let store: MeetingSessionStore
    @ObservedObject private var library = SyncLibraryRuntime.shared
    @State private var isPresented = false

    var body: some View {
        SettingsGroup(title: "Importar") {
            SettingsRow(
                icon: "square.and.arrow.down",
                title: "Importar do Granola",
                subtitle: library.canStartNewWorkInLibrary
                    ? "Resumos, transcrições e pastas da sua conta."
                    : "Esta biblioteca é somente leitura. Troque de biblioteca em Perfil."
            ) {
                Button("Importar…") { isPresented = true }
                    .buttonStyle(GranolaPillButtonStyle())
                    .disabled(!library.canStartNewWorkInLibrary)
            }
        }
        .sheet(isPresented: $isPresented) {
            GranolaImportSheet(store: store) { isPresented = false }
        }
    }
}

struct GranolaImportSheet: View {
    @StateObject private var importer: GranolaImporter
    @FocusState private var keyFocused: Bool
    let onClose: () -> Void

    init(store: MeetingSessionStore, onClose: @escaping () -> Void) {
        _importer = StateObject(wrappedValue: GranolaImporter(store: store))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
                Text("Importar do Granola")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
            }
            content
        }
        .padding(24)
        .frame(width: 440)
        .background(VoizTheme.surfaceBackground)
        .interactiveDismissDisabled(isBusy)
        .onDisappear { importer.cancel() }
    }

    private var isBusy: Bool {
        if case .importing = importer.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch importer.phase {
        case .choosingSource:
            sourceChoice
        case .enteringKey(let error):
            keyEntry(error: error)
        case .choosingFile(let error):
            fileChoice(error: error)
        case .checking:
            progressRow { Text("Conectando…") }
            footer { closeButton("Cancelar") }
        case .ready(let plan):
            review(plan)
        case .importing(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(VoizTheme.accent)
            caption(Text("Importando \(done) de \(total)"))
            footer {
                Button("Parar") { importer.cancel() }
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        case .finished(let outcome):
            result(outcome)
        }
    }

    private var sourceChoice: some View {
        Group {
            VStack(spacing: 8) {
                sourceRow(icon: "key", title: "Com chave de API",
                          subtitle: "Business e Enterprise. Traz horários e falantes.") { importer.chooseAPIKey() }
                sourceRow(icon: "doc.text", title: "Com arquivo CSV",
                          subtitle: "Todos os planos, inclusive o gratuito.") { importer.chooseFile() }
            }
            footer { closeButton("Cancelar") }
        }
    }

    private func sourceRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(VoizTheme.primaryText)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(VoizTheme.mutedText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoizTheme.elevatedBackground)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileChoice(error: String?) -> some View {
        Group {
            caption(Text("No Granola: Settings › Profile › Generate CSV. O arquivo chega por e-mail em algumas horas."))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
            footer {
                Button("Voltar") { importer.backToSources() }
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Escolher arquivo…", action: pickFile)
                    .buttonStyle(VoizPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importer.open(fileAt: url)
        }
    }

    private func keyEntry(error: String?) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Chave de API", text: $importer.apiKey, prompt: Text(verbatim: "grn_…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(VoizTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(VoizTheme.elevatedBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(keyFocused ? VoizTheme.accent.opacity(0.6) : VoizTheme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($keyFocused)
                    .onSubmit { importer.connect() }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            caption(Text("No Granola: Settings › Connectors › API keys. Requer plano Business ou Enterprise. A chave não fica salva."))
            footer {
                Button("Voltar") { importer.backToSources() }
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Continuar") { importer.connect() }
                    .buttonStyle(VoizPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!importer.canConnect)
                    .opacity(importer.canConnect ? 1 : 0.5)
            }
        }
        // Vindo da escolha da rota, o foco só pega depois que a troca de tela assenta.
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            keyFocused = true
        }
    }

    private func review(_ plan: GranolaImportPlan) -> some View {
        Group {
            VStack(spacing: 8) {
                factRow("Novas", value: "\(plan.pending.count)")
                if plan.alreadyInLibrary > 0 {
                    factRow("Já no Voiz", value: "\(plan.alreadyInLibrary)")
                }
                if let oldest = plan.oldest, let newest = plan.newest {
                    factRow("Período", value: "\(dateText(oldest)) – \(dateText(newest))")
                }
            }
            if plan.pending.isEmpty {
                caption(Text("Nada novo para importar."))
            } else {
                HStack {
                    Text("Pastas").foregroundColor(VoizTheme.mutedText)
                    Spacer()
                    Picker("Pastas", selection: $importer.folderPlacement) {
                        Text("Manter as do Granola").tag(GranolaFolderPlacement.keepGranolaFolders)
                        Text("Tudo em uma pasta Granola").tag(GranolaFolderPlacement.singleFolder)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .font(.system(size: 13))
                caption(Text("O Granola não guarda áudio e só entrega reuniões com resumo."))
                if plan.lacksTranscripts {
                    caption(Text("Este arquivo não traz transcrições, só os resumos."))
                }
            }
            footer {
                closeButton(plan.pending.isEmpty ? "Fechar" : "Cancelar")
                if !plan.pending.isEmpty {
                    Button("Importar \(plan.pending.count)") { importer.startImport() }
                        .buttonStyle(VoizPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func result(_ outcome: GranolaImportOutcome) -> some View {
        Group {
            Label(outcome.isComplete ? "Importação concluída" : "Importação interrompida",
                  systemImage: outcome.isComplete ? "checkmark.circle" : "pause.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(VoizTheme.primaryText)
            VStack(spacing: 8) {
                factRow("Importadas", value: "\(outcome.imported)")
                if outcome.failed > 0 {
                    factRow("Com falha", value: "\(outcome.failed)")
                }
            }
            if let reason = outcome.stopReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
            if !outcome.isComplete || outcome.failed > 0 {
                caption(Text("Importe de novo para continuar. O que já entrou não se repete."))
            }
            footer { closeButton("Fechar") }
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(.voizInterface))
    }

    private func factRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title).foregroundColor(VoizTheme.mutedText)
            Spacer()
            Text(verbatim: value).foregroundColor(VoizTheme.primaryText).monospacedDigit()
        }
        .font(.system(size: 13))
    }

    private func progressRow<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            label().font(.system(size: 13)).foregroundColor(VoizTheme.mutedText)
        }
    }

    private func caption(_ text: Text) -> some View {
        text.font(.system(size: 12))
            .foregroundColor(VoizTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func closeButton(_ title: LocalizedStringKey) -> some View {
        Button(title, action: onClose)
            .buttonStyle(GranolaPillButtonStyle())
            .keyboardShortcut(.cancelAction)
    }

    private func footer<Buttons: View>(@ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Spacer()
            buttons()
        }
    }
}
