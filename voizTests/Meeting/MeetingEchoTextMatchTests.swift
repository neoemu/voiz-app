import Foundation
import Testing

@Suite("Eco ao vivo — heurística textual de display")
struct MeetingEchoTextMatchTests {

    /// Par real do screenshot do humano (ASR diverge em cognation/coodition e Cnation/Cnition).
    private static let fixtureMic =
        "Cadê que é o da cognation e esse que eu achei legal também, Rafa, é o seguinte, a Cnation ela é uma competidora direta do cursor, né"
    /// 25 palavras sem colisão de fuzzy entre si (distância > 1 em pares ≥5
    /// chars) — fixture de eco longo com divergência controlada.
    private static let distinctWords = [
        "alfa", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliett", "kilo", "lima", "mike", "november", "oscar", "papa",
        "quebec", "romeu", "sierra", "tango", "uniform", "victor", "whiskey",
        "xadrez", "yankee"
    ]

    private static let fixtureSystem =
        "Cadê que é o da coodition e esse que eu achei legal também Rafa é o seguinte a Cnition ela é uma competidora direta do cursor né"

    private func utterance(
        _ text: String,
        start: TimeInterval = 10,
        end: TimeInterval = 12
    ) -> MeetingEchoTextMatch.Utterance {
        MeetingEchoTextMatch.Utterance(text: text, startTime: start, endTime: end)
    }

    @Test("Token fuzzy: Cnition/Cnation casa; cognation/coodition (dist 3) não")
    func fuzzyTokenMatchCoversOneEditOnly() {
        #expect(MeetingEchoTextMatch.tokensMatch("cnation", "cnition", fuzzy: true))
        #expect(MeetingEchoTextMatch.editDistance("cognation", "coodition") == 3)
        #expect(MeetingEchoTextMatch.tokensMatch("cognation", "coodition", fuzzy: true) == false)
        #expect(MeetingEchoTextMatch.tokensMatch("ok", "oi", fuzzy: true) == false)
        #expect(MeetingEchoTextMatch.tokensMatch("cade", "cade", fuzzy: false))
        #expect(MeetingEchoTextMatch.tokensMatch("cnation", "cnition", fuzzy: false) == false)
    }

