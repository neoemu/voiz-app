import Foundation

nonisolated enum GranolaCSVError: Error, Equatable, Sendable {
    case unreadableFile
    case notAGranolaExport

    var message: String {
        switch self {
        case .unreadableFile: return String(localized: "Não foi possível ler este arquivo.")
        case .notAGranolaExport: return String(localized: "Este arquivo não parece uma exportação do Granola.")
        }
    }
}

/// Exportação CSV do Granola (Settings › Profile › Generate CSV), a rota que também existe no plano
/// gratuito. O formato não é documentado: os cabeçalhos são reconhecidos por apelidos e a
/// transcrição é lida como texto. Cada linha vira a mesma `GranolaNote` da API.
nonisolated struct GranolaCSVArchive: GranolaNoteSource {
    let notes: [GranolaNote]
    /// Linhas sem data legível: entrariam fora de ordem no histórico.
    let unreadableRows: Int

    var hasTranscripts: Bool { notes.contains { !($0.transcript ?? []).isEmpty } }

    func listNotes() async throws -> [GranolaNoteListing] {
        notes.map { GranolaNoteListing(id: $0.id, title: $0.title, createdAt: $0.createdAt, deletedAt: nil) }
    }

    func note(id: String) async throws -> GranolaNote {
        guard let note = notes.first(where: { $0.id == id }) else { throw GranolaImportError.noteUnavailable }
        return note
    }

    static func load(from url: URL) throws -> GranolaCSVArchive {
        guard let data = try? Data(contentsOf: url) else { throw GranolaCSVError.unreadableFile }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> GranolaCSVArchive {
        guard String(data: data.prefix(4_096), encoding: .utf8) != nil
                || String(data: data, encoding: .utf8) != nil else { throw GranolaCSVError.unreadableFile }
        let rows = records(in: data)
        guard let header = rows.first else { throw GranolaCSVError.notAGranolaExport }
        let columns = Columns(header: header)
        guard columns.identifiesAGranolaExport else { throw GranolaCSVError.notAGranolaExport }

        var notes: [GranolaNote] = []
        var seen = Set<String>()
        var unreadable = 0
        for row in rows.dropFirst() where row.contains(where: { !$0.isEmpty }) {
            guard let note = note(from: row, columns: columns) else { unreadable += 1; continue }
            if seen.insert(note.id).inserted { notes.append(note) }
        }
        return GranolaCSVArchive(notes: notes, unreadableRows: unreadable)
    }

    // MARK: - Colunas

    private struct Columns {
        var id: Int?, title: Int?, date: Int?, summary: Int?, transcript: Int?, privateNotes: Int?, folder: Int?

        init(header: [String]) {
            let names = header.map(Self.normalized)
            func column(_ aliases: [String]) -> Int? { names.firstIndex { aliases.contains($0) } }
            id = column(["id", "noteid", "documentid"])
            title = column(["title", "notetitle", "meetingtitle", "name"])
            date = column(["createdat", "created", "date", "meetingdate", "startedat", "starttime", "datetime", "createddate"])
            summary = column(["summary", "notesummary", "aisummary", "enhancednotes", "summarymarkdown"])
            transcript = column(["transcript", "fulltranscript", "meetingtranscript"])
            privateNotes = column(["privatenotes", "mynotes", "usernotes", "notes"])
            folder = column(["folder", "foldername", "folders"])
        }

        var identifiesAGranolaExport: Bool {
            date != nil && title != nil && (summary != nil || transcript != nil)
        }

        private static func normalized(_ name: String) -> String {
            name.replacingOccurrences(of: "\u{FEFF}", with: "").lowercased().filter { $0.isLetter || $0.isNumber }
        }
    }

    private static func note(from row: [String], columns: Columns) -> GranolaNote? {
        func value(_ index: Int?) -> String? {
            guard let index, row.indices.contains(index) else { return nil }
            let text = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let date = value(columns.date).flatMap(parseDate) else { return nil }
        let title = value(columns.title)
        let id = value(columns.id).flatMap { $0.hasPrefix("not_") ? $0 : nil }
            ?? "csv:\(date.timeIntervalSince1970):\(title ?? "")"
        return GranolaNote(
            id: id,
            title: title,
            createdAt: date,
            calendarEvent: nil,
            folderMembership: value(columns.folder).map { [.init(id: "csv", name: $0)] } ?? [],
            summaryText: nil,
            summaryMarkdown: value(columns.summary),
            privateNotesText: value(columns.privateNotes),
            privateNotesMarkdown: nil,
            transcript: value(columns.transcript).map { transcript(from: $0, at: date) }
        )
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Transcrição

    private static let ownerLabels: Set<String> = ["me", "you", "eu", "você"]
    private static let otherLabels: Set<String> = ["them", "others", "outros"]
    private static let maxSegmentLength = 600

    /// `Rótulo: fala` por linha, com rótulo só quando é conhecido ou se repete: "Nota: algo" solto
    /// numa frase não é um falante. Sem horários no texto, todas as falas ficam no início da reunião.
    private static func transcript(from text: String, at date: Date) -> [GranolaNote.Segment] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for line in lines { if let label = label(in: line)?.0 { counts[label, default: 0] += 1 } }

        var segments: [GranolaNote.Segment] = []
        var speaker = GranolaNote.Speaker(source: "speaker", attribution: nil, diarizationLabel: nil, name: nil)
        for line in lines {
            var body = line
            if let (name, rest) = label(in: line), counts[name, default: 0] >= 2 || isKnownLabel(name) {
                speaker = self.speaker(named: name)
                body = rest
            }
            for piece in pieces(of: body) {
                segments.append(.init(speaker: speaker, text: piece, startTime: date, endTime: date))
            }
        }
        return segments
    }

    private static func label(in line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard (1...40).contains(name.count), !rest.isEmpty, name.first?.isNumber == false,
              !name.contains(where: { ".?!".contains($0) }) else { return nil }
        return (name, rest)
    }

    private static func isKnownLabel(_ name: String) -> Bool {
        ownerLabels.contains(name.lowercased()) || otherLabels.contains(name.lowercased())
    }

    private static func speaker(named name: String) -> GranolaNote.Speaker {
        if ownerLabels.contains(name.lowercased()) {
            return .init(source: "microphone", attribution: "me", diarizationLabel: nil, name: nil)
        }
        if otherLabels.contains(name.lowercased()) {
            return .init(source: "speaker", attribution: "them", diarizationLabel: nil, name: nil)
        }
        return .init(source: "speaker", attribution: "them", diarizationLabel: nil, name: name)
    }

    /// Texto corrido vira frases, para o teto de tamanho das falas ter onde cortar.
    private static func pieces(of text: String) -> [String] {
        guard text.count > maxSegmentLength else { return [text] }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - CSV

    /// RFC 4180 em bytes: aspas protegem separador e quebra de linha. Planilhas em pt-BR regravam
    /// com ponto e vírgula, então o separador sai da primeira linha.
    private static func records(in data: Data) -> [[String]] {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let quote = UInt8(ascii: "\""), newline = UInt8(ascii: "\n"), carriage = UInt8(ascii: "\r")
        let separator = detectSeparator(in: bytes)

        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = 0
        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote, field.isEmpty {
                quoted = true
            } else if byte == separator {
                endField()
            } else if byte == newline || byte == carriage {
                if byte == carriage, index + 1 < bytes.count, bytes[index + 1] == newline { index += 1 }
                endField()
                rows.append(row)
                row = []
            } else {
                field.append(byte)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
        return rows
    }

    private static func detectSeparator(in bytes: [UInt8]) -> UInt8 {
        var counts: [UInt8: Int] = [:]
        var quoted = false
        for byte in bytes {
            if byte == UInt8(ascii: "\"") { quoted.toggle() }
            if !quoted, byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") { break }
            if !quoted, [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t")].contains(byte) {
                counts[byte, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? UInt8(ascii: ",")
    }
}
