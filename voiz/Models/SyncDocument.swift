import Foundation

nonisolated enum SyncEntityType: String, CaseIterable, Sendable {
    case meeting, transcript, summary, conversation, message, dictation, translation, folder, note, preferences
}

nonisolated enum SyncMutationKind: String, Sendable { case upsert, trash, restore, purge }

nonisolated enum SyncIdentifier {
    static func validate(_ value: String) throws {
        guard value.utf8.count == 36, let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
            throw SyncWireError.invalidIdentifier
        }
    }
    static func validateHash(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SyncWireError.invalidHash
        }
    }
}

/// A closed, validated DTO; it has no generic Codable export path for application models.
/// The schema is mirrored from the backend contract and checked before hashing or persisting.
nonisolated struct SyncDocument: Equatable, Sendable {
    static let inlineDocumentBytes = 1_024 * 1_024
    let entityType: SyncEntityType
    let value: SyncJSONValue
    var entityID: String { value.object!["id"]!.string! }
    var parentID: String? {
        switch entityType {
        case .transcript, .summary: return value.object?["meeting_id"]?.string
        case .message: return value.object?["conversation_id"]?.string
        default: return nil
        }
    }

    init(entityType: SyncEntityType, value: SyncJSONValue) throws {
        try SyncPayloadSchema.rules[entityType]!.validate(value)
        if entityType == .transcript, case .array(let turns) = value.object?["turns"] {
            for turn in turns {
                guard let fields = turn.object, let start = fields["start_ms"]?.integer,
                      let end = fields["end_ms"]?.integer, end >= start else { throw SyncWireError.invalidSchema }
            }
        }
        self.entityType = entityType
        self.value = value
    }

    init(entityType: SyncEntityType, data: Data) throws {
        try self.init(entityType: entityType, value: SyncCanonicalJSON.decode(data, maximumBytes: Int.max))
    }
    func canonicalData() throws -> Data {
        let data = try SyncCanonicalJSON.encode(value)
        return data
    }
    var quotaBytes: Int { get throws { try canonicalData().count } }
    var sha256: String { get throws { SyncCanonicalJSON.sha256(try canonicalData()) } }
}

nonisolated struct SyncMutationEnvelope: Equatable, Sendable {
    let collectionGeneration: String
    let entityType: SyncEntityType
    let entityID: String
    let operationID: String
    let baseRevision: Int64
    let mutation: SyncMutationKind
    let document: SyncDocument?
    let payloadSHA256: String
    var entityKey: String { entityType.rawValue + "/" + entityID }

    init(collectionGeneration: String, entityType: SyncEntityType, entityID: String,
         operationID: String = UUID().uuidString.lowercased(), baseRevision: Int64,
         mutation: SyncMutationKind, document: SyncDocument?) throws {
        try SyncIdentifier.validate(collectionGeneration)
        try SyncIdentifier.validate(entityID)
        try SyncIdentifier.validate(operationID)
        guard (0...SyncCanonicalJSON.maximumInteger).contains(baseRevision) else { throw SyncWireError.invalidNumber }
        if mutation == .upsert {
            guard let document, document.entityType == entityType, document.entityID == entityID else { throw SyncWireError.invalidSchema }
            _ = try document.canonicalData()
        } else if document != nil { throw SyncWireError.invalidSchema }
        self.collectionGeneration = collectionGeneration
        self.entityType = entityType
        self.entityID = entityID
        self.operationID = operationID
        self.baseRevision = baseRevision
        self.mutation = mutation
        self.document = document
        payloadSHA256 = SyncCanonicalJSON.sha256(try SyncCanonicalJSON.encode(document?.value ?? .null))
    }

    func canonicalData() throws -> Data {
        let data = try SyncCanonicalJSON.encode(.object([
            "schema_version": .integer(1), "collection_generation": .string(collectionGeneration),
            "entity_type": .string(entityType.rawValue), "entity_id": .string(entityID),
            "operation_id": .string(operationID), "base_revision": .integer(baseRevision),
            "mutation": .string(mutation.rawValue), "payload_sha256": .string(payloadSHA256), "payload": document?.value ?? .null
        ]))
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try SyncCanonicalJSON.decode(data, maximumBytes: Int.max)
        guard let fields = value.object,
              Set(fields.keys) == Set(["schema_version", "collection_generation", "entity_type", "entity_id", "operation_id", "base_revision", "mutation", "payload_sha256", "payload"]),
              fields["schema_version"] == .integer(1),
              let generation = fields["collection_generation"]?.string,
              let rawType = fields["entity_type"]?.string, let type = SyncEntityType(rawValue: rawType),
              let id = fields["entity_id"]?.string, let operation = fields["operation_id"]?.string,
              let revision = fields["base_revision"]?.integer,
              let rawMutation = fields["mutation"]?.string, let mutation = SyncMutationKind(rawValue: rawMutation),
              let payload = fields["payload"], let hash = fields["payload_sha256"]?.string else { throw SyncWireError.invalidSchema }
        let document = payload == .null ? nil : try SyncDocument(entityType: type, value: payload)
        let result = try Self(collectionGeneration: generation, entityType: type, entityID: id,
                              operationID: operation, baseRevision: revision, mutation: mutation, document: document)
        guard hash == result.payloadSHA256 else { throw SyncWireError.invalidHash }
        return result
    }
}

