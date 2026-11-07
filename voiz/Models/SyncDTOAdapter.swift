import Foundation

/// Explicit field selection is the only bridge from local models to Sync. Codable for
/// MeetingSession/AppSettings must never be used as a portable representation.
@MainActor
enum SyncDTOAdapter {
    static func meeting(_ session: MeetingSession) throws -> SyncDocument {
        try document(.meeting, id: session.id, [
            "title": .string(session.title), "session_type": .string(session.sessionType.rawValue),
            "started_at_ms": .integer(try milliseconds(session.startedAt.timeIntervalSince1970)),
            "ended_at_ms": try optionalMilliseconds(session.endedAt?.timeIntervalSince1970),
            "paused_ms": .integer(try milliseconds(session.pausedDuration ?? 0)),
            "notes": .string(session.notes), "include_notes_in_summary": .bool(session.usesNotesInSummary),
            "context_session_ids": .array((session.contextSessionIDs ?? []).map(uuid)),
            "speakers": .array(session.speakers.map { .object(["id": .string($0.id), "name": .string($0.name), "source": source($0.source)]) }),
            "folder_id": optionalUUID(session.folderId)
        ])
    }

    static func transcript(_ session: MeetingSession, generationID: UUID) throws -> SyncDocument {
        try document(.transcript, id: session.id, [
            "meeting_id": uuid(session.id), "generation_id": uuid(generationID),
            "turns": .array(try session.turns.map { turn in
                .object([
                    "id": uuid(turn.id), "source": source(turn.source), "speaker_id": optionalString(turn.speakerId),
                    "speaker_name": .string(turn.speakerName), "text": .string(turn.text),
                    "start_ms": .integer(try milliseconds(turn.startTime)), "end_ms": .integer(try milliseconds(turn.endTime)),
                    "confidence_basis_points": .integer(Int64((portableConfidence(turn.confidence) * 10_000).rounded()))
                ])
            })
        ])
    }

    static func summary(_ session: MeetingSession, transcriptGenerationID: UUID?) throws -> SyncDocument? {
        guard let summary = session.summary else { return nil }
        return try document(.summary, id: session.id, [
            "meeting_id": uuid(session.id), "transcript_generation_id": optionalUUID(transcriptGenerationID),
            "title": .string(summary.title),
            "sections": .array(summary.sections.map { section in
                .object([
                    "id": .string(section.id), "title": .string(section.title),
                    "kind": .string(section.kind == .actionItems ? "action_items" : section.kind.rawValue),
                    "paragraph": .string(section.paragraph), "bullets": .array(section.bullets.map(SyncJSONValue.string)),
                    "action_items": .array(section.actionItems.map { item in .object([
                        "id": uuid(item.id), "text": .string(item.text), "assignee": optionalString(item.assignee),
                        "due_date": optionalString(item.dueDate), "done": .bool(item.done), "followed": .bool(item.isFollowed)
                    ]) }),
                    "evidence": .array((section.evidence ?? []).map { evidence in .object([
                        "item_index": .integer(Int64(evidence.itemIndex)), "turn_ids": .array(evidence.turnIDs.map(uuid))
                    ]) })
                ])
            }),
            "chapters": .array(try (session.chapters ?? []).map { chapter in .object([
                "id": uuid(chapter.id), "title": .string(chapter.title), "start_ms": .integer(try milliseconds(chapter.startTime))
            ]) })
        ])
    }

    static func folder(_ value: MeetingFolder) throws -> SyncDocument {
        try document(.folder, id: value.id, ["name": .string(value.name), "details": .string(value.details),
                                           "created_at_ms": .integer(try milliseconds(value.createdAt.timeIntervalSince1970))])
    }

    static func dictation(_ entry: TranscriptionEntry) throws -> SyncDocument {
        try document(.dictation, id: entry.id, [
            "title": optionalString(entry.title), "text": .string(entry.text), "language": .string(entry.language.rawValue),
            "timestamp_ms": .integer(try milliseconds(entry.timestamp.timeIntervalSince1970)),
            "duration_ms": .integer(try milliseconds(entry.duration)),
            "raw_text": optionalString(entry.rawText), "previous_text": optionalString(entry.previousText)
        ])
    }

