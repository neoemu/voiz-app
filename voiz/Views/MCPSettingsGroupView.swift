import AppKit
import SwiftUI

/// Configuração do endpoint local no mesmo vocabulário visual das demais preferências do Voiz.
struct MCPSettingsGroupView: View {
    @ObservedObject private var server = LocalMCPServer.shared
    @State private var copiedTarget: CopyTarget?
    @State private var isConfirmingRevocation = false

    var body: some View {
        SettingsGroup(title: "MCP local") {
            SettingsRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Servidor MCP",
                subtitle: "Permite que apps de IA leiam suas reuniões e notas. Ditados e áudio ficam de fora."
            ) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(VoizTheme.accent)
                    .accessibilityLabel("Ativar servidor MCP local")
            }

            if server.isEnabled {
                SettingsDivider()
                statusStrip

                SettingsDivider()
                endpointBlock

                SettingsDivider()
                clientRow(
                    target: .claude,
                    icon: "sparkles",
                    title: "Claude Code",
                    subtitle: "Copia o comando de instalação.",
                    accessibilityLabel: "Copiar configuração do Claude Code",
                    value: { server.claudeCodeConfiguration }
                )

                SettingsDivider()
                clientRow(
                    target: .other,
                    icon: "link",
                    title: "Outros apps",
                    subtitle: "Copia a URL e o token de acesso.",
                    accessibilityLabel: "Copiar configuração para outros apps",
                    value: { server.genericConfiguration }
                )

                SettingsDivider()
                SettingsRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Revogar conexões copiadas",
                    subtitle: "Gera um token novo. Os apps conectados precisarão reconfigurar."
                ) {
                    Button("Revogar") {
                        isConfirmingRevocation = true
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                    .disabled(server.status != .running)
                    .accessibilityLabel("Revogar conexões MCP copiadas")
                }

                privacyNotice
            }
        }
        .confirmationDialog(
            "Revogar todas as conexões copiadas?",
            isPresented: $isConfirmingRevocation,
            titleVisibility: .visible
        ) {
            Button("Revogar conexões", role: .destructive) {
                server.rotateCredential()
                copiedTarget = nil
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Os clientes atuais param de funcionar imediatamente e precisarão de uma configuração nova.")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: { server.setEnabled($0) }
        )
    }

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
                if let detail = statusDetail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(VoizTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if case .failed = server.status {
                Button("Tentar novamente") { server.retry() }
                    .buttonStyle(GranolaPillButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.leading, 48)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch server.status {
        case .starting:
            ProgressView().controlSize(.small)
        case .running:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        case .waitingForMeetingStore:
            Image(systemName: "clock.fill").foregroundColor(.orange)
        case .disabled:
            Image(systemName: "circle").foregroundColor(VoizTheme.mutedText)
        }
    }

    private var statusTitle: String {
        switch server.status {
        case .disabled: return String(localized: "Desativado")
        case .waitingForMeetingStore: return String(localized: "Aguardando o Voiz ficar pronto")
        case .starting: return String(localized: "Iniciando…")
        case .running: return String(localized: "Ativo somente neste Mac")
        case .failed: return String(localized: "Não foi possível iniciar")
        }
    }

    private var statusDetail: String? {
        switch server.status {
        case .running:
            if let date = server.lastRequestAt {
                return String(localized: "Último acesso: \(date.formatted(date: .omitted, time: .shortened))")
            }
            return nil
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .failed: return .red
        case .waitingForMeetingStore: return .orange
        default: return VoizTheme.mutedText
        }
    }

    private var endpointBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Endpoint local")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(VoizTheme.primaryText)

            HStack(spacing: 10) {
                Text(server.connectionURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(VoizTheme.primaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    copy(server.connectionURL, target: .endpoint)
                } label: {
                    Label(
                        copiedTarget == .endpoint ? "Copiado" : "Copiar URL",
                        systemImage: copiedTarget == .endpoint ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(GranolaPillButtonStyle())
                .disabled(server.status != .running)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(VoizTheme.elevatedBackground)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(VoizTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Text("As configurações abaixo incluem um token. Trate-o como senha.")
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func clientRow(
        target: CopyTarget,
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        accessibilityLabel: LocalizedStringKey,
        value: @escaping () -> String?
    ) -> some View {
        SettingsRow(icon: icon, title: title, subtitle: subtitle) {
            Button {
                guard let value = value() else { return }
                copy(value, target: target, containsCredential: true)
            } label: {
                Label(
                    copiedTarget == target ? "Copiado" : "Copiar configuração",
                    systemImage: copiedTarget == target ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(GranolaPillButtonStyle())
            .disabled(server.status != .running)
            .accessibilityLabel(
                copiedTarget == target ? Text("Configuração copiada") : Text(accessibilityLabel)
            )
        }
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield")
                .foregroundColor(VoizTheme.accent)
            Text("Funciona só neste Mac, enquanto o Voiz está aberto. O token copiado sai da área de transferência após 60 segundos.")
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func copy(_ value: String, target: CopyTarget, containsCredential: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if containsCredential {
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            pasteboard.writeObjects([item])
        } else {
            pasteboard.setString(value, forType: .string)
        }
        let pasteboardChangeCount = pasteboard.changeCount
        withAnimation(.easeOut(duration: 0.12)) { copiedTarget = target }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard copiedTarget == target else { return }
            withAnimation(.easeOut(duration: 0.12)) { copiedTarget = nil }
        }
        guard containsCredential else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard pasteboard.changeCount == pasteboardChangeCount,
                  pasteboard.string(forType: .string) == value else { return }
            pasteboard.clearContents()
        }
    }

    private enum CopyTarget: Equatable {
        case endpoint
        case claude
        case other
    }
}
