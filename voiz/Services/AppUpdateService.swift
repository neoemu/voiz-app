import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdateService()

    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private var sparkleCanCheck = false
    @Published private var pendingInstallation: (() -> Void)?
    private var controller: SPUStandardUpdaterController?
    let isConfigured: Bool

    var canCheckForUpdates: Bool { sparkleCanCheck || pendingInstallation != nil }

    private override init() {
        isConfigured = AppUpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil
        super.init()
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$sparkleCanCheck)
        // Sparkle owns persistence and scheduling; observe its setting so the toggle also
        // reflects changes made in Sparkle's initial permission prompt.
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        controller.startUpdater()
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    private var isBusy: Bool { VoizWorkTracker.shared.hasActiveWork }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        guard !isBusy else { showBusyAlert(); return }
        if let install = pendingInstallation {
            pendingInstallation = nil
            install()
        } else {
            controller?.checkForUpdates(nil)
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !isBusy else {
            throw NSError(domain: "com.rmb.voiz.updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Conclua a gravação ou o processamento antes de atualizar.")
            ])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        pendingInstallation = installHandler
        showBusyAlert()
        return true
    }

    private func showBusyAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Conclua a gravação ou o processamento antes de atualizar.")
        alert.informativeText = String(localized: "Depois, clique novamente em Buscar atualizações para continuar.")
        alert.runModal()
    }
}
