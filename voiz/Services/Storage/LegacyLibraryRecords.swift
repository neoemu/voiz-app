// Legacy persisted protocol records, retained for journal recovery only. No transport.
import Foundation

nonisolated struct SyncServerError: Error, Equatable, Sendable {
    let code: String
    let retryable: Bool
}

nonisolated struct SyncReceipt: Equatable, Sendable {
    let collectionGeneration: String
    let operationID: String
    let entityType: SyncEntityType
    let entityID: String
    let revision: Int64
    let cursor: Int64
    let payloadSHA256: String
    let logicalBytes: Int64
    let state: String

    init(value: SyncJSONValue) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "collection_generation", "operation_id", "entity_type", "entity_id", "revision", "cursor", "payload_sha256", "logical_bytes", "state"])
        try fields.version()
        collectionGeneration = try fields.identifier("collection_generation")
        operationID = try fields.identifier("operation_id")
        entityID = try fields.identifier("entity_id")
        guard let type = SyncEntityType(rawValue: try fields.string("entity_type")) else { throw SyncWireError.invalidSchema }
        entityType = type
        revision = try fields.integer("revision", minimum: 1)
        cursor = try fields.integer("cursor", minimum: 1)
        payloadSHA256 = try fields.string("payload_sha256")
        try SyncIdentifier.validateHash(payloadSHA256)
        logicalBytes = try fields.integer("logical_bytes")
        state = try fields.string("state")
        guard ["active", "trash", "gone"].contains(state) else { throw SyncWireError.invalidSchema }
    }

    func validate(for mutation: SyncMutationEnvelope) throws {
        guard collectionGeneration == mutation.collectionGeneration, operationID == mutation.operationID,
              entityType == mutation.entityType, entityID == mutation.entityID, revision == mutation.baseRevision + 1 else { throw SyncWireError.invalidSchema }
        switch mutation.mutation {
        case .upsert:
            guard state == "active", payloadSHA256 == mutation.payloadSHA256,
                  logicalBytes == Int64(try mutation.document!.quotaBytes) else { throw SyncWireError.invalidHash }
        case .trash: guard state == "trash" else { throw SyncWireError.invalidSchema }
        case .restore: guard state == "active" else { throw SyncWireError.invalidSchema }
        case .purge:
            guard state == "gone", logicalBytes == 0, payloadSHA256 == mutation.payloadSHA256 else { throw SyncWireError.invalidHash }
        }
    }
}

nonisolated struct SyncPreparedResponse: Equatable, Sendable {
    let operationID: String
    let uploadID: String?
    let expiresAtMS: Int64?
    let receipt: SyncReceipt?

    init(value: SyncJSONValue) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "operation_id", "state", "expires_at_ms", "upload_id", "receipt"])
        try fields.version()
        operationID = try fields.identifier("operation_id")
        uploadID = try fields.optionalIdentifier("upload_id")
        expiresAtMS = try fields.optionalInteger("expires_at_ms")
        receipt = fields.values["receipt"] == .null ? nil : try SyncReceipt(value: fields.values["receipt"]!)
        switch try fields.string("state") {
        case "prepared": guard receipt == nil, expiresAtMS != nil else { throw SyncWireError.invalidSchema }
        case "committed": guard receipt != nil, uploadID == nil, expiresAtMS == nil else { throw SyncWireError.invalidSchema }
        default: throw SyncWireError.invalidSchema
        }
    }
}

nonisolated struct SyncChangesPage: Equatable, Sendable {
    let collectionGeneration: String
    let changes: [SyncStagedChange]
    let nextCursor: Int64
    let hasMore: Bool

    init(value: SyncJSONValue, staged: [SyncStagedChange]? = nil) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "collection_generation", "changes", "next_cursor", "has_more"])
        try fields.version()
        collectionGeneration = try fields.identifier("collection_generation")
        nextCursor = try fields.integer("next_cursor")
        hasMore = try fields.bool("has_more")
        guard case .array(let values) = fields.values["changes"], values.count <= 200 else { throw SyncWireError.invalidSchema }
        changes = try staged ?? values.map { try SyncStagedChange(SyncRemoteChange(value: $0)) }
        guard changes.count == values.count, changes.allSatisfy({ $0.collectionGeneration == collectionGeneration && $0.cursor <= nextCursor }) else { throw SyncWireError.invalidSchema }
    }
}

nonisolated struct SyncSnapshotPage: Equatable, Sendable {
    let collectionGeneration: String
    let snapshotID: String
    let cursor: Int64
    let entities: [SyncStagedChange]
    let nextPage: String?

    init(value: SyncJSONValue, staged: [SyncStagedChange]? = nil) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "collection_generation", "snapshot_id", "cursor", "entities", "next_page"])
        try fields.version()
        collectionGeneration = try fields.identifier("collection_generation")
        snapshotID = try fields.identifier("snapshot_id")
        cursor = try fields.integer("cursor")
        nextPage = try fields.optionalString("next_page")
        guard nextPage == nil || (!nextPage!.isEmpty && nextPage!.utf8.count <= 2_048),
              case .array(let values) = fields.values["entities"], values.count <= 200 else { throw SyncWireError.invalidSchema }
        entities = try staged ?? values.map { try SyncStagedChange(SyncRemoteChange(value: $0)) }
        guard entities.count == values.count, entities.allSatisfy({ $0.collectionGeneration == collectionGeneration && $0.cursor <= cursor }) else { throw SyncWireError.invalidSchema }
    }
}