/// Server revisions are immutable; the remote feed carries the current safe document for
/// live/trashed records and null for purged records. No local file references are introduced.
nonisolated struct SyncRemoteChange: Equatable, Sendable {
    let collectionGeneration: String
    let cursor: Int64
    let revision: Int64
    let entityType: SyncEntityType
    let entityID: String
    let mutation: SyncMutationKind
    let document: SyncDocument?
    let payloadSHA256: String
    let trashExpiresAtMS: Int64?

    init(collectionGeneration: String, cursor: Int64, revision: Int64, entityType: SyncEntityType,
         entityID: String, mutation: SyncMutationKind, document: SyncDocument?, trashExpiresAtMS: Int64? = nil) throws {
        try SyncIdentifier.validate(collectionGeneration)
        try SyncIdentifier.validate(entityID)
        guard (1...SyncCanonicalJSON.maximumInteger).contains(cursor),
              (1...SyncCanonicalJSON.maximumInteger).contains(revision) else { throw SyncWireError.invalidNumber }
        if let document {
            guard document.entityType == entityType, document.entityID == entityID, mutation != .purge else { throw SyncWireError.invalidSchema }
        } else if mutation != .purge { throw SyncWireError.invalidSchema }
        if mutation == .trash {
            guard let trashExpiresAtMS, (0...SyncCanonicalJSON.maximumInteger).contains(trashExpiresAtMS) else { throw SyncWireError.invalidSchema }
        } else if trashExpiresAtMS != nil { throw SyncWireError.invalidSchema }
        self.collectionGeneration = collectionGeneration
        self.cursor = cursor
        self.revision = revision
        self.entityType = entityType
        self.entityID = entityID
        self.mutation = mutation
        self.document = document
        self.trashExpiresAtMS = trashExpiresAtMS
        payloadSHA256 = SyncCanonicalJSON.sha256(try SyncCanonicalJSON.encode(document?.value ?? .null))
    }

    func canonicalData() throws -> Data {
        try SyncCanonicalJSON.encode(.object([
            "schema_version": .integer(1), "collection_generation": .string(collectionGeneration),
            "cursor": .integer(cursor), "revision": .integer(revision), "entity_type": .string(entityType.rawValue),
            "entity_id": .string(entityID), "mutation": .string(mutation.rawValue),
            "payload_sha256": .string(payloadSHA256), "payload": document?.value ?? .null,
            "trash_expires_at_ms": trashExpiresAtMS.map(SyncJSONValue.integer) ?? .null
        ]))
    }

    static func decode(_ data: Data) throws -> Self {
        try Self(value: SyncCanonicalJSON.decode(data, maximumBytes: Int.max))
    }

    init(value: SyncJSONValue) throws {
        guard let fields = value.object,
              Set(fields.keys) == Set(["schema_version", "collection_generation", "cursor", "revision", "entity_type", "entity_id", "mutation", "payload_sha256", "payload", "trash_expires_at_ms"]),
              fields["schema_version"] == .integer(1), let generation = fields["collection_generation"]?.string,
              let cursor = fields["cursor"]?.integer, let revision = fields["revision"]?.integer,
              let rawType = fields["entity_type"]?.string, let type = SyncEntityType(rawValue: rawType),
              let id = fields["entity_id"]?.string,
              let rawMutation = fields["mutation"]?.string, let mutation = SyncMutationKind(rawValue: rawMutation),
              let payload = fields["payload"], let hash = fields["payload_sha256"]?.string else { throw SyncWireError.invalidSchema }
        guard fields["trash_expires_at_ms"] == .null || fields["trash_expires_at_ms"]?.integer != nil else { throw SyncWireError.invalidSchema }
        let document = payload == .null ? nil : try SyncDocument(entityType: type, value: payload)
        let change = try Self(collectionGeneration: generation, cursor: cursor, revision: revision,
                              entityType: type, entityID: id, mutation: mutation, document: document, trashExpiresAtMS: fields["trash_expires_at_ms"]?.integer)
        guard hash == change.payloadSHA256 else { throw SyncWireError.invalidHash }
        self = change
    }
}


extension SyncRemoteChange {
    static func storedMetadata(_ data: Data) throws -> (cursor: Int64, revision: Int64, entityKey: String) {
        let fields = try SyncObjectReader(SyncCanonicalJSON.envelopeMetadata(data), keys: ["schema_version", "collection_generation", "cursor", "revision", "entity_type", "entity_id", "mutation", "payload_sha256", "payload", "trash_expires_at_ms"])
        try fields.version()
        guard let type = SyncEntityType(rawValue: try fields.string("entity_type")) else { throw SyncWireError.invalidSchema }
        return (try fields.integer("cursor", minimum: 1), try fields.integer("revision", minimum: 1), type.rawValue + "/" + (try fields.identifier("entity_id")))
    }
}
