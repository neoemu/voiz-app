import Foundation
import Darwin

/// Immutable local content is flushed before SQLite records its reference. Interrupted
/// transactions may leave an unreferenced file; they never expose a partially written blob.
/// This private format is separate from every wire DTO and is versioned by its owning DB.
nonisolated struct SyncDurableBlobStore: Sendable {
    static let inlineLimit = 1_024 * 1_024
    let directory: URL

    init(databaseURL: URL) {
        directory = databaseURL.deletingLastPathComponent().appendingPathComponent(databaseURL.lastPathComponent + ".blobs", isDirectory: true)
    }

    func store(_ data: Data) throws -> Data {
        if data.count <= Self.inlineLimit { var stored = Data([0]); stored.append(data); return stored }
        let hash = SyncCanonicalJSON.sha256(data)
        let url = directory.appendingPathComponent(hash)
        try Self.createDirectoryDurably(directory)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url, options: .alwaysMapped)
            guard existing.count == data.count, SyncCanonicalJSON.sha256(existing) == hash else { throw SyncJournalError.corruptRecord }
        } else {
            let temporary = directory.appendingPathComponent("pending-" + UUID().uuidString)
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            for start in stride(from: 0, to: data.count, by: SyncPayloadManifest.chunkBytes) {
                try Task.checkCancellation()
                try handle.write(contentsOf: data.subdata(in: start..<min(data.count, start + SyncPayloadManifest.chunkBytes)))
            }
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try Self.synchronizeDirectory(directory)
        try Self.synchronizeDirectory(directory.deletingLastPathComponent())
        var reference = Data([1])
        reference.append(Data((hash + ":" + String(data.count)).utf8))
        return reference
    }

    func load(_ stored: Data) throws -> Data {
        guard let tag = stored.first else { throw SyncJournalError.corruptRecord }
        if tag == 0 { return Data(stored.dropFirst()) }
        guard tag == 1, let text = String(data: stored.dropFirst(), encoding: .utf8) else { throw SyncJournalError.corruptRecord }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let count = Int(pieces[1]), count > Self.inlineLimit,
              String(count) == pieces[1] else { throw SyncJournalError.corruptRecord }
        let hash = String(pieces[0])
        try SyncIdentifier.validateHash(hash)
        let data = try Data(contentsOf: directory.appendingPathComponent(hash), options: .alwaysMapped)
        guard data.count == count, SyncCanonicalJSON.sha256(data) == hash else { throw SyncJournalError.corruptRecord }
        return data
    }

    /// Metadata-only quota inventory; ordinary reads/uploads still verify the full hash.
    func referencedByteCount(_ stored: Data) throws -> Int64 {
        guard stored.first == 1, let text = String(data: stored.dropFirst(), encoding: .utf8) else { throw SyncJournalError.corruptRecord }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let count = Int64(pieces[1]), count > Self.inlineLimit,
              String(count) == pieces[1] else { throw SyncJournalError.corruptRecord }
        let hash = String(pieces[0])
        try SyncIdentifier.validateHash(hash)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(hash).path)
        guard (attributes[.size] as? NSNumber)?.int64Value == count else { throw SyncJournalError.corruptRecord }
        return count
    }

    /// Flush every newly created directory and the parent entry that names it. The
    /// caller additionally flushes this directory after creating its SQLite database.
    static func createDirectoryDurably(_ url: URL) throws {
        var missing: [URL] = []
        var cursor = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else { throw CocoaError(.fileWriteUnknown) }
            cursor = parent
        }
        guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in missing.reversed() {
            try synchronizeDirectory(directory)
            try synchronizeDirectory(directory.deletingLastPathComponent())
        }
        if missing.isEmpty { try synchronizeDirectory(url) }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
