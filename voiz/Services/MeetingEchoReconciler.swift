import Foundation
import AVFoundation
import Accelerate

/// Pós-call: remove o **eco da caixa de som** que vazou para o microfone — tanto do **transcript**
/// (turns de "Você" que são eco) quanto do **áudio** (gera um `microphone-clean.caf` p/ o player não
/// reproduzir o eco mixado com o system audio).
///
/// **Por que correlação (e não energia).** A 1ª versão usava energia (eco = mais fraco que a voz),
/// mas em reunião real com caixa de som **alta** o eco vem *mais alto* que a voz do usuário → a energia
/// inverte e o gating falha. Medindo **correlação** mic×system (o eco é uma *cópia atrasada* do
/// system), eco e voz separam **independente do volume**.
///
/// **v2 (validada na "Entrevista Rosiane").** A v1 deixava eco passar por dois motivos: (a) o
/// denominador da correlação usava a energia do segmento INTEIRO de busca (win+2·search) em vez da
/// energia da sub-janela alinhada — NCC enviesado pra baixo, eco real dando 0.3–0.4; (b) janelas de
/// 1 s são grossas nas bordas dos turnos. A v2 roda em 2 passadas: (1) busca larga ±300 ms p/ estimar
/// o **atraso global** do eco (mediana dos lags das janelas confiantes; na gravação real é estável,
/// ~-218±15 ms); (2) classifica janelas de **0,5 s** com NCC **corretamente normalizado** (energia da
/// sub-janela por lag, via somas-prefixo) buscando só ±75 ms em torno do atraso global — no áudio real
/// o eco fica em 0.45–0.97 e o double-talk ≤0.44, e a v2 pegou 39 janelas de eco que a v1 deixou.
///
/// **Seguro/transparente.** Roda offline sobre os arquivos gravados — não toca no áudio ao vivo.
/// Auto-adapta: com **fone** não há eco (nenhuma janela confiante na passada 1) → nada é gateado.
struct MeetingEchoReconciler {
    struct Result {
        var turns: [MeetingTurn]
        var droppedCount: Int
        /// Turns de mic que tiveram um trecho ecoado recortado do texto (ver `trimEchoedText`).
        var trimmedCount: Int
        /// Uma linha por recorte, para conferir o que saiu sem abrir o transcript.
        var trimLog: [String]
        var cleanMicFileName: String?
        var note: String

        init(turns: [MeetingTurn], droppedCount: Int, trimmedCount: Int = 0,
             trimLog: [String] = [], cleanMicFileName: String?, note: String) {
            self.turns = turns
            self.droppedCount = droppedCount
            self.trimmedCount = trimmedCount
            self.trimLog = trimLog
            self.cleanMicFileName = cleanMicFileName
            self.note = note
        }
    }

    private let inSR: Double = 16000
    private let dsFactor = 4                       // correlação roda a 4 kHz (suficiente p/ atraso)
    private var corrSR: Double { inSR / Double(dsFactor) }
    private let windowSec = 0.5
    private let searchSec = 0.30                    // passada 1: busca de atraso ±300 ms
    private let narrowSec = 0.075                   // passada 2: ±75 ms em torno do atraso global
    private let sysOnDb: Float = -50                // "outro lado falando"
    private let micOnDb: Float = -55                // mic audível (passada 1)
    private let anchorThreshold: Float = 0.60       // janela "confiante" p/ estimar o atraso global
    private let minAnchors = 3                      // mínimo de janelas confiantes p/ assumir eco
    private let corrThreshold: Float = 0.42         // passada 2: acima disso = eco (cópia do system)

    // Sala com ruído de fundo (medido em 11/10/2026): o ruído do ambiente derruba a correlação do eco,
    // e com menos de 3 janelas ≥ 0,60 a passada 1 concluía "provável fone" mesmo com janelas de eco
    // acima de 0,42. O que continua inequívoco é o **atraso**: o eco chega sempre no mesmo lag (93%
    // das janelas em ±12 ms), e sem eco o melhor lag de cada janela cai em qualquer lugar (2–9%
    // concordando, no controle deslocado). O consenso só acha o atraso; quem decide cada janela
    // continua sendo a NCC alta da passada 2 — evidência mais fraca que ela apagava fala do usuário
    // (revisões do PR #71) e ficou de fora.
    /// Tolerância para uma janela "concordar" com o atraso do eco.
    private let lagToleranceSec = 0.012
    /// Passada 1 por consenso: janelas no grupo de atrasos mais denso (faixa de ±12 ms), em número
    /// e em fração.
    private let minConsensusWindows = 8
    private let minConsensusFraction = 0.35
    private let echoTurnFraction = 0.5

