import Foundation

/// References refer to real turns, never to model-generated timestamps.
struct MeetingSummaryEvidence: Codable, Equatable {
    let itemIndex: Int
    let turnIDs: [UUID]
}

struct MeetingTaskReference: Identifiable {
    let sessionID: UUID
    let sessionTitle: String
    let meetingDate: Date
    let sectionID: String
    let item: MeetingActionItem
    var id: String { "\(sessionID)/\(sectionID)/\(item.id)" }
}

enum MeetingProductivity {
    static func tasks(in sessions: [MeetingSession]) -> [MeetingTaskReference] {
        sessions.sorted { $0.startedAt > $1.startedAt }.flatMap { session in
            (session.summary?.sections ?? []).filter { $0.kind == .actionItems }.flatMap { section in
                section.actionItems.filter { $0.isFollowed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                    MeetingTaskReference(sessionID: session.id, sessionTitle: session.title,
                                         meetingDate: session.startedAt, sectionID: section.id, item: $0)
                }
            }
        }
    }

    /// Regeneration must not reopen completed tasks or change their stable identities.
    /// Only an unambiguous exact normalized text + owner match carries state forward.
    static func preservingTaskState(_ generated: MeetingSummary, from previous: MeetingSummary?) -> MeetingSummary {
        guard let previous else { return generated }
        func key(_ item: MeetingActionItem) -> String {
            [item.text, item.assignee ?? ""].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.joined(separator: "\u{001F}")
        }
        let old = Dictionary(grouping: previous.allActionItems, by: key)
        let counts = Dictionary(grouping: generated.allActionItems, by: key)
        var result = generated
        for sectionIndex in result.sections.indices {
            for itemIndex in result.sections[sectionIndex].actionItems.indices {
                let item = result.sections[sectionIndex].actionItems[itemIndex]
                guard let matches = old[key(item)], matches.count == 1, counts[key(item)]?.count == 1 else { continue }
                result.sections[sectionIndex].actionItems[itemIndex].id = matches[0].id
                result.sections[sectionIndex].actionItems[itemIndex].done = matches[0].done
                result.sections[sectionIndex].actionItems[itemIndex].followed = matches[0].followed
            }
        }
        // A changed/omitted AI action must not silently discard something the user chose
        // to follow. Keep its original text and identity in an explicitly labelled section.
        var retainedIDs = Set(result.allActionItems.map(\.id))
        let retained = previous.allActionItems.filter { $0.isFollowed && retainedIDs.insert($0.id).inserted }
        if !retained.isEmpty {
            var sectionID = "voiz.followedActions"
            while result.sections.contains(where: { $0.id == sectionID }) { sectionID += ".retained" }
            result.sections.append(.actions(id: sectionID, title: String(localized: "Ações em acompanhamento"), items: retained))
        }
        return result
    }

