import Foundation
import Testing

/// A costura entre os dois motores da prévia.
///
/// O gate da Onda 4 proíbe frase duplicada na troca de fonte. Estes testes prendem a regra que
/// impede isso: a divisão é por tempo de áudio, e nunca existe um instante coberto pelos dois.
@Suite("Costura da prévia entre Whisper e Apple")
struct MeetingPreviewComposerTests {

    typealias Composer = MeetingPreviewComposer

    @Test("Antes do Apple entregar, a prévia é a janela do Whisper")
    func whisperCarriesTheStart() {
        let texto = Composer.compose(
            segments: [],
            tail: .init(startsAt: 0, text: "bom dia pessoal")
        )

        #expect(texto == "bom dia pessoal")
        #expect(Composer.appleHasTakenOver(segments: [], tail: .init(startsAt: 0, text: "x")) == false)
    }

    @Test("Quando o Apple cobre a janela do Whisper, o texto do Whisper sai — não soma")
    func appleReplacesTheOverlap() {
        // O caso que o gate proíbe: os dois reconheceram a mesma fala. Se o composer somasse, a
        // pessoa leria a frase duas vezes na tela.
        let texto = Composer.compose(
            segments: [.init(start: 0, end: 12, text: "bom dia pessoal tudo certo")],
            tail: .init(startsAt: 6, text: "bom dia pessoal")
        )

        #expect(texto == "bom dia pessoal tudo certo")
    }

    @Test("A ponta que o Apple ainda não alcançou continua aparecendo")
    func tailBeyondAppleIsKept() {
        let texto = Composer.compose(
            segments: [.init(start: 0, end: 12, text: "bom dia pessoal")],
            tail: .init(startsAt: 12, text: "vamos começar")
        )

        #expect(texto == "bom dia pessoal vamos começar")
    }

    @Test("Resultados finais fora de ordem saem na ordem do áudio")
    func segmentsAreOrderedByAudioTime() {
        // A sonda de 27/08 mostrou o primeiro final chegando cobrindo 24,60–33,60 enquanto o
        // trecho anterior ainda não tinha chegado: ordenar pela chegada embaralharia a reunião.
        let texto = Composer.compose(
            segments: [
                .init(start: 24.6, end: 33.6, text: "segunda parte"),
                .init(start: 0, end: 24.6, text: "primeira parte"),
            ],
            tail: nil
        )

        #expect(texto == "primeira parte segunda parte")
    }

    @Test("Segmento vazio não vira espaço solto no meio da prévia")
    func emptySegmentsAreDropped() {
        let texto = Composer.compose(
            segments: [
                .init(start: 0, end: 5, text: "olá"),
                .init(start: 5, end: 9, text: "   "),
                .init(start: 9, end: 14, text: "tudo bem"),
            ],
            tail: nil
        )

        #expect(texto == "olá tudo bem")
    }

    @Test("Sem nada de nenhum dos dois, a prévia é vazia — não é espaço nem lixo")
    func nothingYieldsEmpty() {
        #expect(Composer.compose(segments: [], tail: nil).isEmpty)
        #expect(Composer.compose(segments: [], tail: .init(startsAt: 0, text: "  ")).isEmpty)
    }

    @Test("A troca é detectada quando o Apple ultrapassa o início da janela")
    func takeoverIsDetected() {
        let antes = Composer.appleHasTakenOver(
            segments: [.init(start: 0, end: 4, text: "a")],
            tail: .init(startsAt: 6, text: "b")
        )
        let depois = Composer.appleHasTakenOver(
            segments: [.init(start: 0, end: 8, text: "a")],
            tail: .init(startsAt: 6, text: "b")
        )

        #expect(antes == false)
        #expect(depois)
    }

    /// O caso real de 27/08: 25 segundos sem nada do Apple, e depois ele chega cobrindo tudo.
    @Test("No caso medido, a prévia nunca fica vazia nem repete")
    func measuredHandoffNeverDuplicatesNorBlanks() {
        // Segundos 0–25: só o Whisper, janela andando.
        var texto = Composer.compose(segments: [], tail: .init(startsAt: 18, text: "parte inicial"))
        #expect(texto == "parte inicial")

        // Aos 25,8s o Apple entrega de uma vez o trecho que o Whisper vinha cobrindo.
        let appleChegou: [Composer.Segment] = [.init(start: 0, end: 26, text: "parte inicial corrigida")]
        texto = Composer.compose(segments: appleChegou, tail: .init(startsAt: 18, text: "parte inicial"))
        #expect(texto == "parte inicial corrigida")

        // E daí em diante a ponta volta a aparecer, já depois do que o Apple cobriu.
        texto = Composer.compose(segments: appleChegou, tail: .init(startsAt: 26, text: "continuando"))
        #expect(texto == "parte inicial corrigida continuando")
    }
}

/// O acúmulo dos resultados do Apple antes de chegarem ao compositor.
@Suite("Acúmulo dos resultados do Apple")
struct MeetingPreviewAppleBufferTests {