    static func translation(_ entry: TranslationEntry) throws -> SyncDocument {
        try document(.translation, id: entry.id, [
            "title": optionalString(entry.title), "source_text": .string(entry.sourceText), "translated_text": .string(entry.translatedText),
            "source_language": .string(entry.sourceLanguage.rawValue), "target_language": .string(entry.targetLanguage.rawValue),
            "timestamp_ms": .integer(try milliseconds(entry.timestamp.timeIntervalSince1970))
        ])
    }

    static func preferences(_ value: SyncPreferences, id: UUID) throws -> SyncDocument {
        try document(.preferences, id: id, [
            "interface_language": .string(value.interfaceLanguage.rawValue), "appearance": .string(value.appearance.rawValue),
            "selected_language": .string(value.selectedLanguage.rawValue), "notes_language": .string(value.notesLanguage.rawValue),
            "show_confidence": .bool(value.showConfidence)
        ])
    }

    static func conversation(id: UUID, title: String, createdAt: Date, updatedAt: Date, isPinned: Bool, meetingID: UUID? = nil) throws -> SyncDocument {
        try document(.conversation, id: id, [
            "title": .string(title), "created_at_ms": .integer(try milliseconds(createdAt.timeIntervalSince1970)),
            "updated_at_ms": .integer(try milliseconds(updatedAt.timeIntervalSince1970)), "is_pinned": .bool(isPinned),
            "meeting_id": optionalUUID(meetingID)
        ])
    }

    static func message(id: UUID, conversationID: UUID, role: String, content: String, position: Int, replyToID: UUID? = nil) throws -> SyncDocument {
        try document(.message, id: id, [
            "conversation_id": uuid(conversationID), "role": .string(role), "content": .string(content),
            "position": .integer(Int64(position)), "reply_to_id": optionalUUID(replyToID)
        ])
    }

    /// Updates portable fields only. Existing audio paths, embeddings, capture settings and
    /// processing flags stay local. A new Mac receives an intentionally audio-free meeting.
    static func applyingMeeting(_ document: SyncDocument, to existing: MeetingSession?) throws -> MeetingSession {
        let fields = try fields(document, type: .meeting)
        let id = UUID(uuidString: document.entityID)!
        guard existing == nil || existing?.id == id else { throw SyncWireError.invalidIdentifier }
        var result = existing ?? MeetingSession(id: id)
        result.title = fields["title"]!.string!
        result.sessionType = MeetingSessionType(rawValue: fields["session_type"]!.string!)!
        result.startedAt = date(fields["started_at_ms"]!)
        result.endedAt = fields["ended_at_ms"] == .null ? nil : date(fields["ended_at_ms"]!)
        result.pausedDuration = seconds(fields["paused_ms"]!)
        result.notes = fields["notes"]!.string!
        if case .bool(let value) = fields["include_notes_in_summary"]! { result.includeNotesInSummary = value }
        if case .array(let values) = fields["context_session_ids"]! { result.contextSessionIDs = values.map { UUID(uuidString: $0.string!)! } }
        result.folderId = fields["folder_id"]!.string.flatMap(UUID.init(uuidString:))
        if case .array(let speakers) = fields["speakers"]! {
            result.speakers = speakers.map { speaker in
                let item = speaker.object!
                let speakerID = item["id"]!.string!
                let source: MeetingCaptureSource = item["source"]!.string == "microphone" ? .microphone : .systemAudio
                let embedding = existing?.speakers.first(where: { $0.id == speakerID && $0.source == source })?.embedding
                return MeetingSpeaker(id: speakerID, source: source, name: item["name"]!.string!, embedding: embedding)
            }
        }
        return result
    }