    // Passada textual (ver `trimEchoedText`).
    /// Palavras **casadas** mínimas para um trecho ser eco, e não coincidência de vocabulário.
    ///
    /// Continua 6, como na v2 — o que mudou é que elas não precisam mais ser **seguidas**. Os dois
    /// lados são transcrições diferentes do mesmo áudio, então uma palavra reconhecida diferente
    /// (ou uma a mais, "ou *tipo* não existe") partia a sequência ao meio e reprovava eco real.
    /// Agora as 6 podem estar espalhadas pelo trecho (ver `echoSpans`), com metade dele literal.
    ///
    /// **Por que não baixar para 4**, que é o que pegaria o terceiro eco relatado pelo humano: numa
    /// gravação com caixa de som alta o mapa acústico **satura** — na entrevista de 79 min, 92% das
    /// janelas com o outro lado falando são eco. Nesse regime o aval acústico quase não discrimina,
    /// e a evidência textual é a que sobra; 4 palavras casadas com um mapa saturado é o bastante
    /// para apagar uma repetição legítima ("confirmar repetindo a frase do outro"). Deixar um eco no
    /// transcript é menos grave que comer fala do usuário. O terceiro eco (4 palavras casadas) só
    /// será pego quando o lote deixar de ter 26 s — ver O2 em DECISOES.
    private let minEchoMatch = 6
    /// O caminho alternativo ao piso de 6: palavras casadas **com conteúdo**.
    ///
    /// O O2 aconteceu: o lote é cortado na troca de falante, o eco chega em turnos curtos e puros —
    /// e o piso de 6, que existia para o regime saturado do lote de 26 s, passou a imunizar
    /// exatamente eles (medido nas reuniões de 20–24/08: praticamente todo turn de mic com cara de
    /// eco tinha menos de 6 palavras). Com o turno curto a folga proporcional encolhe junto
    /// (10% de 2,5 s = 0,25 s) e o aval acústico volta a medir o lugar exato — a objeção que
    /// segurava o piso perdeu a base, como a própria lápide acima previa.
    ///
    /// A régua não virou contagem menor: virou **conteúdo**. "sim tá bom né" casando com a caixa
    /// não abre recorte (zero palavras com conteúdo); "orçamento aprovado pela diretoria" abre
    /// (três ou mais palavras específicas), e ainda assim só sai se o áudio confirmar cópia no
    /// instante certo. Palavra de função não conta como evidência — é a decisão registrada em
    /// DECISOES ("casamento por informatividade no lugar do piso por contagem").
    private let minInformativeMatch = 3
    /// Palavras de função e interjeições (na forma de `normalizedWord`: minúsculas, sem acento).
    /// Não contam como evidência de eco — casar "que", "de", "sim" é coincidência de vocabulário.
    private static let functionWords: Set<String> = [
        // pt-BR — artigos, preposições, pronomes, conjunções
        "a", "o", "as", "os", "um", "uma", "uns", "umas", "de", "do", "da", "dos", "das",
        "em", "no", "na", "nos", "nas", "por", "pra", "pras", "para", "pro", "pros", "com",
        "sem", "sobre", "ate", "apos", "que", "e", "ou", "mas", "se", "ao", "aos",
        "eu", "tu", "voce", "voces", "ele", "ela", "eles", "elas", "gente", "me", "te",
        "meu", "minha", "seu", "sua", "teu", "tua", "dele", "dela", "isso", "isto", "aquilo",
        "esse", "essa", "este", "esta", "aquele", "aquela", "qual", "quais", "quem", "onde",
        "como", "quando", "porque", "entao", "tipo", "assim", "tambem", "ja", "ainda", "so",
        "mais", "menos", "muito", "bem", "la", "aqui", "ai", "ca", "foi", "era", "ser", "estar",
        "esta", "estou", "to", "ta", "tem", "ter", "tinha", "vai", "vou", "vamos", "ir",
        // interjeições e muletas
        "sim", "nao", "ok", "okay", "ne", "ah", "eh", "oh", "hum", "uhum", "aham", "hein",
        "bom", "boa", "beleza", "certo", "claro", "exato", "isso", "opa", "oi", "ola", "tchau",
        "obrigado", "obrigada", "valeu", "legal", "perfeito", "otimo", "show", "top",
        // en — function words e interjeições
        "the", "an", "of", "to", "in", "on", "at", "for", "and", "or", "but", "is", "are",
        "was", "were", "be", "been", "it", "its", "that", "this", "these", "those", "you",
        "i", "we", "he", "she", "they", "my", "your", "his", "her", "our", "their", "yes",
        "no", "not", "so", "like", "well", "right", "uh", "um", "yeah", "okey", "hi", "hello",
        "bye", "thanks", "thank", "cool", "great", "sure"
    ]
    /// Quantas das palavras dadas carregam conteúdo (não são de função/interjeição).
    private func informativeCount(_ words: some Sequence<String>) -> Int {
        words.reduce(0) { $0 + (Self.functionWords.contains($1) ? 0 : 1) }
    }
    /// Distância máxima, em palavras e **dos dois lados**, entre blocos casados do mesmo trecho.
    /// É o que permite a divergência de reconhecimento no meio do eco sem deixar o trecho crescer
    /// por cima de fala nova.
    private let maxBlockGap = 3
    /// Fração mínima de palavras literalmente iguais dentro do trecho recortado.
    private let minSpanAgreement = 0.5
    /// Fração mínima de janelas de eco **dentro de uma janela do tamanho do trecho** (ver
    /// `bestEchoFraction`).
    ///
    /// Alto de propósito: a fração de eco de uma reunião com caixa de som é alta em toda parte
    /// (56% das janelas da entrevista de 79 min, 92% das que têm o outro lado falando). Um limiar
    /// perto dessa taxa-base aprova qualquer coisa — mede o ambiente, não o trecho. Eco de verdade,
    /// medido no lugar certo, dá 1,00.
    private let minSpanEchoFraction = 0.8
    /// Quanto o intervalo do trecho pode ser **deslocado** na busca, proporcional à duração do turn.
    ///
    /// Palavra não tem timestamp: o intervalo do trecho é estimado distribuindo o turn
    /// uniformemente entre as palavras, e o erro dessa conta cresce com o tamanho do turn. Quando um
    /// turn era uma janela de 6–12 s o erro era desprezível; com o lote de 26 s do pós-call ele
    /// passa de 2 s, e um trecho de 2 s procurado no lugar errado não acha eco nenhum.
    ///
    /// **É deslocamento, não alargamento** (achado CRÍTICO da Quilha). Somar a folga às duas pontas
    /// e medir o intervalo inteiro faz a vizinhança decidir: um trecho de 3,9 s virava um veredito
    /// sobre 9,2 s, e mais da metade da evidência vinha de fora do que seria recortado. A janela
    /// tem o tamanho do trecho e **desliza** dentro da folga; vale o melhor lugar, não a média do
    /// bairro.
    private let spanTimeToleranceRatio = 0.10
    private let maxSpanTimeTolerance: TimeInterval = 3.0
    /// Abaixo disso o que sobra não é fala aproveitável (resíduo de ASR) — o turn inteiro sai.
    private let minRemainingWords = 3

