import Combine
import Foundation
import Testing

@Suite("Player de reunião — índice e publicação do turno atual")
@MainActor
struct MeetingAudioPlayerTurnIndexTests {
    private func turn(id: UUID = UUID(), startTime: TimeInterval) -> MeetingTurn {
        MeetingTurn(
            id: id,
            source: .systemAudio,
            speakerName: "Participante",
            text: "fala sintética",
            startTime: startTime,
            endTime: startTime + 1
        )
    }

    @Test("Fronteiras exatas avançam para o turno que começa naquele instante")
    func exactBoundariesSelectTheNewTurn() {
        let first = turn(startTime: 1)
        let second = turn(startTime: 5)
        let third = turn(startTime: 10)
        let index = MeetingTurnPlaybackIndex(turns: [first, second, third])

        #expect(index.turnID(at: 1) == first.id)
        #expect(index.turnID(at: 4.999) == first.id)
        #expect(index.turnID(at: 5) == second.id)
        #expect(index.turnID(at: 10) == third.id)

        // Uma regressão para `< time` escolheria `first` exatamente em 5 s.
        let defectiveStrictBoundary = [first, second, third]
            .last(where: { $0.startTime < 5 })?.id
        #expect(defectiveStrictBoundary == first.id)
        #expect(index.turnID(at: 5) != defectiveStrictBoundary)
    }

    @Test("Antes do primeiro não há destaque; depois do último o último permanece")
    func outsideTimelineBounds() {
        let first = turn(startTime: 3)
        let last = turn(startTime: 8)
        let index = MeetingTurnPlaybackIndex(turns: [first, last])

        #expect(index.turnID(at: 2.999) == nil)
        #expect(index.turnID(at: 80) == last.id)

        // Um fallback defeituoso para o primeiro turno destacaria fala antes de ela começar.
        let defectiveBeforeFirstFallback = [first, last].first?.id
        #expect(defectiveBeforeFirstFallback != index.turnID(at: 2.999))
    }

    @Test("Lista vazia nunca produz turno")
    func emptyTranscript() {
        let index = MeetingTurnPlaybackIndex(turns: [])
        #expect(index.turnID(at: -1) == nil)
        #expect(index.turnID(at: 0) == nil)
        #expect(index.turnID(at: 1_000) == nil)
    }

    @Test("Tempos iguais preservam a semântica de último empate")
    func duplicateStartTimesSelectLastSourceTurn() {
        let firstAtTwo = turn(startTime: 2)
        let lastAtTwo = turn(startTime: 2)
        let later = turn(startTime: 4)
        let index = MeetingTurnPlaybackIndex(turns: [firstAtTwo, lastAtTwo, later])

        #expect(index.turnID(at: 2) == lastAtTwo.id)
        #expect(index.turnID(at: 3.999) == lastAtTwo.id)

        // Um lower-bound que para no primeiro empate mudaria o destaque neste caso.
        #expect(firstAtTwo.id != index.turnID(at: 2))
    }

    @Test("Entrada fora de ordem é indexada uma única vez em ordem temporal")
    func unsortedTranscriptIsIndexedChronologically() {
        let late = turn(startTime: 10)
        let early = turn(startTime: 0)
        let middle = turn(startTime: 5)
        let index = MeetingTurnPlaybackIndex(turns: [late, early, middle])

        #expect(index.turnID(at: 0) == early.id)
        #expect(index.turnID(at: 7) == middle.id)
        #expect(index.turnID(at: 10) == late.id)
    }

    @Test("Consulta permanece logarítmica em transcript gigante")
    func lookupHasLogarithmicComparisonBound() {
        let turns = (0..<4_096).map { turn(startTime: TimeInterval($0)) }
        let index = MeetingTurnPlaybackIndex(turns: turns)
        let lookup = index.lookup(at: 4_095)

        #expect(lookup.turnID == turns.last?.id)
        #expect(lookup.comparisonCount <= 13)

        // A antiga varredura `last(where:)` precisa inspecionar os 4.096 itens neste cenário;
        // esse valor reprovaria explicitamente o teto acima se reintroduzido na implementação.
        var linearComparisons = 0
        var linearResult: UUID?
        for turn in turns {
            linearComparisons += 1
            if turn.startTime <= 4_095 { linearResult = turn.id }
        }
        #expect(linearResult == lookup.turnID)
        #expect(linearComparisons > 13)
    }

    @Test("Ticks dentro do mesmo turno não publicam novamente")
    func sameTurnTicksDoNotPublish() {
        let first = turn(startTime: 0)
        let second = turn(startTime: 5)
        let index = MeetingTurnPlaybackIndex(turns: [first, second])
        let state = MeetingTurnPlaybackState()
        var emissions: [UUID?] = []
        let observation = state.$currentTurnID
            .dropFirst()
            .sink { emissions.append($0) }

        #expect(state.updateCurrentTurnID(index.turnID(at: 0)))
        #expect(state.updateCurrentTurnID(index.turnID(at: 0.2)) == false)
        #expect(state.updateCurrentTurnID(index.turnID(at: 4.8)) == false)
        #expect(emissions == [first.id])

        #expect(state.updateCurrentTurnID(index.turnID(at: 5)))
        #expect(state.updateCurrentTurnID(index.turnID(at: 5.2)) == false)
        #expect(emissions == [first.id, second.id])

        // Sem o guard de igualdade seriam cinco emissões, reproduzindo a invalidação por tick.
        #expect(emissions.count == 2)
        withExtendedLifetime(observation) {}
    }

    @Test("Trocar o transcript reindexa o destaque no tempo atual")
    func replacingTurnsReindexesCurrentPlaybackPosition() {
        let originalFirst = turn(startTime: 0)
        let originalCurrent = turn(startTime: 5)
        let replacementFirst = turn(startTime: 0)
        let replacementCurrent = turn(startTime: 5)
        let state = MeetingTurnPlaybackState(turns: [originalFirst, originalCurrent])
        var emissions: [UUID?] = []
        let observation = state.$currentTurnID
            .dropFirst()
            .sink { emissions.append($0) }

        // Simula um player já carregado e posicionado no segundo turno.
        #expect(state.updateCurrentTime(6))
        #expect(state.currentTurnID == originalCurrent.id)

        // Reprocessar preserva o ID da sessão e os tempos, mas cria novos UUIDs de turnos.
        #expect(
            state.updateTurns(
                [replacementFirst, replacementCurrent],
                at: 6
            )
        )
        #expect(state.currentTurnID == replacementCurrent.id)
        #expect(emissions == [originalCurrent.id, replacementCurrent.id])

        // O defeito congelado continuaria resolvendo o UUID morto do transcript original.
        let defectiveFrozenIndex = MeetingTurnPlaybackIndex(
            turns: [originalFirst, originalCurrent]
        )
        #expect(defectiveFrozenIndex.turnID(at: 6) == originalCurrent.id)
        #expect(defectiveFrozenIndex.turnID(at: 6) != replacementCurrent.id)
        withExtendedLifetime(observation) {}
    }
}
