import Foundation
import Testing

@Suite("Eco ao vivo — hold-off e histerese da bolha volátil do mic")
struct MeetingLiveMicVolatileGateTests {

    private let echo = "vamos fechar o contrato na semana passada"

    private func utterance(
        _ text: String,
        start: TimeInterval = 10,
        end: TimeInterval = 12
    ) -> MeetingEchoTextMatch.Utterance {
        MeetingEchoTextMatch.Utterance(text: text, startTime: start, endTime: end)
    }

    @Test("Mic chega antes do system em <0,6s: bolha nunca aparece")
    func micLeadingSystemNeverFlashes() {
        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 10.1,
            clock: 10.1,
            systemUtterances: []
        )
        #expect(gate.phase == .holding)
        #expect(gate.displaysText == false)

        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 10.4,
            clock: 10.4,
            systemUtterances: [utterance(echo, start: 10, end: 10.4)]
        )
        #expect(gate.phase == .suppressed)
        #expect(
            gate.displaysText == false,
            "sem hold-off a bolha teria aparecido em 10.1 e sumido em 10.4 — o flick"
        )
    }

    @Test("Sem hold-off o flicker volta (defeito antigo)")
    func withoutHoldOffMicFlashesBeforeSystem() {
        var gate = MeetingLiveMicVolatileGate()
        gate.holdOff = 0
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 10.1,
            clock: 10.1,
            systemUtterances: []
        )
        #expect(
            gate.displaysText,
            "hold-off 0 reproduz o defeito: a bolha aparece antes do system e some depois"
        )
    }

    @Test("Double-talk: cobertura abaixo de 0,45 reaparece com o texto acumulado")
    func doubleTalkReappearsBelowRevealThreshold() {
        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 10.2,
            clock: 10.2,
            systemUtterances: [utterance(echo)]
        )
        #expect(gate.phase == .suppressed)

        let doubleTalk = echo + " prefiro adiar a decisao ate segunda feira agora mesmo sem pressa nenhuma"
        gate.apply(
            micText: doubleTalk,
            micStart: 10,
            micEnd: 14,
            clock: 14,
            systemUtterances: [utterance(echo)]
        )
        #expect(MeetingEchoTextMatch.bestNearbyCoverage(
            micText: doubleTalk,
            micStart: 10,
            micEnd: 14,
            systemUtterances: [utterance(echo)]
        ) < MeetingLiveMicVolatileGate.revealBelow)
        #expect(gate.phase == .holding)
        #expect(gate.displaysText == false)

        gate.apply(
            micText: doubleTalk,
            micStart: 10,
            micEnd: 14.7,
            clock: 14.7,
            systemUtterances: [utterance(echo)]
        )
        #expect(gate.phase == .visible)
        #expect(gate.displaysText)
    }

    @Test("Histerese: oscilação 0,55–0,75 não faz a bolha piscar")
    func hysteresisBandDoesNotFlicker() {
        let system = "alpha bravo charlie delta echo foxtrot"
        let mid = "alpha bravo charlie delta echo foxtrot um dois tres quatro"
        let high = "alpha bravo charlie delta echo foxtrot um dois"
        #expect(MeetingEchoTextMatch.micCoverage(mic: mid, system: system) > 0.55)
        #expect(MeetingEchoTextMatch.micCoverage(mic: mid, system: system) < 0.70)
        #expect(MeetingEchoTextMatch.micCoverage(mic: high, system: system) >= 0.70)
        #expect(MeetingEchoTextMatch.micCoverage(mic: high, system: system) <= 0.80)

        let window = utterance(system, start: 10, end: 14)
        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: system,
            micStart: 10,
            micEnd: 11,
            clock: 11,
            systemUtterances: [window]
        )
        #expect(gate.phase == .suppressed)

        gate.apply(
            micText: mid,
            micStart: 10,
            micEnd: 12,
            clock: 12,
            systemUtterances: [window]
        )
        #expect(gate.phase == .suppressed)
        #expect(gate.displaysText == false)

        gate.apply(
            micText: high,
            micStart: 10,
            micEnd: 13,
            clock: 13,
            systemUtterances: [window]
        )
        #expect(gate.phase == .suppressed)
        #expect(gate.displaysText == false)
    }

    @Test("Fone: sem system a bolha aparece depois do hold-off de 0,6s")
    func headphonesAppearAfterHoldOff() {
        var gate = MeetingLiveMicVolatileGate()
        let speech = "prefiro adiar a decisao ate segunda"
        gate.apply(
            micText: speech,
            micStart: 10,
            micEnd: 10.2,
            clock: 10.2,
            systemUtterances: []
        )
        #expect(gate.phase == .holding)
        #expect(gate.displaysText == false)

        gate.apply(
            micText: speech,
            micStart: 10,
            micEnd: 10.7,
            clock: 10.7,
            systemUtterances: []
        )
        #expect(gate.displaysText == false, "0,5s ainda em hold")

        gate.apply(
            micText: speech,
            micStart: 10,
            micEnd: 10.85,
            clock: 10.85,
            systemUtterances: []
        )
        #expect(gate.phase == .visible)
        #expect(gate.displaysText)
    }

    @Test("System 2s depois do mic: a bolha do usuário aparece — não é eco")
    func userFirstThenSystemRepeatDoesNotHideVolatile() {
        var gate = MeetingLiveMicVolatileGate()
        let speech = echo
        gate.apply(
            micText: speech,
            micStart: 10,
            micEnd: 10.7,
            clock: 10.7,
            systemUtterances: []
        )
        gate.apply(
            micText: speech,
            micStart: 10,
            micEnd: 12,
            clock: 12,
            systemUtterances: [utterance(speech, start: 12, end: 14)]
        )
        #expect(gate.phase != .suppressed)
        #expect(
            gate.displaysText,
            "janela simétrica voltaria a ocultar a fala do usuário quando Eles repetem"
        )
    }

    @Test("Jitter 0,6s com sobreposição: a bolha do mic some (é eco)")
    func overlappingJitterStillHidesMicVolatile() {
        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 10.4,
            clock: 10.4,
            systemUtterances: []
        )
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 14,
            clock: 14,
            systemUtterances: [utterance(echo, start: 10.6, end: 14)]
        )
        #expect(gate.phase == .suppressed)
        #expect(gate.displaysText == false)
    }

    @Test("Mesmo predicado causal no gate: 3s de mic exclusivo não ocultam a bolha")
    func gateUsesTheSameCausalPredicate() {
        var gate = MeetingLiveMicVolatileGate()
        gate.holdOff = 0
        // mic [0,10] × system [3,10]: overlap 0,70 e cobertura 1 — o gate ocultava
        // a bolha do usuário que já falava desde 0.
        gate.apply(
            micText: echo,
            micStart: 0,
            micEnd: 10,
            clock: 10,
            systemUtterances: [utterance(echo, start: 3, end: 10)]
        )
        #expect(gate.phase != .suppressed)
        #expect(gate.displaysText)

        // O mesmo candidato causalmente compatível continua suprimindo.
        var echoGate = MeetingLiveMicVolatileGate()
        echoGate.apply(
            micText: echo,
            micStart: 0,
            micEnd: 10,
            clock: 10,
            systemUtterances: [utterance(echo, start: 0.6, end: 10)]
        )
        #expect(echoGate.phase == .suppressed)
        #expect(echoGate.displaysText == false)
    }

    @Test("Atraso do system não faz a bolha piscar: suppressed → lag >1s por >0,6s → catch-up")
    func systemLagNeverRevealsTheBubble() {
        var gate = MeetingLiveMicVolatileGate()

        // 1. Eco julgado: a bolha some.
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 12,
            clock: 12,
            systemUtterances: [utterance(echo, start: 10, end: 12)]
        )
        #expect(gate.phase == .suppressed)

        // 2. O mic volátil continua crescendo (é o mesmo eco chegando) e o
        //    volátil do system fica para trás: mic end passa de system end + 1s.
        //    Antes, o candidato virava "inelegível" e o suppressed caía em
        //    holding; com o atraso persistindo além do hold-off, a bolha
        //    aparecia — e sumia de novo no catch-up. O flick.
        #expect(
            MeetingEchoTextMatch.candidateIsLagging(
                micStart: 10, micEnd: 13.2, systemStart: 10, systemEnd: 12
            )
        )
        for clock in [13.2, 13.6, 14.0, 14.4] {
            gate.apply(
                micText: echo,
                micStart: 10,
                micEnd: clock,
                clock: clock,
                systemUtterances: [utterance(echo, start: 10, end: 12)]
            )
            #expect(gate.phase == .suppressed, "atraso do system em t=\(clock) não pode revelar a bolha")
            #expect(gate.displaysText == false)
        }

        // 3. Catch-up: o system alcança e o julgamento volta a valer.
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 14.4,
            clock: 14.5,
            systemUtterances: [utterance(echo, start: 10, end: 14.4)]
        )
        #expect(gate.phase == .suppressed)
        #expect(gate.displaysText == false)
    }

    @Test("Final antigo + system mudo: a bolha do parágrafo aparece depois do prazo")
    func staleFinalDoesNotTrapTheBubbleForever() {
        var gate = MeetingLiveMicVolatileGate()
        let stale = utterance(echo, start: 10, end: 12)

        // O eco é julgado e a bolha some.
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 12,
            clock: 12,
            systemUtterances: [stale]
        )
        #expect(gate.phase == .suppressed)

        // O system fica MUDO: nenhum final novo chega, o de [10,12] é o único
        // candidato. O usuário emenda um parágrafo que segue além de 13.
        // Curto o bastante para a cobertura contra o candidato continuar acima do
        // reveal: assim o teste isola o PRAZO do atraso, e não o caminho do
        // conteúdo (que já tem teste próprio).
        let paragraph = echo + " e depois revisamos"
        for clock in [13.5, 14.5] {
            gate.apply(
                micText: paragraph,
                micStart: 10,
                micEnd: clock,
                clock: clock,
                systemUtterances: [stale]
            )
            #expect(gate.phase != .visible, "dentro do prazo o atraso ainda segura")
        }

        // Passado o prazo (trail > 1s + 2s de margem), o candidato está morto:
        // o gate volta ao ciclo normal e a bolha aparece depois do hold-off.
        gate.apply(
            micText: paragraph,
            micStart: 10,
            micEnd: 15.2,
            clock: 15.2,
            systemUtterances: [stale]
        )
        #expect(gate.phase == .holding)
        gate.apply(
            micText: paragraph,
            micStart: 10,
            micEnd: 16,
            clock: 16,
            systemUtterances: [stale]
        )
        #expect(gate.phase == .visible)
        #expect(gate.displaysText)

        // Consistência display/persist: o final desse parágrafo TAMBÉM não é
        // suprimido. Se divergissem, o turn persistia sem nunca ter aparecido.
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: paragraph,
                micStart: 10,
                micEnd: 16,
                systemUtterances: [stale]
            ) == false
        )
    }

    @Test("O atraso julga pelo texto ADMISSÍVEL, não pelo texto bruto do composto")
    func laggingUsesAdmissibleTextOfTheCandidate() {
        // O system falou `echo` em [10,20] e "certo" em [20,22]; o usuário
        // REPETE `echo` a partir de 19,5. O composto [10,22] contém o texto
        // inteiro, então julgar pelo texto bruto dava cobertura 1,0 e o
        // "atraso" segurava a bolha genuína. Pelo texto admissível para
        // [19,5;24] sobra quase nada do começo do composto.
        let candidates = [
            utterance(echo, start: 10, end: 20),
            utterance("certo", start: 20, end: 22)
        ]
        let composite = MeetingEchoTextMatch.contiguousComposites(candidates)
        #expect(
            MeetingEchoTextMatch.candidateIsLagging(
                micStart: 19.5, micEnd: 24, systemStart: 10, systemEnd: 22
            ),
            "o composto está atrasado 2s em relação ao mic — dentro do prazo"
        )
        #expect(
            MeetingEchoTextMatch.micCoverage(mic: echo, system: composite[0].text) >= 0.45,
            "pelo texto bruto o atraso seguraria a bolha"
        )
        #expect(
            MeetingEchoTextMatch.micCoverage(
                mic: echo,
                system: composite[0].admissibleText(micStart: 19.5, micEnd: 24, jitter: 0.6)
            ) < MeetingLiveMicVolatileGate.revealBelow
        )

        var gate = MeetingLiveMicVolatileGate()
        gate.holdOff = 0
        gate.apply(
            micText: echo,
            micStart: 19.5,
            micEnd: 24,
            clock: 24,
            systemUtterances: candidates
        )
        #expect(gate.phase == .visible)
        #expect(
            gate.displaysText,
            "julgar pelo texto bruto prendia a bolha do usuário em holding"
        )
    }

    @Test("Divergência deliberada gate/persist no candidato simples: só no sentido seguro")
    func gateMayHideWhatPersistKeeps() {
        // O gate enxerga o texto inteiro do candidato simples (anti-flicker) e
        // o persist filtra por token. Onde os dois divergem, o gate é o MAIS
        // supressivo: a bolha some por um instante e o final aparece logo
        // depois. O sentido perigoso — bolha visível e turn descartado — não
        // pode acontecer, porque o gate suprime num superconjunto.
        let x = "vamos fechar o contrato"
        let candidate = utterance("\(x) e depois vemos o resto disso aqui agora", start: 0, end: 10)

        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: x,
                micStart: 3,
                micEnd: 10,
                systemUtterances: [candidate]
            ) == false,
            "persist: o turn fica"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: x,
                micStart: 3,
                micEnd: 10,
                systemUtterances: [candidate],
                perTokenOnSimpleCandidates: false,
                fuzzyTokenMatching: true
            ),
            "gate: a bolha some — transitório, e o final entra logo em seguida"
        )

        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: x,
            micStart: 3,
            micEnd: 10,
            clock: 10,
            systemUtterances: [candidate]
        )
        #expect(gate.phase == .suppressed)
        #expect(gate.displaysText == false)

        // O casamento exato do persist (r10) é a SEGUNDA razão para a mesma
        // direção, e agora ela é trivial: token idêntico é um subconjunto do
        // que o fuzzy do gate casa. A correção de uma palavra fica no
        // transcript; a bolha pode ter sumido no caminho.
        let corrected = "vamos fechar o contato"
        let spoken = utterance("vamos fechar o contrato", start: 0, end: 4)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: corrected,
                micStart: 0,
                micEnd: 4,
                systemUtterances: [spoken]
            ) == false,
            "persist com casamento exato: mantém"
        )
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: corrected,
                micStart: 0,
                micEnd: 4,
                systemUtterances: [spoken],
                perTokenOnSimpleCandidates: false,
                fuzzyTokenMatching: true
            ),
            "gate com fuzzy: suprime — o superconjunto continua valendo"
        )
    }

    @Test("Atraso não segura a bolha quando o CONTEÚDO já desmente o eco")
    func laggingCandidateDoesNotBlockWhenContentRefutesTheEcho() {
        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 12,
            clock: 12,
            systemUtterances: [utterance(echo, start: 10, end: 12)]
        )
        #expect(gate.phase == .suppressed)

        // O usuário emenda fala própria: a cobertura cai abaixo do reveal. O
        // candidato continua atrasado, mas quem manda aí é o conteúdo.
        let doubleTalk = echo + " prefiro adiar a decisao ate segunda feira agora mesmo sem pressa nenhuma"
        gate.apply(
            micText: doubleTalk,
            micStart: 10,
            micEnd: 16,
            clock: 16,
            systemUtterances: [utterance(echo, start: 10, end: 12)]
        )
        #expect(gate.phase == .holding)
        gate.apply(
            micText: doubleTalk,
            micStart: 10,
            micEnd: 16.7,
            clock: 16.7,
            systemUtterances: [utterance(echo, start: 10, end: 12)]
        )
        #expect(gate.phase == .visible)
        #expect(gate.displaysText)
    }

    @Test("Volátil do system em t=12 ainda julga o mic em t=14; saída de suppressed reentra em holding")
    func inFlightSystemFinalKeepsCandidateAndHoldOff() {
        let leftover = utterance(echo, start: 10, end: 12)
        let candidates = MeetingEchoTextMatch.echoCandidates(
            finals: [],
            currentVolatileText: echo,
            currentVolatileWindow: leftover,
            captureClock: 14
        )
        #expect(candidates.count == 1)
        #expect(
            MeetingEchoTextMatch.shouldSuppressMicDisplay(
                micText: echo,
                micStart: 10.2,
                micEnd: 12.4,
                systemUtterances: candidates
            ),
            "o final do mic ainda é julgado contra o volátil — o system final pode estar em voo"
        )

        var gate = MeetingLiveMicVolatileGate()
        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 12,
            clock: 12,
            systemUtterances: [leftover]
        )
        #expect(gate.phase == .suppressed)

        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 14,
            clock: 14,
            systemUtterances: []
        )
        #expect(gate.phase == .holding)
        #expect(
            gate.displaysText == false,
            "suppressed não pode pular direto para visible quando o candidato some"
        )

        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 14.5,
            clock: 14.5,
            systemUtterances: []
        )
        #expect(gate.displaysText == false, "hold-off de 0,6s ainda não venceu")

        gate.apply(
            micText: echo,
            micStart: 10,
            micEnd: 14.7,
            clock: 14.7,
            systemUtterances: []
        )
        #expect(gate.phase == .visible)
        #expect(gate.displaysText)
    }
}
