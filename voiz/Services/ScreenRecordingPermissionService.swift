import Foundation
import CoreGraphics
import AppKit

/// Permissão de **Gravação de Tela** — é ela que o `ScreenCaptureKit` exige para capturar o
/// **áudio do sistema** (a faixa "Outros" das reuniões). É uma permissão TCC *separada* da
/// Acessibilidade (`AccessibilityPermissionService`): conceder uma não concede a outra.
///
/// Sem ela, o `system-audio.caf` sai vazio e tudo cai no microfone — por isso o serviço espelha
/// o de Acessibilidade (preflight + request + deep-link para Ajustes) para guiar o usuário.
///
/// Persistência em build de dev: o macOS amarra a permissão à *assinatura* do app. O mesmo cert
/// estável "Voiz Dev" que mantém a Acessibilidade entre rebuilds mantém esta também — desde que
/// concedida uma vez. Ver [[voiz-signing-accessibility]].
final class ScreenRecordingPermissionService {
    static let shared = ScreenRecordingPermissionService()

    private init() {}

    /// Já concedida? Não dispara prompt (`CGPreflightScreenCaptureAccess`).
    var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Dispara o prompt do sistema (uma vez por "vida" do app não-concedido). Retorna o estado
    /// resultante. O macOS só mostra o diálogo na 1ª vez; depois é preciso ir aos Ajustes.
    @discardableResult
    func requestAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let granted = CGRequestScreenCaptureAccess()
        print("🔐 ScreenRecordingPermissionService.requestAccess() → granted: \(granted)")
        return granted
    }

    func openScreenRecordingSettings() {
        print("🔧 Abrindo Ajustes → Gravação de Tela…")
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func revealAppInFinder() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
