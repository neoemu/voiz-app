import Foundation
import ApplicationServices
import AppKit

final class AccessibilityPermissionService {
    static let shared = AccessibilityPermissionService()
    
    private init() {}
    
    func ensurePrompt() {
        let trusted = AXIsProcessTrusted()
        print("🔐 AccessibilityPermissionService.ensurePrompt() - isTrusted: \(trusted)")
        print("   Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
        print("   Process name: \(ProcessInfo.processInfo.processName)")
        
        guard !trusted else {
            print("   ✅ Já confiável, não precisa prompt")
            return
        }
        
        print("   ⚠️ Não confiável, mostrando prompt...")
        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        
        // Check again after prompt
        let trustedAfter = AXIsProcessTrusted()
        print("   Após prompt - isTrusted: \(trustedAfter)")
    }
    
    func openAccessibilitySettings() {
        print("🔧 Abrindo configurações de Acessibilidade...")
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    func revealAppInFinder() {
        print("📂 Revelando app no Finder...")
        if let bundlePath = Bundle.main.bundlePath as String? {
            let url = URL(fileURLWithPath: bundlePath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            print("   Path: \(bundlePath)")
        }
    }
    
    var isTrusted: Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("🔐 AccessibilityPermissionService.isTrusted getter:")
            print("   Result: \(trusted)")
            print("   Bundle ID: \(Bundle.main.bundleIdentifier ?? "nil")")
            print("   Process name: \(ProcessInfo.processInfo.processName)")
            print("   Executable path: \(Bundle.main.executablePath ?? "nil")")
        }
        return trusted
    }
}
