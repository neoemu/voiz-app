import Foundation

/// Validates canonical payloads directly over file-backed bytes. Text and array elements
/// are visited without retaining them; only bounded schema keys/identifiers are captured.
/// This deliberately shares the closed DTO rules with the ordinary decoder.
nonisolated enum SyncStreamedPayload {
    static func validate(_ data: Data, type: SyncEntityType, id: String) throws {
        try data.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self))
            let fields = try reader.object(SyncPayloadSchema.rules[type]!, depth: 0)
            guard reader.offset == raw.count, fields["id"]?.string == id else { throw SyncWireError.invalidSchema }
        }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var offset = 0

        mutating func take(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }
        mutating func expect(_ byte: UInt8) throws {
            guard take(byte) else { throw SyncWireError.invalidJSON }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try expect(byte) }
        }

        mutating func object(_ rule: SyncPayloadSchema.Rule, depth: Int) throws -> [String: SyncJSONValue] {
            guard case .object(let fields) = rule, depth <= 64 else { throw SyncWireError.invalidSchema }
            try expect(123)
            var captured: [String: SyncJSONValue] = [:]
            // Exact canonical order rejects duplicates, unknown fields and omissions.
            let keys = fields.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, key) in keys.enumerated() {
                if index > 0 { try expect(44) }
                try literal("\"" + key + "\":") // Schema keys are fixed ASCII identifiers.
                captured[key] = try value(fields[key]!, depth: depth + 1)
            }
            try expect(125)
            if let start = captured["start_ms"]?.integer, let end = captured["end_ms"]?.integer, end < start {
                throw SyncWireError.invalidSchema
            }
            return captured
        }

        mutating func value(_ rule: SyncPayloadSchema.Rule, depth: Int) throws -> SyncJSONValue {
            guard depth <= 64 else { throw SyncWireError.tooDeep }
            try Task.checkCancellation()
            switch rule {
            case .object:
                _ = try object(rule, depth: depth)
                return .null
            case .array(let child):
                try expect(91)
                if take(93) { return .null }
                while true {
                    _ = try value(child, depth: depth + 1)
                    if take(93) { return .null }
                    try expect(44)
                }
            case .nullable(let child):
                if offset < bytes.count, bytes[offset] == 110 { try literal("null"); return .null }
                return try value(child, depth: depth)
            case .literal(let expected):
                let spelling = try SyncCanonicalJSON.encode(expected)
                for byte in spelling { try expect(byte) }
                return expected
            case .string(let minimum):
                _ = try string(minimum: minimum, captureLimit: nil)
                return .null
            case .identifier:
                let text = try string(minimum: 1, captureLimit: 36)
                try SyncIdentifier.validate(text)
                return .string(text)
            case .choices(let choices):
                let text = try string(minimum: 0, captureLimit: choices.map { $0.utf8.count }.max() ?? 0)
                guard choices.contains(text) else { throw SyncWireError.invalidSchema }
                return .string(text)
            case .boolean:
                if offset < bytes.count, bytes[offset] == 116 { try literal("true"); return .bool(true) }
                try literal("false"); return .bool(false)
            case .integer(let minimum, let maximum):
                let start = offset
                _ = take(45)
                if !take(48) {
                    guard offset < bytes.count, (49...57).contains(bytes[offset]) else { throw SyncWireError.invalidNumber }
                    while offset < bytes.count, (48...57).contains(bytes[offset]) {
                        offset += 1
                        guard offset - start <= 17 else { throw SyncWireError.invalidNumber }
                    }
                }
                let text = String(decoding: bytes[start..<offset], as: UTF8.self)
                guard text != "-0", let number = Int64(text), (minimum...maximum).contains(number) else { throw SyncWireError.invalidNumber }
                return .integer(number)
            }
        }

        /// Canonical JSON escapes only controls, quote and backslash. UTF-8 is checked
        /// scalar by scalar (including overlong/surrogate rejection) without a String.
        mutating func string(minimum: Int, captureLimit: Int?) throws -> String {
            try expect(34)
            let start = offset
            var scalars = 0
            while offset < bytes.count {
                if offset & 0xffff == 0 { try Task.checkCancellation() }
                let byte = bytes[offset]
                offset += 1
                if byte == 34 {
                    guard scalars >= minimum else { throw SyncWireError.invalidSchema }
                    guard captureLimit != nil else { return "" }
                    // Captured identifiers/choices cannot contain canonical escapes.
                    guard let text = String(bytes: bytes[start..<(offset - 1)], encoding: .utf8), !text.contains("\\") else { throw SyncWireError.invalidSchema }
                    return text
                }
                if let limit = captureLimit, offset - start > limit { throw SyncWireError.invalidSchema }
                guard byte >= 32 else { throw SyncWireError.invalidJSON }
                scalars += 1
                if byte == 92 {
                    guard offset < bytes.count else { throw SyncWireError.invalidJSON }
                    let escape = bytes[offset]; offset += 1
                    if [34, 92, 98, 116, 110, 102, 114].contains(escape) { continue }
                    guard escape == 117 else { throw SyncWireError.invalidJSON }
                    try expect(48); try expect(48)
                    guard offset + 2 <= bytes.count else { throw SyncWireError.invalidJSON }
                    let high = bytes[offset], low = bytes[offset + 1]; offset += 2
                    guard high == 48 || high == 49 else { throw SyncWireError.invalidJSON }
                    let digit: Int
                    if (48...57).contains(low) { digit = Int(low - 48) }
                    else if (97...102).contains(low) { digit = Int(low - 87) }
                    else { throw SyncWireError.invalidJSON }
                    let code = Int(high - 48) * 16 + digit
                    guard ![8, 9, 10, 12, 13].contains(code) else { throw SyncWireError.invalidJSON }
                } else if byte >= 128 {
                    let length: Int
                    let lower: UInt8
                    let upper: UInt8
                    switch byte {
                    case 0xc2...0xdf: length = 1; lower = 0x80; upper = 0xbf
                    case 0xe0: length = 2; lower = 0xa0; upper = 0xbf
                    case 0xe1...0xec, 0xee...0xef: length = 2; lower = 0x80; upper = 0xbf
                    case 0xed: length = 2; lower = 0x80; upper = 0x9f
                    case 0xf0: length = 3; lower = 0x90; upper = 0xbf
                    case 0xf1...0xf3: length = 3; lower = 0x80; upper = 0xbf
                    case 0xf4: length = 3; lower = 0x80; upper = 0x8f
                    default: throw SyncWireError.invalidJSON
                    }
                    guard offset + length <= bytes.count, (lower...upper).contains(bytes[offset]) else { throw SyncWireError.invalidJSON }
                    for index in 1..<length { guard (0x80...0xbf).contains(bytes[offset + index]) else { throw SyncWireError.invalidJSON } }
                    offset += length
                }
            }
            throw SyncWireError.invalidJSON
        }
    }
}
