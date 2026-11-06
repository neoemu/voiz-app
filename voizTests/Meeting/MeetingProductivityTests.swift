import Testing
import Foundation

@Suite("Meeting productivity")
struct MeetingProductivityTests {
    @Test("Older sessions retain note behavior; new sessions require opting in")
    func notesCompatibility() throws {
        let session = MeetingSession(notes: "private observation")
        #expect(!session.usesNotesInSummary)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json.removeValue(forKey: "includeNotesInSummary")
        json.removeValue(forKey: "contextSessionIDs")
        let legacy = try JSONDecoder().decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.usesNotesInSummary)
        #expect(legacy.contextSessionIDs == nil)
        #expect(legacy.notes == "private observation")
    }

    @Test("Task references remain distinct across meetings with the same task text")
    func taskSources() {
        let a = MeetingSession(title: "A", summary: .init(title: "A", sections: [.actions(id: "actions", title: "Actions", items: [.init(text: "Ship", followed: true)])]))
        let b = MeetingSession(title: "B", summary: .init(title: "B", sections: [.actions(id: "actions", title: "Actions", items: [.init(text: "Ship", followed: true)])]))
        let tasks = MeetingProductivity.tasks(in: [a, b])
        #expect(tasks.count == 2)
        #expect(Set(tasks.map(\.id)).count == 2)
        #expect(Set(tasks.map(\.sessionID)) == [a.id, b.id])
    }

    @Test("Legacy actions stay in meetings and are not followed until explicitly selected")
    func followingIsOptIn() throws {
        let legacy = Data("{\"id\":\"6C6A1B3E-9F44-4E71-9A0C-0E6F1B2D3A45\",\"text\":\"Action in a meeting\",\"done\":false}".utf8)
        var action = try JSONDecoder().decode(MeetingActionItem.self, from: legacy)
        #expect(!action.isFollowed)
        var session = MeetingSession(summary: .init(title: "Meeting", sections: [.actions(id: "a", title: "Actions", items: [action])]))
        #expect(MeetingProductivity.tasks(in: [session]).isEmpty)
        #expect(session.summary?.allActionItems.count == 1)
        action.followed = true
        action.done = true
        session.summary?.sections[0].actionItems[0] = action
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        #expect(MeetingProductivity.tasks(in: [restored]).first?.item.isFollowed == true)
        #expect(MeetingProductivity.tasks(in: [restored]).first?.item.done == true)
        session.summary?.sections[0].actionItems[0].followed = false
        #expect(MeetingProductivity.tasks(in: [session]).isEmpty)
        #expect(session.summary?.allActionItems[0].done == true)
        #expect(session.summary?.allActionItems[0].text == action.text)
    }

    @Test("Regeneration retains explicitly followed actions when AI omits or changes them")
    func followingSurvivesRegeneration() {
        let followed = MeetingActionItem(text: "Original action", assignee: "Ana", done: true, followed: true)
        let ignored = MeetingActionItem(text: "Unfollowed action")
        let old = MeetingSummary(title: "Old", sections: [.actions(id: "a", title: "Actions", items: [followed, ignored])])
        let fresh = MeetingSummary(title: "New", sections: [.actions(id: "b", title: "Actions", items: [.init(text: "Reworded action", assignee: "Ana")])])
        let result = MeetingProductivity.preservingTaskState(fresh, from: old)
        #expect(result.allActionItems.filter(\.isFollowed).map(\.id) == [followed.id])
        #expect(result.allActionItems.first { $0.id == followed.id }?.done == true)
        #expect(!result.allActionItems.contains { $0.id == ignored.id })
        let again = MeetingProductivity.preservingTaskState(fresh, from: result)
        #expect(again.allActionItems.filter(\.isFollowed).count == 1)
        let matching = MeetingSummary(title: "New", sections: [.actions(id: "b", title: "Actions", items: [.init(text: "Original action", assignee: "Ana")])])
        let matched = MeetingProductivity.preservingTaskState(matching, from: old)
        #expect(matched.allActionItems.count == 1)
        #expect(matched.allActionItems[0].isFollowed)
        #expect(matched.allActionItems[0].id == followed.id)
    }

    @Test("Regenerating carries completed status only to an unambiguous task with the same owner")
    func taskRegeneration() {
        let item = MeetingActionItem(text: "Ship release", assignee: "Ana", done: true)
        let old = MeetingSummary(title: "Old", sections: [.actions(id: "a", title: "Tasks", items: [item])])
        let fresh = MeetingSummary(title: "New", sections: [.actions(id: "b", title: "Next", items: [
            .init(text: "ship release", assignee: "Ana"), .init(text: "Ship release", assignee: "Bruno")
        ])])
        let result = MeetingProductivity.preservingTaskState(fresh, from: old)
        #expect(result.allActionItems[0].id == item.id)
        #expect(result.allActionItems[0].done)
        #expect(!result.allActionItems[1].done)
        var ambiguous = fresh
        ambiguous.sections[0].actionItems.append(.init(text: "Ship release", assignee: "Ana"))
        #expect(MeetingProductivity.preservingTaskState(ambiguous, from: old).allActionItems.allSatisfy { !$0.done })
    }

    @Test("Evidence rejects invented turns, out-of-range items and duplicate references")
    func evidenceValidation() throws {
        let turn = MeetingTurn(source: .microphone, speakerName: "Ana", text: "We agreed", startTime: 32, endTime: 34)
        let section = MeetingSummarySection.bullets(id: "decisions", title: "Decisions", items: ["Agreed"])
        let raw: [[String: Any]] = [
            ["itemIndex": 0, "turnIDs": [turn.id.uuidString, UUID().uuidString, turn.id.uuidString]],
            ["itemIndex": 12, "turnIDs": [turn.id.uuidString]],
            ["itemIndex": -1, "turnIDs": [turn.id.uuidString]],
            ["itemIndex": 0, "turnIDs": ["not-a-uuid"]]
        ]
        let validated = MeetingProductivity.validatedEvidence(raw, for: section, turns: [turn])
        #expect(validated == [.init(itemIndex: 0, turnIDs: [turn.id])])
        var cited = section
        cited.evidence = validated
        let decoded = try JSONDecoder().decode(MeetingSummarySection.self, from: JSONEncoder().encode(cited))
        #expect(decoded.evidence == validated)
        var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cited)) as? [String: Any])
        oldJSON.removeValue(forKey: "evidence")
        #expect(try JSONDecoder().decode(MeetingSummarySection.self, from: JSONSerialization.data(withJSONObject: oldJSON)).evidence == nil)
    }

    @Test("Context contains only selected meetings, includes task state and excludes manual notes")
    func selectedContext() {
        let selected = MeetingSession(title: "Allowed", notes: "PRIVATE-NOTE", summary: .init(title: "Allowed", sections: [.actions(id: "a", title: "Actions", items: [.init(text: "Done task", done: true)])]))
        let excluded = MeetingSession(title: "SECRET-MEETING")
        let result = MeetingProductivity.context(sessions: [excluded, selected], selectedIDs: [selected.id])
        #expect(result.contains(selected.id.uuidString))
        #expect(result.contains("[x] Done task"))
        #expect(!result.contains("SECRET-MEETING"))
        #expect(!result.contains("PRIVATE-NOTE"))
        #expect(MeetingProductivity.context(sessions: [selected], selectedIDs: []).isEmpty)
    }

    @Test("Selected context includes persisted timing and chapters without reprocessing")
    func selectedContextTiming() {
        let session = MeetingSession(
            title: "Daily de teste",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_180),
            pausedDuration: 60,
            turns: [
                MeetingTurn(source: .microphone, speakerName: "Ana", text: "Decisão", startTime: 0, endTime: 90),
                MeetingTurn(source: .systemAudio, speakerName: "Bruno", text: "Próximo passo", startTime: 90, endTime: 120)
            ],
            chapters: [.init(title: "Decisões e ações", startTime: 90)],
            isProcessingCompleted: true
        )
        let context = MeetingProductivity.context(sessions: [session], selectedIDs: [session.id])
        #expect(context.contains("Duração da reunião (sem pausas): 00:02:00"))
        #expect(context.contains("Ana: 00:01:30 (75.0%)"))
        #expect(context.contains("[00:01:30] Decisões e ações"))
        #expect(context.contains("Não estime por palavras"))
    }

    @Test("Commands expand only a complete first token and preserve extra instructions")
    func commandExpansion() {
        let recipes: [MeetingAIRecipe] = [.init(command: "riscos", title: "Risks", instruction: "List risks")]
        #expect(MeetingAIRecipe.expanded("/riscos for next week", recipes: recipes) == "List risks\nfor next week")
        #expect(MeetingAIRecipe.expanded("/riscos-extra", recipes: recipes) == "/riscos-extra")
        #expect(MeetingAIRecipe.expanded("Explain /riscos", recipes: recipes) == "Explain /riscos")
        #expect(!MeetingAIRecipe.validCommand("has space"))
        #expect(!MeetingAIRecipe.validCommand("/riscos"))
        #expect(MeetingAIRecipe.validCommand("riscos-2"))
    }

    @Test("Slash picker opens only while the first token is being typed")
    func slashCommandQuery() {
        #expect(ChatSlashCommand.query(in: "/") == "")
        #expect(ChatSlashCommand.query(in: "/ris") == "ris")
        #expect(ChatSlashCommand.query(in: "/riscos amanhã") == nil)
        #expect(ChatSlashCommand.query(in: "") == nil)
        #expect(ChatSlashCommand.query(in: "riscos") == nil)
    }

    @Test("Slash picker matches command prefix first, then command or title content")
    func slashCommandMatches() {
        let recipes: [MeetingAIRecipe] = [
            .init(command: "decisoes", title: "Decisões", instruction: "a"),
            .init(command: "riscos", title: "Riscos", instruction: "b"),
            .init(command: "followup", title: "Preparar follow-up", instruction: "c")
        ]
        #expect(ChatSlashCommand.matches(recipes, query: "").map(\.command) == ["decisoes", "riscos", "followup"])
        #expect(ChatSlashCommand.matches(recipes, query: "RI").map(\.command) == ["riscos"])
        #expect(ChatSlashCommand.matches(recipes, query: "prep").map(\.command) == ["followup"])
        #expect(ChatSlashCommand.matches(recipes, query: "s").map(\.command) == ["decisoes", "riscos"])
        #expect(ChatSlashCommand.matches(recipes, query: "xyz").isEmpty)
    }

    @Test("Applying an action replaces the typed command and keeps the remaining text")
    func slashCommandApply() {
        let recipe = MeetingAIRecipe(command: "riscos", title: "Riscos", instruction: "b")
        #expect(ChatSlashCommand.apply(recipe, to: "/ris") == "/riscos ")
        #expect(ChatSlashCommand.apply(recipe, to: "") == "/riscos ")
        #expect(ChatSlashCommand.apply(recipe, to: "para a sprint") == "/riscos para a sprint")
        #expect(ChatSlashCommand.apply(recipe, to: "/decisoes para a sprint") == "/riscos para a sprint")
    }
}