    func reconcile(turns: [MeetingTurn], micURL: URL, systemURL: URL,
                   outputDirectory: URL, cleanMicFileName: String) -> Result {
        guard turns.contains(where: { $0.source == .microphone }),
              turns.contains(where: { $0.source == .systemAudio }) else {
            return Result(turns: turns, droppedCount: 0, cleanMicFileName: nil, note: "fonte única — nada a reconciliar")
        }
        let map: EchoMap
        switch echoMap(micURL: micURL, systemURL: systemURL) {
        case .success(let value): map = value
        case .failure(let reason):
            return Result(turns: turns, droppedCount: 0, cleanMicFileName: nil, note: reason)
        }
        let echo = map.echo

        let cleanName = writeCleanMic(mic16k: map.mic, echo: echo, directory: outputDirectory, fileName: cleanMicFileName)

        var dropped = 0
        let kept = turns.filter { turn in
            guard turn.source == .microphone else { return true }
            if echoFraction(start: turn.startTime, end: turn.endTime, echo: echo) > echoTurnFraction {
                dropped += 1; return false
            }
            return true
        }

        let trim = trimEchoedText(in: kept, echo: echo)
        let trimmed = trim.turns
        let trimCount = trim.trimmedCount
        let trimLog = trim.log
        dropped += trim.droppedCount

        let note = map.summary
            + "\(dropped) turn(s) removido(s), \(trimCount) turn(s) com recorte, "
            + "mic limpo \(cleanName != nil ? "ok" : "—")"
        return Result(turns: trimmed, droppedCount: dropped, trimmedCount: trimCount,
                      trimLog: trimLog, cleanMicFileName: cleanName, note: note)
    }

    // MARK: - Regeneração só do áudio

    /// Refaz **apenas** o `microphone-clean.caf` a partir do mic e do system gravados, sem olhar
    /// para o transcript e sem devolver turns.
    ///
    /// **Por que existe como caminho separado.** O `reconcile` é a passagem inteira do pós-call:
    /// gera o áudio limpo *e* reescreve os turns. Quando o que está errado é só a faixa derivada —
    /// como nas duas reuniões que o `boxSmooth` em `Float` mutilou —, rodar o `reconcile` para
    /// consertar o áudio custaria reprocessar o transcript, e transcript é onde mora o trabalho
    /// humano (nomes de falantes corrigidos à mão, edições). Esta função regenera o que quebrou e
    /// não encosta no resto.
    ///
    /// O arquivo de saída é sobrescrito; preservar o anterior é responsabilidade de quem chama.
    ///
    /// **Entrada de manutenção: hoje não tem chamador de produção.** Quem a aciona é o operador (foi
    /// assim que as duas reuniões mutiladas pelo `boxSmooth` em `Float` foram recuperadas). Dar um
    /// dono na UI é decisão de produto e está no backlog das ondas — enquanto não estiver lá, este
    /// doc é o aviso de que o `reconcile` continua sendo o único caminho automático.
    func regenerateCleanMic(micURL: URL, systemURL: URL,
                            outputDirectory: URL, cleanMicFileName: String) -> Regeneration {
        switch echoMap(micURL: micURL, systemURL: systemURL) {
        case .failure(let reason):
            return Regeneration(cleanMicFileName: nil, gatedSeconds: 0, note: reason)
        case .success(let map):
            let name = writeCleanMic(mic16k: map.mic, echo: map.echo,
                                     directory: outputDirectory, fileName: cleanMicFileName)
            let gated = Double(map.echo.filter { $0 }.count) * windowSec
            return Regeneration(cleanMicFileName: name, gatedSeconds: gated,
                                note: map.summary + "mic limpo \(name != nil ? "regravado" : "FALHOU")")
        }
    }

    struct Regeneration {
        /// nil quando não havia eco a remover (fone) ou a escrita falhou — nos dois casos o arquivo
        /// anterior continua onde estava.
        var cleanMicFileName: String?
        /// Quanto do mic foi silenciado por ser eco.
        var gatedSeconds: Double
        var note: String
    }

    // MARK: - Mapa acústico de eco

    /// O mapa de eco e o que ele custou, compartilhado pelas duas entradas (`reconcile` e
    /// `regenerateCleanMic`) para que as duas vejam exatamente a mesma classificação.
    private struct EchoMap {
        /// Uma posição por janela de `windowSec`: o mic é cópia atrasada do system ali?
        var echo: [Bool]
        /// O mic a 16 kHz, já lido — quem chama precisa dele para escrever a faixa limpa.
        var mic: [Float]
        var summary: String
    }

    private enum EchoMapOutcome {
        case success(EchoMap)
        /// Motivo já redigido para o log (sem transcript, sem nome de arquivo do usuário).
        case failure(String)
    }