    private func update(_ start: Double, _ end: Double, _ text: String, final: Bool)
        -> MeetingPreviewAppleBuffer.Update
    {
        .init(segment: .init(start: start, end: end, text: text), isFinal: final)
    }

    @Test("Voláteis do mesmo trecho não se acumulam — só o último vale")
    func volatileResultsReplaceEachOther() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(0, 2, "bom", final: false))
        buffer.apply(update(0, 4, "bom dia", final: false))
        buffer.apply(update(0, 6, "bom dia pessoal", final: false))

        #expect(buffer.segments.count == 1)
        #expect(buffer.segments.first?.text == "bom dia pessoal")
    }

    @Test("O final substitui o volátil do mesmo intervalo")
    func finalReplacesVolatile() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(0, 6, "bom dia pesoal", final: false))
        buffer.apply(update(0, 6, "bom dia pessoal", final: true))

        #expect(buffer.segments.map(\.text) == ["bom dia pessoal"])
    }

    @Test("Finais fora de ordem ficam na ordem do áudio")
    func finalsAreKeptInAudioOrder() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(24.6, 33.6, "segunda", final: true))
        buffer.apply(update(0, 24.6, "primeira", final: true))

        #expect(buffer.segments.map(\.text) == ["primeira", "segunda"])
    }

    @Test("Final que reescreve um intervalo já final não duplica")
    func overlappingFinalsReplace() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(0, 10, "versão antiga", final: true))
        buffer.apply(update(0, 12, "versão corrigida", final: true))

        #expect(buffer.segments.map(\.text) == ["versão corrigida"])
    }

    @Test("O volátil só aparece na parte que os finais ainda não cobrem")
    func volatileOnlyShowsBeyondFinals() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(0, 10, "fechado", final: true))
        buffer.apply(update(4, 8, "atrasado", final: false))
        #expect(buffer.segments.map(\.text) == ["fechado"])

        buffer.apply(update(10, 14, "novo", final: false))
        #expect(buffer.segments.map(\.text) == ["fechado", "novo"])
    }

    @Test("Bloco fechado é descartado sem levar o que veio depois")
    func droppingCommittedKeepsTheRest() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(0, 10, "bloco antigo", final: true))
        buffer.apply(update(10, 18, "bloco novo", final: true))

        buffer.commitFrontier(at: 10)

        #expect(buffer.segments.map(\.text) == ["bloco novo"])
    }

    @Test("Intervalo degenerado é ignorado")
    func degenerateRangesAreIgnored() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(5, 5, "vazio", final: true))

        #expect(buffer.segments.isEmpty)
    }
}

/// A fronteira do bloco: o que já foi para a tela não pode voltar.
///
/// Defeito visto pelo humano em reunião real (27/08): a prévia repetiu blocos inteiros. O bloco
/// fechava com o texto do Whisper e, 0,66s depois, os resultados finais do analisador chegavam
/// cobrindo o MESMO trecho — e entravam no bloco seguinte.
@Suite("Fronteira do bloco na prévia")
struct MeetingPreviewFrontierTests {

    private func update(_ start: Double, _ end: Double, _ text: String, final: Bool)
        -> MeetingPreviewAppleBuffer.Update
    {
        .init(segment: .init(start: start, end: end, text: text), isFinal: final)
    }

    @Test("Final atrasado sobre trecho já entregue é descartado, não vira bloco novo")
    func lateFinalOverCommittedAudioIsDropped() {
        var buffer = MeetingPreviewAppleBuffer()
        // O bloco visual fechou cobrindo tudo até 20s — o Whisper já mostrou isso na tela.
        buffer.commitFrontier(at: 20)

        // O analisador entrega, atrasado, o trecho que já foi para a tela.
        buffer.apply(update(6, 19, "então vamos fazer isso", final: true))

        #expect(buffer.segments.isEmpty, "trecho já entregue voltou para a prévia")
    }

    @Test("Depois da fronteira, o que é novo continua entrando")
    func contentAfterTheFrontierStillArrives() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.commitFrontier(at: 20)

        buffer.apply(update(20, 26, "parte nova", final: true))

        #expect(buffer.segments.map(\.text) == ["parte nova"])
    }

    /// Este teste afirmava o CONTRÁRIO até 27/08/2026, e o contrário era o bug.
    ///
    /// A ideia era "a parte nova dele importa, então deixa entrar". Só que o texto vem inteiro, sem
    /// dizer onde acaba a parte velha — e a parte velha já estava na tela. Em reunião real isso
    /// repetiu blocos inteiros. O teste verde estava defendendo o defeito.
    @Test("Resultado que cruza a fronteira é descartado inteiro")
    func straddlingResultIsDropped() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.commitFrontier(at: 20)

        buffer.apply(update(18, 25, "atravessa o corte", final: true))

        #expect(buffer.segments.isEmpty)
    }
}

/// Reprodução do defeito de 27/08 com os intervalos REAIS que a sonda mediu.
///
/// Finais disjuntos e sequenciais (0–22,26 / 22,26–34,56 / 34,56–45,90) e um bloco visual que fecha
/// no meio do segundo deles. Antes da correção, o resultado que atravessava o corte reaparecia com
/// a fala que já estava na tela.
@Suite("Reprodução: bloco repetido na reunião real")
struct MeetingPreviewRealMeetingRegressionTests {

