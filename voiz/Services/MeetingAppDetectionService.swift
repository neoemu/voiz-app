import AppKit
import Combine
import CoreAudio
import Foundation
import OSLog

/// Uma chamada em curso detectada num app de reunião (Teams, Meet, Zoom…), candidata a gravação.
struct DetectedMeetingApp: Equatable, Identifiable {
    /// Muda a cada chamada nova do mesmo app (permite a UI reagir a re-detecções).
    let id: String
    /// Chave estável do app ("meet", "teams", "zoom"…), usada no snooze por chamada.
    let appKey: String
    /// Nome exibido no card ("Google Meet", "Microsoft Teams"…).
    let appName: String
}

/// Detecta reuniões em curso no Mac (estilo Granola): quando o usuário entra numa call do
/// Teams/Meet/Zoom/Webex/FaceTime, publica `detectedApp` para a UI sugerir gravar.
///
/// Como detecta (tudo on-device, nada sai do Mac):
/// - **Microfone em uso** (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` em qualquer
///   device de entrada): sinal de que ALGUÉM está numa chamada — sem ele, app aberto não conta.
/// - **Apps nativos** rodando (bundle id via NSWorkspace): Teams, Zoom, Webex, FaceTime.
/// - **Reuniões no navegador** via título de janela (CGWindowList): "Meet – xxx", "Zoom Meeting",
///   "Microsoft Teams". Os títulos só aparecem com a permissão de Gravação de Tela, que o Voiz
///   já pede para capturar o áudio do sistema — sem ela, o caminho dos apps nativos segue valendo.
///
/// Anti-ruído:
/// - Candidato precisa persistir 2 ticks (~6s) antes do card aparecer.
/// - `isSelfCapturing` suprime quando o próprio Voiz está com o mic (ditado/gravação).
/// - Snooze por chamada: dispensou ou começou a gravar → não pergunta de novo até a chamada
///   daquele app acabar (candidato sumir por alguns ticks).
@MainActor
final class MeetingAppDetectionService: ObservableObject {
    @Published private(set) var detectedApp: DetectedMeetingApp?

    /// A UI/VM injeta: `true` quando o Voiz mesmo está capturando o mic (evita auto-detecção).
    var isSelfCapturing: () -> Bool = { false }

    private struct KnownApp {
        let key: String
        let name: String
        /// Bundle ids do app nativo (conta como chamada se rodando + mic em uso).
        let bundleIds: [String]
        /// Trechos de título de janela que indicam chamada (navegador/PWA).
        let windowTitleNeedles: [String]
    }

    /// Ordem = prioridade quando mais de um candidato aparece no mesmo tick.
    private static let knownApps: [KnownApp] = [
        KnownApp(key: "meet", name: "Google Meet", bundleIds: [],
                 windowTitleNeedles: ["meet – ", "meet - ", "google meet"]),
        KnownApp(key: "teams", name: "Microsoft Teams",
                 bundleIds: ["com.microsoft.teams2", "com.microsoft.teams"],
                 windowTitleNeedles: ["microsoft teams"]),
        KnownApp(key: "zoom", name: "Zoom", bundleIds: ["us.zoom.xos"],
                 windowTitleNeedles: ["zoom meeting", "reunião zoom", "reunião do zoom"]),
        KnownApp(key: "webex", name: "Webex", bundleIds: ["Cisco-Systems.Spark"],
                 windowTitleNeedles: ["webex"]),
        KnownApp(key: "facetime", name: "FaceTime", bundleIds: ["com.apple.FaceTime"],
                 windowTitleNeedles: []),
    ]

    private let pollInterval: TimeInterval = 3
    private let fireAfterTicks = 2
    /// Ticks sem o candidato para considerar a chamada encerrada (limpa snooze/card).
    private let clearAfterTicks = 3

    private var timer: Timer?
    private var presenceStreak: [String: Int] = [:]
    private var absenceStreak: [String: Int] = [:]
    private var snoozedKeys: Set<String> = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rmb.voiz", category: "meeting-detect")

    /// Liga/desliga o monitoramento (segue o toggle de Ajustes).
    func configure(enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            presenceStreak = [:]
            absenceStreak = [:]
            snoozedKeys = []
            detectedApp = nil
        }
    }

    /// Usuário dispensou o card (ou ele expirou): silencia até a chamada desse app acabar.
    func dismissCurrent() {
        guard let app = detectedApp else { return }
        snoozedKeys.insert(app.appKey)
        detectedApp = nil
    }

    /// Usuário começou a gravar a partir do card: mesmo silêncio do dismiss.
    func markHandled() {
        dismissCurrent()
    }

    // MARK: - Poll

    private func tick() {
        // Voiz gravando/ditando: o mic em uso é nosso — não detecta nada nem mantém card.
        if isSelfCapturing() {
            presenceStreak = [:]
            detectedApp = nil
            return
        }

        let current = currentCandidateKeys()

        for app in Self.knownApps {
            if current.contains(app.key) {
                presenceStreak[app.key, default: 0] += 1
                absenceStreak[app.key] = 0
            } else {
                presenceStreak[app.key] = 0
                absenceStreak[app.key, default: 0] += 1
                // Chamada acabou: libera o snooze pra próxima call do mesmo app.
                if absenceStreak[app.key, default: 0] >= clearAfterTicks {
                    snoozedKeys.remove(app.key)
                }
            }
        }

        // Card em exibição cujo app saiu de chamada → esconde sozinho.
        if let shown = detectedApp, !current.contains(shown.appKey) {
            detectedApp = nil
        }

        guard detectedApp == nil else { return }
        for app in Self.knownApps where !snoozedKeys.contains(app.key) {
            if presenceStreak[app.key, default: 0] >= fireAfterTicks {
                log.info("Reunião detectada: \(app.name, privacy: .public)")
                detectedApp = DetectedMeetingApp(
                    id: "\(app.key)-\(Date().timeIntervalSince1970)",
                    appKey: app.key,
                    appName: app.name
                )
                break
            }
        }
    }

    /// Chaves dos apps que parecem estar em chamada AGORA. Regra: mic em uso por alguém
    /// (fora o Voiz) E (título de janela de reunião OU app nativo de reunião rodando).
    private func currentCandidateKeys() -> Set<String> {
        guard anyInputDeviceInUse() else { return [] }

        var keys: Set<String> = []

        let runningBundleIds = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for app in Self.knownApps where app.bundleIds.contains(where: runningBundleIds.contains) {
            keys.insert(app.key)
        }

        let titles = onScreenWindowTitles()
        if !titles.isEmpty {
            for app in Self.knownApps where !app.windowTitleNeedles.isEmpty {
                if titles.contains(where: { title in app.windowTitleNeedles.contains { title.contains($0) } }) {
                    keys.insert(app.key)
                }
            }
        }

        return keys
    }

    /// Títulos (minúsculos) das janelas visíveis. Vazio sem a permissão de Gravação de Tela —
    /// o sistema simplesmente omite `kCGWindowName`, não há erro.
    private func onScreenWindowTitles() -> [String] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { ($0[kCGWindowName as String] as? String)?.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// `true` se qualquer device de ENTRADA está capturando pra algum processo
    /// (`kAudioDevicePropertyDeviceIsRunningSomewhere`) — o "estou numa call" do sistema.
    private func anyInputDeviceInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }

        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else {
            return false
        }

        for device in devices where hasInputStreams(device) {
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &runningSize, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }
}
