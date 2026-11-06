import AppKit
import Foundation

/// Aplica o idioma da interface escolhido nas Configurações.
///
/// Não existe troca de idioma a quente no macOS: o bundle resolve a localização **uma vez**, no
/// launch, e tanto o SwiftUI quanto os `String(localized:)` espalhados pelos serviços leem dali.
/// Forçar só o `Environment(\.locale)` traduziria as telas e deixaria descrições de enum e mensagens
/// de erro no idioma antigo — pior que não trocar. Então gravamos a preferência e reiniciamos.
enum InterfaceLanguageService {
    /// Chave que o macOS lê para decidir a localização do bundle.
    private static let appleLanguagesKey = "AppleLanguages"

    /// Persiste a escolha. Só tem efeito no próximo launch.
    static func apply(_ language: AppSettings.InterfaceLanguage) {
        let defaults = UserDefaults.standard
        if let code = language.localeCode {
            defaults.set([code], forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
        defaults.synchronize()
    }

    /// A escolha salva já é a que está rodando? Serve para a UI só oferecer reiniciar quando adianta.
    static func isPending(_ language: AppSettings.InterfaceLanguage) -> Bool {
        let running = Bundle.main.preferredLocalizations.first ?? ""
        guard let desired = language.localeCode else {
            // Em `system`, o que vale é não haver preferência gravada.
            return UserDefaults.standard.array(forKey: appleLanguagesKey) != nil
        }
        // "pt-BR" contra "pt", "en-US" contra "en": comparar pelo prefixo de idioma.
        return !running.hasPrefix(desired.prefix(2))
    }

    /// Abre uma instância nova e encerra a atual.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