    static func validatedEvidence(_ raw: Any?, for section: MeetingSummarySection, turns: [MeetingTurn]) -> [MeetingSummaryEvidence] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        let validIDs = Set(turns.map(\.id))
        let count: Int
        switch section.kind {
        case .paragraph: count = section.paragraph.isEmpty ? 0 : 1
        case .bullets: count = section.bullets.count
        case .actionItems: count = section.actionItems.count
        }
        var grouped: [Int: [UUID]] = [:]
        for entry in entries {
            guard let index = entry["itemIndex"] as? Int, (0..<count).contains(index),
                  let ids = entry["turnIDs"] as? [String] else { continue }
            for id in ids.compactMap(UUID.init(uuidString:)) where validIDs.contains(id) {
                if !(grouped[index] ?? []).contains(id) { grouped[index, default: []].append(id) }
            }
        }
        return grouped.keys.sorted().map { MeetingSummaryEvidence(itemIndex: $0, turnIDs: Array(grouped[$0, default: []].prefix(4))) }
    }

    static func timingContext(_ session: MeetingSession) -> String {
        let partial = session.endedAt == nil || session.isProcessingCompleted == false
        let stats = session.talkTimeStats
        let times = stats.map { stat in
            let percent = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), stat.fraction * 100)
            return "\(stat.speakerName): \(timeLabel(stat.duration)) (\(percent)%)"
        }.joined(separator: "; ")
        return """
        Duração da reunião (sem pausas): \(timeLabel(session.duration))
        Tempo de fala por participante (\(partial ? "parcial; processamento pendente ou gravação em andamento" : "intervalos salvos")): \(times.isEmpty ? "indisponível; não há intervalos de fala válidos" : times)
        """
    }

    private static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A fixed source budget makes the selected scope predictable. Omitted sources are not cited.
    static func context(sessions: [MeetingSession], selectedIDs: Set<UUID>) -> String {
        sessions.filter { selectedIDs.contains($0.id) }.prefix(8).map { session in
            let summary = session.summary?.sections.map(\.searchableText).joined(separator: "\n") ?? ""
            let tasks = session.summary?.allActionItems.map {
                "\($0.done ? "[x]" : "[ ]") \($0.text) | \($0.assignee ?? "") | \($0.dueDate ?? "")"
            }.joined(separator: "\n") ?? ""
            return """
            [\(session.id.uuidString)] \(session.title) — \(session.startedAt.formatted(date: .numeric, time: .omitted))
            \(timingContext(session))
            Tempo de fala estimado pelos intervalos salvos; percentuais da soma das falas, não da duração total. Não estime por palavras.
            Capítulos: \((session.chapters ?? []).map { "[\(timeLabel($0.startTime))] \($0.title)" }.joined(separator: "; "))
            Resumo: \(summary.prefix(3000))
            Tarefas: \(tasks.prefix(2000))
            Transcrição: \(session.transcriptText.prefix(5000))
            """
        }.joined(separator: "\n\n")
    }
}

struct MeetingAIRecipe: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var command: String
    var title: String
    var instruction: String

    static var defaults: [Self] { [
        .init(command: "decisoes", title: String(localized: "Decisões"), instruction: String(localized: "Liste decisões confirmadas, separando propostas ainda abertas. Cite as fontes disponíveis.")),
        .init(command: "riscos", title: String(localized: "Riscos"), instruction: String(localized: "Liste riscos e bloqueios mencionados, com impacto e próximo passo quando houver evidência.")),
        .init(command: "followup", title: String(localized: "Preparar follow-up"), instruction: String(localized: "Prepare um rascunho curto de follow-up com decisões, responsáveis e próximos passos. Não envie nada.")),
        .init(command: "pendencias", title: String(localized: "Pendências"), instruction: String(localized: "Liste as ações pendentes que estou acompanhando, agrupadas por responsável, com a reunião de origem e o prazo quando houver. Destaque o que está atrasado."))
    ] }

    static func expanded(_ input: String, recipes: [Self]) -> String {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, first.hasPrefix("/"),
              let recipe = recipes.first(where: { "/" + $0.command == first.lowercased() }) else { return input }
        return recipe.instruction + (parts.count > 1 ? "\n" + parts[1] : "")
    }

    static func validCommand(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0)
        }
    }
}

struct MeetingPreparation: Codable, Equatable {
    var eventID: String
    var title: String
    var eventDate: Date
    var selectedSessionIDs: [UUID]
    var text: String
    var generatedAt: Date
}

/// Preparation stays separate from recorded sessions: opening an event creates no recording.
struct ScheduledMeetingDraft: Codable, Equatable {
    var eventID: String
    var notes = ""
    var messages: [ScheduledMeetingMessage] = []
    /// nil migrates the old briefing selection; an empty array explicitly clears the context.
    var contextSessionIDs: [UUID]?

    mutating func coalesceUnansweredRetries() {
        messages = messages.reduce(into: []) { result, message in
            if let previous = result.last, previous.role == .user, message.role == .user,
               previous.content.trimmingCharacters(in: .whitespacesAndNewlines)
                == message.content.trimmingCharacters(in: .whitespacesAndNewlines) { return }
            result.append(message)
        }
    }
}

struct ScheduledMeetingMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var content: String
    var sourceSessionIDs: [UUID]?
}
