import Combine
import SwiftUI

/// Estados do ditado espelhados no notch (equivalente ao RecordingHUD flutuante).
enum NotchDictationState: Equatable {
    case listening
    case processing
}

/// Estado compartilhado entre o serviço `NotchOverlay` e a view desenhada no painel.
@MainActor
final class NotchOverlayModel: ObservableObject {
    struct Toast: Equatable {
        let id: UUID
        let message: String
        let symbol: String
    }

    /// Reunião iminente do calendário (countdown estilo Alcove nas asas).
    struct CalendarCountdown: Equatable {
        let id: String
        let title: String
        let startDate: Date
        let isInProgress: Bool
    }

    /// Card "reunião detectada — gravar?" ancorado no notch. Os callbacks ficam
    /// no serviço (closures não são Equatable); a view chama `NotchOverlay.shared`.
    struct Prompt: Equatable {
        let id: UUID
        let appName: String
    }

    @Published var isRecording = false
    @Published var isPaused = false
    /// Início "virtual" da gravação: avança a cada retomada pra descontar as pausas,
    /// então o cronômetro do notch bate com a duração efetivamente gravada.
    @Published var recordingStart = Date()
    /// Tempo congelado exibido enquanto a gravação está pausada.
    @Published var frozenElapsed: TimeInterval = 0
    @Published var audioLevel: CGFloat = 0
    @Published var toast: Toast?
    @Published var prompt: Prompt?
    @Published var dictation: NotchDictationState?
    @Published var calendarEvent: CalendarCountdown?
    /// Painel expandido pelo hover: mostra a cauda da transcrição + controles.
    @Published var expanded = false
    /// Fim do que está sendo falado agora (já limitado pelo view model). Renderizado
    /// com truncação no início, então o texto "rola" conforme a fala avança.
    @Published var liveTail: String = ""
}

/// Conteúdo desenhado colado ao notch (ou como pílula em telas sem notch).
/// O vão central (`notchGap`) fica vazio porque ali está o hardware — todo o
/// conteúdo vive nas "asas" laterais e no bloco que expande pra baixo.
struct NotchOverlayView: View {
    @ObservedObject var model: NotchOverlayModel
    let notchGap: CGFloat
    let barHeight: CGFloat

    /// Largura das asas quando o painel é interativo (expandido/prompt). O painel
    /// AppKit é redimensionado pra este conteúdo + margem de sombra — ver `NotchOverlay`.
    static let interactiveWingWidth: CGFloat = 150

    private var hasContent: Bool {
        model.isRecording || model.toast != nil || model.prompt != nil
            || model.dictation != nil || model.calendarEvent != nil
    }
    private var isInteractive: Bool {
        model.prompt != nil
            || (model.expanded && (model.isRecording || model.calendarEvent != nil))
    }
    private var totalWidth: CGFloat { notchGap + 2 * Self.interactiveWingWidth }

