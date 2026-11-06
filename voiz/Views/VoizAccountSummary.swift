import SwiftUI

struct VoizProfileAvatar: View {
    let name: String
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let initial = name.first {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.42, weight: .regular, design: .serif))
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.38))
            }
        }
        .foregroundStyle(VoizTheme.accent)
        .frame(width: size, height: size)
        .background(VoizTheme.selectedBackground, in: Circle())
        .accessibilityHidden(true)
    }
}

/// Local profile row in Settings.
struct VoizAccountSummaryRow: View {
    let action: () -> Void
    @ObservedObject private var profileStore = UserProfileStore.shared
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VoizProfileAvatar(name: profileStore.profile.displayName, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: profileStore.profile.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                    Text("Perfil e bibliotecas locais")
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
            }
            .padding(16)
            .background(isHovering ? VoizTheme.hoverBackground : VoizTheme.surfaceBackground)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(VoizTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text("Abrir perfil"))
    }
}
