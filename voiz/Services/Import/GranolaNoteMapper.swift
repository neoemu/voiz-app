import CryptoKit
import Foundation

/// Converte uma nota do Granola em `MeetingSession`. Puro: não toca em rede nem em disco.
enum GranolaNoteMapper {
    /// Carimbado em `summaryModel`: a pill do resumo já mostra a origem sem campo novo no modelo.
    static let summaryOrigin = "Granola"
    private static let unassignedSpeakerID = MeetingCaptureSource.systemAudio.rawValue
    /// Mesma costura do transcript do Voiz (`MeetingRecordingLifecycle.merge`).
    private static let maxMergeGap: TimeInterval = 3
    /// Reuniões antigas trazem todos os outros como um único anônimo: sem teto, a costura produzia
    /// falas de 27 mil caracteres. O corte cai sempre na borda de um segmento.
    private static let maxTurnLength = 800

    /// Derivado do ID da nota: importar de novo cai no mesmo registro, sem marcador novo no modelo
    /// nem no contrato do Sync.
    static func sessionID(forNoteID noteID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("voiz.import.granola.note:\(noteID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Sem áudio e com `isProcessingCompleted`: o pós-processamento (e seu custo de IA) não a alcança.
    static func session(from note: GranolaNote, folderID: UUID? = nil) -> MeetingSession {
        let segments = (note.transcript ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
        let startedAt = segments.first?.startTime ?? note.calendarEvent?.scheduledStartTime ?? note.createdAt
        let endedAt = segments.map(\.endTime).max() ?? note.calendarEvent?.scheduledEndTime ?? startedAt
        let (speakers, turns) = transcript(from: segments, startedAt: startedAt)
        let title = displayTitle(for: note)
        return MeetingSession(
            id: sessionID(forNoteID: note.id),
            title: title,
            startedAt: startedAt,
            endedAt: max(startedAt, endedAt),
            notes: privateNotes(of: note),
            speakers: speakers,
            turns: turns,
            summary: summary(markdown: note.summaryMarkdown, plainText: note.summaryText, title: title),
            folderId: folderID,
            summaryModel: summaryOrigin,
            isProcessingCompleted: true
        )
    }

    private static func displayTitle(for note: GranolaNote) -> String {
        let candidates = [note.title, note.calendarEvent?.eventTitle]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? String(localized: "Reunião importada do Granola")
    }

    private static func privateNotes(of note: GranolaNote) -> String {
        let candidates = [note.privateNotesMarkdown, note.privateNotesText]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }

    // MARK: - Transcrição

    private static func transcript(
        from segments: [GranolaNote.Segment],
        startedAt: Date
    ) -> ([MeetingSpeaker], [MeetingTurn]) {
        var speakers = MeetingCaptureSource.allCases.map { MeetingSpeaker(source: $0) }
        var idsByName: [String: String] = [:]
        var turns: [MeetingTurn] = []

        for segment in segments {
            let source = isOwner(segment.speaker) ? MeetingCaptureSource.microphone : .systemAudio
            let speakerID: String
            if source == .microphone {
                speakerID = MeetingCaptureSource.microphone.rawValue
            } else if let name = resolvedName(of: segment.speaker) {
                if let known = idsByName[name] {
                    speakerID = known
                } else {
                    speakerID = "granola-\(idsByName.count + 1)"
                    idsByName[name] = speakerID
                    speakers.append(MeetingSpeaker(id: speakerID, source: .systemAudio, name: name))
                }
            } else {
                speakerID = unassignedSpeakerID
            }

            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = max(0, segment.startTime.timeIntervalSince(startedAt))
            let end = max(start, segment.endTime.timeIntervalSince(startedAt))
            if let index = turns.indices.last, turns[index].speakerId == speakerID,
               start - turns[index].endTime <= maxMergeGap, turns[index].text.count < maxTurnLength {
                turns[index].text += " " + text
                turns[index].endTime = max(turns[index].endTime, end)
            } else {
                let name = speakers.first { $0.id == speakerID }?.name ?? source.defaultSpeakerName
                turns.append(MeetingTurn(source: source, speakerId: speakerID, speakerName: name,
                                         text: text, startTime: start, endTime: end))
            }
        }
        return (speakers, turns)
    }

    /// `attribution` manda. Sem ela, microfone anônimo é o dono da nota; o iOS manda tudo como
    /// `microphone`, e aí nome ou rótulo de diarização indicam outra pessoa.
    private static func isOwner(_ speaker: GranolaNote.Speaker) -> Bool {
        switch speaker.attribution {
        case "me": return true
        case "them": return false
        default: return speaker.source == "microphone" && resolvedName(of: speaker) == nil
        }
    }

    private static func resolvedName(of speaker: GranolaNote.Speaker) -> String? {
        [speaker.name, speaker.diarizationLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    // MARK: - Resumo

    static func summary(markdown: String?, plainText: String?, title: String) -> MeetingSummary? {
        var sections = sections(fromMarkdown: markdown ?? "")
        if sections.isEmpty, let text = plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            sections = [.paragraph(id: "granola-summary", title: String(localized: "Resumo"), text: text)]
        }
        return sections.isEmpty ? nil : MeetingSummary(title: title, sections: sections)
    }

    private struct SectionDraft {
        var title: String
        var items: [(text: String, isBullet: Bool)] = []
    }

    /// O Granola escreve `# Tópico`, bullets com filhos indentados e, no fim, `---` mais um link
    /// para `notes.granola.ai`. O Voiz desenha texto puro em seções de um nível: filho vira linha do
    /// bullet e o rodapé sai, para não virar conteúdo da reunião.
    private static func sections(fromMarkdown markdown: String) -> [MeetingSummarySection] {
        var drafts: [SectionDraft] = []

        func append(_ text: String, isBullet: Bool) {
            if drafts.isEmpty { drafts.append(SectionDraft(title: String(localized: "Resumo"))) }
            drafts[drafts.count - 1].items.append((text, isBullet))
        }
        func extendLastBullet(with text: String) -> Bool {
            guard let section = drafts.indices.last, let item = drafts[section].items.indices.last,
                  drafts[section].items[item].isBullet else { return false }
            drafts[section].items[item].text += "\n" + text
            return true
        }

        for line in bodyLines(of: markdown) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let content = String(line.dropFirst(indent))
            if content.isEmpty || isRule(content) { continue }
            if let heading = headingText(content) {
                drafts.append(SectionDraft(title: inlineText(heading)))
            } else if let bullet = bulletText(content) {
                let text = inlineText(bullet)
                if indent == 0 || !extendLastBullet(with: "– " + text) { append(text, isBullet: true) }
            } else {
                let text = inlineText(content)
                if indent == 0 || !extendLastBullet(with: text) { append(text, isBullet: false) }
            }
        }

        return drafts.enumerated().compactMap { index, draft in
            guard !draft.items.isEmpty else { return nil }
            let id = "granola-\(index)"
            if draft.items.contains(where: \.isBullet) {
                return .bullets(id: id, title: draft.title, items: draft.items.map(\.text))
            }
            return .paragraph(id: id, title: draft.title, text: draft.items.map(\.text).joined(separator: "\n\n"))
        }
    }

    private static func bodyLines(of markdown: String) -> [String] {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = lines.last?.trimmingCharacters(in: .whitespaces),
              last.isEmpty || isRule(last) || last.contains("notes.granola.ai") {
            lines.removeLast()
        }
        return lines
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && Set(line).count == 1 && (line.first == "-" || line.first == "*" || line.first == "_")
    }

    private static func headingText(_ line: String) -> String? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(_ line: String) -> String? {
        var body: Substring?
        if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
            body = line.dropFirst(2)
        } else {
            let digits = line.prefix(while: \.isNumber)
            if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
                body = line.dropFirst(digits.count + 2)
            }
        }
        guard var body else { return nil }
        for box in ["[ ] ", "[x] ", "[X] "] where body.hasPrefix(box) { body = body.dropFirst(box.count) }
        return String(body)
    }

    /// `Text` de resumo não interpreta Markdown: negrito e links apareceriam crus.
    private static func inlineText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
