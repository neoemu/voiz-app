import Foundation
import Darwin

/// Completes the rename and file/directory barriers before a caller acknowledges a result.
nonisolated enum DurableLocalFile {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        var directories = [directory]
        var parent = directory
        while !fileManager.fileExists(atPath: parent.path), parent.path != "/" {
            parent = parent.deletingLastPathComponent()
            directories.append(parent)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try synchronize(url)
        for directory in directories { try synchronize(directory) }
    }
    private static func synchronize(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
