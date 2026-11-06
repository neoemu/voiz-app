import Foundation
import Testing

@Suite("Translation chunks preserve source order")
struct TranslationChunkOrderingTests {
    @Test func fasterLaterRepliesWaitForTheirPredecessor() throws {
        var results = OrderedTranslationResults()
        let firstReservation = results.reserve()
        let first = try #require(firstReservation)
        let secondReservation = results.reserve()
        let second = try #require(secondReservation)
        let thirdReservation = results.reserve()
        let third = try #require(thirdReservation)
        let completedThird = results.complete(third, text: "Terceiro.")
        #expect(completedThird)
        #expect(results.text.isEmpty)
        let completedSecond = results.complete(second, text: "Segundo.")
        #expect(completedSecond)
        #expect(results.text.isEmpty)
        let completedFirst = results.complete(first, text: "Primeiro.")
        #expect(completedFirst)
        #expect(results.text == "Primeiro. Segundo. Terceiro.")
    }

    @Test func failedPredecessorDoesNotLoseLaterReplies() throws {
        var results = OrderedTranslationResults()
        let firstReservation = results.reserve()
        let first = try #require(firstReservation)
        let secondReservation = results.reserve()
        let second = try #require(secondReservation)
        let thirdReservation = results.reserve()
        let third = try #require(thirdReservation)
        let completedThird = results.complete(third, text: "Última tarefa.")
        #expect(completedThird)
        let completedFirst = results.complete(first, text: "Primeira tarefa.")
        #expect(completedFirst)
        #expect(results.text == "Primeira tarefa.")
        let failedSecond = results.fail(second)
        #expect(failedSecond)
        #expect(results.text == "Primeira tarefa. Última tarefa.")
        let rejectedDuplicate = !results.complete(second, text: "Resposta duplicada depois da falha.")
        #expect(rejectedDuplicate)
    }

    @Test func timeoutPreservesFinishedSuccessorsAndRejectsLateReplies() throws {
        var results = OrderedTranslationResults()
        let missingReservation = results.reserve()
        let missing = try #require(missingReservation)
        let secondReservation = results.reserve()
        let second = try #require(secondReservation)
        let thirdReservation = results.reserve()
        let third = try #require(thirdReservation)
        let completedThird = results.complete(third, text: "Terceiro.")
        #expect(completedThird)
        let completedSecond = results.complete(second, text: "Segundo.")
        #expect(completedSecond)
        results.close()
        #expect(results.text == "Segundo. Terceiro.")
        let rejectedLateReply = !results.complete(missing, text: "Chegou depois do arquivamento.")
        #expect(rejectedLateReply)
        let rejectedReservation = results.reserve() == nil
        #expect(rejectedReservation)
        results.close()
        #expect(results.text == "Segundo. Terceiro.")
    }

    @Test func oldSessionRepliesCannotChangeNewRecordingAtSameOrdinal() throws {
        var results = OrderedTranslationResults()
        let oldReservation = results.reserve()
        let old = try #require(oldReservation)
        results.reset()
        let currentReservation = results.reserve()
        let current = try #require(currentReservation)
        let rejectedOldReply = !results.complete(old, text: "Gravação anterior.")
        #expect(rejectedOldReply)
        let rejectedOldFailure = !results.fail(old)
        #expect(rejectedOldFailure)
        #expect(results.text.isEmpty)
        let completedCurrent = results.complete(current, text: "Gravação atual.")
        #expect(completedCurrent)
        #expect(results.text == "Gravação atual.")
    }

    @Test func duplicateCompletionCannotOverwriteSavedText() throws {
        var results = OrderedTranslationResults()
        let reservation = results.reserve()
        let ticket = try #require(reservation)
        let completed = results.complete(ticket, text: "  Resultado preservado.  ")
        #expect(completed)
        let rejectedDuplicate = !results.complete(ticket, text: "Duplicado.")
        #expect(rejectedDuplicate)
        let rejectedFailure = !results.fail(ticket)
        #expect(rejectedFailure)
        results.close()
        #expect(results.text == "Resultado preservado.")
    }
}
