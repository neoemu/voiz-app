import Testing
import Foundation

/// A passada textual do eco contra o **lote de 26 s** que a T2.5 trouxe para o pós-call.
///
/// Todo o texto daqui é inventado (PLANO, regra 7 — nunca comitar transcript). O que é real são as
/// **formas** de falha, tiradas de uma entrevista de 79 min gravada com caixa de som e mic do
/// MacBook, e das duas reviews que reprovaram a primeira versão desta v3.
///
/// **O fixture é aritmética, não aproximação.** Todo turn de mic tem 53 palavras em 26,5 s, então
/// cada palavra ocupa exatamente 0,5 s — a janela do mapa acústico. A primeira versão desta suíte
/// montava 33 palavras em 26,5 s (0,803 s cada) e o teste-bandeira passava **por causa** do bug que
/// deveria pegar: com os tempos certos ele reprovava. Fixture torto é teste que mente.
@Suite("Reunião — o recorte de eco sobrevive ao lote de 26 s")
struct MeetingEchoTrimTests {

    private static let turnStart: TimeInterval = 100
    private static let turnEnd: TimeInterval = 126.5      // 53 palavras => 0,5 s por palavra
    private static let wordCount = 53

    private static func micTurn(_ text: String, start: TimeInterval = turnStart, end: TimeInterval = turnEnd) -> MeetingTurn {
        MeetingTurn(source: .microphone, speakerName: "Você", text: text, startTime: start, endTime: end)
    }

    private static func systemTurn(_ text: String, start: TimeInterval = turnStart, end: TimeInterval = turnEnd) -> MeetingTurn {
        MeetingTurn(source: .systemAudio, speakerName: "Participante 1", text: text, startTime: start, endTime: end)
    }

    /// Mapa acústico de eco: janelas de 0,5 s, `true` nos intervalos pedidos (em segundos).
    private static func echoMap(_ ranges: [(Double, Double)], totalSeconds: Double = 200) -> [Bool] {
        var map = [Bool](repeating: false, count: Int(totalSeconds / 0.5))
        for (start, end) in ranges {
            for w in Int(start / 0.5)..<min(map.count, Int(end / 0.5)) { map[w] = true }
        }
        return map
    }

    private static func filler(_ count: Int, prefix: String) -> [String] {
        (0..<count).map { "\(prefix)\($0)" }
    }

    /// Monta um turn de mic com exatamente `wordCount` palavras, encaixando os trechos pedidos nas
    /// posições pedidas — é o que dá o mapa palavra→segundo exato de cada teste.
    private static func micTurn(placing pieces: [(at: Int, text: String)],
                                start: TimeInterval = turnStart,
                                end: TimeInterval = turnEnd) -> MeetingTurn {
        var words = filler(wordCount, prefix: "fala")
        for piece in pieces {
            let parts = piece.text.split(separator: " ").map(String.init)
            for (offset, word) in parts.enumerated() { words[piece.at + offset] = word }
        }
        return micTurn(words.joined(separator: " "), start: start, end: end)
    }

    private static func trim(_ turns: [MeetingTurn], _ echo: [Bool])
        -> (turns: [MeetingTurn], trimmedCount: Int, droppedCount: Int, log: [String]) {
        MeetingEchoReconciler().trimEchoedText(in: turns, echo: echo)
    }

    @Test("Dois trechos ecoados no mesmo lote — os dois saem, não só o primeiro")
    func trimsEveryEchoedSpanInTheBatch() {
        let primeiro = "a gente fechou o contrato na semana passada"   // 8 palavras: 103–107 s
        let segundo = "depois eu te mando o documento assinado"        // 7 palavras: 115–118,5 s
        let mic = Self.micTurn(placing: [(at: 6, text: primeiro), (at: 30, text: segundo)])
        let system = Self.systemTurn("\(primeiro) e \(segundo)")
        let echo = Self.echoMap([(103, 107), (115, 118.5)])

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        #expect(!texto.contains("contrato"))
        #expect(!texto.contains("documento"))
        #expect(texto.contains("fala0"))
        #expect(texto.contains("fala52"))
        #expect(result.log.first?.contains("2 trecho(s)") == true)
    }