    static func applyingTranscript(_ document: SyncDocument, to existing: MeetingSession) throws -> MeetingSession {
        let fields = try fields(document, type: .transcript)
        guard fields["meeting_id"]!.string == existing.id.uuidString.lowercased() else { throw SyncWireError.invalidIdentifier }
        var result = existing
        if case .array(let turns) = fields["turns"]! {
            result.turns = turns.map { value in
                let turn = value.object!
                return MeetingTurn(id: UUID(uuidString: turn["id"]!.string!)!,
                                   source: turn["source"]!.string == "microphone" ? .microphone : .systemAudio,
                                   speakerId: turn["speaker_id"]!.string, speakerName: turn["speaker_name"]!.string!,
                                   text: turn["text"]!.string!, startTime: seconds(turn["start_ms"]!), endTime: seconds(turn["end_ms"]!),
                                   confidence: Float(turn["confidence_basis_points"]!.integer ?? 0) / 10_000)
            }
        }
        return result
    }

    /// `transcript_generation_id` says which transcript the evidence turn IDs came from; it does
    /// not gate the summary. The local model keeps a summary when the transcript changes.
    static func applyingSummary(_ document: SyncDocument, to existing: MeetingSession) throws -> MeetingSession {
        let fields = try fields(document, type: .summary)
        guard fields["meeting_id"]!.string == existing.id.uuidString.lowercased() else { throw SyncWireError.invalidSchema }
        var result = existing
        guard case .array(let sections) = fields["sections"]!, case .array(let chapters) = fields["chapters"]! else { throw SyncWireError.invalidSchema }
        result.summary = MeetingSummary(title: fields["title"]!.string!, sections: sections.map { value in
            let section = value.object!
            let kind = section["kind"]!.string!
            var result = MeetingSummarySection(id: section["id"]!.string!, title: section["title"]!.string!,
                                               kind: kind == "action_items" ? .actionItems : MeetingSectionKind(rawValue: kind)!,
                                               paragraph: section["paragraph"]!.string!)
            if case .array(let items) = section["bullets"]! { result.bullets = items.map { $0.string! } }
            if case .array(let items) = section["action_items"]! {
                result.actionItems = items.map { value in
                    let item = value.object!
                    let done: Bool = if case .bool(let flag) = item["done"]! { flag } else { false }
                    let followed: Bool = if case .bool(let flag) = item["followed"]! { flag } else { false }
                    return MeetingActionItem(id: UUID(uuidString: item["id"]!.string!)!, text: item["text"]!.string!,
                                             assignee: item["assignee"]!.string, dueDate: item["due_date"]!.string, done: done, followed: followed)
                }
            }
            if case .array(let items) = section["evidence"]! {
                result.evidence = items.map { value in
                    let evidence = value.object!
                    var turnIDs: [UUID] = []
                    if case .array(let ids) = evidence["turn_ids"]! { turnIDs = ids.map { UUID(uuidString: $0.string!)! } }
                    return MeetingSummaryEvidence(itemIndex: Int(evidence["item_index"]!.integer!), turnIDs: turnIDs)
                }
            }
            return result
        })
        result.chapters = chapters.map { value in
            let item = value.object!
            return MeetingChapter(id: UUID(uuidString: item["id"]!.string!)!, title: item["title"]!.string!, startTime: seconds(item["start_ms"]!))
        }
        return result
    }

    static func applyingPreferences(_ document: SyncDocument, to settings: inout AppSettings) throws {
        let fields = try fields(document, type: .preferences)
        guard let interface = AppSettings.InterfaceLanguage(rawValue: fields["interface_language"]!.string!),
              let appearance = AppSettings.InterfaceAppearance(rawValue: fields["appearance"]!.string!),
              let spoken = Language(rawValue: fields["selected_language"]!.string!),
              let notes = AppSettings.NotesLanguage(rawValue: fields["notes_language"]!.string!),
              case .bool(let confidence) = fields["show_confidence"]! else { throw SyncWireError.invalidSchema }
        settings.interfaceLanguage = interface
        settings.appearance = appearance
        settings.selectedLanguage = spoken
        settings.notesLanguage = notes
        settings.showConfidence = confidence
    }

