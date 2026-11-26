import CoreGraphics
import Foundation

/// Estados do ditado espelhados no notch (equivalente ao RecordingHUD flutuante).
enum NotchDictationState: Equatable {
    case listening
    case processing
}

/// Etapas do pós-processamento de reunião exibidas continuamente após o encerramento.
enum NotchProcessingStage: Equatable {
    case diarizing
    case transcribing
    case summarizing

    var localizedTitle: String {
        switch self {
        case .diarizing:
            return String(localized: "Identificando vozes…")
        case .transcribing:
            return String(localized: "Transcrevendo…")
        case .summarizing:
            return String(localized: "Gerando resumo…")
        }
    }

    var symbolName: String {
        switch self {
        case .diarizing:
            return "person.2.wave.2"
        case .transcribing:
            return "waveform"
        case .summarizing:
            return "sparkles"
        }
    }
}

/// Tom semântico de toasts exibidos na bandeja abaixo do notch.
enum NotchToastTone: Equatable {
    case neutral
    case success
    case warning
    case accent
}

/// Modo visual resolvido por precedência para o overlay do notch.
enum NotchVisualMode: Equatable {
    case idle
    case prompt
    case dictation(NotchDictationState)
    case recording
    case processing
    case calendar
    case toastOnly
}

/// Regras puras de geometria, precedência, temporização e formatação do overlay do notch.
/// Mantidas fora da camada AppKit/SwiftUI para permitir testes unitários diretos.
enum NotchOverlayLayout {
    /// Atraso de intenção antes de expandir no hover: evita disparos acidentais ao cruzar a menu bar.
    static let hoverOpenDelayNanoseconds: UInt64 = 200_000_000
    /// Pequena folga ao sair com o cursor antes de recolher: facilita alcançar os botões sem fechar.
    static let hoverCloseDelayNanoseconds: UInt64 = 260_000_000
    /// Duração da retração suave para dentro do notch antes de esconder o painel ocioso.
    static let idleHideDelayNanoseconds: UInt64 = 440_000_000
    /// Duração extra após o cursor sair de um toast clicável pausado no hover.
    static let toastResumeAfterHoverDuration: TimeInterval = 1.4

    /// Raio das curvas côncavas no topo em telas com notch físico.
    static let topFlareRadius: CGFloat = 8
    /// Margem lateral/inferior transparente no canvas fixo do `NSPanel` para a sombra nunca cortar.
    static let shadowMargin: CGFloat = 24
    /// Margem superior da pílula flutuante em telas sem notch físico.
    static let pillTopMargin: CGFloat = 6

    /// Largura fixa de cada asa nos modos interativos/expandidos (simétrica em torno do notch).
    static let interactiveWingWidth: CGFloat = 108
    /// Largura mínima de cartões expandidos em telas sem notch físico (`notchGap == 0`).
    static let minimumExpandedWidth: CGFloat = 376
    /// Largura mínima da bandeja de toast abaixo do notch.
    static let minimumToastTrayWidth: CGFloat = 324
    /// Altura máxima reservada para o canvas fixo do `NSPanel` (evita redimensionar durante springs).
    static let maxTrayCanvasHeight: CGFloat = 168

    /// Altura exata da faixa superior em telas com notch físico: segue `safeAreaInsets.top`
    /// para casar pixel-a-pixel com a base do recorte físico e respeitar a borda superior
    /// de janelas maximizadas logo abaixo da menu bar.
    static func notchedStripHeight(safeAreaTop: CGFloat, menuBarHeight: CGFloat) -> CGFloat {
        safeAreaTop > 0 ? safeAreaTop : menuBarHeight
    }

    /// Resolve o modo principal exibido nas asas conforme precedência de contexto.
    /// Um toast durante gravação ativa mantém as asas da gravação e abre a bandeja abaixo do notch.
    static func resolvedMode(
        hasPrompt: Bool,
        dictation: NotchDictationState?,
        isRecording: Bool,
        isProcessing: Bool,
        hasCalendar: Bool,
        hasToast: Bool
    ) -> NotchVisualMode {
        if hasPrompt { return .prompt }
        if let dictation { return .dictation(dictation) }
        if isRecording { return .recording }
        if isProcessing { return .processing }
        if hasCalendar { return .calendar }
        if hasToast { return .toastOnly }
        return .idle
    }

    /// Largura simétrica garantida para CADA asa (esquerda == direita).
    /// Compacta o suficiente para não invadir os menus do app ativo (ex.: Chrome "Janela"),
    /// preservando alinhamento pixel-a-pixel do vão central (`notchGap`) sobre o hardware.
    static func symmetricWingWidth(
        for mode: NotchVisualMode,
        isExpanded: Bool,
        hasLongTimer: Bool
    ) -> CGFloat {
        if isExpanded || mode == .prompt {
            return interactiveWingWidth
        }
        switch mode {
        case .idle:
            return 0
        case .prompt:
            return interactiveWingWidth
        case .dictation:
            return 48
        case .recording:
            return hasLongTimer ? 74 : 60
        case .processing:
            return 56
        case .calendar:
            return 50
        case .toastOnly:
            return 42
        }
    }

