import Foundation

/// Serializa uma reunião num pacote completo em **Markdown** — resumo (seções) + action items
/// (com responsável/prazo/✓) + notas + transcript. Base local do export; a Onda 3 reusa a mesma
/// serialização para destinos externos (Notion/Slack/email).
enum MeetingExporter {

    /// Markdown completo da sessão.
    static func markdown(for session: MeetingSession) -> String {
        var lines: [String] = []

        lines.append("# \(displayTitle(session))")
        lines.append("")

        // Metadados
        var meta: [String] = [session.formattedDate, session.sessionType.displayName, durationLabel(session.duration)]
        meta = meta.filter { !$0.isEmpty }
        lines.append("> " + meta.joined(separator: " · "))
        let participants = session.speakers.map(\.name).filter { !$0.isEmpty }
        if !participants.isEmpty {
            lines.append(">")
            lines.append("> Participantes: " + participants.joined(separator: ", "))
        }
        lines.append("")

        // Resumo (seções dinâmicas)
        if let summary = session.summary, summary.hasContent {
            lines.append("## Resumo")
            lines.append("")
            for section in summary.sections where !section.isEmpty {
                lines.append("### \(section.title)")
                lines.append("")
                switch section.kind {
                case .paragraph:
                    lines.append(section.paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
                case .bullets:
                    for bullet in section.bullets where !bullet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("- \(bullet.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                case .actionItems:
                    for item in section.actionItems where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(actionItemLine(item))
                    }
                }
                lines.append("")
            }
        }

        // Notas
        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("## Notas")
            lines.append("")
            lines.append(notes)
            lines.append("")
        }

        // Transcript
        if !session.turns.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            for turn in session.turns {
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("**\(turn.speakerName)** (\(timeLabel(turn.startTime))): \(text)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Título de exibição da reunião (título do resumo do LLM se houver; senão o título da sessão).
    /// Usado no assunto do e-mail/share e no nome de arquivo.
    static func title(for session: MeetingSession) -> String {
        displayTitle(session)
    }

    /// Nome de arquivo sugerido (sem extensão), ex.: "2026-06-21 Entrevista Rosiane".
    static func suggestedFileName(for session: MeetingSession) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: session.startedAt)
        let titlePart = displayTitle(session)
        let raw = "\(datePart) \(titlePart)"
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return raw.components(separatedBy: invalid).joined(separator: "-")
    }

    // MARK: - Helpers

    private static func actionItemLine(_ item: MeetingActionItem) -> String {
        var line = "- [\(item.done ? "x" : " ")] \(item.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        var tags: [String] = []
        if let assignee = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
            tags.append("Responsável: \(assignee)")
        }
        if let due = item.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            tags.append("Prazo: \(due)")
        }
        if !tags.isEmpty {
            line += " — " + tags.joined(separator: " · ")
        }
        return line
    }

    private static func displayTitle(_ session: MeetingSession) -> String {
        let summaryTitle = session.summary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summaryTitle.isEmpty { return summaryTitle }
        let sessionTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionTitle.isEmpty ? "Reunião" : sessionTitle
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