    private func echoMap(micURL: URL, systemURL: URL) -> EchoMapOutcome {
        guard let mic = readSamples(url: micURL), let sys = readSamples(url: systemURL),
              !mic.isEmpty, !sys.isEmpty else {
            return .failure("áudio indisponível")
        }

        let micD = downsample(mic, factor: dsFactor)
        let sysD = downsample(sys, factor: dsFactor)
        let n = min(micD.count, sysD.count)
        let win = Int(windowSec * corrSR)
        let search = Int(searchSec * corrSR)
        let narrow = Int(narrowSec * corrSR)
        guard n >= win, win > 0 else { return .failure("áudio curto demais") }
        let nb = n / win

        // system com pad de zeros nas pontas cobrindo o maior lag possível (busca nas bordas).
        let pad = search + narrow
        var paddedSys = [Float](repeating: 0, count: n + 2 * pad)
        for i in 0..<n { paddedSys[i + pad] = sysD[i] }

        // Somas-prefixo (Double: precisão em arquivos longos) p/ energia/média por sub-janela e lag.
        var prefixSum = [Double](repeating: 0, count: paddedSys.count + 1)
        var prefixSqSum = [Double](repeating: 0, count: paddedSys.count + 1)
        for i in 0..<paddedSys.count {
            let v = Double(paddedSys[i])
            prefixSum[i + 1] = prefixSum[i] + v
            prefixSqSum[i + 1] = prefixSqSum[i] + v * v
        }

        // Passada 1 — atraso global do eco: mediana dos lags das janelas com NCC alto (busca larga).
        // Sem âncoras suficientes, aceita o consenso de atraso de todas as janelas (sala ruidosa).
        var anchorLags: [Int] = []
        var candidateLags: [Int] = []
        for b in 0..<nb {
            let start = b * win
            guard rmsDb(Array(sysD[start..<start + win])) >= sysOnDb,
                  rmsDb(Array(micD[start..<start + win])) >= micOnDb else { continue }
            let (ncc, lag) = bestNcc(micD: micD, paddedSys: paddedSys, prefixSum: prefixSum,
                                     prefixSqSum: prefixSqSum, pad: pad, start: start, win: win,
                                     lagLo: -search, lagHi: search)
            candidateLags.append(lag)
            if ncc >= anchorThreshold { anchorLags.append(lag) }
        }
        let globalLag: Int
        var byConsensus = false
        if anchorLags.count >= minAnchors {
            globalLag = anchorLags.sorted()[anchorLags.count / 2]
        } else {
            let lagTolerance = Int(lagToleranceSec * corrSR)
            let (consensusLag, agreeing) = densestLagCluster(candidateLags, width: 2 * lagTolerance)
            guard agreeing >= minConsensusWindows,
                  Double(agreeing) >= minConsensusFraction * Double(candidateLags.count) else {
                return .failure("sem eco detectado (\(anchorLags.count) janela(s) confiante(s), "
                    + "\(agreeing) de \(candidateLags.count) no mesmo atraso) — provável fone")
            }
            globalLag = consensusLag
            byConsensus = true
        }

        // Passada 2 — classifica cada janela buscando só em torno do atraso global.
        var echo = [Bool](repeating: false, count: nb)
        var echoCount = 0, dtCount = 0, voiceCount = 0
        for b in 0..<nb {
            let start = b * win
            if rmsDb(Array(sysD[start..<start + win])) < sysOnDb { voiceCount += 1; continue }
            let (ncc, _) = bestNcc(micD: micD, paddedSys: paddedSys, prefixSum: prefixSum,
                                   prefixSqSum: prefixSqSum, pad: pad, start: start, win: win,
                                   lagLo: globalLag - narrow, lagHi: globalLag + narrow)
            if ncc >= corrThreshold {
                echo[b] = true; echoCount += 1
            } else {
                dtCount += 1
            }
        }

        guard echoCount > 0 else { return .failure("sem eco detectado (corr baixa) — provável fone") }

        let lagMs = Int(Double(globalLag) / corrSR * 1000)
        let summary = String(format: "corr-gating v2 (atraso %dms%@): eco %.0fs / você-junto %.0fs / voz %.0fs → ",
                             lagMs, byConsensus ? ", por consenso" : "", Double(echoCount) * windowSec,
                             Double(dtCount) * windowSec, Double(voiceCount) * windowSec)
        return .success(EchoMap(echo: echo, mic: mic, summary: summary))
    }

    // MARK: - Passada textual

