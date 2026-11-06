import SwiftUI

/// A denied action must have a visible result even when Profile is not open.
struct VoizAccessNotice: View {
    var onOpenProfile: () -> Void = {}
    @ObservedObject private var access = VoizAccessStore.shared
    var body: some View {
        if let error = access.lastError {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "info.circle")
                Text(error).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                // The library selection and storage error are available in Profile.
                Button("Abrir Perfil") {
                    access.dismissError()
                    onOpenProfile()
                }
                .buttonStyle(GranolaPillButtonStyle())
                Button { access.dismissError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fechar aviso")
            }
            .padding(14)
            .background(VoizTheme.elevatedBackground)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
