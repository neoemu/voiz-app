import Combine
import SwiftUI

/// Card flutuante estilo Granola: "Reunião no <app> — Gravar?", com contagem regressiva
/// (auto-dispensa) e botões Gravar / fechar. Renderizado dentro do `MeetingDetectionPanel`.
struct MeetingDetectionCardView: View {
    static let cardWidth: CGFloat = 320
    /// Tamanho do painel AppKit (card + respiro da sombra).
    static let panelSize = NSSize(width: 332, height: 100)

    /// Tempo até o card se dispensar sozinho (conta como "agora não" — snooze da chamada).
    static let autoDismissSeconds: TimeInterval = 30

    let appName: String
    let onRecord: () -> Void
    let onDismiss: () -> Void

    @State private var remaining: TimeInterval = MeetingDetectionCardView.autoDismissSeconds
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.purple.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reunião detectada")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(appName) em chamada · gravar com o Voiz?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onRecord) {
                    Label("Gravar", systemImage: "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Agora não")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Barrinha de cooldown: quando zera, o card se dispensa sozinho.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Rectangle()
                        .fill(Color.purple.opacity(0.55))
                        .frame(width: geo.size.width * remaining / Self.autoDismissSeconds)
                }
            }
            .frame(height: 3)
            .animation(.linear(duration: 0.5), value: remaining)
        }
        .frame(width: Self.cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(6)
        .onReceive(ticker) { _ in
            remaining = max(0, remaining - 0.5)
            if remaining <= 0 {
                onDismiss()
            }
        }
    }
}
