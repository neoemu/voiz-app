#if DEBUG
import Foundation

/// Identidade reprodutível do artefato de modelo efetivamente no disco (DEBUG-only).
///
/// Não usa rótulos genéricos fixos: fingerprint a partir de pesos/config no Mac atual.
nonisolated enum BenchmarkModelIdentity {
    /// Revisão/fingerprint do modelo de `target` como está neste processo.
    nonisolated static func revision(
        for target: BenchmarkEngineTarget,
        fileManager: FileManager = .default,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        switch target.engine {
        case .whisperKit:
            return whisperRevision(variant: target.model.rawValue, fileManager: fileManager)
        case .appleSpeechAnalyzer:
            let v = processInfo.operatingSystemVersion
            return "system-\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        case .parakeet:
            return parakeetRevision(fileManager: fileManager)
        default:
            return "unknown-engine:\(target.engine.rawValue)"
        }
    }

    nonisolated static func whisperRevision(
        variant: String,
        fileManager: FileManager = .default
    ) -> String {
        guard let folder = WhisperKitEngineSupport.modelFolderURL(
            for: variant,
            fileManager: fileManager
        ) else {
            return "not-downloaded:\(variant)"
        }
        let weight = folder
            .appendingPathComponent("TextDecoder.mlmodelc")
            .appendingPathComponent("weights")
            .appendingPathComponent("weight.bin")
        if let fp = fileFingerprint(weight, fileManager: fileManager) {
            return "\(variant)@\(fp)"
        }
        if WhisperKitEngineSupport.areWeightsPresent(inModelFolder: folder, fileManager: fileManager) {
            return "\(variant)@weights-present"
        }
        return "\(variant)@missing-weights"
    }

    nonisolated static func parakeetRevision(fileManager: FileManager = .default) -> String {
        // FluidAudio / ModelHub costuma espelhar sob Application Support ou Caches.
        let roots = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        let markers = [
            "parakeet-tdt-0.6b-v3",
            "ParakeetTDT",
            "fluidaudio",
        ]
        for root in roots {
            if let hit = firstFile(
                under: root,
                matching: { name in
                    let lower = name.lowercased()
                    return markers.contains { lower.contains($0.lowercased()) }
                        && (lower.hasSuffix(".mlmodelc") || lower.contains("weight"))
                },
                fileManager: fileManager
            ), let fp = fileFingerprint(hit, fileManager: fileManager) {
                return "parakeet-tdt-0.6b-v3@\(fp)"
            }
        }
        return "parakeet-tdt-0.6b-v3@not-fingerprinted"
    }

    /// `size{bytes}m{mtime_unix}` — estável o bastante para reproduzir "qual binário rodou".
    nonisolated static func fileFingerprint(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ]) else { return nil }
        let size = values.fileSize ?? 0
        let mtime = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "size\(size)m\(mtime)"
    }

    nonisolated private static func firstFile(
        under root: URL,
        matching: (String) -> Bool,
        fileManager: FileManager
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var depth = 0
        while let next = enumerator.nextObject() as? URL {
            depth += 1
            if depth > 4_000 { return nil } // limite de varredura DEBUG
            if matching(next.lastPathComponent) {
                return next
            }
        }
        return nil
    }
}
#endif