    private func update(_ start: Double, _ end: Double, _ text: String)
        -> MeetingPreviewAppleBuffer.Update
    {
        .init(segment: .init(start: start, end: end, text: text), isFinal: true)
    }

    @Test("Bloco fechado no meio de um resultado não volta na prévia seguinte")
    func committedBlockDoesNotComeBack() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(update(0, 22.26, "imagino que precisemos de um engenheiro um criativo"))

        // O Whisper fechou o bloco aos 30s e essa fala já foi para a tela.
        buffer.commitFrontier(at: 30)

        // O analisador entrega o trecho que atravessa o corte, com a fala já exibida dentro.
        buffer.apply(update(22.26, 34.56, "um criativo e mais importante quero fazer experimentos"))

        #expect(buffer.segments.isEmpty, "a fala do bloco fechado voltou para a prévia")

        // O próximo, que começa limpo depois do corte, entra normalmente.
        buffer.apply(update(34.56, 45.90, "no fim das contas quero que você controle tudo"))
        #expect(buffer.segments.map(\.text) == ["no fim das contas quero que você controle tudo"])
    }
}

/// A junção dos blocos no view model.
///
/// Defeito de 27/08: o VM costura hipóteses procurando até 24 palavras de sobreposição, porque a
/// janela do Whisper repete o fim da anterior. O texto composto pelos dois motores NÃO repete — e
/// quando a costura não achava sobreposição, ela anexava o bloco inteiro ao prefixo, repetindo tudo
/// na tela.
@Suite("Junção de blocos da prévia")
struct MeetingPreviewJoinTests {

    @Test("Blocos são concatenados, sem procurar sobreposição")
    func blocksAreConcatenated() {
        let texto = MeetingPreviewComposer.join(
            prefix: "certo vamos analisar esta lista",
            block: "certo vamos analisar esta lista primeiro"
        )

        // Mesmo com repetição aparente, a junção NÃO tenta adivinhar: quem garante que não há
        // sobreposição é a divisão por tempo de áudio, lá no compositor. Heurística de texto aqui
        // seria a mesma que falhou na supressão de eco.
        #expect(texto == "certo vamos analisar esta lista certo vamos analisar esta lista primeiro")
    }

    @Test("Prefixo vazio devolve o bloco, e bloco vazio devolve o prefixo")
    func emptySidesAreHandled() {
        #expect(MeetingPreviewComposer.join(prefix: "", block: "olá") == "olá")
        #expect(MeetingPreviewComposer.join(prefix: "olá", block: "   ") == "olá")
        #expect(MeetingPreviewComposer.join(prefix: "  ", block: "  ").isEmpty)
    }
}

/// Admissão e limpeza têm que usar a MESMA régua.
@Suite("Fronteira: limpar e admitir pelo mesmo critério")
struct MeetingPreviewFrontierConsistencyTests {

    @Test("Trecho já guardado que atravessa o corte é limpo, não sobrevive para o bloco seguinte")
    func straddlingStoredSegmentIsCleared() {
        var buffer = MeetingPreviewAppleBuffer()
        // Guardado ANTES do corte, atravessando-o.
        buffer.apply(.init(segment: .init(start: 10, end: 25, text: "atravessa"), isFinal: true))

        buffer.commitFrontier(at: 20)

        // Ele já foi exibido no bloco que fechou; deixá-lo aqui o mostraria duas vezes.
        #expect(buffer.segments.isEmpty)
    }

    @Test("Volátil que atravessa o corte também sai")
    func straddlingVolatileIsCleared() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(.init(segment: .init(start: 10, end: 25, text: "parcial"), isFinal: false))

        buffer.commitFrontier(at: 20)

        #expect(buffer.segments.isEmpty)
    }
}

/// Reprodução do defeito de 27/08 no modo de um motor só, com as faixas medidas.
@Suite("Volátil sobreposto a um final")
struct MeetingPreviewOverlappingVolatileTests {

    @Test("Volátil que começa dentro do que os finais cobrem não é exibido")
    func overlappingVolatileIsHidden() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(.init(
            segment: .init(start: 59.10, end: 71.94, text: "eu devia ter restarado ele"),
            isFinal: true
        ))
        // Mesmo início, alguns décimos a mais no fim: é a MESMA fala, em outra versão.
        buffer.apply(.init(
            segment: .init(start: 59.10, end: 72.25, text: "eu devia restarado ele"),
            isFinal: false
        ))

        #expect(buffer.segments.map(\.text) == ["eu devia ter restarado ele"])
    }

    @Test("Volátil que começa depois dos finais continua aparecendo")
    func volatileBeyondFinalsStillShows() {
        var buffer = MeetingPreviewAppleBuffer()
        buffer.apply(.init(segment: .init(start: 0, end: 10, text: "fechado"), isFinal: true))
        buffer.apply(.init(segment: .init(start: 10, end: 14, text: "novo"), isFinal: false))

        #expect(buffer.segments.map(\.text) == ["fechado", "novo"])
    }
}