    @Test("O mesmo eco com uma palavra a mais numa das faixas ainda é reconhecido")
    func trimsAcrossRecognitionDivergence() {
        // Uma palavra INSERIDA no meio partia a sequência literal em 5 e reprovava no piso de 6.
        let noMic = "existe um seguro para a moto ou tipo não existe esse produto"    // 12 palavras
        let noSystem = "existe um seguro para a moto ou não existe esse produto"      // 11 palavras
        let mic = Self.micTurn(placing: [(at: 10, text: noMic)])                      // 105–111 s
        let system = Self.systemTurn(noSystem)
        let echo = Self.echoMap([(105, 111)])

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        #expect(!texto.contains("seguro"))
        #expect(!texto.contains("produto"))
        #expect(texto.contains("fala0"))
    }

    @Test("A janela desliza até o eco: erro de posição do lote não reprova o recorte")
    func slidesTheWindowToFindTheEcho() {
        // Palavra não tem timestamp: o intervalo sai distribuindo o lote uniformemente, e num lote
        // de 26 s o erro passa de 2 s. O trecho é estimado em 105–109 s e o eco está em 107,5–112 s:
        // parado, a fração dá 0,38; deslizando a janela (do tamanho do trecho) dentro da folga de
        // 2,65 s, dá 1,00. Alargar em vez de deslizar era o CRÍTICO da Quilha — o veredito passava
        // a ser sobre a vizinhança.
        let ecoado = "isso ia ser o ideal para a gente"     // 8 palavras: 105–109 s
        let mic = Self.micTurn(placing: [(at: 10, text: ecoado)])
        let system = Self.systemTurn(ecoado)

        let result = Self.trim([mic, system], Self.echoMap([(107.5, 112)]))
        #expect(result.trimmedCount == 1)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("ideal") == false)

        // E com o eco fora de qualquer folga razoável, nada é recortado: folga é folga.
        let longe = Self.trim([mic, system], Self.echoMap([(160, 180)]))
        #expect(longe.trimmedCount == 0)
    }

    /// Contraexemplo CRÍTICO do Farol (r1), confirmado pela Quilha com a fórmula do deslocamento
    /// (m·D/N, sempre para trás e auto-alimentado). A primeira versão do laço recalculava o mapa
    /// palavra→tempo sobre o texto **já encurtado**: depois do primeiro recorte, tudo que vinha
    /// depois era renumerado para trás e passava a ser julgado pelo mapa acústico do trecho
    /// anterior. Uma repetição legítima posterior sumia com a evidência do eco inicial.
    @Test("Eco inicial + repetição legítima depois: só o eco sai")
    func laterLegitimateRepetitionSurvivesTheFirstTrim() {
        let ecoInicial = "a gente precisa fechar o escopo antes de abrir o chamado para a equipe de plataforma"
        let repetiçãoLegítima = "abrir o chamado para a equipe mesmo"      // 7 palavras: 114–117,5 s
        let mic = Self.micTurn(placing: [(at: 0, text: ecoInicial),        // 18 palavras: 100–109 s
                                         (at: 28, text: repetiçãoLegítima)])
        let system = Self.systemTurn("\(ecoInicial) e aí você \(repetiçãoLegítima)")
        // Eco acústico SÓ no começo do turn. O fim em 110,5 s é escolhido: com os tempos ORIGINAIS
        // a repetição legítima (114–117,5 s) não alcança o eco nem com a folga inteira, mas sob a
        // renumeração ela é jogada para 107,6–112,9 s e cai dentro dele — é o teste que separa as
        // duas versões.
        let echo = Self.echoMap([(100, 110.5)])

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        #expect(!texto.contains("escopo"))       // o eco saiu…
        #expect(texto.contains("mesmo"))         // …e a repetição legítima de depois ficou
        #expect(result.log.first?.contains("1 trecho(s)") == true)
    }

