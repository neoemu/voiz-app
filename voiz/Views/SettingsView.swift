import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var notionToken = ""
    @State private var notionDestination = ""
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("Idioma") {
                Picker("Idioma padrão", selection: $viewModel.settings.selectedLanguage) {
                    ForEach(Language.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
            
            Section("Modelo") {
                Picker("Tamanho do modelo", selection: $viewModel.settings.modelSize) {
                    ForEach(AppSettings.ModelSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                
                Text("⚠️ Ao trocar de modelo, ele é baixado no primeiro uso (pode levar alguns segundos)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            Section("API de Tradução") {
                if viewModel.hasCredentialDrafts {
                    Text(verbatim: viewModel.credentialDraftMessage)
                    Button(action: viewModel.saveCredentialEdits) {
                        Text(verbatim: viewModel.credentialSaveTitle)
                    }
                    .disabled(viewModel.isSavingCredentials)
                }
                if viewModel.isSavingCredentials {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(verbatim: viewModel.credentialSavingTitle)
                    }
                }
                if viewModel.hasCredentialError {
                    Text(verbatim: viewModel.credentialErrorMessage)
                        .foregroundStyle(.red)
                    Button(action: viewModel.retryCredentialAccess) {
                        Text(verbatim: viewModel.credentialRetryTitle)
                    }
                    .disabled(viewModel.isSavingCredentials)
                }
                Picker("Provedor", selection: $viewModel.settings.translationProvider) {
                    ForEach(AppSettings.TranslationProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                switch viewModel.settings.translationProvider {
                case .openai:
                    SecureField("OpenAI API Key", text: viewModel.credentialBinding(.openAIKey))
                        .font(.system(.body, design: .monospaced))

                    Text("Obtenha em platform.openai.com")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Modelo", selection: $viewModel.settings.translationModel) {
                        ForEach(AppSettings.TranslationModel.allCases, id: \.self) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model)
                        }
                    }
                case .anthropic:
                    SecureField("Anthropic API Key", text: viewModel.credentialBinding(.anthropicKey))
                        .font(.system(.body, design: .monospaced))

                    Text("Obtenha em console.anthropic.com")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Modelo", selection: $viewModel.settings.anthropicModel) {
                        ForEach(AppSettings.AnthropicModel.allCases, id: \.self) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model)
                        }
                    }
                case .xai:
                    SecureField("xAI API Key", text: viewModel.credentialBinding(.xaiKey))
                        .font(.system(.body, design: .monospaced))

                    Text("Obtenha em console.x.ai")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Modelo", selection: $viewModel.settings.xaiModel) {
                        ForEach(AppSettings.XAIModel.allCases, id: \.self) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model)
                        }
                    }
                case .gemini:
                    SecureField("Gemini API Key", text: viewModel.credentialBinding(.geminiKey))
                        .font(.system(.body, design: .monospaced))

                    Text("Obtenha em aistudio.google.com/apikey")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Modelo", selection: $viewModel.settings.geminiModel) {
                        ForEach(AppSettings.GeminiModel.allCases, id: \.self) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model)
                        }
                    }
                case .custom:
                    TextField("Endpoint (URL OpenAI-compatible)", text: $viewModel.settings.customBaseURL)
                        .font(.system(.body, design: .monospaced))

                    Text("Ex.: http://localhost:4000 (seu LiteLLM ou proxy)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SecureField("API Key", text: viewModel.credentialBinding(.customKey))
                        .font(.system(.body, design: .monospaced))

                    TextField("Modelo (nome exato no seu endpoint)", text: $viewModel.settings.customModel)
                        .font(.system(.body, design: .monospaced))
                }

                let supportedEfforts = viewModel.settings.supportedReasoningEfforts
                if !supportedEfforts.isEmpty {
                    // Mesmo motivo do painel principal: mostra o valor já grampeado na faixa
                    // do modelo, não o guardado.
                    let effortBinding = Binding(
                        get: { viewModel.settings.effectiveReasoningEffort },
                        set: { viewModel.settings.reasoningEffort = $0 }
                    )
                    Picker("Raciocínio", selection: effortBinding) {
                        ForEach([AppSettings.ReasoningEffort.auto] + supportedEfforts, id: \.self) { effort in
                            VStack(alignment: .leading) {
                                Text(effort.displayName)
                                Text(effort.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .tag(effort)
                        }
                    }
                }
            }
            
            Section("Comportamento") {
                Toggle("Inserir texto automaticamente", isOn: $viewModel.settings.autoInsertText)
                
                Toggle("Mostrar confiança", isOn: $viewModel.settings.showConfidence)
            }

            Section("Reuniões") {
                Picker("Modo de reunião", selection: $viewModel.settings.meetingMode) {
                    ForEach(AppSettings.MeetingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(viewModel.settings.meetingMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if viewModel.settings.meetingMode == .granola {
                    LabeledContent("Engine ao vivo", value: "Apple SpeechAnalyzer")
                    Text("Apple SpeechAnalyzer do sistema, otimizado para transcrição contínua e usado automaticamente.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Toggle("Prévia ao vivo contínua (1s)", isOn: $viewModel.settings.meetingLivePreviewEnabled)
                    Text("Prévia opcional do modo Qualidade. Pode aumentar o uso de CPU e bateria; não altera o transcript final.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Notion") {
                SecureField("Token do Notion", text: $notionToken)
                    .font(.system(.body, design: .monospaced))
                Text("Internal Integration Token. Cole o secret_ da sua integração.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Destino no Notion", text: $notionDestination)
                    .font(.system(.body, design: .monospaced))
                Text("URL ou ID da página ou database. Compartilhe o destino com a integração.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Permissões") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Acessibilidade")
                                .font(.body)
                            Text(AccessibilityPermissionService.shared.isTrusted ? "✅ Concedida" : "⚠️ Necessária para auto-paste")
                                .font(.caption)
                                .foregroundColor(AccessibilityPermissionService.shared.isTrusted ? .green : .orange)
                        }
                        Spacer()
                    }
                    
                    if !AccessibilityPermissionService.shared.isTrusted {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Como ativar:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            
                            Text("1. Clique em 'Mostrar App' para revelar o app no Finder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("2. Clique em 'Abrir Ajustes' nas configurações de Acessibilidade")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("3. Clique no '+' e selecione o 'voiz.app' revelado no Finder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("4. Ative o switch ao lado do Voiz")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 12) {
                                Button("Mostrar App no Finder") {
                                    AccessibilityPermissionService.shared.revealAppInFinder()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Abrir Ajustes") {
                                    AccessibilityPermissionService.shared.openAccessibilitySettings()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            
            Section("Atalhos de ditado") {
                Toggle("Ativar atalhos de ditado (Fn)", isOn: $viewModel.settings.dictationHotkeysEnabled)

                if viewModel.settings.dictationHotkeysEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Segurar para falar (push-to-talk)")
                            .font(.subheadline)
                        HotKeyRecorder(shortcut: $viewModel.settings.pushToTalkShortcut)
                        Button("Restaurar padrão (Fn)") {
                            viewModel.settings.pushToTalkShortcut = .fnPushToTalk
                        }
                        .buttonStyle(.link)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mãos livres (toca pra alternar)")
                            .font(.subheadline)
                        HotKeyRecorder(shortcut: $viewModel.settings.handsFreeShortcut)
                        Button("Restaurar padrão (Fn+Espaço)") {
                            viewModel.settings.handsFreeShortcut = .fnSpaceHandsFree
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            
            Section("Interface") {
                Picker("Aparência", selection: $viewModel.settings.appearance) {
                    ForEach(AppSettings.InterfaceAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }

                Toggle("Mostrar indicador de gravação", isOn: $viewModel.settings.showRecordingHUD)

                Text("O indicador visual aparece sobre outros apps durante ditados e reuniões")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Notch como status (experimental)", isOn: $viewModel.settings.notchOverlayEnabled)

                Text("Mostra a gravação e avisos ao redor do notch do MacBook")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Sobre") {
                HStack {
                    Text("Versão")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                
                Link("GitHub", destination: URL(string: "https://github.com")!)
            }
        }
        .formStyle(.grouped)
            
            HStack(spacing: 12) {
                Button("Cancelar") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Salvar") {
                    saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSavingCredentials || viewModel.hasCredentialError || viewModel.hasCredentialDrafts)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 520)
        .preferredColorScheme(viewModel.settings.appearance.colorScheme)
        .onAppear {
            notionToken = NotionCredentialsStore.shared.token()
            notionDestination = NotionCredentialsStore.shared.destination()
        }
    }
    
    private func saveSettings() {
        // Força o salvamento das configurações
        let settingsStore = SettingsStore()
        settingsStore.saveWithSync(viewModel.settings)
        NotionCredentialsStore.shared.setToken(notionToken)
        NotionCredentialsStore.shared.setDestination(notionDestination)

        let keyInfo = viewModel.settings.currentAPIKey.isEmpty ? "VAZIA" : "CONFIGURADA"
        print("✅ Configurações salvas!")
        print("   - Provedor: \(viewModel.settings.translationProvider.displayName)")
        print("   - API Key: \(keyInfo)")
        print("   - Modelo: \(viewModel.settings.currentModelId)")

        // Notifica que as configurações mudaram
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }
}

#Preview {
    SettingsView()
        .environmentObject(TranscriptionViewModel())
}