nonisolated struct SyncObjectReader {
    let values: [String: SyncJSONValue]
    init(_ value: SyncJSONValue, keys: Set<String>) throws {
        guard let values = value.object, Set(values.keys) == keys else { throw SyncWireError.invalidSchema }
        self.values = values
    }
    func version() throws { guard values["schema_version"] == .integer(1) else { throw SyncWireError.unsupportedVersion } }
    func string(_ key: String) throws -> String { guard let value = values[key]?.string else { throw SyncWireError.invalidSchema }; return value }
    func identifier(_ key: String) throws -> String { let value = try string(key); try SyncIdentifier.validate(value); return value }
    func integer(_ key: String, minimum: Int64 = 0) throws -> Int64 {
        guard let value = values[key]?.integer, (minimum...SyncCanonicalJSON.maximumInteger).contains(value) else { throw SyncWireError.invalidNumber }; return value
    }
    func bool(_ key: String) throws -> Bool { guard case .bool(let value) = values[key] else { throw SyncWireError.invalidSchema }; return value }
    func optionalString(_ key: String) throws -> String? { values[key] == .null ? nil : try string(key) }
    func optionalIdentifier(_ key: String) throws -> String? { values[key] == .null ? nil : try identifier(key) }
    func optionalInteger(_ key: String) throws -> Int64? { values[key] == .null ? nil : try integer(key) }
}

nonisolated enum SyncConflictResolutionChoice: String, Sendable { case keepLocal, keepRemote }

/// Current authority read by entity, independent from an editable local projection.
nonisolated struct SyncEntitySnapshot: Equatable, Sendable {
    let collectionGeneration: String
    let entityType: SyncEntityType
    let entityID: String
    let cursor: Int64
    let revision: Int64
    let state: String
    let document: SyncDocument?
    let payloadSHA256: String
    let trashExpiresAtMS: Int64?

    init(value: SyncJSONValue) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "collection_generation", "entity_type", "entity_id", "cursor", "revision", "state", "payload", "payload_sha256", "trash_expires_at_ms"])
        try fields.version()
        collectionGeneration = try fields.identifier("collection_generation")
        entityID = try fields.identifier("entity_id")
        guard let type = SyncEntityType(rawValue: try fields.string("entity_type")) else { throw SyncWireError.invalidSchema }
        entityType = type
        cursor = try fields.integer("cursor")
        revision = try fields.integer("revision")
        state = try fields.string("state")
        trashExpiresAtMS = try fields.optionalInteger("trash_expires_at_ms")
        payloadSHA256 = try fields.string("payload_sha256")
        try SyncIdentifier.validateHash(payloadSHA256)
        document = fields.values["payload"] == .null ? nil : try SyncDocument(entityType: type, value: fields.values["payload"]!)
        let expectedHash = SyncCanonicalJSON.sha256(try SyncCanonicalJSON.encode(document?.value ?? .null))
        guard document == nil || document?.entityID == entityID,
              payloadSHA256 == expectedHash, cursor >= revision else { throw SyncWireError.invalidHash }
        switch state {
        case "active": guard document != nil, revision > 0, trashExpiresAtMS == nil else { throw SyncWireError.invalidSchema }
        case "trash": guard document != nil, revision > 0, trashExpiresAtMS != nil else { throw SyncWireError.invalidSchema }
        case "gone": guard document == nil, trashExpiresAtMS == nil else { throw SyncWireError.invalidSchema }
        default: throw SyncWireError.invalidSchema
        }
    }
    var entityKey: String { entityType.rawValue + "/" + entityID }
    func canonicalData() throws -> Data {
        try SyncCanonicalJSON.encode(.object([
            "schema_version": .integer(1), "collection_generation": .string(collectionGeneration),
            "entity_type": .string(entityType.rawValue), "entity_id": .string(entityID), "cursor": .integer(cursor),
            "revision": .integer(revision), "state": .string(state), "payload": document?.value ?? .null,
            "payload_sha256": .string(payloadSHA256), "trash_expires_at_ms": trashExpiresAtMS.map(SyncJSONValue.integer) ?? .null
        ]))
    }
}

nonisolated struct SyncCancellationResult: Equatable, Sendable {
    let collectionGeneration: String
    let operationID: String
    let receipt: SyncReceipt?
    let value: SyncJSONValue

    init(value: SyncJSONValue) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "collection_generation", "operation_id", "state", "receipt"])
        try fields.version()
        collectionGeneration = try fields.identifier("collection_generation")
        operationID = try fields.identifier("operation_id")
        receipt = fields.values["receipt"] == .null ? nil : try SyncReceipt(value: fields.values["receipt"]!)
        switch try fields.string("state") {
        case "cancelled": guard receipt == nil else { throw SyncWireError.invalidSchema }
        case "committed": guard receipt != nil else { throw SyncWireError.invalidSchema }
        default: throw SyncWireError.invalidSchema
        }
        self.value = value
    }
    func validate(for mutation: SyncMutationEnvelope) throws {
        guard collectionGeneration == mutation.collectionGeneration, operationID == mutation.operationID else { throw SyncWireError.invalidSchema }
        if let receipt { try receipt.validate(for: mutation) }
    }
}

