import CoreGraphics
import Foundation
import Testing

@Suite("NotchOverlayLayout")
struct NotchOverlayLayoutTests {

    @Test("Precedência de modo prioriza prompt > ditado > gravação > processamento > calendário > toast")
    func modePrecedence() {
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: true,
                dictation: .listening,
                isRecording: true,
                isProcessing: true,
                hasCalendar: true,
                hasToast: true
            ) == .prompt
        )
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: false,
                dictation: .listening,
                isRecording: true,
                isProcessing: true,
                hasCalendar: true,
                hasToast: true
            ) == .dictation(.listening)
        )
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: false,
                dictation: nil,
                isRecording: true,
                isProcessing: true,
                hasCalendar: true,
                hasToast: true
            ) == .recording
        )
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: false,
                dictation: nil,
                isRecording: false,
                isProcessing: true,
                hasCalendar: true,
                hasToast: true
            ) == .processing
        )
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: false,
                dictation: nil,
                isRecording: false,
                isProcessing: false,
                hasCalendar: true,
                hasToast: true
            ) == .calendar
        )
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: false,
                dictation: nil,
                isRecording: false,
                isProcessing: false,
                hasCalendar: false,
                hasToast: true
            ) == .toastOnly
        )
        #expect(
            NotchOverlayLayout.resolvedMode(
                hasPrompt: false,
                dictation: nil,
                isRecording: false,
                isProcessing: false,
                hasCalendar: false,
                hasToast: false
            ) == .idle
        )
    }

    @Test("Asas simétricas acomodam cronômetros acima de 1h sem deslocar o vão do notch")
    func symmetricWingsAndLongTimer() {
        let shortWing = NotchOverlayLayout.symmetricWingWidth(
            for: .recording,
            isExpanded: false,
            hasLongTimer: false
        )
        let longWing = NotchOverlayLayout.symmetricWingWidth(
            for: .recording,
            isExpanded: false,
            hasLongTimer: true
        )
        #expect(longWing > shortWing)

        let notchedWidth = NotchOverlayLayout.contentWidth(
            notchGap: 200,
            mode: .recording,
            isExpanded: false,
            hasToastTray: false,
            hasLongTimer: true
        )
        // A largura total é notchGap + 2 * asa -> esquerda e direita idênticas
        #expect(notchedWidth == 200 + 2 * longWing)

        // Toast compacto abaixo do notch nunca estica para 650px na menu bar
        let toastWidth = NotchOverlayLayout.contentWidth(
            notchGap: 200,
            mode: .toastOnly,
            isExpanded: false,
            hasToastTray: true,
            hasLongTimer: false
        )
        #expect(toastWidth == NotchOverlayLayout.minimumToastTrayWidth)
        #expect(toastWidth < 400)
    }

    @Test("Zona de hover e altura da faixa acompanham exatamente o notch físico")
    func hoverTriggerRectTracksVisibleWings() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let stripHeight = NotchOverlayLayout.notchedStripHeight(safeAreaTop: 32, menuBarHeight: 33)
        #expect(abs(stripHeight - 32) < 0.01)

        let rect = NotchOverlayLayout.hoverTriggerRect(
            screenFrame: screen,
            notchGap: 185,
            barHeight: stripHeight,
            wingWidth: 60
        )
        let expectedWidth: CGFloat = 185 + 2 * 60 + 6
        let expectedHeight: CGFloat = stripHeight + 4
        #expect(abs(rect.midX - screen.midX) < 0.01)
        #expect(abs(rect.maxY - screen.maxY) < 0.01)
        #expect(abs(rect.width - expectedWidth) < 0.01)
        #expect(abs(rect.height - expectedHeight) < 0.01)

        let expanded = NotchOverlayLayout.expandedContentRect(
            screenFrame: screen,
            notchGap: 185,
            barHeight: stripHeight,
            mode: .recording
        )
        let expectedExpandedWidth: CGFloat = 185 + 2 * NotchOverlayLayout.interactiveWingWidth
        #expect(abs(expanded.midX - screen.midX) < 0.01)
        #expect(abs(expanded.maxY - screen.maxY) < 0.01)
        #expect(abs(expanded.width - expectedExpandedWidth) < 0.01)
        #expect(expanded.height > stripHeight)
    }

    @Test("Suavização de áudio sobe rápido e cai de forma gradual")
    func smoothedAudioLevelAttackAndDecay() {
        let attack = NotchOverlayLayout.smoothedAudioLevel(raw: 0.05, current: 0)
        #expect(abs(attack - 0.6) < 0.001)

        let decay = NotchOverlayLayout.smoothedAudioLevel(raw: 0, current: 0.6)
        #expect(abs(decay - 0.432) < 0.001)

        let clamped = NotchOverlayLayout.smoothedAudioLevel(raw: 1.0, current: 0)
        #expect(clamped == 1.0)
    }

    @Test("cleanLiveTail recorta em fronteira de palavra preservando o trecho recente")
    func cleanLiveTailWordBoundary() {
        let short = "Resumo rápido da revisão."
        #expect(NotchOverlayLayout.cleanLiveTail(short, maxCharacters: 180) == short)

        let long = "Primeiro tópico encerrado agora vamos alinhar o cronograma da entrega de infraestrutura com o time de plataforma."
        let cleaned = NotchOverlayLayout.cleanLiveTail(long, maxCharacters: 45)
        #expect(cleaned.hasPrefix("…"))
        #expect(cleaned.hasSuffix("plataforma."))
        #expect(!cleaned.hasPrefix("…o "))
    }

    @Test("Formatação de duração e countdown de calendário")
    func durationAndCountdownFormatting() {
        #expect(NotchOverlayLayout.formatDuration(0) == "0:00")
        #expect(NotchOverlayLayout.formatDuration(125) == "2:05")
        #expect(NotchOverlayLayout.formatDuration(3661) == "1:01:01")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            NotchOverlayLayout.countdownLabel(
                to: now.addingTimeInterval(360),
                inProgress: false,
                now: now
            ) == "6m"
        )
        #expect(
            NotchOverlayLayout.countdownLabel(
                to: now.addingTimeInterval(3600),
                inProgress: false,
                now: now
            ) == "1h"
        )
        #expect(
            NotchOverlayLayout.countdownLabel(
                to: now.addingTimeInterval(3900),
                inProgress: false,
                now: now
            ) == "1h 5m"
        )
        #expect(
            NotchOverlayLayout.countdownLabel(
                to: now.addingTimeInterval(30),
                inProgress: false,
                now: now
            ) == String(localized: "agora")
        )
        #expect(
            NotchOverlayLayout.countdownLabel(
                to: now.addingTimeInterval(300),
                inProgress: true,
                now: now
            ) == String(localized: "agora")
        )
    }
}