    /// Recorta do texto de um turn de mic os trechos que **repetem** o que um turn de system
    /// sobreposto disse.
    ///
    /// **Por que existe.** Um "turn" é uma janela de transcrição (6–12 s ao vivo, até 28 s nos lotes
    /// do pós-call), não uma fala: numa janela cabem o eco do outro *e* a sua fala. O gating
    /// acústico só descarta o turn inteiro
    /// quando mais da metade dele é eco, então turno misto passa inteiro e a frase do outro
    /// aparece duplicada como se fosse sua. Nas duas reuniões usadas para calibrar, **todos** os
    /// turns contaminados tinham fala real junto — descartar o turn perderia fala do usuário.
    ///
    /// **Por que dois sinais.** O texto sozinho não distingue eco de repetição legítima (confirmar
    /// repetindo a frase do outro). O mapa acústico é direcional por construção — mede o mic como
    /// cópia atrasada do system — então só recorta quando os dois concordam.
    ///
    /// **v3 (o lote de 26 s da T2.5).** O pós-call deixou de transcrever janelas de 6–12 s e passou
    /// a mandar lotes de até 28 s ao motor, e um turn de mic virou um bloco onde cabem fala real e
    /// **mais de um** trecho ecoado. Três consequências, todas medidas na entrevista de 79 min, e
    /// esta versão responde às três: (a) o descarte de turn inteiro (`echoTurnFraction`) ficou
    /// inalcançável — nenhum turn passou de 0,50 de eco —, então o recorte é que precisa dar conta;
    /// (b) o recorte era **um por turn** e deixava o segundo trecho no texto; agora repete até não
    /// achar mais nada; (c) o casamento exigia 6 palavras seguidas idênticas e as duas faixas nunca
    /// transcrevem igual — agora casa por blocos espalhados (`echoSpans`), o que reconhece o
    /// mesmo eco com palavra a mais, a menos ou trocada.
    func trimEchoedText(in turns: [MeetingTurn], echo: [Bool])
        -> (turns: [MeetingTurn], trimmedCount: Int, droppedCount: Int, log: [String]) {
        let systemTurns = turns.filter { $0.source == .systemAudio }
        guard !systemTurns.isEmpty else { return (turns, 0, 0, []) }

        var log: [String] = []
        var trimmed = 0
        var droppedByTrim = 0
        var out: [MeetingTurn] = []
        out.reserveCapacity(turns.count)

        for turn in turns {
            guard turn.source == .microphone else { out.append(turn); continue }

            var overlapping: [[String]] = systemTurns
                .filter { $0.endTime > turn.startTime && $0.startTime < turn.endTime }
                .map { other in
                    other.text.split(separator: " ")
                        .map { normalizedWord(String($0)) }
                        .filter { !$0.isEmpty }
                }
            guard !overlapping.isEmpty else { out.append(turn); continue }

            // A folga que o tamanho do lote impõe (ver `spanTimeToleranceRatio`). Sai da duração
            // ORIGINAL do turn, e não do que sobrou: o mapa de tempo das palavras é o do áudio.
            let duration = max(0, turn.endTime - turn.startTime)
            let tolerance = min(maxSpanTimeTolerance, duration * spanTimeToleranceRatio)

            let tokens = turn.text.split(separator: " ").map(String.init)
            let normalized = tokens.map(normalizedWord)
            // `slots` é a numeração ORIGINAL das palavras que contam, e é ela que vira tempo. O
            // laço abaixo remove palavras, mas nunca renumera: uma palavra que era a 30ª do lote
            // continua caindo no segundo em que foi dita mesmo depois de o trecho anterior sair.
            // Renumerar (o que a primeira versão desta v3 fazia, ao recalcular `perWord` sobre o
            // texto encurtado) desloca todo o resto do turn para trás e faz a segunda volta
            // consultar o mapa acústico do PRIMEIRO eco — achado CRÍTICO do Farol, e o jeito de
            // apagar fala legítima com a evidência de outro trecho.
            let wordTokens = normalized.enumerated().filter { !$0.element.isEmpty }.map { $0.offset }
            // O turn menor que o piso de contagem ainda entra SE puder cumprir o piso de
            // conteúdo — é o turno curto e puro que o O2 produz (ver `minInformativeMatch`).
            guard wordTokens.count >= minInformativeMatch else { out.append(turn); continue }
            let perWord = duration / Double(wordTokens.count)

            var removedTokens: Set<Int> = []
            // Trechos que casaram no texto mas o áudio reprovou. Saem da BUSCA (não do texto) para
            // que a volta seguinte possa achar **outra ocorrência** da mesma frase: `matchingBlocks`
            // reconstrói UMA subsequência comum, então, com a frase repetida no mic e dita uma vez
            // pelo outro lado, só a primeira ocorrência aparecia — e se era ela a legítima, a
            // segunda (a ecoada, com aval acústico perfeito) nunca chegava a ser avaliada. É o
            // MAIOR do Farol no r2.
            var shieldedTokens: Set<Int> = []
            var removedSpans: [String] = []

            // Um lote de 26 s costuma trazer mais de um trecho ecoado. Cada volta remove (ou blinda)
            // um trecho e reavalia o que sobrou — as duas coisas só encolhem o material da busca, e
            // cada uma tira ao menos `minInformativeMatch` palavras, então o laço termina.
            while true {
                var compact: [String] = []
                var slots: [Int] = []
                for (slot, token) in wordTokens.enumerated()
                where !removedTokens.contains(token) && !shieldedTokens.contains(token) {
                    compact.append(normalized[token])
                    slots.append(slot)
                }
                guard compact.count >= minInformativeMatch else { break }

                // Todos os trechos casados contra os turns de system sobrepostos, do mais casado
                // ao menos casado. Ficar só com o maior e desistir quando ele não tinha aval
                // acústico sombreava um eco menor **de verdade** no mesmo turn (MAIOR do Farol):
                // agora o maior é só o primeiro a ser tentado.
                var candidates: [Span] = []
                for (index, otherWords) in overlapping.enumerated() {
                    candidates.append(contentsOf: echoSpans(compact, otherWords, other: index))
                }
                candidates.sort { $0.matched > $1.matched }

                var applied = false
                var recusadoPeloAudio: Span?
                for span in candidates {
                    // Um candidato que atravessa a costura de um recorte anterior mede um intervalo
                    // inflado: as palavras dele estão longe no áudio, e o trecho entre elas já não
                    // existe no texto. Só vale trecho contíguo na numeração ORIGINAL (MENOR da
                    // Quilha).
                    let width = slots[span.end - 1] - slots[span.start] + 1
                    guard width == span.end - span.start else { continue }

                    // Palavras não têm timestamp: o intervalo sai da numeração ORIGINAL das
                    // palavras do trecho, e a folga o DESLOCA (não o alarga) na busca.
                    let spanStart = turn.startTime + Double(slots[span.start]) * perWord
                    let spanEnd = turn.startTime + Double(slots[span.end - 1] + 1) * perWord
                    guard bestEchoFraction(start: spanStart, end: spanEnd,
                                           tolerance: tolerance, echo: echo) >= minSpanEchoFraction else {
                        if recusadoPeloAudio == nil { recusadoPeloAudio = span }
                        continue
                    }

                    let dropped = slots[span.start..<span.end].map { wordTokens[$0] }
                    removedSpans.append(dropped.sorted().map { tokens[$0] }.joined(separator: " "))
                    removedTokens.formUnion(dropped)
                    // As palavras do system que este trecho consumiu saem de cena: uma frase dita
                    // UMA vez não pode justificar dois recortes no mic (MENOR da Quilha).
                    for i in span.otherStart..<span.otherEnd where i < overlapping[span.other].count {
                        overlapping[span.other][i] = Self.consumedWord
                    }
                    applied = true
                    break
                }
                guard !applied else { continue }

                // Ninguém passou no áudio. Blinda o melhor candidato reprovado **pelo áudio** e
                // tenta de novo: a busca reconstrói UMA subsequência comum por vez, e é assim que a
                // próxima ocorrência da mesma frase entra em cena. Se ninguém chegou nem a ser
                // medido (só candidatos não-contíguos), acabou — blindá-los tiraria da busca
                // palavras que nunca foram acusadas.
                guard let recusado = recusadoPeloAudio else { break }
                shieldedTokens.formUnion(slots[recusado.start..<recusado.end].map { wordTokens[$0] })
            }

            guard !removedSpans.isEmpty else { out.append(turn); continue }

            let kept = tokens.enumerated().filter { !removedTokens.contains($0.offset) }.map { $0.element }
            let remainingWords = kept.filter { !normalizedWord($0).isEmpty }
            let stamp = String(format: "%.0fs", turn.startTime)
            let removed = removedSpans.joined(separator: " / ")
            if remainingWords.count < minRemainingWords {
                droppedByTrim += 1
                log.append("\(stamp): turn removido (era todo eco) — \"\(removed.prefix(60))\"")
                continue
            }

            var edited = turn
            edited.text = kept.joined(separator: " ")
            out.append(edited)
            trimmed += 1
            let words = removedSpans.reduce(0) { $0 + $1.split(separator: " ").count }
            log.append("\(stamp): recortado \(words) palavra(s) em \(removedSpans.count) trecho(s) — \"\(removed.prefix(60))\"")
        }

        return (out, trimmed, droppedByTrim, log)
    }

