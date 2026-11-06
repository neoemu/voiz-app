import SwiftUI

struct HotKeyConfigView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Definir atalho global")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Escolha as teclas que iniciam o ditado em qualquer app.")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Segurar para falar")
                    .font(.subheadline).fontWeight(.medium)
                HotKeyRecorder(shortcut: $viewModel.settings.pushToTalkShortcut)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Mãos livres (toque para alternar)")
                    .font(.subheadline).fontWeight(.medium)
                HotKeyRecorder(shortcut: $viewModel.settings.handsFreeShortcut)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Dicas")
                    .font(.headline)
                Text("• Pode usar Fn/🌐 sozinha ou com outra tecla (ex.: Fn+Espaço).")
                Text("• Evite atalhos já usados por outros aplicativos.")
                Text("• Segurar: \(viewModel.settings.pushToTalkShortcut.displayString) · Mãos livres: \(viewModel.settings.handsFreeShortcut.displayString).")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(24)
        .frame(width: 380, height: 380)
        .preferredColorScheme(viewModel.settings.appearance.colorScheme)
    }
}

#Preview {
    HotKeyConfigView()
        .environmentObject(TranscriptionViewModel())
}
