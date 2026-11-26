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

// MARK: - Review presentation helpers

struct MeetingSummaryBulletEntry: Identifiable, Equatable {
    let index: Int
    let text: String
    let tag: String?
    var id: Int { index }
}

struct MeetingSummaryBulletGroup: Identifiable, Equatable {
    static let otherGroupID = "__other__"

    let id: String
    let title: String
    let entries: [MeetingSummaryBulletEntry]

    var isOther: Bool { id == Self.otherGroupID }

    /// Agrupa bullets que repetem um prefixo estruturado (ex.: "João — feito: ..."),
    /// preservando `index` original para que os links de evidência continuem exatos.
    /// Retorna `nil` quando não há repetição real (mantendo lista simples).
    static func groups(for bullets: [String]) -> [MeetingSummaryBulletGroup]? {
        let nonEmpty: [(index: Int, text: String)] = bullets.enumerated().compactMap { offset, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (offset, trimmed)
        }
        guard nonEmpty.count >= 3 else { return nil }

        var order: [String] = []
        var titles: [String: String] = [:]
        var groupedEntries: [String: [MeetingSummaryBulletEntry]] = [:]
        var ungrouped: [MeetingSummaryBulletEntry] = []
        var matchedCount = 0

        for item in nonEmpty {
            if let parsed = parsePrefixedBullet(item.text) {
                matchedCount += 1
                let key = normalizedKey(parsed.prefix)
                if titles[key] == nil {
                    order.append(key)
                    titles[key] = parsed.prefix
                }
                groupedEntries[key, default: []].append(
                    MeetingSummaryBulletEntry(index: item.index, text: parsed.body, tag: parsed.tag)
                )
            } else {
                ungrouped.append(MeetingSummaryBulletEntry(index: item.index, text: item.text, tag: nil))
            }
        }

        // Exige cobertura relevante (>= 60%) e pelo menos um grupo repetido (>= 2 itens).
        guard matchedCount * 100 >= nonEmpty.count * 60 else { return nil }
        guard groupedEntries.values.contains(where: { $0.count >= 2 }) else { return nil }

        var result = order.compactMap { key -> MeetingSummaryBulletGroup? in
            guard let title = titles[key], let entries = groupedEntries[key], !entries.isEmpty else { return nil }
            return MeetingSummaryBulletGroup(id: key, title: title, entries: entries)
        }
        if !ungrouped.isEmpty {
            result.append(MeetingSummaryBulletGroup(
                id: otherGroupID,
                title: String(localized: "Outros"),
                entries: ungrouped
            ))
        }
        return result
    }

    static func matchingSpeaker(for groupTitle: String, in speakers: [MeetingSpeaker]) -> MeetingSpeaker? {
        let key = normalizedKey(groupTitle)
        guard !key.isEmpty else { return nil }

        if let exact = speakers.first(where: { normalizedKey($0.name) == key }) {
            return exact
        }

        let groupFirst = key.split(separator: " ").first.map(String.init) ?? key
        let prefixMatches = speakers.filter { speaker in
            let speakerKey = normalizedKey(speaker.name)
            guard !speakerKey.isEmpty else { return false }
            let speakerFirst = speakerKey.split(separator: " ").first.map(String.init) ?? speakerKey
            return speakerKey.hasPrefix(key + " ")
                || key.hasPrefix(speakerKey + " ")
                || (groupFirst.count >= 3 && speakerFirst == groupFirst)
        }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func parsePrefixedBullet(_ text: String) -> (prefix: String, tag: String?, body: String)? {
        guard let split = splitPrefix(in: text) else { return nil }
        let cleanedPrefix = split.prefix
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_")))
        let remainder = split.remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidPrefix(cleanedPrefix), !remainder.isEmpty else { return nil }

        if let sub = extractTag(from: remainder) {
            return (cleanedPrefix, sub.tag, sub.body)
        }
        return (cleanedPrefix, nil, remainder)
    }

    private static func splitPrefix(in text: String) -> (prefix: String, remainder: String)? {
        let separatorGroups: [([String], Int)] = [
            ([" — ", " – "], 48),
            ([" - "], 44),
            ([": "], 42)
        ]

        for (separators, maxOffset) in separatorGroups {
            var earliest: Range<String.Index>?
            for separator in separators {
                if let range = text.range(of: separator) {
                    let distance = text.distance(from: text.startIndex, to: range.lowerBound)
                    if distance <= maxOffset {
                        if earliest == nil || range.lowerBound < earliest!.lowerBound {
                            earliest = range
                        }
                    }
                }
            }
            if let range = earliest {
                let prefix = String(text[..<range.lowerBound])
                let remainder = String(text[range.upperBound...])
                return (prefix, remainder)
            }
        }
        return nil
    }

    private static func isValidPrefix(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 42 else { return false }
        let words = value.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count) else { return false }
        let lower = value.lowercased()
        guard !lower.contains("http://"), !lower.contains("https://") else { return false }
        let forbidden = CharacterSet(charactersIn: ".?!;\"'“”()[]{}")
        return value.rangeOfCharacter(from: forbidden) == nil
    }

