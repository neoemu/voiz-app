import SwiftUI

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdateService.shared

    var body: some View {
        Button("Buscar atualizações…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
            .help(updater.isConfigured
                ? String(localized: "Buscar uma nova versão do Voiz")
                : String(localized: "Este build recebe atualizações por instalação manual."))
    }
}
