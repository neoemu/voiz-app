import Testing

/// Sentinela da fundação (T1.1): existe só para provar que o alvo `voizTests` compila,
/// é empacotado e roda em `xcodebuild test`. As ondas seguintes penduram os testes reais
/// de transcrição neste mesmo alvo.
///
/// O alvo é um bundle de teste **sem host app**: o `voiz.app` pede permissão de
/// Acessibilidade e inicializa o serviço de transcrição já no `init` do
/// `TranscriptionViewModel`, então usá-lo como `TEST_HOST` travaria a suíte em diálogos
/// do sistema. Código de produção que precisar de cobertura entra no alvo de teste por
/// arquivo (build phase Sources), não via `@testable import voiz`.
@Suite("Fundação")
struct SentinelTests {
    @Test("O alvo de testes está vivo")
    func targetIsWired() {
        #expect(Bool(true))
    }
}
