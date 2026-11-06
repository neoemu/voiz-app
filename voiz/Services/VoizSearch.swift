import Foundation

/// De onde veio um resultado da busca global. Define ícone, rótulo e para qual aba o ⌘K navega.
enum VoizSearchKind: String, CaseIterable, Identifiable {
    case meeting
    case dictation
    case translation

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .meeting: return "person.2.wave.2"
        case .dictation: return "waveform"
        case .translation: return "translate"
        }
    }

    var label: String {
        switch self {
        case .meeting: return String(localized: "Reunião")
        case .dictation: return String(localized: "Ditado")
        case .translation: return String(localized: "Tradução")
        }
    }

    /// Índice da aba correspondente em `ContentView`.
    var tab: Int {
        switch self {
        case .dictation: return 2
        case .translation: return 3
        case .meeting: return 4
        }
    }
}

/// Uma linha da paleta de busca. `id` é o id do item de origem — é ele que a aba de destino usa
/// para abrir o conteúdo.
struct VoizSearchResult: Identifiable, Equatable {
    let id: UUID
    let kind: VoizSearchKind
    let title: String
    /// Trecho do texto ao redor do termo buscado, ou o começo do conteúdo quando o casamento
    /// veio do título.
    let snippet: String
    let date: Date
}

/// Local matching and bounded aggregation for global search. Archived histories are
/// supplied in pages so old entries remain searchable without expanding the UI cache.
enum VoizSearch {
    /// Teto de resultados. A paleta é para achar rápido, não para navegar o histórico inteiro.
    static let resultLimit = 40

    /// Quantos itens a paleta mostra antes de o usuário digitar.
    static let recentsLimit = 8

    /// Últimos itens de todas as fontes, para a paleta já abrir com algo útil.
    static func recents(
        dictations: [TranscriptionEntry],
        meetings: [MeetingSession],
        translations: [TranslationEntry],
        limit: Int = recentsLimit
    ) -> [VoizSearchResult] {
        all(dictations: dictations, meetings: meetings, translations: translations, term: "")
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    static func results(
        query: String,
        dictations: [TranscriptionEntry],
        meetings: [MeetingSession],
        translations: [TranslationEntry]
    ) -> [VoizSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        return all(dictations: dictations, meetings: meetings, translations: translations, term: term)
            .sorted { $0.date > $1.date }
            .prefix(resultLimit)
            .map { $0 }
    }

    /// Every retained page participates, but only the best 40 rows survive each merge.
    /// Closures capture one immutable library's stores; this method never switches accounts.
    @MainActor
    static func archivedResults(
        query: String, meetings: [MeetingSession],
        dictationPage: @MainActor (String) throws -> [TranscriptionEntry],
        translationPage: @MainActor (String) throws -> [TranslationEntry]
    ) async throws -> [VoizSearchResult] {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var best: [VoizSearchResult] = []
        for offset in stride(from: 0, to: meetings.count, by: 100) {
            let page = Array(meetings[offset..<min(offset + 100, meetings.count)])
            best = limited(best + results(query: term, dictations: [], meetings: page, translations: []))
            await Task.yield()
            try Task.checkCancellation()
        }
        var after = ""
        while true {
            try Task.checkCancellation()
            let page = try dictationPage(after)
            guard let last = page.last else { break }
            let next = last.id.uuidString.lowercased()
            guard next > after else { throw TextHistoryArchiveError.corruptRecord }
            best = limited(best + results(query: term, dictations: page, meetings: [], translations: []))
            after = next
            await Task.yield()
        }
        after = ""
        while true {
            try Task.checkCancellation()
            let page = try translationPage(after)
            guard let last = page.last else { break }
            let next = last.id.uuidString.lowercased()
            guard next > after else { throw TextHistoryArchiveError.corruptRecord }
            best = limited(best + results(query: term, dictations: [], meetings: [], translations: page))
            after = next
            await Task.yield()
        }
        try Task.checkCancellation()
        return best
    }

    private static func limited(_ values: [VoizSearchResult]) -> [VoizSearchResult] {
        Array(values.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(resultLimit))
    }

    /// Converte as três fontes em resultados. Termo vazio casa com tudo — é o que alimenta os
    /// recentes.
    private static func all(
        dictations: [TranscriptionEntry],
        meetings: [MeetingSession],
        translations: [TranslationEntry],
        term: String
    ) -> [VoizSearchResult] {
        var results: [VoizSearchResult] = []

        for session in meetings where session.matches(term) {
            results.append(
                result(
                    id: session.id,
                    kind: .meeting,
                    title: session.title,
                    body: session.previewText,
                    term: term,
                    date: session.startedAt
                )
            )
        }

        for entry in dictations where matches(entry.searchableText, term) {
            results.append(
                result(
                    id: entry.id,
                    kind: .dictation,
                    title: entry.displayTitle,
                    body: entry.text,
                    term: term,
                    date: entry.timestamp
                )
            )
        }

        for entry in translations where matches(entry.searchableText, term) {
            results.append(
                result(
                    id: entry.id,
                    kind: .translation,
                    title: entry.displayTitle,
                    body: [entry.sourceText, entry.translatedText].joined(separator: "\n"),
                    term: term,
                    date: entry.timestamp
                )
            )
        }

        return results
    }

    /// Monta a linha do resultado. O trecho sai do *corpo* (nunca do título) e é omitido quando
    /// não acrescenta nada — no ditado sem nome, por exemplo, o título já é o começo do texto.
    private static func result(
        id: UUID,
        kind: VoizSearchKind,
        title: String,
        body: String,
        term: String,
        date: Date
    ) -> VoizSearchResult {
        var text = snippet(in: body, around: term)
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "… "))
        if bare.isEmpty || title.range(of: bare, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            text = ""
        }
        return VoizSearchResult(id: id, kind: kind, title: title, snippet: text, date: date)
    }

    /// Termo vazio casa com tudo (é como os recentes reaproveitam a mesma varredura).
    static func matches(_ text: String, _ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        return text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Recorta ~`context` caracteres em volta da primeira ocorrência do termo, para a linha do
    /// resultado mostrar *por que* ela casou. Sem termo (recentes) ou sem ocorrência (casou só
    /// pelo título), devolve o começo do texto.
    static func snippet(in text: String, around term: String, context: Int = 42) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "" }
        guard !term.isEmpty else { return truncated(flattened, to: context * 2) }

        guard let match = flattened.range(
            of: term,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return truncated(flattened, to: context * 2)
        }

        let start = flattened.index(match.lowerBound, offsetBy: -context, limitedBy: flattened.startIndex)
            ?? flattened.startIndex
        let end = flattened.index(match.upperBound, offsetBy: context, limitedBy: flattened.endIndex)
            ?? flattened.endIndex

        var slice = String(flattened[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flattened.startIndex { slice = "…" + slice }
        if end < flattened.endIndex { slice += "…" }
        return slice
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

extension TranscriptionEntry {
    /// Texto varrido pela busca global: o nome dado pelo usuário (quando houver) e a transcrição.
    var searchableText: String {
        [title ?? "", text].joined(separator: "\n")
    }
}

extension TranslationEntry {
    /// Texto varrido pela busca global: nome, original e tradução.
    var searchableText: String {
        [title ?? "", sourceText, translatedText].joined(separator: "\n")
    }
}
