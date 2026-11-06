import SwiftUI

/// Introduces local storage, optional external AI providers and macOS permissions.
struct VoizOnboardingView: View {
    @ObservedObject var profileStore: UserProfileStore
    var isReview = false
    var onFinish: (() -> Void)?
    @State private var step = 0
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(profileStore: UserProfileStore, isReview: Bool = false, onFinish: (() -> Void)? = nil) {
        self.profileStore = profileStore
        self.isReview = isReview
        self.onFinish = onFinish
        _name = State(initialValue: profileStore.profile.displayName)
    }

    private var validName: Bool {
        (try? VoizUserProfile.validatedName(name)) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .foregroundStyle(VoizTheme.accent)
                Text(verbatim: "voiz")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
                Text("Etapa \(step + 1) de 3")
                    .font(.system(size: 12))
                    .foregroundStyle(VoizTheme.mutedText)
                if isReview {
                    Button("Fechar") { onFinish?() }
                        .buttonStyle(.plain)
                        .padding(.leading, 12)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 20)

            GeometryReader { proxy in
                ScrollView {
                    Group {
                        switch step {
                        case 0: plansPage
                        case 1: welcomePage
                        default: featuresPage
                        }
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 36)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }

            VStack(spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    if step > 0 {
                        Button("Voltar") {
                            errorMessage = nil
                            step -= 1
                        }
                        .buttonStyle(GranolaPillButtonStyle())
                    }
                    Spacer()
                    Button(action: advance) {
                        HStack(spacing: 8) {
                            Text(step == 2 ? LocalizedStringKey("Concluir apresentação") : LocalizedStringKey("Continuar"))
                            Image(systemName: step == 2 ? "checkmark" : "arrow.right")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .foregroundStyle(.white)
                        .background(VoizTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(step == 1 && !validName)
                    .opacity(step == 1 && !validName ? 0.45 : 1)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 22)
            .background(VoizTheme.appBackground)
        }
        .foregroundStyle(VoizTheme.primaryText)
        .background(VoizTheme.appBackground)
        .environment(\.locale, .voizInterface)
        .onChange(of: step) { _, value in nameFocused = value == 1 }
    }

    private var welcomePage: some View {
        VStack(spacing: 28) {
            heading("Bem-vindo ao Voiz", subtitle: "Seu trabalho, no seu Mac.", icon: "waveform")
            VStack(alignment: .leading, spacing: 8) {
                Text("Seu nome")
                    .font(.system(size: 13, weight: .medium))
                TextField("Como podemos chamar você?", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .padding(14)
                    .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
                    .focused($nameFocused)
                    .onSubmit { if validName { advance() } }
                // The limit only matters near the end; showing it earlier is noise.
                if name.trimmingCharacters(in: .whitespacesAndNewlines).count > 60 {
                    Text(verbatim: "\(name.trimmingCharacters(in: .whitespacesAndNewlines).count)/80")
                        .font(.system(size: 12))
                        .foregroundStyle(VoizTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: 400)
        }
    }

    private var featuresPage: some View {
        VStack(spacing: 28) {
            heading("Conheça seu Voiz", subtitle: "Da conversa à próxima ideia.", icon: "sparkles")
            VStack(alignment: .leading, spacing: 18) {
                feature("Reuniões", icon: "waveform.badge.mic", detail: "Grave, transcreva e releia suas reuniões.")
                feature("Ditado", icon: "mic", detail: "Fale para escrever em qualquer app.")
                feature("Tradução", icon: "globe", detail: "Traduza conversas com a IA que você escolher.")
                feature("Chat", icon: "bubble.left.and.bubble.right", detail: "Pergunte às suas notas e encontre decisões e próximos passos.")
                Label("O macOS pede cada permissão quando você usar o recurso.", systemImage: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(VoizTheme.mutedText)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private var plansPage: some View {
        VStack(spacing: 28) {
            heading("Seu trabalho, no seu Mac", subtitle: "Grave, transcreva e organize sem uma conta Voiz.", icon: "internaldrive")
            VStack(alignment: .leading, spacing: 18) {
                feature("Biblioteca local", icon: "folder", detail: "Suas reuniões, conversas e áudios ficam neste Mac. Mantenha uma cópia de segurança.")
                feature("Sua escolha de IA", icon: "sparkles", detail: "Configure um provedor com sua própria chave ou um serviço local. Provedores externos podem exigir internet e cobrar pelo uso.")
                feature("Modelos de transcrição", icon: "arrow.down.circle", detail: "Alguns recursos precisam baixar modelos antes do primeiro uso.")
            }
        }
    }

    /// Same header on every step, so moving between steps feels like one flow.
    private func heading(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(VoizTheme.accent)
                .frame(height: 40)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(VoizTheme.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func feature(_ title: LocalizedStringKey, icon: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(VoizTheme.accent)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(VoizTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func advance() {
        if step == 1 {
            do { name = try VoizUserProfile.validatedName(name) }
            catch { errorMessage = error.localizedDescription; return }
        }
        errorMessage = nil
        if step < 2 {
            nameFocused = false
            step += 1
        } else {
            do {
                try profileStore.completeOnboarding(name: name, usagePreference: profileStore.profile.usagePreference)
                onFinish?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
