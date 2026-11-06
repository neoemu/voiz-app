import SwiftUI

struct HotKeyCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    
    var body: some Commands {
        CommandMenu("Atalho") {
            Button("Definir atalho…") {
                openWindow(id: "hotkey-config")
            }
            .keyboardShortcut(",", modifiers: [.command, .option])
        }
    }
}
