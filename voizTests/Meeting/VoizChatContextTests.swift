import Foundation
import Testing

@Suite("Chat — metadados persistidos de reuniões")
struct VoizChatContextTests {
    private func sample() -> MeetingSession {
        MeetingSession(
            title: "Entrevista de teste",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_180),
            pausedDuration: 60,
            turns: [
                MeetingTurn(source: .microphone, speakerName: "Ana", text: "Primeira fala", startTime: 0, endTime: 60),
                MeetingTurn(source: .microphone, speakerName: "Ana", text: "Segunda fala", startTime: 90, endTime: 120),
                MeetingTurn(source: .systemAudio, speakerName: "Bruno", text: "Resposta", startTime: 60, endTime: 90)
            ],
            summary: MeetingSummary(title: "Entrevista", sections: [
                .paragraph(id: "overview", title: "Resumo", text: "Conversa de teste"),
                .bullets(id: "decisions", title: "Decisões", items: ["Avançar para a próxima etapa"]),
                .actions(id: "tasks", title: "Ações", items: [MeetingActionItem(text: "Marcar retorno", assignee: "Ana", dueDate: "sexta")])
            ]),
            chapters: [MeetingChapter(title: "Experiência profissional", startTime: 60)],
            isProcessingCompleted: true
        )
    }

    private func prompt(_ meetings: [MeetingSession], attachments: [ChatAttachment] = [], folders: [MeetingFolder] = []) -> String {
        VoizChatPromptBuilder.systemPrompt(
            context: VoizChatContext(meetings: meetings, folders: folders),
            attachments: attachments,
            answerLanguage: "Português"
        )
    }

    @Test("Horários persistidos alimentam tempo de fala sem reprocessar sessões antigas")
    func savedLegacyTimingReachesChat() throws {
        var session = sample()
        session.isProcessingCompleted = nil
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: data)
        #expect(restored.chaptersError == nil)
        let text = prompt([restored])
        #expect(text.contains("Duração da reunião (sem pausas): 00:02:00"))
        #expect(text.contains("Ana: 00:01:30 (75.0%)"))
        #expect(text.contains("Bruno: 00:00:30 (25.0%)"))
        #expect(text.contains("[00:01:00] Experiência profissional"))
        #expect(text.contains("Avançar para a próxima etapa"))
        #expect(text.contains("responsável: Ana"))
        #expect(text.contains("prazo: sexta"))
        #expect(text.contains(ChatCitation.marker(kind: .meeting, id: session.id)))
    }

    @Test("Reuniões fora da janela de resumos continuam com tempo de fala consultável")
    func olderMeetingTimingIsInCompleteIndex() {
        let older = sample()
        let newer = (1...15).map { index in
            MeetingSession(title: "Mais recente \(index)", startedAt: older.startedAt.addingTimeInterval(Double(index)), endedAt: older.endedAt)
        }
        let text = prompt(newer + [older])
        #expect(text.contains("Ana: 00:01:30 (75.0%)"))
        #expect(!text.contains("Avançar para a próxima etapa"))
    }

    @Test("Anexar reunião ou pasta mantém tempos, capítulos e seções personalizadas")
    func attachmentsRetainMetadata() {
        let folder = MeetingFolder(name: "Entrevistas")
        var session = sample()
        session.folderId = folder.id
        session.turns[0].text = String(repeating: "texto ", count: 12_000)
        for attachment in [
            ChatAttachment(id: session.id, kind: .meeting, title: session.title),
            ChatAttachment(id: folder.id, kind: .folder, title: folder.name)
        ] {
            let text = prompt([session], attachments: [attachment], folders: [folder])
            #expect(text.contains("Ana: 00:01:30 (75.0%)"))
            #expect(text.contains("[00:01:00] Experiência profissional"))
            #expect(text.contains("Avançar para a próxima etapa"))
        }
    }

    @Test("Dados parciais e falta de horários não são apresentados como medição final")
    func partialAndMissingTiming() {
        var session = sample()
        session.isProcessingCompleted = false
        #expect(prompt([session]).contains("parcial; processamento pendente"))
        session.turns = [MeetingTurn(source: .microphone, speakerName: "Ana", text: "Só texto", startTime: 0, endTime: 0)]
        let text = prompt([session])
        #expect(text.contains("indisponível; não há intervalos de fala válidos"))
        #expect(!text.contains("Ana: 00:00:00"))
    }

    @Test("Renomes e novos intervalos refletem no chat depois de salvar e reabrir")
    func editsDoNotLeaveStaleStatistics() throws {
        var session = sample()
        for index in session.turns.indices where session.turns[index].speakerName == "Ana" {
            session.turns[index].speakerName = "Carla"
        }
        session.turns[1].endTime = 150
        session.chaptersError = "Falha de teste"
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        #expect(restored.chapters == session.chapters)
        #expect(restored.chaptersError == "Falha de teste")
        let text = prompt([restored])
        #expect(text.contains("Carla: 00:02:00 (80.0%)"))
        #expect(!text.contains("Ana: 00:01:30"))
    }
    @Test("Personal task context includes only explicit selections, even outside recent details")
    func followedTaskScope() {
        var session = sample()
        session.summary?.sections[2].actionItems[0].followed = true
        let newer = (1...15).map { index in
            MeetingSession(title: "Mais recente \(index)", startedAt: session.startedAt.addingTimeInterval(Double(index)), endedAt: session.endedAt)
        }
        let text = prompt(newer + [session])
        #expect(text.contains("ACOMPANHAMENTO EXPLÍCITO (1)"))
        #expect(text.contains("Marcar retorno"))
        session.summary?.sections[2].actionItems[0].followed = false
        let unselected = prompt(newer + [session])
        #expect(unselected.contains("ACOMPANHAMENTO EXPLÍCITO (0)"))
        #expect(!unselected.contains("Marcar retorno"))
    }

}
