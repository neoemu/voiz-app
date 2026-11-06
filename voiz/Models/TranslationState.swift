import Foundation

enum TranslationIssue: Equatable {
    case missingAPIKey(provider: String)
    case credentialsUnavailable
    case requestFailed

    static func configuration(in settings: AppSettings, credentialsAreReady: Bool = true) -> Self? {
        guard credentialsAreReady else { return nil }
        guard settings.translationProvider.requiresAPIKey,
              settings.currentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .missingAPIKey(provider: settings.translationProvider.displayName)
    }

    func afterSettingsReload(settingsChanged: Bool, credentialsAreReady: Bool) -> Self? {
        if self == .credentialsUnavailable {
            return credentialsAreReady ? nil : self
        }
        return settingsChanged ? nil : self
    }

    var message: String {
        switch self {
        case .missingAPIKey(let provider):
            return String(localized: "Configure a chave de \(provider) em Configurações → IA & Tradução para começar.")
        case .credentialsUnavailable:
            return String(localized: "Não foi possível acessar as chaves de API. Tente novamente em Configurações → IA & Tradução.")
        case .requestFailed:
            // Provider errors can echo request content. Keep those details out of this notice and logs.
            return String(localized: "Não foi possível traduzir. Verifique a conexão e a configuração do provedor de IA.")
        }
    }
}

nonisolated enum TranslationArchiveNotice: Equatable {
    case complete
    case missingTail
    case translationIncomplete

    static func result(drainCompleted: Bool, translationFailed: Bool) -> Self {
        if translationFailed { return .translationIncomplete }
        return drainCompleted ? .complete : .missingTail
    }

    /// An archived original is not proof of a successful translation. Keep it visible after a failure.
    var shouldClearWorkspace: Bool { self != .translationIncomplete }

    var message: String {
        switch self {
        case .complete: return String(localized: "Salvo em Recentes")
        case .missingTail: return String(localized: "Salvo em Recentes (sem o final)")
        case .translationIncomplete: return String(localized: "Original salvo; tradução incompleta")
        }
    }
}