    /// Raio das curvinhas côncavas no topo, onde o preto "escorre" da menu bar
    /// (estilo Alcove/Dynamic Island). O painel AppKit soma isso à largura.
    static let topFlareRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            if hasContent {
                VStack(spacing: 0) {
                    strip
                    if model.prompt != nil {
                        promptSection
                    } else if model.expanded && model.isRecording {
                        expandedSection
                    } else if model.expanded, model.calendarEvent != nil {
                        calendarSection
                    }
                }
                // Respiro lateral pras curvas do topo, que flaram pra fora do conteúdo.
                .padding(.horizontal, Self.topFlareRadius)
                .background(
                    NotchShape(
                        topRadius: Self.topFlareRadius,
                        bottomRadius: isInteractive ? 22 : 9
                    )
                    .fill(.black)
                    .shadow(color: .black.opacity(isInteractive ? 0.45 : 0.25),
                            radius: isInteractive ? 16 : 6, y: 5)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hasContent)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isPaused)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.prompt)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.dictation)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.calendarEvent)
    }

    /// Rente à menu bar: qualquer pixel a mais invade a janela maximizada logo abaixo.
    private var stripHeight: CGFloat { barHeight + (notchGap > 0 ? 0 : 2) }

    // MARK: - Faixa colada ao notch

    /// No estado passivo as asas abraçam o notch (largura intrínseca — sem Spacer,
    /// que esticaria o HStack até a largura total do painel e engoliria a menu bar).
    /// Nos estados interativos elas ganham largura fixa pra alinhar com o bloco abaixo.
    private var strip: some View {
        HStack(spacing: 0) {
            leftWing
                // -22 desconta os paddings, mantendo asa+respiro = interactiveWingWidth
                // (senão a faixa fica mais larga que o bloco expandido logo abaixo).
                .frame(width: isInteractive ? Self.interactiveWingWidth - 22 : nil, alignment: .trailing)
                .padding(.leading, 14)
                .padding(.trailing, 8)
            Color.clear
                .frame(width: notchGap, height: 1)
            rightWing
                .frame(width: isInteractive ? Self.interactiveWingWidth - 22 : nil, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 14)
        }
        .frame(height: stripHeight)
    }

    @ViewBuilder
    private var leftWing: some View {
        if model.prompt != nil {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.purple)
        } else if let toast = model.toast {
            // Cópia invisível do texto: força a asa esquerda a ter a MESMA largura da
            // direita. Asas desiguais deslocam o vão central pra fora do notch físico
            // (o conjunto é centralizado na tela) e o notch cobria o início do texto.
            ZStack(alignment: .trailing) {
                toastText(toast).hidden()
                Image(systemName: toast.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else if let dictation = model.dictation {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dictation == .listening ? Color.red : .white.opacity(0.6))
                .frame(minWidth: 40, alignment: .leading)
        } else if model.isRecording {
            HStack(spacing: 6) {
                RecordingDot(paused: model.isPaused)
                elapsedText
            }
            .frame(minWidth: 64, alignment: .leading)
        } else if model.calendarEvent != nil {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
                .frame(minWidth: 40, alignment: .leading)
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if model.prompt != nil {
            Text("Reunião detectada")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        } else if let toast = model.toast {
            toastText(toast)
        } else if let dictation = model.dictation {
            Group {
                if dictation == .listening {
                    AudioLevelBars(level: model.audioLevel)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(minWidth: 40, alignment: .trailing)
        } else if model.isRecording {
            AudioLevelBars(level: model.isPaused ? 0 : model.audioLevel)
                .frame(minWidth: 64, alignment: .trailing)
        } else if let event = model.calendarEvent {
            // Recalcula a cada 30s; o serviço some com o card quando o evento passa.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.countdownLabel(to: event.startDate,
                                         inProgress: event.isInProgress,
                                         now: context.date))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            }
            .frame(minWidth: 40, alignment: .trailing)
        }
    }

    private func toastText(_ toast: NotchOverlayModel.Toast) -> some View {
        Text(toast.message)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(2)
            .frame(maxWidth: 250, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var elapsedText: some View {
        Group {
            if model.isPaused {
                Text(Self.format(model.frozenElapsed))
            } else {
                Text(model.recordingStart, style: .timer)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.92))
    }

    // MARK: - Bloco expandido (hover durante a gravação)

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Cauda da transcrição: truncação no início + conteúdo ancorado embaixo
            // fazem o texto "rolar" sozinho conforme a fala avança, sem scroll manual.
            Group {
                if model.liveTail.isEmpty {
                    Text("Ouvindo…")
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text(model.liveTail)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .font(.system(size: 11, design: .rounded))
            .lineLimit(3)
            .truncationMode(.head)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)

            HStack(spacing: 8) {
                NotchPillButton(
                    title: model.isPaused ? String(localized: "Retomar") : String(localized: "Pausar"),
                    symbol: model.isPaused ? "play.fill" : "pause.fill",
                    tint: .white.opacity(0.14)
                ) {
                    NotchOverlay.shared.togglePauseTapped()
                }
                NotchPillButton(
                    title: String(localized: "Parar"),
                    symbol: "stop.fill",
                    tint: .red.opacity(0.85)
                ) {
                    NotchOverlay.shared.stopTapped()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: totalWidth, alignment: .leading)
    }

    // MARK: - Prompt "reunião detectada"

    @ViewBuilder
    private var promptSection: some View {
        if let prompt = model.prompt {
            VStack(alignment: .leading, spacing: 9) {
                Text("\(prompt.appName) em chamada · gravar com o Voiz?")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    NotchPillButton(
                        title: String(localized: "Gravar"),
                        symbol: "record.circle",
                        tint: .purple
                    ) {
                        NotchOverlay.shared.promptRecordTapped()
                    }
                    NotchPillButton(
                        title: String(localized: "Agora não"),
                        symbol: nil,
                        tint: .white.opacity(0.14)
                    ) {
                        NotchOverlay.shared.promptDismissTapped()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(width: totalWidth, alignment: .leading)
        }
    }

    // MARK: - Bloco expandido do calendário (hover no countdown)

    @ViewBuilder
    private var calendarSection: some View {
        if let event = model.calendarEvent {
            VStack(alignment: .leading, spacing: 9) {
                Text(event.title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text(event.startDate, style: .time)
                }
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 8) {
                    NotchPillButton(
                        title: String(localized: "Gravar"),
                        symbol: "record.circle",
                        tint: .purple
                    ) {
                        NotchOverlay.shared.calendarRecordTapped()
                    }
                    NotchPillButton(
                        title: String(localized: "Agora não"),
                        symbol: nil,
                        tint: .white.opacity(0.14)
                    ) {
                        NotchOverlay.shared.calendarDismissTapped()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(width: totalWidth, alignment: .leading)
        }
    }

    /// "6m" / "1h 5m" / "agora", estilo Alcove.
    static func countdownLabel(to start: Date, inProgress: Bool, now: Date) -> String {
        let remaining = start.timeIntervalSince(now)
        if inProgress || remaining < 45 {
            return String(localized: "agora")
        }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Contorno de "extensão do notch": cantos inferiores arredondados pra dentro e, no
/// topo, curvas côncavas pra fora — o preto parece escorrer da menu bar, como no
/// Alcove/Dynamic Island. O corpo do conteúdo fica inset em `topRadius` de cada lado;
/// as curvas ocupam essa margem.
private struct NotchShape: Shape {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Botão-pílula pro fundo preto do notch (o estilo padrão do AppKit destoa ali).
private struct NotchPillButton: View {
    let title: String
    let symbol: String?
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint))
            .overlay(Capsule().stroke(.white.opacity(hovering ? 0.35 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Ponto vermelho pulsante; âmbar e estático quando pausado.
private struct RecordingDot: View {
    let paused: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(paused ? Color.orange : Color.red)
            .frame(width: 7, height: 7)
            .opacity(paused ? 0.9 : (pulsing ? 0.35 : 1))
            .animation(
                paused ? .default : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

/// Mini-visualizador de nível: barras que reagem ao áudio (mic ou sistema).
private struct AudioLevelBars: View {
    let level: CGFloat
    private let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2.5, height: height(for: index))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        // Perfil em "colina": barras centrais reagem mais, como um equalizador.
        let profile: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
        let base: CGFloat = 3
        let maxExtra: CGFloat = 11
        return base + maxExtra * level * profile[index % profile.count]
    }
}