    private static func extractTag(from remainder: String) -> (tag: String, body: String)? {
        guard let range = remainder.range(of: ": ") else { return nil }
        let distance = remainder.distance(from: remainder.startIndex, to: range.lowerBound)
        guard distance >= 2, distance <= 22 else { return nil }

        let rawTag = String(remainder[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_")))
        let body = String(remainder[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard body.count >= 4, !rawTag.isEmpty else { return nil }
        let words = rawTag.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count) else { return nil }
        let forbidden = CharacterSet(charactersIn: ".?!;\"'“”()[]{}0123456789/")
        guard rawTag.rangeOfCharacter(from: forbidden) == nil else { return nil }

        let formattedTag = rawTag.prefix(1).uppercased() + rawTag.dropFirst()
        return (formattedTag, body)
    }
}

struct MeetingTranscriptGroup: Identifiable, Equatable {
    let source: MeetingCaptureSource
    let speakerId: String?
    let speakerName: String
    let turns: [MeetingTurn]

    var id: UUID { turns[0].id }
    var startTime: TimeInterval { turns[0].startTime }
    var endTime: TimeInterval { turns.last?.endTime ?? turns[0].endTime }
    var speakerKey: String { Self.speakerKey(for: turns[0]) }

    static func speakerKey(for turn: MeetingTurn) -> String {
        "\(turn.source.rawValue):\(turn.speakerId ?? turn.speakerName)"
    }

    /// Agrupa turnos consecutivos do mesmo falante para reduzir o ruído visual de bolhas
    /// fragmentadas, mantendo todos os turnos e IDs individuais para seek e destaque.
    static func group(
        _ turns: [MeetingTurn],
        maxGap: TimeInterval = 30,
        maxTurnsPerGroup: Int = 8
    ) -> [MeetingTranscriptGroup] {
        var groups: [MeetingTranscriptGroup] = []
        for turn in turns {
            let key = speakerKey(for: turn)
            if var last = groups.last,
               last.speakerKey == key,
               last.turns.count < maxTurnsPerGroup,
               (turn.startTime - last.endTime) <= maxGap {
                last = MeetingTranscriptGroup(
                    source: last.source,
                    speakerId: last.speakerId,
                    speakerName: last.speakerName,
                    turns: last.turns + [turn]
                )
                groups[groups.count - 1] = last
            } else {
                groups.append(MeetingTranscriptGroup(
                    source: turn.source,
                    speakerId: turn.speakerId,
                    speakerName: turn.speakerName,
                    turns: [turn]
                ))
            }
        }
        return groups
    }
}

extension MeetingSummarySection {
    var displayItemCount: Int {
        switch kind {
        case .paragraph:
            return isEmpty ? 0 : 1
        case .bullets:
            return bullets.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        case .actionItems:
            return actionItems.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
    }
}
