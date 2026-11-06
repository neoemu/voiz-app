import Foundation

// Closed payload contracts from service/sync/contracts/v1.schema.json. Keep fixture parity
// tests when changing either side; additional properties are always rejected recursively.
nonisolated enum SyncPayloadSchema {
    static let rules: [SyncEntityType: Rule] = [
        .meeting: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "title": .string(0), "session_type": .choices(["meeting", "interview"]), "started_at_ms": .integer(0, 9007199254740991), "ended_at_ms": .nullable(.integer(0, 9007199254740991)), "paused_ms": .integer(0, 9007199254740991), "notes": .string(0), "include_notes_in_summary": .boolean, "context_session_ids": .array(.identifier), "speakers": .array(.object(["id": .string(1), "name": .string(0), "source": .choices(["microphone", "system_audio"])])), "folder_id": .nullable(.identifier)]),
        .transcript: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "meeting_id": .identifier, "generation_id": .identifier, "turns": .array(.object(["id": .identifier, "source": .choices(["microphone", "system_audio"]), "speaker_id": .nullable(.string(0)), "speaker_name": .string(0), "text": .string(0), "start_ms": .integer(0, 9007199254740991), "end_ms": .integer(0, 9007199254740991), "confidence_basis_points": .nullable(.integer(0, 10000))]))]),
        .summary: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "meeting_id": .identifier, "transcript_generation_id": .nullable(.identifier), "title": .string(0), "sections": .array(.object(["id": .string(0), "title": .string(0), "kind": .choices(["paragraph", "bullets", "action_items"]), "paragraph": .string(0), "bullets": .array(.string(0)), "action_items": .array(.object(["id": .identifier, "text": .string(0), "assignee": .nullable(.string(0)), "due_date": .nullable(.string(0)), "done": .boolean, "followed": .boolean])), "evidence": .array(.object(["item_index": .integer(0, 9007199254740991), "turn_ids": .array(.identifier)]))])), "chapters": .array(.object(["id": .identifier, "title": .string(0), "start_ms": .integer(0, 9007199254740991)]))]),
        .conversation: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "title": .string(0), "created_at_ms": .integer(0, 9007199254740991), "updated_at_ms": .integer(0, 9007199254740991), "is_pinned": .boolean, "meeting_id": .nullable(.identifier)]),
        .message: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "conversation_id": .identifier, "role": .choices(["user", "assistant"]), "content": .string(0), "position": .integer(0, 9007199254740991), "reply_to_id": .nullable(.identifier)]),
        .dictation: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "title": .nullable(.string(0)), "text": .string(0), "language": .choices(["pt", "en", "es", "fr", "de", "ja", "zh"]), "timestamp_ms": .integer(0, 9007199254740991), "duration_ms": .integer(0, 9007199254740991), "raw_text": .nullable(.string(0)), "previous_text": .nullable(.string(0))]),
        .translation: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "title": .nullable(.string(0)), "source_text": .string(0), "translated_text": .string(0), "source_language": .choices(["pt", "en", "es", "fr", "de", "ja", "zh"]), "target_language": .choices(["pt", "en", "es", "fr", "de", "ja", "zh"]), "timestamp_ms": .integer(0, 9007199254740991)]),
        .folder: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "name": .string(0), "details": .string(0), "created_at_ms": .integer(0, 9007199254740991)]),
        .note: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "title": .string(0), "text": .string(0), "meeting_id": .nullable(.identifier), "created_at_ms": .integer(0, 9007199254740991), "updated_at_ms": .integer(0, 9007199254740991)]),
        .preferences: .object(["schema_version": .literal(.integer(1)), "id": .identifier, "interface_language": .choices(["system", "pt-BR", "en", "es", "fr", "de", "ja", "zh-Hans"]), "appearance": .choices(["system", "light", "dark"]), "selected_language": .choices(["pt", "en", "es", "fr", "de", "ja", "zh"]), "notes_language": .choices(["spoken", "interface", "pt-BR", "en"]), "show_confidence": .boolean]),
    ]

    indirect enum Rule: Sendable {
        case object([String: Rule]), array(Rule), nullable(Rule), literal(SyncJSONValue)
        case string(Int), integer(Int64, Int64), boolean, identifier, choices(Set<String>)

        func validate(_ value: SyncJSONValue) throws {
            switch (self, value) {
            case (.object(let fields), .object(let object)):
                guard Set(object.keys) == Set(fields.keys) else { throw SyncWireError.invalidSchema }
                for (key, rule) in fields { try rule.validate(object[key]!) }
            case (.array(let rule), .array(let values)): for item in values { try rule.validate(item) }
            case (.nullable, .null): return
            case (.nullable(let rule), _): try rule.validate(value)
            case (.literal(let expected), _): guard expected == value else { throw SyncWireError.unsupportedVersion }
            case (.string(let minimum), .string(let text)):
                guard text.unicodeScalars.count >= minimum else { throw SyncWireError.invalidSchema }
            case (.integer(let minimum, let maximum), .integer(let integer)):
                guard (minimum...maximum).contains(integer) else { throw SyncWireError.invalidNumber }
            case (.boolean, .bool): return
            case (.identifier, .string(let text)): try SyncIdentifier.validate(text)
            case (.choices(let allowed), .string(let text)):
                guard allowed.contains(text) else { throw SyncWireError.invalidSchema }
            default: throw SyncWireError.invalidSchema
            }
        }
    }
}
