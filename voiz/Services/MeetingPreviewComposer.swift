import Foundation

/// Junta o que dois motores produzem para a MESMA gravação em um texto de prévia.
///
/// A prévia da reunião tem dois problemas que nenhum motor resolve sozinho, medidos em 27/08/2026
/// com áudio real de reunião:
///
/// - o `SpeechAnalyzer` do sistema é o mais preciso e o mais barato (≈2% de um núcleo somando app e
///   daemon), com parciais a cada 3ms depois que engata — mas em áudio com fala sobreposta ele
///   pode segurar **25 segundos** antes de mostrar a primeira palavra;
/// - a janela deslizante do Whisper aparece em ~1s sempre, e é o pior dos motores medidos em
///   qualidade (28,64% de WER contra 15,16%).
///
/// Daí a divisão por TEMPO DE ÁUDIO, e não por texto: o Apple manda em todo trecho que ele já
/// cobriu, e o Whisper preenche só a ponta que o Apple ainda não alcançou. Não existe janela em que
/// os dois falem — é isso que impede a frase duplicada na troca de fonte, sem depender de comparar
/// strings (que foi o caminho que falhou na supressão de eco: "normalização pra absorver ruído
/// acaba absorvendo sentido").
struct MeetingPreviewComposer {

    /// Um trecho reconhecido, com o intervalo de áudio que ele cobre.
    struct Segment: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String

        init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// O que o Whisper tem para a ponta: a hipótese e o instante do áudio em que a janela começa.
    struct Tail: Equatable {
        var startsAt: TimeInterval
        var text: String

        init(startsAt: TimeInterval, text: String) {
            self.startsAt = startsAt
            self.text = text
        }
    }

    /// Até onde o Apple já cobriu. `0` quando ele ainda não entregou nada.
    static func coveredUpTo(_ segments: [Segment]) -> TimeInterval {
        segments.map(\.end).max() ?? 0
    }

    /// O texto a exibir.
    ///
    /// - Parameters:
    ///   - segments: o que o Apple entregou, em qualquer ordem de chegada — os resultados finais
    ///     não vêm necessariamente na ordem do áudio, então a ordenação é por tempo aqui e não pela
    ///     ordem de chegada.
    ///   - tail: a hipótese da janela do Whisper, ou `nil` quando ela não existe.
    static func compose(segments: [Segment], tail: Tail?) -> String {
        let ordenados = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        var partes = ordenados.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let tail {
            let coberto = coveredUpTo(ordenados)
            // A ponta só entra pelo que o Apple ainda não cobriu. Quando ele já passou do começo da
            // janela, o texto do Whisper para aquele trecho é descartado inteiro em vez de ser
            // recortado: recortar exigiria saber a que instante cada palavra corresponde, e a
            // janela deslizante não sabe. Descartar troca uma duplicata por um atraso de uma
            // janela, e a duplicata é o defeito que a prévia não pode ter.
            if tail.startsAt >= coberto {
                let limpo = tail.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !limpo.isEmpty { partes.append(limpo) }
            }
        }

        return partes.joined(separator: " ")
    }

    /// Junta blocos que já vêm sem sobreposição.
    ///
    /// Não procura repetição de palavras de propósito. Quem garante que um bloco não repete o
    /// anterior é a divisão por tempo de áudio, logo acima; procurar sobreposição aqui traria de
    /// volta a heurística de texto que a divisão por tempo existe para evitar.
    ///
    /// A costura por sobreposição do view model (até 24 palavras) foi escrita para a janela
    /// deslizante do Whisper, em que cada hipótese repete o fim da anterior. Aplicada a um bloco
    /// inteiro ela não acha sobreposição e anexa tudo de novo — a repetição vista em reunião real
    /// em 27/08/2026.
    static func join(prefix: String, block: String) -> String {
        let anterior = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let atual = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if anterior.isEmpty { return atual }
        if atual.isEmpty { return anterior }
        return anterior + " " + atual
    }

    /// O Apple já assumiu a prévia?
    ///
    /// Serve para a UI decidir se ainda vale manter a janela do Whisper rodando — e para o custo:
    /// depois que o Apple engata, manter os dois é gastar CPU para produzir texto que é descartado.
    static func appleHasTakenOver(segments: [Segment], tail: Tail?) -> Bool {
        guard let tail else { return !segments.isEmpty }
        return coveredUpTo(segments) > tail.startsAt
    }
}

