import Foundation
import Testing

@Suite("Guarda de idioma — privacidade")
struct TranscriptionLanguagePrivacyTests {
    private static func guardSource(_ name: String, file: String = #filePath) throws -> String {
        let seam = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .appendingPathComponent("LanguageSeam")
        let source = try String(contentsOf: seam.appendingPathComponent(name), encoding: .utf8)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Os componentes da guarda não logam nem recebem texto reconhecido")
    func guardComponentsNeverLog() throws {
        for name in ["TranscriptionLanguageProbe.swift", "TranscriptionLanguageGuard.swift"] {
            let source = try Self.guardSource(name)
            #expect(!source.isEmpty)
            #expect(!source.contains("print("))
            #expect(!source.contains(".text"))
        }
    }

    @Test("A linha de log do probe traz idioma e duração, sem transcript")
    func probeLogSummaryIsRedactedByConstruction() {
        let corrected = TranscriptionLanguageProbe.logSummary(
            .corrects(to: .portuguese),
            planned: .english,
            speechSeconds: 30
        )
        #expect(corrected.contains("en"))
        #expect(corrected.contains("pt"))
        #expect(corrected.contains("30 s de fala"))

        let kept = TranscriptionLanguageProbe.logSummary(
            .keepsPlan(.engineDoesNotDetect(.parakeet)),
            planned: .portuguese,
            speechSeconds: 12
        )
        #expect(kept.contains("parakeet"))
        #expect(kept.contains("não detecta idioma"))

        let sovereign = TranscriptionLanguageProbe.logSummary(
            .keepsPlan(.explicitLanguageIsSovereign(detected: .english)),
            planned: .portuguese,
            speechSeconds: 30
        )
        #expect(sovereign.contains("pt"))
        #expect(sovereign.contains("en"))
        #expect(sovereign.contains("explícita"))
        #expect(sovereign.contains("ignorada"))
    }
}