    /// Largura total do corpo de conteúdo (sem contar `topFlareRadius` nem `shadowMargin`).
    static func contentWidth(
        notchGap: CGFloat,
        mode: NotchVisualMode,
        isExpanded: Bool,
        hasToastTray: Bool,
        hasLongTimer: Bool
    ) -> CGFloat {
        let wing = symmetricWingWidth(for: mode, isExpanded: isExpanded, hasLongTimer: hasLongTimer)
        let base = notchGap + 2 * wing
        if isExpanded || mode == .prompt {
            return max(base, minimumExpandedWidth)
        }
        if hasToastTray {
            return max(base, minimumToastTrayWidth)
        }
        return notchGap > 0 ? base : max(base, 172)
    }

    /// Largura do canvas fixo do `NSPanel`, suficiente para qualquer estado sem redimensionar.
    static func panelCanvasWidth(notchGap: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let isNotched = notchGap > 0
        let maxContent = max(notchGap + 2 * interactiveWingWidth, minimumExpandedWidth)
        let flares: CGFloat = isNotched ? 2 * topFlareRadius : 0
        return min(maxContent + flares + 2 * shadowMargin, screenWidth)
    }

    /// Altura do canvas fixo do `NSPanel`, suficiente para qualquer estado sem redimensionar.
    static func panelCanvasHeight(notchGap: CGFloat, barHeight: CGFloat) -> CGFloat {
        let isNotched = notchGap > 0
        let topOffset: CGFloat = isNotched ? 0 : pillTopMargin
        let stripHeight: CGFloat = isNotched ? barHeight : 32
        return topOffset + stripHeight + maxTrayCanvasHeight + shadowMargin
    }

    /// Altura reservada para o bloco abaixo da faixa do notch em cada modo.
    static func trayHeight(
        mode: NotchVisualMode,
        isExpanded: Bool,
        hasToastTray: Bool,
        hasToastDetail: Bool
    ) -> CGFloat {
        if mode == .prompt {
            return 94
        }
        if isExpanded {
            switch mode {
            case .recording:
                return 134
            case .processing:
                return 96
            case .calendar:
                return 108
            default:
                break
            }
        }
        if hasToastTray {
            return hasToastDetail ? 66 : 52
        }
        return 0
    }

    /// Retângulo da zona de disparo do hover: cobre estritamente o notch + asas visíveis.
    static func hoverTriggerRect(
        screenFrame: CGRect,
        notchGap: CGFloat,
        barHeight: CGFloat,
        wingWidth: CGFloat
    ) -> CGRect {
        let isNotched = notchGap > 0
        let width = isNotched ? (notchGap + 2 * wingWidth + 6) : max(2 * wingWidth + 24, 176)
        let height = (isNotched ? barHeight : 32 + pillTopMargin) + 4
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Retângulo real do corpo expandido em coordenadas da tela (para manter o hover estável
    /// mesmo com o `NSPanel` em tamanho fixo).
    static func expandedContentRect(
        screenFrame: CGRect,
        notchGap: CGFloat,
        barHeight: CGFloat,
        mode: NotchVisualMode
    ) -> CGRect {
        let isNotched = notchGap > 0
        let width = contentWidth(
            notchGap: notchGap,
            mode: mode,
            isExpanded: true,
            hasToastTray: false,
            hasLongTimer: false
        )
        let topOffset: CGFloat = isNotched ? 0 : pillTopMargin
        let stripHeight: CGFloat = isNotched ? barHeight : 32
        let tray = trayHeight(mode: mode, isExpanded: true, hasToastTray: false, hasToastDetail: false)
        let totalHeight = topOffset + stripHeight + tray
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - totalHeight,
            width: width,
            height: totalHeight
        )
    }

    /// Suavização de nível de áudio: ataque imediato e queda suave para animar sem piscar.
    static func smoothedAudioLevel(raw: Float, current: CGFloat) -> CGFloat {
        let target = min(max(CGFloat(raw) * 12, 0), 1)
        return target >= current ? target : max(target, current * 0.72)
    }

    /// Recorta a cauda da transcrição ao vivo em fronteira de palavra para evitar cortes bruscos.
    static func cleanLiveTail(_ text: String, maxCharacters: Int = 180) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters, maxCharacters > 16 else { return trimmed }
        let suffix = String(trimmed.suffix(maxCharacters))
        if let space = suffix.firstIndex(of: " "),
           suffix.distance(from: suffix.startIndex, to: space) < 28 {
            let afterSpace = suffix[suffix.index(after: space)...]
            return "…" + afterSpace.trimmingCharacters(in: .whitespaces)
        }
        return "…" + suffix.trimmingCharacters(in: .whitespaces)
    }

    /// "6m" / "1h 5m" / "agora", compacto para a asa do calendário.
    static func countdownLabel(to start: Date, inProgress: Bool, now: Date) -> String {
        let remaining = start.timeIntervalSince(now)
        if inProgress || remaining < 45 {
            return String(localized: "agora")
        }
        let minutes = Int((remaining / 60).rounded(.up))
        if minutes >= 60 {
            let hours = minutes / 60
            let rem = minutes % 60
            return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
        }
        return "\(minutes)m"
    }

    /// Formata duração de gravação (`MM:SS` ou `H:MM:SS`).
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