    /// Trecho do turn de mic que repete o que o outro lado disse: onde começa e acaba (no mic),
    /// quantas palavras de fato casaram, e que pedaço de qual turn de system o justificou.
    private struct Span {
        var start: Int
        var end: Int
        var matched: Int
        var other: Int
        var otherStart: Int
        var otherEnd: Int
    }

    /// Marca as palavras do system já usadas por um recorte. Tem caractere de controle no meio de
    /// propósito: `normalizedWord` só produz alfanuméricos, então isto nunca casa com nada.
    private static let consumedWord = "\u{0}consumido"

    /// Um pedaço idêntico nos dois lados, na ordem em que os dois o dizem.
    private struct Block {
        var start: Int
        var otherStart: Int
        var length: Int

        /// As palavras do mic que este bloco casou — é sobre elas que o conteúdo é medido.
        func micWords(in mic: [String]) -> ArraySlice<String> {
            mic[start..<Swift.min(start + length, mic.count)]
        }
    }

    /// **Todos** os trechos do mic que repetem um turn de system: cada **aglomerado** de blocos
    /// comuns separados por no máximo `maxBlockGap` palavras **dos dois lados**.
    ///
    /// Por que aglomerado, e não a maior sequência idêntica: as duas faixas são transcrições
    /// diferentes do mesmo áudio. O eco real aparece como "cinco palavras iguais, uma trocada, mais
    /// quatro iguais" — a maior sequência idêntica vê só as cinco, e uma palavra **inserida** numa
    /// das faixas ainda desalinha o resto. Exigir a proximidade nos dois lados é o que impede o
    /// aglomerado de pular fala nova: duas palavras comuns distantes não se juntam.
    ///
    /// Devolve todos, e não só o melhor, porque o aval acústico vem depois: um trecho maior sem eco
    /// no áudio não pode enterrar um trecho menor que tem.
    ///
    /// Também devolve os **prefixos** de cada aglomerado, e não só ele inteiro (MENOR da Quilha):
    /// juntar blocos é guloso, e o aglomerado maximal pode diluir a concordância abaixo do mínimo
    /// enquanto o começo dele, sozinho, era eco claro.
    private func echoSpans(_ mic: [String], _ other: [String], other index: Int) -> [Span] {
        let blocks = matchingBlocks(mic, other)
        guard !blocks.isEmpty else { return [] }

        var spans: [Span] = []
        var i = 0
        while i < blocks.count {
            var j = i
            var last = blocks[i]
            var matched = blocks[i].length
            var informative = informativeCount(blocks[i].micWords(in: mic))
            while true {
                let start = blocks[i].start
                let end = last.start + last.length
                let width = end - start
                // Dois pisos alternativos, um por regime: 6 palavras casadas (o lote longo, onde o
                // aval acústico satura) OU 3 casadas COM CONTEÚDO (o turno curto pós-O2, onde o
                // aval acústico mede o lugar exato). Ver `minInformativeMatch`.
                if matched >= minEchoMatch || informative >= minInformativeMatch, width > 0,
                   Double(matched) / Double(width) >= minSpanAgreement {
                    spans.append(Span(start: start, end: end, matched: matched, other: index,
                                      otherStart: blocks[i].otherStart,
                                      otherEnd: last.otherStart + last.length))
                }
                guard j + 1 < blocks.count else { break }
                let next = blocks[j + 1]
                let micGap = next.start - (last.start + last.length)
                let otherGap = next.otherStart - (last.otherStart + last.length)
                guard micGap <= maxBlockGap, otherGap <= maxBlockGap else { break }
                j += 1
                last = next
                matched += next.length
                informative += informativeCount(next.micWords(in: mic))
            }
            i = j + 1
        }
        return spans
    }

