import Foundation
import CryptoKit

/// Wire manifests have one canonical partition: full 1 MiB chunks followed by one tail.
/// Quota bounds descriptor count; document text has no separate product/duration limit.
nonisolated struct SyncPayloadManifest: Equatable, Sendable {
    static let chunkBytes = 1_024 * 1_024
    static let maximumQuotaBytes: Int64 = 5_000_000_000
    struct Chunk: Equatable, Sendable {
        let index: Int
        let sha256: String
        let bytes: Int
        var value: SyncJSONValue { .object(["index": .integer(Int64(index)), "sha256": .string(sha256), "bytes": .integer(Int64(bytes))]) }
    }
    let totalBytes: Int
    let payloadSHA256: String
    let chunks: [Chunk]

    init(data: Data) throws {
        guard data.count > Self.chunkBytes, Int64(data.count) <= Self.maximumQuotaBytes else { throw SyncWireError.tooLarge }
        totalBytes = data.count
        payloadSHA256 = SyncCanonicalJSON.sha256(data)
        var result: [Chunk] = []
        for start in stride(from: 0, to: data.count, by: Self.chunkBytes) {
            let end = min(data.count, start + Self.chunkBytes)
            result.append(Chunk(index: result.count, sha256: SyncCanonicalJSON.sha256(data.subdata(in: start..<end)), bytes: end - start))
        }
        chunks = result
    }

    init(value: SyncJSONValue) throws {
        let fields = try SyncObjectReader(value, keys: ["schema_version", "total_bytes", "payload_sha256", "chunks"])
        try fields.version()
        let size = try fields.integer("total_bytes", minimum: Int64(Self.chunkBytes + 1))
        guard size <= Self.maximumQuotaBytes, case .array(let values) = fields.values["chunks"],
              values.count == Int((size + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes)) else { throw SyncWireError.invalidSchema }
        totalBytes = Int(size)
        payloadSHA256 = try fields.string("payload_sha256")
        try SyncIdentifier.validateHash(payloadSHA256)
        chunks = try values.enumerated().map { index, value in
            let chunk = try SyncObjectReader(value, keys: ["index", "sha256", "bytes"])
            let bytes = try chunk.integer("bytes", minimum: 1)
            let expected = index == values.count - 1 ? Int(size) - index * Self.chunkBytes : Self.chunkBytes
            guard try chunk.integer("index") == Int64(index), bytes == Int64(expected) else { throw SyncWireError.invalidSchema }
            let hash = try chunk.string("sha256")
            try SyncIdentifier.validateHash(hash)
            return Chunk(index: index, sha256: hash, bytes: expected)
        }
    }
    var value: SyncJSONValue {
        .object(["schema_version": .integer(1), "total_bytes": .integer(Int64(totalBytes)),
                 "payload_sha256": .string(payloadSHA256), "chunks": .array(chunks.map(\.value))])
    }
}

nonisolated enum SyncLocalPayloadError: Error, Equatable, Sendable {
    case duplicateTurnIdentifiers
}

extension SyncMutationEnvelope {
    /// Publication-only constraints never prevent saving/exporting the complete local
    /// model. Cancellation deliberately accepts this original envelope to fence its ID.
    func validateForUpload() throws {
        guard let document, document.entityType == .transcript,
              case .array(let turns) = document.value.object?["turns"] else { return }
        var ids = Set<String>()
        for turn in turns {
            guard let id = turn.object?["id"]?.string else { throw SyncWireError.invalidSchema }
            guard ids.insert(id).inserted else { throw SyncLocalPayloadError.duplicateTurnIdentifiers }
        }
    }

    /// The journal retains the complete closed DTO. Only HTTP uses the manifest variant.
    /// The same deterministic variant must also be used for cancellation/idempotency.
    func transportData() throws -> Data {
        guard let document else { return try canonicalData() }
        let payload = try document.canonicalData()
        if payload.count <= SyncPayloadManifest.chunkBytes { return try canonicalData() }
        let manifest = try SyncPayloadManifest(data: payload)
        guard manifest.payloadSHA256 == payloadSHA256 else { throw SyncWireError.invalidHash }
        let data = try SyncCanonicalJSON.encode(.object([
            "schema_version": .integer(1), "collection_generation": .string(collectionGeneration),
            "entity_type": .string(entityType.rawValue), "entity_id": .string(entityID),
            "operation_id": .string(operationID), "base_revision": .integer(baseRevision),
            "mutation": .string(mutation.rawValue), "payload_sha256": .string(payloadSHA256), "payload": .null,
            "payload_manifest": manifest.value, "parent_id": document.parentID.map(SyncJSONValue.string) ?? .null
        ]))
        guard data.count <= SyncCanonicalJSON.maximumBytes else { throw SyncWireError.tooLarge }
        return data
    }
}