    static func dictationEntry(_ document: SyncDocument, preserving existing: TranscriptionEntry? = nil) throws -> TranscriptionEntry {
        let fields = try fields(document, type: .dictation)
        let id = UUID(uuidString: document.entityID)!
        guard existing == nil || existing?.id == id else { throw SyncWireError.invalidIdentifier }
        return TranscriptionEntry(id: id, text: fields["text"]!.string!, language: Language(rawValue: fields["language"]!.string!)!,
                                  timestamp: date(fields["timestamp_ms"]!), duration: seconds(fields["duration_ms"]!), title: fields["title"]!.string,
                                  provenance: existing?.provenance, audioID: existing?.audioID, rawText: fields["raw_text"]!.string,
                                  previousText: fields["previous_text"]!.string, processingMessage: existing?.processingMessage)
    }

    static func translationEntry(_ document: SyncDocument) throws -> TranslationEntry {
        let fields = try fields(document, type: .translation)
        return TranslationEntry(id: UUID(uuidString: document.entityID)!, sourceText: fields["source_text"]!.string!,
                                translatedText: fields["translated_text"]!.string!, sourceLanguage: Language(rawValue: fields["source_language"]!.string!)!,
                                targetLanguage: Language(rawValue: fields["target_language"]!.string!)!, timestamp: date(fields["timestamp_ms"]!), title: fields["title"]!.string)
    }

    static func folderValue(_ document: SyncDocument) throws -> MeetingFolder {
        let fields = try fields(document, type: .folder)
        return MeetingFolder(id: UUID(uuidString: document.entityID)!, name: fields["name"]!.string!, details: fields["details"]!.string!, createdAt: date(fields["created_at_ms"]!))
    }

    /// Whisper reports an average log-probability (≤ 0); older meetings stored it as-is.
    /// Map it to a probability so one legacy turn never blocks the library; source JSON is untouched.
    static func portableConfidence(_ value: Float) -> Double {
        guard value.isFinite else { return 0 }
        let confidence = Double(value)
        return confidence < 0 ? exp(confidence) : min(confidence, 1)
    }

    static func milliseconds(_ value: TimeInterval) throws -> Int64 {
        guard value.isFinite, value >= 0, value * 1_000 <= Double(SyncCanonicalJSON.maximumInteger) else { throw SyncWireError.invalidNumber }
        return Int64((value * 1_000).rounded())
    }
    private static func document(_ type: SyncEntityType, id: UUID, _ fields: [String: SyncJSONValue]) throws -> SyncDocument {
        var fields = fields
        fields["schema_version"] = .integer(1)
        fields["id"] = uuid(id)
        return try SyncDocument(entityType: type, value: .object(fields))
    }
    private static func fields(_ document: SyncDocument, type: SyncEntityType) throws -> [String: SyncJSONValue] {
        guard document.entityType == type, let fields = document.value.object else { throw SyncWireError.invalidSchema }
        return fields
    }
    private static func uuid(_ value: UUID) -> SyncJSONValue { .string(value.uuidString.lowercased()) }
    private static func optionalUUID(_ value: UUID?) -> SyncJSONValue { value.map(uuid) ?? .null }
    private static func optionalString(_ value: String?) -> SyncJSONValue { value.map(SyncJSONValue.string) ?? .null }
    private static func source(_ value: MeetingCaptureSource) -> SyncJSONValue { .string(value == .microphone ? "microphone" : "system_audio") }
    private static func optionalMilliseconds(_ value: TimeInterval?) throws -> SyncJSONValue { try value.map { .integer(try milliseconds($0)) } ?? .null }
    private static func seconds(_ value: SyncJSONValue) -> TimeInterval { Double(value.integer!) / 1_000 }
    private static func date(_ value: SyncJSONValue) -> Date { Date(timeIntervalSince1970: seconds(value)) }
}
