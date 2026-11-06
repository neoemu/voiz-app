import Foundation
import Darwin

/// Private scratch storage. A file is flushed before its bytes can be handed to the
/// journal. Unlinking after mapping is safe: the mapping owns the inode until released.
/// No name/path is accepted from a server, and an interrupted transfer has no cursor.
nonisolated final class SyncTransferFile {
    let url: URL
    private let handle: FileHandle
    private var closed = false

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("voiz-sync-" + UUID().uuidString)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // No directory entry needs to survive a crash: the journal durably imports the
        // completed mapping before exposing it. Unlink now also cleans up process death.
        guard Darwin.unlink(url.path) == 0 else {
            try? handle.close()
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { try? handle.close() }

    func append(_ data: Data) throws {
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
    }

    func finish() throws -> Data {
        guard !closed else { throw CocoaError(.fileReadUnknown) }
        try handle.synchronize()
        let count = try handle.offset()
        guard count <= UInt64(Int.max) else { throw SyncWireError.tooLarge }
        if count == 0 { closed = true; try handle.close(); return Data() }
        guard let address = mmap(nil, Int(count), PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0), address != MAP_FAILED else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = Data(bytesNoCopy: address, count: Int(count), deallocator: .custom { pointer, count in munmap(pointer, count) })
        closed = true
        try handle.close()
        return data
    }

    static func stage(_ data: Data) throws -> Data {
        let file = try SyncTransferFile()
        // Bounded writes also handle documents larger than the syscall's signed count.
        for start in stride(from: 0, to: data.count, by: SyncPayloadManifest.chunkBytes) {
            try Task.checkCancellation()
            try file.append(data.subdata(in: start..<min(data.count, start + SyncPayloadManifest.chunkBytes)))
        }
        return try file.finish()
    }
}

/// Canonical serialization spills after 1 MiB. Large journal/index envelopes remain
/// mapped files rather than another quota-sized heap allocation beside the decoded DTO.
nonisolated final class SyncJSONOutput {
    private var buffer: [UInt8] = []
    private var file: SyncTransferFile?
    private let bufferLimit = 64 * 1_024

    func append(_ byte: UInt8) throws {
        buffer.append(byte)
        if buffer.count >= (file == nil ? SyncPayloadManifest.chunkBytes : bufferLimit) {
            try Task.checkCancellation()
            if file == nil { file = try SyncTransferFile() }
            try file!.append(Data(buffer))
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func append<S: Sequence>(contentsOf bytes: S) throws where S.Element == UInt8 {
        for byte in bytes { try append(byte) }
    }

    func finish() throws -> Data {
        guard let file else { return Data(buffer) }
        if !buffer.isEmpty { try file.append(Data(buffer)); buffer.removeAll(keepingCapacity: false) }
        return try file.finish()
    }
}

/// A page retains serialized, file-backed records, never a page of decoded documents.
/// Import/application call load one at a time; mapping lifetimes do not depend on a path.
nonisolated struct SyncStagedChange: Equatable, Sendable {
    let collectionGeneration: String
    let cursor: Int64
    let revision: Int64
    let entityKey: String
    let bytes: Data

    init(_ change: SyncRemoteChange) throws {
        collectionGeneration = change.collectionGeneration
        cursor = change.cursor
        revision = change.revision
        entityKey = change.entityType.rawValue + "/" + change.entityID
        bytes = try SyncTransferFile.stage(change.canonicalData())
    }

    /// Payload bytes were authenticated and schema-checked by the streaming downloader.
    /// Construct the canonical envelope without decoding/re-encoding its text.
    init(value: SyncJSONValue, payload: Data) throws {
        guard var fields = value.object else { throw SyncWireError.invalidSchema }
        fields.removeValue(forKey: "payload_manifest")
        let reader = try SyncObjectReader(.object(fields), keys: ["schema_version", "collection_generation", "entity_type", "entity_id", "cursor", "revision", "mutation", "payload", "payload_sha256", "trash_expires_at_ms"])
        try reader.version()
        collectionGeneration = try reader.identifier("collection_generation")
        cursor = try reader.integer("cursor", minimum: 1)
        revision = try reader.integer("revision", minimum: 1)
        let id = try reader.identifier("entity_id")
        guard let type = SyncEntityType(rawValue: try reader.string("entity_type")),
              let mutation = SyncMutationKind(rawValue: try reader.string("mutation")), mutation != .purge,
              fields["payload"] == .null else { throw SyncWireError.invalidSchema }
        let expiry = try reader.optionalInteger("trash_expires_at_ms")
        guard (mutation == .trash) == (expiry != nil) else { throw SyncWireError.invalidSchema }
        // Keep this initializer safe even for local callers outside the downloader.
        let hash = try reader.string("payload_sha256")
        guard SyncCanonicalJSON.sha256(payload) == hash else { throw SyncWireError.invalidHash }
        try SyncStreamedPayload.validate(payload, type: type, id: id)
        entityKey = type.rawValue + "/" + id
        let file = try SyncTransferFile()
        try file.append(Data([123]))
        for (index, key) in fields.keys.sorted().enumerated() {
            if index > 0 { try file.append(Data([44])) }
            try file.append(SyncCanonicalJSON.encode(.string(key)))
            try file.append(Data([58]))
            if key == "payload" {
                for start in stride(from: 0, to: payload.count, by: SyncPayloadManifest.chunkBytes) {
                    try Task.checkCancellation()
                    try file.append(payload.subdata(in: start..<min(payload.count, start + SyncPayloadManifest.chunkBytes)))
                }
            } else { try file.append(SyncCanonicalJSON.encode(fields[key]!)) }
        }
        try file.append(Data([125]))
        bytes = try file.finish()
    }

    func load() throws -> SyncRemoteChange { try SyncRemoteChange.decode(bytes) }
}