    /// Contraexemplo MAIOR do Farol (r1). Ficar só com o trecho mais bem casado e desistir quando
    /// ele não tinha aval acústico sombreava um eco **menor e real** no mesmo turn.
    @Test("Trecho maior sem eco no áudio não enterra o trecho menor que tem")
    func triesEverySpanUntilOnePassesTheAcousticGate() {
        let semEco = "eu queria entender como vocês fazem esse controle hoje"    // 9 palavras: 102,5–107 s
        let comEco = "isso resolve o problema todo aqui"                         // 6 palavras: 123,5–126,5 s
        let mic = Self.micTurn(placing: [(at: 5, text: semEco), (at: 47, text: comEco)])
        let systemA = Self.systemTurn(semEco)
        let systemB = Self.systemTurn(comEco)
        let echo = Self.echoMap([(123.5, 126.5)])       // eco só no fim, onde está o trecho menor

        let result = Self.trim([mic, systemA, systemB], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        #expect(!texto.contains("resolve"))    // o eco real saiu
        #expect(texto.contains("queria"))      // e o trecho maior, sem aval acústico, ficou
    }

    /// Contraexemplo CRÍTICO da Quilha (review de arquitetura). Numa reunião com caixa de som o
    /// mapa acústico é alto em toda parte; um limiar perto dessa taxa-base aprova qualquer coisa e
    /// apaga fala legítima. Aqui o turn é 100% do usuário, com o mapa a 40% espalhado — a janela
    /// deslizante do tamanho do trecho não acha 80% em lugar nenhum, e nada é recortado.
    @Test("Mapa acústico alto e espalhado não basta: repetição legítima fica")
    func doesNotTrimWhenEchoIsOnlyBackgroundRate() {
        let repetição = "então a ideia é fechar tudo isso ainda esta semana sim"   // 11 palavras
        let mic = Self.micTurn(placing: [(at: 20, text: repetição)])               // 110–115,5 s
        let system = Self.systemTurn(repetição)
        // 40% das janelas em eco, alternando 1 s sim / 1,5 s não pelo turn inteiro.
        var ranges: [(Double, Double)] = []
        var t = Self.turnStart
        while t < Self.turnEnd { ranges.append((t, t + 1)); t += 2.5 }

        let result = Self.trim([mic, system], Self.echoMap(ranges))

        #expect(result.trimmedCount == 0)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("fechar") == true)
    }

    /// Holdout do regime antigo: turns de 6–12 s, que é o que a prévia ao vivo e as sessões
    /// anteriores à T2.5 produzem. Os parâmetros desta v3 foram calibrados para o lote de 26 s, e
    /// esta suíte existe para que a próxima mudança de granularidade (O2, cortar o lote na troca de
    /// falante) mostre a quebra em vez de escondê-la: num turn curto a folga é pequena (10% de 9 s
    /// = 0,9 s) e um eco de verdade continua sendo recortado no lugar certo.
    @Test("Regime antigo (turn de 9 s) continua funcionando com a folga proporcional")
    func stillWorksOnTheShortTurnsOfTheLivePreview() {
        let ecoado = "isso aí foi exatamente o que eu falei"     // 8 palavras
        let mic = Self.micTurn("\(ecoado) e aí eu segui", start: 100, end: 109)   // 12 palavras em 9 s
        let system = Self.systemTurn(ecoado, start: 99, end: 108)
        // O eco ocupa as 8 primeiras palavras: 100–106 s.
        let result = Self.trim([mic, system], Self.echoMap([(100, 106)]))

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        #expect(!texto.contains("exatamente"))
        #expect(texto.contains("segui"))
    }

    /// Contraexemplo CRÍTICO do Farol (r2). O primeiro lote de uma reunião começa em 0 s, e a folga
    /// empurra a janela para ANTES do arquivo. Enquanto o denominador era recortado nas bordas, o
    /// pedaço de fora sumia da conta e o veredito virava um plebiscito entre as poucas janelas que
    /// sobravam: uma única janela de eco em 0–0,5 s dava fração 1,00 e apagava fala legítima.
    @Test("Janela deslocada para fora do arquivo não vira veredito sobre o que sobrou (início)")
    func doesNotCountOutOfBoundsWindowsAsEvidenceAtTheStart() {
        let repetição = "isso resolve o problema todo aqui"        // 6 palavras, slots 0–5 => 0–3 s
        let mic = Self.micTurn(placing: [(at: 0, text: repetição)], start: 0, end: 26.5)
        let system = Self.systemTurn(repetição, start: 0, end: 26.5)
        // Eco SÓ na primeira janela do arquivo: 0,5 s de 3 s é 0,17 — longe de 0,8.
        let echo = Self.echoMap([(0, 0.5)])

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 0)
        #expect(result.droppedCount == 0)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("resolve") == true)
    }