    /// A maior fração de eco que uma janela **do tamanho do trecho** encontra deslizando dentro da
    /// folga. Ver `spanTimeToleranceRatio`: a folga move a janela, não a estica.
    /// A busca é **simétrica**: os deslocamentos são múltiplos inteiros da janela, de `-k` a `+k`.
    /// A versão anterior somava `windowSec` a partir de `-tolerance` e parava antes de alcançá-la
    /// (com folga de 2,65 s, o último passo era +2,35), então procurava mais para trás do que para
    /// a frente. Isso mascarava metade do bug do denominador — e é por isso que a simetria só entra
    /// **depois** do `echoFraction` estar contando o que fica fora do arquivo como não-eco.
    private func bestEchoFraction(start: TimeInterval, end: TimeInterval,
                                  tolerance: TimeInterval, echo: [Bool]) -> Double {
        let steps = Int((tolerance / windowSec).rounded(.down))
        guard steps > 0 else { return echoFraction(start: start, end: end, echo: echo) }
        var best = 0.0
        for step in (-steps)...steps {
            let offset = Double(step) * windowSec
            best = max(best, echoFraction(start: start + offset, end: end + offset, echo: echo))
        }
        return best
    }

    /// Pedaços idênticos das duas sequências, na ordem — os blocos de uma subsequência comum máxima.
    private func matchingBlocks(_ a: [String], _ b: [String]) -> [Block] {
        MeetingEchoTextMatch.matchingBlocks(a, b).map {
            Block(start: $0.start, otherStart: $0.otherStart, length: $0.length)
        }
    }

    /// Minúscula, sem acento e sem pontuação — o mesmo texto sai diferente nas duas faixas.
    private func normalizedWord(_ token: String) -> String {
        MeetingEchoTextMatch.normalizedWord(token)
    }

    // MARK: - Correlação

    /// NCC máxima da janela do mic contra o system deslocado por lag ∈ [lagLo, lagHi] (em amostras
    /// a 4 kHz; lag negativo = mic é cópia do system do passado, o caso do eco). Normalização
    /// **correta**: energia da sub-janela do system em cada lag (somas-prefixo), não do segmento
    /// inteiro de busca — era o viés da v1. Retorna (ncc, lag do pico).
    private func bestNcc(micD: [Float], paddedSys: [Float], prefixSum: [Double], prefixSqSum: [Double],
                         pad: Int, start: Int, win: Int, lagLo: Int, lagHi: Int) -> (Float, Int) {
        let outN = lagHi - lagLo + 1
        guard outN > 0 else { return (0, 0) }
        let base = pad + start + lagLo
        guard base >= 0, base + outN - 1 + win <= paddedSys.count else { return (0, 0) }

        let micWin = centered(Array(micD[start..<start + win]))
        var micSq: Float = 0
        vDSP_svesq(micWin, 1, &micSq, vDSP_Length(win))
        let micNorm = Double(sqrt(micSq))
        guard micNorm > 0 else { return (0, 0) }

        // Numerador em todos os lags de uma vez: D[m] = Σ sys[base+m+p]·micWin[p].
        // (mic centrado ⇒ a média do system se cancela no produto — não precisa centrar o system.)
        var d = [Float](repeating: 0, count: outN)
        paddedSys.withUnsafeBufferPointer { sp in
            micWin.withUnsafeBufferPointer { mp in
                vDSP_conv(sp.baseAddress! + base, 1, mp.baseAddress!, 1, &d, 1,
                          vDSP_Length(outN), vDSP_Length(win))
            }
        }

        var best: Float = 0
        var bestLag = lagLo
        let w = Double(win)
        for m in 0..<outN {
            let a = base + m
            let s1 = prefixSum[a + win] - prefixSum[a]
            let s2 = prefixSqSum[a + win] - prefixSqSum[a]
            let variance = max(0, s2 - s1 * s1 / w)
            let denom = micNorm * variance.squareRoot() + 1e-9
            let ncc = Float(Double(abs(d[m])) / denom)
            if ncc > best { best = ncc; bestLag = lagLo + m }
        }
        return (best, bestLag)
    }

    private func centered(_ x: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var neg = -mean
        var out = x
        vDSP_vsadd(out, 1, &neg, &out, 1, vDSP_Length(out.count))
        return out
    }

    // MARK: - Áudio limpo

    /// Escreve uma faixa de mic com os trechos de eco **silenciados** (com ramps de ~10 ms p/ não
    /// estalar). O player usa essa faixa, então o eco some do playback. nil se falhar.
    private func writeCleanMic(mic16k mic: [Float], echo: [Bool], directory: URL, fileName: String) -> String? {
        let total = mic.count
        let perWindow = Int(windowSec * inSR)
        var gain = [Float](repeating: 1, count: total)
        for i in 0..<total {
            let w = i / perWindow
            if w < echo.count, echo[w] { gain[i] = 0 }
        }
        Self.boxSmooth(&gain, radius: Int(0.010 * inSR))   // ramps suaves nas bordas dos trechos de eco

        var clean = [Float](repeating: 0, count: total)
        vDSP_vmul(mic, 1, gain, 1, &clean, 1, vDSP_Length(total))

        let url = directory.appendingPathComponent(fileName)
        return writeCaf(samples: clean, to: url) ? fileName : nil
    }

    /// Fração de janelas de eco no intervalo pedido.
    ///
    /// **O denominador é o intervalo INTEIRO, mesmo a parte que cai fora do mapa.** Antes ele era
    /// recortado nas bordas (`max(0,...)`/`min(echo.count,...)`), e isso invertia o sentido da
    /// medida: uma janela de 3 s no começo do arquivo, deslocada para trás pela folga, ficava com
    /// 2,5 s fora do mapa e virava um veredito sobre os 0,5 s que sobraram — uma única janela de eco
    /// dava fração 1,00 e apagava fala legítima (CRÍTICO do Farol, r2). Fora do arquivo não há
    /// evidência de eco, e "não há evidência" tem que contar contra o recorte, não a favor.
    ///
    /// São **dois** os chamadores. No do recorte (`trimEchoedText`) a mudança fecha o buraco. No do
    /// descarte de turn inteiro (`echoTurnFraction`, no `reconcile`) ela também muda a conta — para
    /// o lado seguro: um turn que passa do fim do mapa agora tem a parte de fora contando como
    /// não-eco, então ele é descartado menos, nunca mais.
    private func echoFraction(start: TimeInterval, end: TimeInterval, echo: [Bool]) -> Double {
        let first = Int((start / windowSec).rounded(.down))
        let last = max(first + 1, Int((end / windowSec).rounded(.up)))
        let total = last - first
        guard total > 0 else { return 0 }
        var echoed = 0
        for w in first..<last where w >= 0 && w < echo.count && echo[w] { echoed += 1 }
        return Double(echoed) / Double(total)
    }

