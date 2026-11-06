import SwiftUI

struct DictationPreferencesView: View {
    @Binding var settings: AppSettings

    var body: some View {
        SettingsGroup(title: "Vocabulário e correções") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vocabulário personalizado")
                        .font(.system(size: 14, weight: .medium))
                    Text("Nomes, siglas e termos que o Voiz deve reconhecer. Um por linha.")
                        .font(.system(size: 12))
                        .foregroundStyle(VoizTheme.mutedText)
                }
                TextEditor(text: $settings.dictationVocabulary)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(VoizTheme.surfaceBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Vocabulário personalizado")
                HStack {
                    Button("Adicionar termos de programação") {
                        let terms = TranscriptionContext.terms(from: settings.dictationVocabulary + "\nauth\nOAuth\nAPI\nGitHub\nTypeScript\nSwift\nKubernetes\npull request\nmerge\ndeploy\ncommit\nbranch")
                        settings.dictationVocabulary = terms.joined(separator: "\n")
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                    Spacer()
                }
            }
            .padding(16)

            SettingsDivider()
            SettingsRow(
                icon: "text.bubble",
                title: "Interpretar correções faladas",
                subtitle: "“laranja, corrigindo, amarelo” vira “amarelo”."
            ) {
                Toggle("Interpretar correções faladas", isOn: $settings.dictationCorrectionsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(VoizTheme.accent)
            }
            if settings.dictationCorrectionsEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Marcadores de correção — um por linha")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $settings.dictationCorrectionMarkers)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 95)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(VoizTheme.surfaceBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Marcadores de correção — um por linha")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}