    /// A outra borda do mesmo achado: o fim do mapa. Deslizar para depois do último segundo gravado
    /// também não pode encolher o denominador.
    @Test("Janela deslocada para fora do arquivo não vira veredito sobre o que sobrou (fim)")
    func doesNotCountOutOfBoundsWindowsAsEvidenceAtTheEnd() {
        let repetição = "isso resolve o problema todo aqui"        // slots 47–52 => 123,5–126,5 s
        let mic = Self.micTurn(placing: [(at: 47, text: repetição)])
        let system = Self.systemTurn(repetição)
        // O mapa acaba ANTES do turn — que é o caso real do último lote: o mapa tem
        // `min(mic, system) / janela` janelas, e a divisão inteira come o resto. Só a última janela
        // dele é eco, e é a única do trecho que cai dentro do mapa.
        let echo = Self.echoMap([(123.5, 124)], totalSeconds: 124)

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 0)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("resolve") == true)
    }

    /// Contraexemplo MAIOR do Farol (r2). `matchingBlocks` reconstrói UMA subsequência comum: com a
    /// frase repetida no mic e dita uma vez pelo outro lado, só uma das ocorrências virava
    /// candidata. Se era a legítima, a ecoada — com aval acústico perfeito — nunca era avaliada, e
    /// as duas ficavam no transcript. Não é o recall que abrimos mão em 78:15: aqui o trecho cumpre
    /// o piso de 6 palavras casadas E tem eco 1,00.
    @Test("Frase repetida no mic: sai a ocorrência que tem eco, fica a que não tem")
    func trimsTheOccurrenceThatHasEchoEvenIfItIsNotTheFirst() {
        let frase = "isso resolve o problema todo aqui"
        // Primeira ocorrência em 105–108 s (sem eco), segunda em 120–123 s (com eco).
        let mic = Self.micTurn(placing: [(at: 10, text: frase), (at: 40, text: frase)])
        let system = Self.systemTurn(frase)
        let echo = Self.echoMap([(120, 123)])

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        // Uma some, a outra fica — e a que fica é a do começo, que o áudio não acusou.
        #expect(texto.components(separatedBy: "resolve").count - 1 == 1)
        // E a que sobrou é a PRIMEIRA: ela ainda aparece antes das palavras que separavam as duas.
        let palavras = texto.split(separator: " ").map(String.init)
        let ondeSobrou = palavras.firstIndex(of: "resolve")
        let ondeEstavaOMeio = palavras.firstIndex(of: "fala39")
        #expect(ondeSobrou != nil && ondeEstavaOMeio != nil && ondeSobrou! < ondeEstavaOMeio!)
    }

    /// O par negativo do holdout de 9 s, e é ele que a O2 mais pode quebrar. A propriedade que
    /// segura este caso é a **folga proporcional**: num turn de 9 s ela vale 0,9 s, então a janela
    /// quase não passeia e uma repetição legítima não alcança o eco do vizinho. Se alguém trocar
    /// `spanTimeToleranceRatio` por um valor fixo (2 s, 3 s), a busca deixa de encolher junto com o
    /// turn e este teste reprova — é para isso que ele existe. Não "consertar" subindo a folga.
    @Test("Regime antigo (turn de 9 s): repetição legítima com mapa sujo ao lado NÃO é recortada")
    func doesNotTrimLegitimateRepetitionOnShortTurns() {
        let frase = "isso resolve o problema todo aqui"
        // 12 palavras em 9 s => 0,75 s por palavra. A repetição ocupa 104,5–109 s…
        let mic = Self.micTurn("antes1 antes2 antes3 antes4 antes5 antes6 \(frase)", start: 100, end: 109)
        let system = Self.systemTurn(frase, start: 99, end: 109)
        // …e o eco está no começo do turn (100–105,5 s). Com a folga proporcional (0,9 s) a janela
        // não alcança: 0,33. Com uma folga FIXA de 3 s ela alcança (0,89) e a fala legítima morre —
        // é exatamente a regressão que este teste existe para pegar.
        let result = Self.trim([mic, system], Self.echoMap([(100, 105.5)]))

        #expect(result.trimmedCount == 0)
        #expect(result.droppedCount == 0)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("resolve") == true)
    }

    @Test("Sem aval acústico o texto igual NÃO é recortado — repetir o outro é legítimo")
    func doesNotTrimWithoutAcousticEvidence() {
        let frase = "a migração começa na segunda que vem de manhã"
        let mic = Self.micTurn(placing: [(at: 10, text: frase)])
        let system = Self.systemTurn(frase)

        let result = Self.trim([mic, system], Self.echoMap([]))

        #expect(result.trimmedCount == 0)
        #expect(result.droppedCount == 0)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("migração") == true)
    }

    @Test("Fala do usuário que não repete ninguém passa inteira, mesmo com eco no mapa")
    func keepsUserSpeechThatIsNotAnEcho() {
        let mic = Self.micTurn("eu queria entender como vocês tratam o rollback quando o deploy falha no meio")
        let system = Self.systemTurn("a gente usa um pipeline diferente para cada ambiente hoje em dia")
        let echo = Self.echoMap([(100, 127)])     // mapa "sujo" no turn inteiro

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 0)
        #expect(result.turns.first { $0.source == .microphone }?.text.contains("rollback") == true)
    }

    @Test("Uma frase dita uma vez não justifica dois recortes no mic")
    func doesNotReuseTheSameSystemWordsTwice() {
        // O usuário repetiu de fato a frase do outro; o system disse UMA vez. O primeiro recorte
        // consome as palavras do system, então a segunda ocorrência não tem mais o que casar.
        let frase = "isso resolve o problema todo aqui"
        let mic = Self.micTurn(placing: [(at: 10, text: frase), (at: 30, text: frase)])
        let system = Self.systemTurn(frase)
        let echo = Self.echoMap([(100, 127)])     // aval acústico liberado nos dois lugares

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        // Uma ocorrência sai, a outra fica: a evidência era de uma frase só.
        #expect(texto.components(separatedBy: "resolve").count - 1 == 1)
        #expect(result.log.first?.contains("1 trecho(s)") == true)
    }

    // MARK: - Pós-O2: o turno curto e puro (informatividade no lugar do piso de contagem)

    /// O caso que o humano reportou em 24/08: com o O2 cortando o lote na troca de falante, o eco
    /// da caixa chega em turnos CURTOS e puros — e o piso de 6 palavras imunizava todos (medido:
    /// praticamente 100% dos turnos de mic com cara de eco tinham <6 palavras). Com conteúdo
    /// casado (>=3 palavras específicas) e aval acústico no lugar exato, o turno sai inteiro.
    @Test("Pós-O2: turno curto que é puro eco com conteúdo sai inteiro")
    func dropsShortPureEchoTurnWithInformativeWords() {
        // 5 palavras em 2,5 s => 0,5 s por palavra, alinhado à janela do mapa.
        let eco = "orcamento aprovado pela diretoria ontem"
        let mic = Self.micTurn(eco, start: 100, end: 102.5)
        let system = Self.systemTurn("entao o \(eco) como combinado", start: 99, end: 103.5)
        let echo = Self.echoMap([(100, 102.5)])

        let result = Self.trim([mic, system], echo)

        #expect(result.droppedCount == 1)
        #expect(!result.turns.contains { $0.source == .microphone })
    }

    /// O negativo que mantém a régua: casar só palavra de função e interjeição não é evidência.
    /// "sim ta bom ne entao" coincide com qualquer conversa — mesmo com o mapa acústico saturado
    /// no instante, o turno fica. Falso-negativo > falso-positivo.
    @Test("Pós-O2: turno curto de função/interjeição NÃO sai, mesmo com mapa saturado")
    func keepsShortFunctionWordTurnEvenWithSaturatedMap() {
        let mic = Self.micTurn("sim ta bom ne entao", start: 100, end: 102.5)
        let system = Self.systemTurn("sim ta bom ne entao vamos fazer assim", start: 99, end: 103.5)
        let echo = Self.echoMap([(100, 102.5)])

        let result = Self.trim([mic, system], echo)

        #expect(result.droppedCount == 0)
        #expect(result.trimmedCount == 0)
        #expect(result.turns.contains { $0.source == .microphone })
    }

    /// O "terceiro eco" de 78:15 que a lápide do `minEchoMatch` adiou para depois do O2: quatro
    /// palavras casadas, mas ESPECÍFICAS, dentro de um turn maior. Contagem reprovava (4 < 6);
    /// conteúdo aprova (4 >= 3) — e o áudio continua tendo a palavra final.
    @Test("Pós-O2: quatro palavras casadas específicas dentro do turn longo são recortadas")
    func trimsFourInformativeMatchedWordsInsideLongTurn() {
        let eco = "faturamento subiu doze porcento"           // 4 palavras: slots 10–13 => 105–107 s
        let mic = Self.micTurn(placing: [(at: 10, text: eco)])
        let system = Self.systemTurn(eco)
        let echo = Self.echoMap([(105, 107)])

        let result = Self.trim([mic, system], echo)

        #expect(result.trimmedCount == 1)
        let texto = result.turns.first { $0.source == .microphone }?.text ?? ""
        #expect(!texto.contains("faturamento"))
        #expect(texto.contains("fala0"))
    }

    /// O caminho novo continua atrás do mesmo portão: sem aval acústico, o turno curto com
    /// conteúdo casado fica — texto sozinho nunca decide (repetir o outro é legítimo).
    @Test("Pós-O2: turno curto com conteúdo casado mas SEM aval acústico fica")
    func keepsShortInformativeTurnWithoutAcousticEvidence() {
        let eco = "orcamento aprovado pela diretoria ontem"
        let mic = Self.micTurn(eco, start: 100, end: 102.5)
        let system = Self.systemTurn(eco, start: 99, end: 103.5)

        let result = Self.trim([mic, system], Self.echoMap([]))

        #expect(result.droppedCount == 0)
        #expect(result.trimmedCount == 0)
        #expect(result.turns.contains { $0.source == .microphone })
    }

    @Test("Turn que era só eco sai do transcript em vez de virar resto de frase")
    func dropsTurnLeftWithNothingUseful() {
        let frase = "então a gente combina de fechar isso amanhã de tarde sem falta"
        let mic = Self.micTurn(frase, start: Self.turnStart, end: Self.turnStart + 6)
        let system = Self.systemTurn(frase, start: Self.turnStart, end: Self.turnStart + 6)
        let echo = Self.echoMap([(100, 106)])

        let result = Self.trim([mic, system], echo)

        #expect(result.droppedCount == 1)
        #expect(result.trimmedCount == 0)
        #expect(!result.turns.contains { $0.source == .microphone })
        #expect(result.turns.count == 1)
    }
}