    // MARK: - DSP utilitário

    private func downsample(_ x: [Float], factor: Int) -> [Float] {
        let m = x.count / factor
        guard m > 0 else { return [] }
        var out = [Float](repeating: 0, count: m)
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            for i in 0..<m {
                var s: Float = 0
                let off = i * factor
                for j in 0..<factor { s += base[off + j] }
                out[i] = s / Float(factor)
            }
        }
        return out
    }

    /// O grupo mais numeroso de atrasos que cabe numa faixa de `width` amostras, e a mediana dele.
    ///
    /// Não a mediana de todos: quando o eco aparece só em parte da reunião (caixa de som e depois
    /// fone, ou janelas em que a fala junto domina), os picos sem relação são maioria e a mediana
    /// geral cai entre eles — o grupo do eco, que existe, deixava de ser visto (revisão do PR #71).
    private func densestLagCluster(_ lags: [Int], width: Int) -> (lag: Int, count: Int) {
        let sorted = lags.sorted()
        guard !sorted.isEmpty else { return (0, 0) }
        var best = (start: 0, count: 0)
        var end = 0
        for start in sorted.indices {
            while end < sorted.count, sorted[end] - sorted[start] <= width { end += 1 }
            if end - start > best.count { best = (start, end - start) }
        }
        return (sorted[best.start + best.count / 2], best.count)
    }

    private func rmsDb(_ x: [Float]) -> Float {
        var ms: Float = 0
        vDSP_measqv(x, 1, &ms, vDSP_Length(x.count))
        return 10 * log10(ms + 1e-12)
    }

    /// Média móvel (box) por soma corrente — cria ramps lineares nas transições do ganho.
    ///
    /// **O acumulador não pode crescer com o arquivo, e isso não é preferência.** A primeira versão
    /// somava tudo num vetor de somas-prefixo em `Float`: como o ganho é quase todo 1, a soma crescia
    /// uma unidade por amostra, saturava em 2²⁴ = 16.777.216 e **congelava** (o arredondamento
    /// engole o `+1`) — daí em diante a diferença entre dois pontos da soma valia 0 para qualquer
    /// janela. Como o resultado é o ganho, o efeito não era um ruidinho: era `microphone-clean.caf`
    /// virar **silêncio absoluto** do minuto ~30 até o fim do arquivo, com a voz do usuário sumindo
    /// do player na maior parte de uma reunião longa. Medido numa entrevista real de 79 min: colapso
    /// em 30:10, 62% da gravação muda, e a soma parando exatamente em 16777216.
    ///
    /// A soma corrente abaixo fecha isso pelos dois lados: o acumulador nunca passa do tamanho da
    /// janela (321 amostras), então nem `Float` chegaria perto do precipício — a classe do bug
    /// deixou de depender da escolha de tipo —, e some o `[Double]` do tamanho do arquivo, que eram
    /// 608 MB na mesma reunião de 79 min.
    static func boxSmooth(_ g: inout [Float], radius: Int) {
        let n = g.count
        guard radius > 0, n > 2 * radius else { return }

        // A janela do primeiro `i` é [0, radius] — as posições negativas não existem.
        var sum = 0.0
        for i in 0...radius { sum += Double(g[i]) }

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - radius), b = min(n, i + radius + 1)
            out[i] = Float(sum / Double(b - a))
            // Avança a janela para o próximo i: entra i+radius+1, sai i-radius.
            let entrando = i + radius + 1
            if entrando < n { sum += Double(g[entrando]) }
            let saindo = i - radius
            if saindo >= 0 { sum -= Double(g[saindo]) }
        }
        g = out
    }

    // MARK: - I/O

    /// Lê o arquivo inteiro **em laço**: `read(into:)` lê *até* a capacidade do buffer, não a
    /// capacidade inteira, e uma leitura só devolvia menos amostras que o arquivo tem (52 ms a
    /// menos numa gravação real de 79 min). Como é daqui que sai o comprimento do `microphone-clean`
    /// escrito, o rabo da gravação sumia do player — pouco, mas sem motivo. O laço para quando o
    /// arquivo acaba ou quando uma leitura não avança, que é a guarda contra laço infinito.
    private func readSamples(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        // Buffer de bloco, não do arquivo inteiro: um `AVAudioPCMBuffer` com a capacidade de uma
        // reunião de 79 min são ~300 MB só de espelho do que já vai para `samples` (memória da
        // Quilha). 1 Mi quadros = 4 MB, e o laço abaixo já lida com leitura parcial.
        let chunk = AVAudioFrameCount(min(UInt32(1 << 20), max(1, frameCount)))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(Int(frameCount))
        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { return nil }
            let read = Int(buffer.frameLength)
            guard read > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: read))
        }
        return samples.isEmpty ? nil : samples
    }

    private func writeCaf(samples: [Float], to url: URL) -> Bool {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inSR,
                                         channels: 1, interleaved: false),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return false }
        let chunk = 65536
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return false }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { p in
                buffer.floatChannelData!.pointee.update(from: p.baseAddress! + offset, count: count)
            }
            do { try file.write(from: buffer) } catch { return false }
            offset += count
        }
        return true
    }
}