/// Acumula o que a sessão do Apple emite até virar uma lista de trechos sem sobreposição.
///
/// O analisador manda **muitos** resultados voláteis para o mesmo intervalo (medido: 628 voláteis
/// para 16 finais em 4,5 min) e os finais não chegam na ordem do áudio. Guardar tudo faria a prévia
/// repetir; guardar só o último faria ela perder o começo.
struct MeetingPreviewAppleBuffer {
    /// Um resultado do analisador, já sem nada do framework de voz junto.
    ///
    /// O tipo mora aqui, e não na sessão, porque quem depende de quem importa: a lógica pura é
    /// compilada pelo alvo de testes e a sessão não é — ela fala com `Speech`. Inverter isso deixa
    /// esta regra sem teste, que é justamente a regra que impede a frase duplicada.
    struct Update: Equatable {
        var segment: MeetingPreviewComposer.Segment
        var isFinal: Bool

        init(segment: MeetingPreviewComposer.Segment, isFinal: Bool) {
            self.segment = segment
            self.isFinal = isFinal
        }
    }

    private(set) var finals: [MeetingPreviewComposer.Segment] = []
    private(set) var volatileSegment: MeetingPreviewComposer.Segment?
    /// Instante até onde a prévia já entregou texto para a tela.
    ///
    /// Existe porque os resultados finais chegam ~0,66s depois do trecho falado: quando um bloco
    /// visual fecha com o texto do Whisper, o analisador ainda vai mandar a versão dele daquele
    /// mesmo trecho. Sem esta marca, essa versão atrasada entrava no bloco seguinte e a prévia
    /// repetia a fala inteira — defeito visto em reunião real em 27/08/2026.
    private(set) var frontier: TimeInterval = 0

    init() {}

    mutating func apply(_ update: Update) {
        guard update.segment.end > update.segment.start else { return }
        // Só entra o que COMEÇA depois da fronteira.
        //
        // Recusar apenas o que termina antes não bastava, e foi o defeito visto em reunião real em
        // 27/08/2026: os finais do analisador são disjuntos e sequenciais (medido: 0–22,26 /
        // 22,26–34,56 / 34,56–45,90), então quando um bloco visual fecha no meio de um deles, esse
        // resultado ATRAVESSA o corte e traz junto a fala que já foi para a tela.
        //
        // Recortar o texto pelo instante do corte exigiria saber a que momento cada palavra
        // corresponde, e o resultado não diz. Então o trecho que atravessa é descartado inteiro e a
        // janela do Whisper cobre o intervalo até o próximo resultado começar limpo — o mesmo
        // critério usado na ponta: atrasar é aceitável, repetir não é.
        guard update.segment.start >= frontier else { return }
        if update.isFinal {
            // Um final substitui qualquer coisa que ocupe o mesmo intervalo: é a versão definitiva
            // daquele trecho, e manter as duas versões duplicaria a fala na tela.
            finals.removeAll { $0.start < update.segment.end && update.segment.start < $0.end }
            finals.append(update.segment)
            finals.sort { $0.start < $1.start }
            // O volátil que o final acabou de cobrir perdeu a validade.
            if let atual = volatileSegment, atual.end <= update.segment.end {
                volatileSegment = nil
            }
        } else {
            volatileSegment = update.segment
        }
    }

    /// Os trechos a exibir: os finais, mais o volátil só quando ele COMEÇA depois deles.
    ///
    /// Olhar o fim não bastava, e foi o defeito de 27/08 no modo de um motor só: o analisador
    /// mantinha um volátil sobre a mesma fala que um final já cobria, começando no mesmo instante
    /// e terminando alguns décimos depois (medido: final 59,10–71,94 e volátil 59,10–72,25). Como
    /// o volátil terminava depois, ele entrava inteiro — e a fala aparecia duas vezes, em duas
    /// versões do mesmo trecho.
    ///
    /// É a mesma regra da divisão entre motores, aplicada aqui dentro: nenhum instante pertence a
    /// dois trechos. O custo é a ponta ficar alguns décimos atrás enquanto o volátil se sobrepõe.
    var segments: [MeetingPreviewComposer.Segment] {
        guard let volatileSegment else { return finals }
        let coberto = MeetingPreviewComposer.coveredUpTo(finals)
        guard volatileSegment.start >= coberto else { return finals }
        return finals + [volatileSegment]
    }

    /// Fecha o bloco visual em `instante`: descarta o que ficou para trás e passa a recusar o que
    /// chegar atrasado sobre esse trecho.
    mutating func commitFrontier(at instante: TimeInterval) {
        frontier = max(frontier, instante)
        // Descarta pelo INÍCIO, a mesma regra que o `apply` usa para admitir.
        //
        // Enquanto a limpeza olhava o fim e a admissão olhava o começo, o trecho que atravessa o
        // corte escapava das duas: já estava guardado, sobrevivia à limpeza e reaparecia no bloco
        // seguinte — depois de já ter sido exibido no bloco que fechou. É a repetição que voltou
        // em 27/08 no modo com um motor só.
        finals.removeAll { $0.start < frontier }
        if let atual = volatileSegment, atual.start < frontier { volatileSegment = nil }
    }
}
