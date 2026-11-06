import Testing
import Foundation

/// A guarda do ganho do áudio limpo: `microphone-clean.caf` é a faixa que o **player** toca, e ela
/// não pode morrer no meio de uma reunião longa.
///
/// O bug que esta suíte trava foi achado numa entrevista real de 79 min: o arquivo era silêncio
/// absoluto de 30:10 até o fim — 62% da gravação sem a voz do usuário. A causa não estava no
/// detector de eco (medido, ele marcava eco em ~35% das janelas), e sim em `boxSmooth`, que suaviza
/// o ganho para não estalar nas bordas dos trechos silenciados: a soma-prefixo era `[Float]`.
///
/// O ganho é quase todo 1, então a soma cresce **uma unidade por amostra**. Ao chegar em
/// 2²⁴ = 16.777.216 o arredondamento do `Float` passa a engolir o `+1` e a soma **congela**; daí em
/// diante `prefix[b] - prefix[a]` vale 0 para qualquer janela, o ganho vira 0 e nunca mais volta.
/// O corte é permanente, não um trecho ruim: a partir de um ponto, tudo é silêncio.
///
/// Por que o teste é grande de propósito: a falha só existe **acima** de 2²⁴ amostras acumuladas.
/// Um array pequeno passa nas duas versões do código, e um teste que passa antes e depois não
/// guarda nada. Os ~17,1 M de amostras aqui são 17,8 min de áudio a 16 kHz — o mínimo que cruza a
/// fronteira, e uma fração do que uma reunião real acumula.
@Suite("Reunião — o ganho do mic limpo sobrevive a arquivos longos")
struct MeetingEchoGainSmoothingTests {

    /// Mesmo raio da produção (`Int(0.010 * 16000)`): a rampa de ~10 ms nas bordas do eco.
    private static let radius = 160
    /// Uma amostra além de 2²⁴, mais folga para medir depois da fronteira.
    private static let sampleCount = 17_100_000

    @Test("Ganho 1 continua 1 depois de 2²⁴ amostras — a faixa limpa não silencia no meio")
    func gainSurvivesPastFloatPrecisionCliff() {
        var gain = [Float](repeating: 1, count: Self.sampleCount)
        MeetingEchoReconciler.boxSmooth(&gain, radius: Self.radius)

        // Antes da correção: 1,0 no começo e 0,0 em qualquer ponto além de 2²⁴ (16.777.216).
        #expect(abs(gain[1_000] - 1) < 1e-4)
        #expect(abs(gain[16_000_000] - 1) < 1e-4)
        #expect(abs(gain[16_777_217] - 1) < 1e-4)
        #expect(abs(gain[17_000_000] - 1) < 1e-4)

        // E o colapso era total, não um desvio: nenhuma amostra pode ter sido zerada.
        let mudos = gain.filter { $0 < 0.5 }.count
        #expect(mudos == 0)
    }

    /// O contrapeso do teste acima: consertar a precisão não pode ter apagado o que a suavização
    /// existe para fazer. Sem a rampa, o corte do eco estala no playback.
    @Test("A rampa de 10 ms nas bordas do trecho silenciado continua linear")
    func rampIsPreservedAtEchoEdges() {
        let sampleRate = 16_000
        var gain = [Float](repeating: 1, count: 10 * sampleRate)
        let echoStart = 4 * sampleRate
        let echoEnd = 6 * sampleRate
        for i in echoStart..<echoEnd { gain[i] = 0 }
        MeetingEchoReconciler.boxSmooth(&gain, radius: Self.radius)

        // Longe da borda, nada mudou.
        #expect(abs(gain[sampleRate] - 1) < 1e-4)
        #expect(abs(gain[5 * sampleRate]) < 1e-4)

        // No centro exato da transição, meio ganho; e a rampa é monótona descendo.
        #expect(abs(gain[echoStart] - 0.5) < 0.02)
        // `through`, e não `to`: a rampa só chega a zero na última amostra da janela (i + radius),
        // que é exatamente onde ela termina.
        let rampa = stride(from: echoStart - Self.radius, through: echoStart + Self.radius, by: 40).map { gain[$0] }
        #expect(zip(rampa, rampa.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(rampa.first! > 0.9)
        #expect(rampa.last! < 0.1)
    }
}