    @Test("Fixture real do screenshot DUPLICA — o persist casa só token idêntico")
    func realScreenshotFixtureDuplicates() {
        // Este par era o fixture que justificava tolerar divergência de ASR.
        // Sob o casamento exato ele duplica, e é o desfecho certo: nenhum
        // critério textual separa "o ASR ouviu errado" de "o usuário falou
        // outra palavra" com segurança, e apagar fala é irreversível.
        let exact = MeetingEchoTextMatch.micCoverage(
            mic: Self.fixtureMic, system: Self.fixtureSystem, fuzzy: false
        )
        #expect(exact >= 0.85, "quase tudo casa — mas quase não basta no persist")
        #expect(
            MeetingEchoTextMatch.unmatchedMicTokens(
                mic: Self.fixtureMic, system: Self.fixtureSystem, fuzzy: false
            ) == 2,
            "cognation/coodition e Cnation/Cnition"
        )
        #expect(
            MeetingEchoTextMatch.textIsEcho(micText: Self.fixtureMic, systemText: Self.fixtureSystem) == false
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: Self.fixtureMic,
                micStart: 10.2,
                micEnd: 18,
                systemUtterances: [utterance(Self.fixtureSystem, start: 10, end: 17.5)]
            ) == false
        )
    }

    @Test("Nenhum par aproximado suprime — nem os que já enganaram cada régua anterior")
    func noApproximateMatchEverSuppresses() {
        // A tabela dos casos que derrubaram cada tentativa: cobertura,
        // orçamento, inserção-vs-substituição, quase-identidade e léxico.
        // Todos duplicam agora, e por uma razão só.
        let pairs = [
            ("contrato", "contato"),   // duas palavras reais, distância 1
            ("swift", "shift"),        // uma fora do dicionário pt-BR
            ("pode", "pare"),          // distância 2
            ("vamos", "vimos"),
            ("transcripto", "transcrito")  // garble de verdade — e ainda assim duplica
        ]
        for (mic, system) in pairs {
            let micText = "vamos revisar o \(mic) agora"
            let systemText = "vamos revisar o \(system) agora"
            #expect(
                MeetingEchoTextMatch.textIsEcho(micText: micText, systemText: systemText) == false,
                "\(mic)/\(system) tem que manter o turn"
            )
            #expect(
                MeetingEchoTextMatch.shouldSuppressMicDisplay(
                    micText: micText,
                    micStart: 10,
                    micEnd: 14,
                    systemUtterances: [utterance(systemText, start: 10, end: 14)]
                ) == false
            )
        }
    }

    @Test("Nem a caixa normaliza — IT/it, WHO/who, Polish/polish mantêm o turn")
    func caseIsAlsoEvidenceOnPersist() {
        // A última candidata a "atributo inofensivo". Nestes pares a
        // capitalização muda o lexema E a pronúncia: acrônimo contra pronome,
        // organização contra interrogativo, gentílico contra verbo.
        for (mic, said) in [
            ("o time de IT resolveu", "o time de it resolveu"),
            ("a WHO publicou o dado", "a who publicou o dado"),
            ("é um Polish antigo", "é um polish antigo")
        ] {
            #expect(
                MeetingEchoTextMatch.textIsEcho(micText: mic, systemText: said) == false,
                "\(mic) não é eco de \(said)"
            )
            #expect(
                MeetingEchoTextMatch.shouldSuppressMicDisplay(
                    micText: mic,
                    micStart: 10,
                    micEnd: 14,
                    systemUtterances: [utterance(said, start: 10, end: 14)]
                ) == false
            )
        }

        // MUDANÇA DELIBERADA (r14): mesmo "Vamos"/"vamos" mantém agora. O par
        // gêmeo, idêntico nos dois canais, continua suprimindo — é isso que
        // separa "a régua ficou estrita" de "a supressão morreu".
        let said = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.textIsEcho(
                micText: "Vamos fechar o contrato na semana passada",
                systemText: said
            ) == false,
            "uma letra maiúscula de fronteira de frase já basta para duplicar"
        )
        #expect(MeetingEchoTextMatch.textIsEcho(micText: said, systemText: said))
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: said,
                micStart: 10,
                micEnd: 14,
                systemUtterances: [utterance(said, start: 10, end: 14)]
            ),
            "texto idêntico — o eco literal do mesmo motor, que é o caso comum"
        )

        // Acento segue valendo, pelo mesmo motivo de sempre.
        #expect(
            MeetingEchoTextMatch.textIsEcho(
                micText: "falei com a secretária ontem",
                systemText: "falei com a secretaria ontem"
            ) == false
        )
    }

    @Test("Nenhum caractere é descartável: nem símbolo interno, nem de borda")
    func noCharacterIsDisposableOnPersist() {
        // Os quatro que derrubaram a remoção genérica de não-alfanuméricos...
        let internalSymbols = [
            ("migramos para C++ ano passado", "migramos para C ano passado"),
            ("o saldo é -10 reais", "o saldo é 10 reais"),
            ("subiu 10% no trimestre", "subiu 10 no trimestre"),
            ("a versão 1.2 já saiu", "a versão 12 já saiu")
        ]
        // ...e os quatro que derrubaram a poda de BORDA com conjunto fechado.
        let edgeSymbols = [
            ("migramos para .NET ano passado", "migramos para NET ano passado"),
            ("o campo é Int? mesmo", "o campo é Int mesmo"),
            ("põe !important nessa regra", "põe important nessa regra"),
            ("subiu .1 no trimestre", "subiu 1 no trimestre")
        ]
        for (mic, said) in internalSymbols + edgeSymbols {
            #expect(
                MeetingEchoTextMatch.textIsEcho(micText: mic, systemText: said) == false,
                "\(mic) não é eco de \(said)"
            )
            #expect(
                MeetingEchoTextMatch.shouldSuppressMicDisplay(
                    micText: mic,
                    micStart: 10,
                    micEnd: 14,
                    systemUtterances: [utterance(said, start: 10, end: 14)]
                ) == false
            )
        }

        // A tabela do normalizador: no persist o token atravessa INTACTO.
        for token in [
            "Vamos", "hoje.", "vamos,", "C++", "-10", "10%", "1.2",
            ".NET", "Int?", "!important", ".1", "IT", "WHO", "secretária"
        ] {
            #expect(
                MeetingEchoTextMatch.normalizedWord(token, for: .persist) == token,
                "\(token) atravessa sem transformação nenhuma"
            )
        }
    }

    @Test("Pontuação terminal divergente MANTÉM o turn — consequência aceita")
    func terminalPunctuationNowDuplicates() {
        // MUDANÇA DELIBERADA (r13). Antes "hoje." e "hoje" eram o mesmo token,
        // pela ideia de que ponto final é decoração do ASR. Mas ponto de borda
        // também carrega sentido — ".NET", ".1" — e não há subconjunto de
        // caracteres seguro para descartar. O preço é este: quando os canais
        // divergem só na pontuação, a frase duplica. Duplicata é visível e
        // corrigível; apagar fala não é.
        let spoken = "acho que a gente fecha isso ainda hoje"
        let mic = "Acho que a gente fecha isso ainda hoje."
        #expect(MeetingEchoTextMatch.textIsEcho(micText: mic, systemText: spoken) == false)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: mic,
                micStart: 10,
                micEnd: 14,
                systemUtterances: [utterance(spoken, start: 10, end: 14)]
            ) == false
        )
        // Com a MESMA pontuação nos dois canais, segue suprimindo.
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: mic,
                micStart: 10,
                micEnd: 14,
                systemUtterances: [utterance("Acho que a gente fecha isso ainda hoje.", start: 10, end: 14)]
            )
        )
    }

    @Test("Igualdade é BIDIRECIONAL: subsequência inverteria o sentido")
    func equalityIsBidirectionalSoNegationSurvives() {
        // O fixture do Codex: o mic é subsequência exata do system, e diz o
        // OPOSTO. "Todo token do mic aparece no system" aprovava isso.
        let spoken = "não podemos aprovar essa proposta hoje"
        let mic = "podemos aprovar essa proposta hoje"
        #expect(
            MeetingEchoTextMatch.unmatchedMicTokens(mic: mic, system: spoken, fuzzy: false) == 0,
            "é subsequência perfeita — a régua antiga parava aqui"
        )
        #expect(MeetingEchoTextMatch.textIsEcho(micText: mic, systemText: spoken) == false)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: mic,
                micStart: 10,
                micEnd: 14,
                systemUtterances: [utterance(spoken, start: 10, end: 14)]
            ) == false,
            "apagar isto trocava a fala do usuário pelo sentido oposto"
        )

        // Token a mais do lado do MIC também mantém — já valia, continua.
        #expect(
            MeetingEchoTextMatch.textIsEcho(
                micText: spoken + " mesmo",
                systemText: spoken
            ) == false
        )
    }

    @Test("Eco idêntico recente é suprimido")
    func identicalEchoIsSuppressed() {
        let system = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: system,
                micStart: 10.25,
                micEnd: 12.3,
                systemUtterances: [utterance(system, start: 10, end: 12)]
            )
        )
    }

    @Test("Fala independente do usuário não é suprimida")
    func independentSpeechIsKept() {
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: "prefiro adiar a decisão até segunda",
                micStart: 10.2,
                micEnd: 12,
                systemUtterances: [
                    utterance("vamos fechar o contrato na semana passada", start: 10, end: 12)
                ]
            ) == false
        )
    }

    @Test("Double-talk parcial não é suprimido")
    func partialDoubleTalkIsKept() {
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: "contrato ok mas eu discordo do prazo proposto agora",
                micStart: 10.2,
                micEnd: 13,
                systemUtterances: [
                    utterance("vamos fechar o contrato na semana passada", start: 10, end: 12)
                ]
            ) == false
        )
    }

    @Test("Sem system (fone) não suprime")
    func headphonesDoNotSuppress() {
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: Self.fixtureMic,
                micStart: 10,
                micEnd: 12,
                systemUtterances: []
            ) == false
        )
    }

    @Test("Confirmação curta não é tratada como eco")
    func shortConfirmationIsKept() {
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: "sim exatamente",
                micStart: 10.2,
                micEnd: 10.8,
                systemUtterances: [
                    utterance("sim exatamente vamos fazer isso", start: 10, end: 12)
                ]
            ) == false
        )
    }

    @Test("Fala do system longe no tempo não suprime")
    func distantSystemSpeechDoesNotSuppress() {
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: Self.fixtureMic,
                micStart: 40,
                micEnd: 48,
                systemUtterances: [utterance(Self.fixtureSystem, start: 10, end: 17)]
            ) == false
        )
    }

    @Test("System 2s DEPOIS do mic com texto idêntico NÃO suprime — o usuário falou primeiro")
    func systemRepeatingUserTwoSecondsLaterIsKept() {
        let speech = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 10,
                micEnd: 12,
                systemUtterances: [utterance(speech, start: 12, end: 14)]
            ) == false,
            "reintroduzir a janela simétrica de 3s apaga fala genuína quando Eles repetem"
        )
    }

    @Test("System um pouco depois do mic (jitter ASR) ainda suprime")
    func systemSlightlyAfterMicStillSuppresses() {
        let speech = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 10,
                micEnd: 12,
                systemUtterances: [utterance(speech, start: 10.2, end: 12)]
            )
        )
    }

    @Test("Overlap 0,5 com cobertura alta NÃO suprime — a metade genuína sobrevive")
    func halfOverlapWithHighCoverageKeepsTheMic() {
        let speech = "vamos fechar o contrato na semana passada"
        #expect(
            abs(
                MeetingEchoTextMatch.intervalOverlapFraction(
                    micStart: 0, micEnd: 10, systemStart: 5, systemEnd: 12
                ) - 0.5
            ) < 0.001
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 0,
                micEnd: 10,
                systemUtterances: [utterance(speech, start: 5, end: 12)]
            ) == false,
            "overlap 0,5 + cobertura alta apagava a primeira metade da fala do usuário"
        )
    }

    @Test("Jitter de segmentação 0,6s com sobreposição suprime; repetição sem sobreposição não")
    func overlappingJitterSuppressesAndNonOverlapDoesNot() {
        let speech = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.intervalOverlapFraction(
                micStart: 10, micEnd: 14, systemStart: 10.6, systemEnd: 14
            ) >= 0.7
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 10,
                micEnd: 14,
                systemUtterances: [utterance(speech, start: 10.6, end: 14)]
            ),
            "system começando 0,6s depois mas cobrindo o mic é eco, não repetição"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 10,
                micEnd: 12,
                systemUtterances: [utterance(speech, start: 12.1, end: 14)]
            ) == false,
            "sem sobreposição o 0,3s de epsilon não pode mais mandar"
        )
    }

    // MARK: - Casamento exato de tokens

    @Test("Interjeição genuína dentro do jitter mantém o turn — 7 ecoados + um 'não'")
    func genuineInterjectionInsideTheJitterKeepsTheTurn() {
        // O fixture do Codex: mic [0,8] com 7 tokens ecoados e um "não" do
        // usuário no último segundo. Overlap 0,875, trail 1,0 e cobertura
        // 7/8 = 0,875 passavam nos três — e o turn INTEIRO era descartado.
        let system = "vamos fechar o contrato na semana passada"
        let mic = "vamos fechar o contrato na semana passada não"
        #expect(MeetingEchoTextMatch.tokenize(mic).count == 8)
        #expect(
            MeetingEchoTextMatch.unmatchedMicTokens(mic: mic, system: system, fuzzy: false) == 1
        )
        #expect(
            abs(
                MeetingEchoTextMatch.intervalOverlapFraction(
                    micStart: 0, micEnd: 8, systemStart: 0, systemEnd: 7
                ) - 0.875
            ) < 0.001,
            "o overlap continua passando — quem tem que reprovar é o texto"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 8, systemStart: 0, systemEnd: 7
            ),
            "trail 1,0s é o limite inclusivo: o predicado causal não salva este caso"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: mic,
                micStart: 0,
                micEnd: 8,
                systemUtterances: [utterance(system, start: 0, end: 7)]
            ) == false,
            "um token genuíno a mais derruba a supressão"
        )
    }

    @Test("Eco longo: só suprime com TODOS os tokens idênticos")
    func longEchoNeedsEveryTokenIdentical() {
        let words = Self.distinctWords
        let system = words.joined(separator: " ")

        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: system,
                micStart: 10,
                micEnd: 20,
                systemUtterances: [utterance(system, start: 10, end: 20)]
            )
        )

        // Uma única edição em 25 tokens já mantém o turn. Era o caso que a
        // régua da r8 ainda suprimia (distância 1 = "mesma palavra").
        var micWords = words
        micWords[13] = "novembe"
        let oneEdit = micWords.joined(separator: " ")
        #expect(MeetingEchoTextMatch.editDistance("november", "novembe") == 1)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: oneEdit,
                micStart: 10,
                micEnd: 20,
                systemUtterances: [utterance(system, start: 10, end: 20)]
            ) == false
        )
    }

    @Test("Um token a mais mantém o turn, em qualquer tamanho")
    func oneExtraTokenAlwaysKeepsTheTurn() {
        // 20 tokens ecoados e um "não" do usuário. Todas as réguas anteriores
        // tinham um tamanho a partir do qual isso cabia na tolerância.
        let system = Self.distinctWords.prefix(20).joined(separator: " ")
        let short = system + " não"
        #expect(MeetingEchoTextMatch.textIsEcho(micText: short, systemText: system) == false)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: short,
                micStart: 0,
                micEnd: 21,
                systemUtterances: [utterance(system, start: 0, end: 20)]
            ) == false
        )

        // 63 tokens e três palavras genuínas no fim.
        let base = Self.distinctWords + Self.distinctWords.map { $0 + "x" }
            + Self.distinctWords.prefix(10).map { $0 + "yz" }
        let longSystem = base.joined(separator: " ")
        #expect(
            MeetingEchoTextMatch.textIsEcho(
                micText: longSystem + " mas eu discordo",
                systemText: longSystem
            ) == false
        )
    }

    @Test("Omissão do mic com interjeição no mesmo trecho mantém o turn")
    func omissionPlusInterjectionKeepsTheTurn() {
        // O gap ficava 1×1 balanceado e nenhuma contagem via a diferença.
        // Com casamento exato o caso é trivial: "não" não tem par.
        let words = Array(Self.distinctWords.prefix(20))
        let system = words.joined(separator: " ")
        var micWords = words
        micWords[10] = "não"
        let mic = micWords.joined(separator: " ")
        #expect(MeetingEchoTextMatch.textIsEcho(micText: mic, systemText: system) == false)
    }

    @Test("Mic contido no system NÃO é mais eco — o extra do system pode ser o sentido")
    func micContainedInSystemIsNoLongerEcho() {
        let system = Self.distinctWords.joined(separator: " ")
        let mic = Self.distinctWords.prefix(20).joined(separator: " ")
        #expect(
            MeetingEchoTextMatch.unmatchedMicTokens(mic: mic, system: system, fuzzy: false) == 0
        )
        #expect(
            MeetingEchoTextMatch.textIsEcho(micText: mic, systemText: system) == false,
            "os 5 tokens que sobram do lado do system podem ser exatamente o que muda o sentido"
        )
    }

    // MARK: - Eco longo segmentado (candidatos compostos)

    @Test("Dois finais contíguos do system compõem um eco só; gap de 3s não compõe")
    func contiguousSystemFinalsComposeASingleEcho() {
        let first = "vamos fechar o contrato"
        let second = "na semana passada mesmo"
        let mic = "\(first) \(second)"

        // Individualmente nenhum dos dois explica o mic longo.
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 10, systemStart: 0, systemEnd: 7
            ) == false,
            "o primeiro final sozinho deixa 3s de trail"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 10, systemStart: 7, systemEnd: 10
            ) == false,
            "o segundo final sozinho deixa 7s de lead"
        )

        let contiguous = [
            utterance(first, start: 0, end: 7),
            utterance(second, start: 7, end: 10)
        ]
        let composites = MeetingEchoTextMatch.contiguousComposites(contiguous)
        #expect(composites.count == 1)
        #expect(composites[0].startTime == 0)
        #expect(composites[0].endTime == 10)
        #expect(composites[0].text == mic)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: mic,
                micStart: 0,
                micEnd: 10,
                systemUtterances: contiguous
            ),
            "eco longo que o system finalizou em dois pedaços continua sendo eco"
        )

        // Gap de 3s: são duas falas, não uma. Nenhum composto, nenhuma supressão.
        let spaced = [
            utterance(first, start: 0, end: 7),
            utterance(second, start: 10, end: 13)
        ]
        #expect(MeetingEchoTextMatch.contiguousComposites(spaced).isEmpty)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: mic,
                micStart: 0,
                micEnd: 13,
                systemUtterances: spaced
            ) == false,
            "3s de silêncio entre os finais não podem virar um eco composto"
        )
    }

    @Test("Candidato SIMPLES longo: o persist não empresta o texto do próprio início")
    func simpleCandidateDoesNotLendItsOwnBeginningOnPersist() {
        // Fixture do Codex: o system falou X em [0,3] e seguiu com Y até 10; o
        // usuário repete X em [3,10]. O candidato é SIMPLES e sobrepõe 100% do
        // mic, então o predicado causal aprova — e o texto inteiro explicava a
        // repetição genuína, apagando o turn.
        let x = "vamos fechar o contrato"
        let y = "e depois vemos o resto disso aqui agora"
        let candidate = utterance("\(x) \(y)", start: 0, end: 10)

        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 3, micEnd: 10, systemStart: 0, systemEnd: 10
            ),
            "o predicado causal aprova: sobreposição 1,0, lead 0, trail 0"
        )
        let admissible = candidate.admissibleText(
            micStart: 3,
            micEnd: 10,
            jitter: 0.6,
            includingSimpleCandidate: true
        )
        #expect(
            admissible.contains("vamos fechar") == false,
            "X está nos primeiros ~3s do candidato, fora do intervalo do mic"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: x,
                micStart: 3,
                micEnd: 10,
                systemUtterances: [candidate]
            ) == false,
            "no persist o turn fica — repetir agora o que a caixa disse antes é fala do usuário"
        )
    }

    @Test("O gate do volátil NÃO filtra candidato simples por token — anti-flicker")
    func gateKeepsTheWholeTextOfASimpleCandidate() {
        // Mesma utterance, mesma janela: o `bestNearbyCoverage` do gate enxerga
        // o texto inteiro. A divergência com o persist é deliberada e
        // display-transitória (ver `admissibleText`): a bolha some por um
        // instante e o final aparece logo depois. Nada é apagado.
        let x = "vamos fechar o contrato"
        let candidate = utterance("\(x) e depois vemos o resto disso aqui agora", start: 0, end: 10)
        #expect(
            candidate.admissibleText(micStart: 3, micEnd: 10, jitter: 0.6) == candidate.text,
            "sem includingSimpleCandidate o texto vai inteiro — é o caminho do gate"
        )
        #expect(
            MeetingEchoTextMatch.bestNearbyCoverage(
                micText: x,
                micStart: 3,
                micEnd: 10,
                systemUtterances: [candidate]
            ) == 1.0
        )
    }

    @Test("Composto respeita o gap de 0,75s na fronteira")
    func compositeGapBoundary() {
        let a = utterance("alpha bravo", start: 0, end: 5)
        let b = utterance("charlie delta", start: 5.75, end: 8)
        let c = utterance("charlie delta", start: 5.76, end: 8)
        #expect(MeetingEchoTextMatch.contiguousComposites([a, b]).count == 1)
        #expect(MeetingEchoTextMatch.contiguousComposites([a, c]).isEmpty)
    }

    @Test("Composto: parte fora do intervalo do mic não empresta cobertura")
    func compositePartOutsideTheMicIntervalLendsNoCoverage() {
        // O fixture do Codex: system A[0,7]="X" e B[7,10]="Y"; o mic repete X
        // GENUINAMENTE em [7,10]. O composto [0,10] "X Y" explicava a resposta
        // do usuário com o texto de um final que aconteceu antes dela.
        let x = "vamos fechar o contrato na semana passada"
        let y = "perfeito combinado então"
        let candidates = [
            utterance(x, start: 0, end: 7),
            utterance(y, start: 7, end: 10)
        ]
        let composite = MeetingEchoTextMatch.contiguousComposites(candidates)
        #expect(composite.count == 1)
        #expect(composite[0].parts.count == 2)
        let admissible = composite[0].admissibleText(micStart: 7, micEnd: 10, jitter: 0.6)
        #expect(
            admissible.contains("vamos fechar o contrato") == false,
            "o miolo da parte [0,7] fica fora do intervalo do mic e não empresta cobertura"
        )
        #expect(admissible.contains(y), "a parte que aconteceu no intervalo do mic conta")
        // O último token de A cai em ~6,5s e entra pelo jitter de 0,6s — é o
        // erro esperado da posição estimada, e uma palavra não explica a frase.
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: x,
                micStart: 7,
                micEnd: 10,
                systemUtterances: candidates
            ) == false,
            "repetir o que o system disse ANTES não é eco — é o usuário falando"
        )
    }

    @Test("Empréstimo integral: parte longa não empresta texto do próprio início")
    func longPartLendsOnlyTheTokensNearTheMic() {
        // O fixture do Codex: A[0,10] tem X no INÍCIO e o mic em [9,3;12]
        // repete X genuinamente. Filtrar por PARTE não bastava — bastava a
        // ponta de A encostar no mic (10 - 9,3 = 0,7 > 0,6) para A emprestar
        // todo o seu texto, X inclusive, e apagar a fala do usuário.
        let x = "vamos fechar o contrato na semana passada"
        let a = "\(x) e depois vemos o resto disso aqui"
        let candidates = [
            utterance(a, start: 0, end: 10),
            utterance("certo", start: 10, end: 12)
        ]
        let composite = MeetingEchoTextMatch.contiguousComposites(candidates)
        #expect(composite.count == 1)

        let admissible = composite[0].admissibleText(micStart: 9.3, micEnd: 12, jitter: 0.6)
        #expect(
            admissible.contains("vamos fechar o contrato") == false,
            "X está nos primeiros ~5s de A, longe do intervalo do mic"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: x,
                micStart: 9.3,
                micEnd: 12,
                systemUtterances: candidates
            ) == false,
            "repetir agora o que a caixa disse no começo do parágrafo é fala do usuário"
        )
    }

    @Test("Eco longo segmentado, com as duas partes sobrepondo, continua suprimindo")
    func compositeWithBothPartsOverlappingStillSuppresses() {
        let x = "vamos fechar o contrato"
        let y = "na semana passada mesmo"
        let candidates = [
            utterance(x, start: 0, end: 7),
            utterance(y, start: 7, end: 10)
        ]
        let composite = MeetingEchoTextMatch.contiguousComposites(candidates)
        #expect(
            composite[0].admissibleText(micStart: 0, micEnd: 10, jitter: 0.6) == "\(x) \(y)"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: "\(x) \(y)",
                micStart: 0,
                micEnd: 10,
                systemUtterances: candidates
            )
        )
    }

    // MARK: - Prazo causal do atraso

    @Test("Atraso tem prazo: passado o trail máximo + 2s o candidato morre")
    func laggingCandidateExpires() {
        // mic [10, x] contra um final [10,12] com o system mudo depois.
        #expect(
            MeetingEchoTextMatch.candidateIsLagging(
                micStart: 10, micEnd: 13.5, systemStart: 10, systemEnd: 12
            ),
            "trail 1,5s: ainda é atraso plausível"
        )
        #expect(
            MeetingEchoTextMatch.candidateIsLagging(
                micStart: 10, micEnd: 15, systemStart: 10, systemEnd: 12
            ),
            "trail 3,0s é o limite inclusivo"
        )
        #expect(
            MeetingEchoTextMatch.candidateIsLagging(
                micStart: 10, micEnd: 15.1, systemStart: 10, systemEnd: 12
            ) == false,
            "além disso o candidato está morto — o persist reprovaria por trail de qualquer forma"
        )
    }

    @Test("Finais do system são podados por progresso de relógio, com o system mudo")
    func finalsArePrunedByClockProgress() {
        let old = utterance("vamos fechar o contrato na semana passada", start: 10, end: 12)
        #expect(
            MeetingEchoTextMatch.echoCandidates(
                finals: [old],
                currentVolatileText: "",
                currentVolatileWindow: nil,
                captureClock: 26
            ).count == 1,
            "16s ainda dentro da retenção? não: 26-12 = 14 <= 15"
        )
        #expect(
            MeetingEchoTextMatch.echoCandidates(
                finals: [old],
                currentVolatileText: "",
                currentVolatileWindow: nil,
                captureClock: 28
            ).isEmpty,
            "sem final novo chegando, a lista envelhecia parada e o final antigo julgava para sempre"
        )
    }

    // MARK: - Evidência causal (lead/trail exclusivos do mic)

    @Test("Overlap 0,70 com 3s próprios ANTES do system NÃO suprime — sobreposição não é causa")
    func exclusiveMicLeadKeepsGenuineSpeechBeforeTheEcho() {
        let speech = "vamos fechar o contrato na semana passada"
        // O cenário exato do Codex: mic [0,10] com fala própria em [0,3], system
        // [3,10] repetindo o resto. Overlap dá exatamente 0,70 e a cobertura textual
        // dá 1 — o turn INTEIRO era descartado no persistLiveFinal.
        #expect(
            abs(
                MeetingEchoTextMatch.intervalOverlapFraction(
                    micStart: 0, micEnd: 10, systemStart: 3, systemEnd: 10
                ) - 0.7
            ) < 0.0001
        )
        #expect(
            MeetingEchoTextMatch.micCoverage(mic: speech, system: speech) == 1.0
        )
        #expect(
            MeetingEchoTextMatch.exclusiveMicLead(micStart: 0, systemStart: 3) == 3
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 0,
                micEnd: 10,
                systemUtterances: [utterance(speech, start: 3, end: 10)]
            ) == false,
            "3s de mic exclusivo antes do system é fala genuína, não eco"
        )
    }

    @Test("Overlap 0,70 com 3s próprios DEPOIS do system NÃO suprime — a borda espelhada")
    func exclusiveMicTrailKeepsGenuineSpeechAfterTheEcho() {
        let speech = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.exclusiveMicTrail(micEnd: 10, systemEnd: 7) == 3
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 0,
                micEnd: 10,
                systemUtterances: [utterance(speech, start: 0, end: 7)]
            ) == false,
            "eco não sobra 3s depois da fonte — ali há resposta do usuário colada no eco"
        )
    }

    @Test("Eco com jitter 0,6s nas duas bordas ainda suprime")
    func segmentationJitterStillSuppresses() {
        let speech = "vamos fechar o contrato na semana passada"
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 10,
                micEnd: 14,
                systemUtterances: [utterance(speech, start: 10.6, end: 13.4)]
            ),
            "0,6s de jitter em cada borda é segmentação do ASR, não fala própria"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 10, micEnd: 14, systemStart: 10.6, systemEnd: 13.4
            )
        )
    }

    @Test("Fronteiras: overlap 0,699/0,700/0,701 e lead 0,9/1,0/1,1")
    func causalPredicateBoundaries() {
        let speech = "vamos fechar o contrato na semana passada"
        // Overlap: com lead/trail dentro do limite, 0,699 ainda reprova e 0,700 passa.
        // mic [0,10]; system [0, x] ⇒ overlap = x/10, trail = 10 - x (fora do limite),
        // então a fronteira do overlap é medida com system cobrindo o fim: [10-x, 10].
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 1, systemStart: 0.301, systemEnd: 1
            ) == false,
            "overlap 0,699 reprova"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 1, systemStart: 0.300, systemEnd: 1
            ),
            "overlap 0,700 passa (limiar inclusivo) e o lead 0,3 cabe em 1s"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 1, systemStart: 0.299, systemEnd: 1
            ),
            "overlap 0,701 passa"
        )

        // Lead exclusivo com overlap folgado (mic [0,20], system cobre até o fim).
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 20, systemStart: 0.9, systemEnd: 20
            ),
            "lead 0,9s cabe no jitter"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 20, systemStart: 1.0, systemEnd: 20
            ),
            "lead 1,0s é o limite inclusivo"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 20, systemStart: 1.1, systemEnd: 20
            ) == false,
            "lead 1,1s já é fala própria antes do eco"
        )
        // Trail exclusivo, mesma fronteira do outro lado.
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 20, systemStart: 0, systemEnd: 19.1
            ),
            "trail 0,9s cabe no jitter"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 20, systemStart: 0, systemEnd: 19.0
            ),
            "trail 1,0s é o limite inclusivo"
        )
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 0, micEnd: 20, systemStart: 0, systemEnd: 18.9
            ) == false,
            "trail 1,1s já é fala própria depois do eco"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: speech,
                micStart: 0,
                micEnd: 20,
                systemUtterances: [utterance(speech, start: 1.1, end: 20)]
            ) == false
        )
    }

    @Test("Repetição posterior sem sobreposição continua fora do predicado causal")
    func laterRepetitionWithoutOverlapIsNotEcho() {
        #expect(
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: 10, micEnd: 12, systemStart: 20, systemEnd: 22
            ) == false
        )
    }

    @Test("Volátil sem atualização recente no relógio da captura não é candidato")
    func staleVolatileIsNotAnEchoCandidate() {
        let leftover = utterance("vamos fechar o contrato na semana passada", start: 10, end: 12)
        let stillLive = MeetingEchoTextMatch.echoCandidates(
            finals: [],
            currentVolatileText: leftover.text,
            currentVolatileWindow: leftover,
            captureClock: 14
        )
        #expect(
            stillLive.count == 1,
            "2s depois ainda está dentro do slack de 3s — o final do system pode estar em voo"
        )
        let expired = MeetingEchoTextMatch.echoCandidates(
            finals: [],
            currentVolatileText: leftover.text,
            currentVolatileWindow: leftover,
            captureClock: 16
        )
        #expect(expired.isEmpty)
    }

    @Test("Volátil retraído não entra nos candidatos de eco")
    func retractedVolatileIsNotAnEchoCandidate() {
        let leftover = utterance("vamos fechar o contrato na semana passada", start: 10, end: 12)
        let candidates = MeetingEchoTextMatch.echoCandidates(
            finals: [],
            currentVolatileText: "",
            currentVolatileWindow: leftover
        )
        #expect(candidates.isEmpty)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: leftover.text,
                micStart: 10.1,
                micEnd: 12,
                systemUtterances: candidates
            ) == false,
            "lastSystemVolatile sozinho (hipótese já retraída) não pode apagar o mic"
        )
    }

    @Test("Volátil corrente entra nos candidatos de eco")
    func currentVolatileIsAnEchoCandidate() {
        let window = utterance("hipótese velha", start: 10, end: 12)
        let current = "vamos fechar o contrato na semana passada"
        let candidates = MeetingEchoTextMatch.echoCandidates(
            finals: [],
            currentVolatileText: current,
            currentVolatileWindow: window
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].text == current)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: current,
                micStart: 10.1,
                micEnd: 12,
                systemUtterances: candidates
            )
        )
    }
}
