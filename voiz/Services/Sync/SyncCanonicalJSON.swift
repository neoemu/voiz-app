import CryptoKit
import Foundation

/// The Sync wire format deliberately has no floating point numbers. Integer values fit
/// exactly in JavaScript and string scalar sequences are preserved without normalization.
nonisolated indirect enum SyncJSONValue: Equatable, Sendable {
    case object([String: SyncJSONValue])
    case array([SyncJSONValue])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    /// Swift String equality normalizes Unicode. Wire equality must preserve scalar
    /// spelling so a composed/decomposed edit produces its own revision and hash.
    static func == (lhs: SyncJSONValue, rhs: SyncJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let left), .bool(let right)): return left == right
        case (.integer(let left), .integer(let right)): return left == right
        case (.string(let left), .string(let right)): return left.utf8.elementsEqual(right.utf8)
        case (.array(let left), .array(let right)): return left == right
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            for (key, value) in left {
                guard let index = right.index(forKey: key), key.utf8.elementsEqual(right[index].key.utf8),
                      value == right[index].value else { return false }
            }
            return true
        default: return false
        }
    }

    var object: [String: SyncJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    var integer: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }
}

nonisolated enum SyncWireError: Error, Equatable, Sendable {
    case invalidJSON
    case duplicateKey
    case invalidNumber
    case tooLarge
    case tooDeep
    case invalidSchema
    case invalidIdentifier
    case invalidHash
    case unsupportedVersion
}

nonisolated enum SyncCanonicalJSON {
    static let maximumInteger: Int64 = 9_007_199_254_740_991
    static let maximumBytes = 4 * 1_024 * 1_024

    /// Parses the original bytes to reject duplicate keys, invalid UTF-8 and unsafe numeric
    /// spellings before Foundation can discard or round any of that information.
    static func decode(_ data: Data, maximumBytes: Int = maximumBytes) throws -> SyncJSONValue {
        guard data.count <= maximumBytes else { throw SyncWireError.tooLarge }
        return try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self))
            let value = try parser.value(depth: 0)
            parser.whitespace()
            guard parser.offset == parser.bytes.count else { throw SyncWireError.invalidJSON }
            return value
        }
    }

    /// Journal records were validated before publication and their backing blob hash is
    /// checked on read. Receipting needs only metadata, never a second decoded payload.
    static func envelopeMetadata(_ data: Data) throws -> SyncJSONValue {
        try data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw.bindMemory(to: UInt8.self), omitRootPayload: true)
            let value = try parser.value(depth: 0)
            parser.whitespace()
            guard parser.offset == parser.bytes.count else { throw SyncWireError.invalidJSON }
            return value
        }
    }

    static func encode(_ value: SyncJSONValue) throws -> Data {
        let output = SyncJSONOutput()
        try append(value, to: output, depth: 0)
        return try output.finish()
    }

    static func canonicalize(_ data: Data) throws -> Data { try encode(decode(data)) }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: SyncJSONValue, to output: SyncJSONOutput, depth: Int) throws {
        guard depth <= 64 else { throw SyncWireError.tooDeep }
        switch value {
        case .null: try output.append(contentsOf: "null".utf8)
        case .bool(let flag): try output.append(contentsOf: (flag ? "true" : "false").utf8)
        case .integer(let number):
            guard (-maximumInteger...maximumInteger).contains(number) else { throw SyncWireError.invalidNumber }
            try output.append(contentsOf: String(number).utf8)
        case .string(let string): try appendString(string, to: output)
        case .array(let values):
            try output.append(91)
            for (index, item) in values.enumerated() {
                if index > 0 { try output.append(44) }
                try append(item, to: output, depth: depth + 1)
            }
            try output.append(93)
        case .object(let values):
            try output.append(123)
            // RFC 8785 orders property names by UTF-16 code units, not the locale.
            let keys = values.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { try output.append(44) }
                try appendString(key, to: output)
                try output.append(58)
                try append(values[key]!, to: output, depth: depth + 1)
            }
            try output.append(125)
        }
    }

    private static func appendString(_ string: String, to output: SyncJSONOutput) throws {
        try output.append(34)
        let hex = Array("0123456789abcdef".utf8)
        // A Swift String is already valid Unicode. Escaping UTF-8 bytes avoids creating
        // a temporary String/Array for every scalar in a large transcript.
        for byte in string.utf8 {
            switch byte {
            case 34: try output.append(contentsOf: [92, 34])
            case 92: try output.append(contentsOf: [92, 92])
            case 8: try output.append(contentsOf: [92, 98])
            case 9: try output.append(contentsOf: [92, 116])
            case 10: try output.append(contentsOf: [92, 110])
            case 12: try output.append(contentsOf: [92, 102])
            case 13: try output.append(contentsOf: [92, 114])
            case 0...31: try output.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
            default: try output.append(byte)
            }
        }
        try output.append(34)
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var offset = 0
        var omitRootPayload = false

        mutating func skipPayload() throws {
            whitespace()
            if offset < bytes.count, bytes[offset] == 110 { try literal("null"); return }
            guard take(123) else { throw SyncWireError.invalidJSON }
            var depth = 1
            var inString = false
            var escaped = false
            while offset < bytes.count {
                if offset & 0xffff == 0 { try Task.checkCancellation() }
                let byte = bytes[offset]; offset += 1
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else {
                    if byte == 34 { inString = true }
                    else if byte == 123 || byte == 91 { depth += 1 }
                    else if byte == 125 || byte == 93 {
                        depth -= 1
                        if depth == 0 { return }
                    }
                }
            }
            throw SyncWireError.invalidJSON
        }

        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func value(depth: Int) throws -> SyncJSONValue {
            guard depth <= 64 else { throw SyncWireError.tooDeep }
            whitespace()
            guard offset < bytes.count else { throw SyncWireError.invalidJSON }
            switch bytes[offset] {
            case 123:
                offset += 1
                whitespace()
                var result: [String: SyncJSONValue] = [:]
                if take(125) { return .object(result) }
                while true {
                    whitespace()
                    let key = try string()
                    guard result[key] == nil else { throw SyncWireError.duplicateKey }
                    whitespace()
                    guard take(58) else { throw SyncWireError.invalidJSON }
                    if omitRootPayload && depth == 0 && key == "payload" {
                        try skipPayload()
                        result[key] = .null
                    } else { result[key] = try value(depth: depth + 1) }
                    whitespace()
                    if take(125) { return .object(result) }
                    guard take(44) else { throw SyncWireError.invalidJSON }
                }
            case 91:
                offset += 1
                whitespace()
                var result: [SyncJSONValue] = []
                if take(93) { return .array(result) }
                while true {
                    result.append(try value(depth: depth + 1))
                    whitespace()
                    if take(93) { return .array(result) }
                    guard take(44) else { throw SyncWireError.invalidJSON }
                }
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57:
                let start = offset
                _ = take(45)
                guard offset < bytes.count, (48...57).contains(bytes[offset]) else { throw SyncWireError.invalidNumber }
                if take(48) {
                    if offset < bytes.count, (48...57).contains(bytes[offset]) { throw SyncWireError.invalidNumber }
                } else {
                    while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
                }
                let text = String(decoding: bytes[start..<offset], as: UTF8.self)
                guard text != "-0", let number = Int64(text),
                      (-SyncCanonicalJSON.maximumInteger...SyncCanonicalJSON.maximumInteger).contains(number)
                else { throw SyncWireError.invalidNumber }
                if offset < bytes.count, [46, 69, 101].contains(bytes[offset]) { throw SyncWireError.invalidNumber }
                return .integer(number)
            default: throw SyncWireError.invalidJSON
            }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        mutating func literal(_ expected: String) throws {
            for byte in expected.utf8 {
                guard take(byte) else { throw SyncWireError.invalidJSON }
            }
        }

        mutating func hexQuad() throws -> UInt32 {
            var result: UInt32 = 0
            for _ in 0..<4 {
                guard offset < bytes.count else { throw SyncWireError.invalidJSON }
                let byte = bytes[offset]
                offset += 1
                let value: UInt8
                switch byte {
                case 48...57: value = byte - 48
                case 65...70: value = byte - 65 + 10
                case 97...102: value = byte - 97 + 10
                default: throw SyncWireError.invalidJSON
                }
                result = result * 16 + UInt32(value)
            }
            return result
        }

        mutating func string() throws -> String {
            guard take(34) else { throw SyncWireError.invalidJSON }
            var result = String()
            var segmentStart = offset
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 34 {
                    guard let segment = String(bytes: bytes[segmentStart..<(offset - 1)], encoding: .utf8) else { throw SyncWireError.invalidJSON }
                    result.append(segment)
                    return result
                }
                guard byte >= 32 else { throw SyncWireError.invalidJSON }
                if byte != 92 { continue }
                guard let segment = String(bytes: bytes[segmentStart..<(offset - 1)], encoding: .utf8) else { throw SyncWireError.invalidJSON }
                result.append(segment)
                guard offset < bytes.count else { throw SyncWireError.invalidJSON }
                let escaped = bytes[offset]
                offset += 1
                switch escaped {
                case 34, 47, 92: result.unicodeScalars.append(UnicodeScalar(escaped))
                case 98: result.unicodeScalars.append(UnicodeScalar(8)!)
                case 102: result.unicodeScalars.append(UnicodeScalar(12)!)
                case 110: result.unicodeScalars.append(UnicodeScalar(10)!)
                case 114: result.unicodeScalars.append(UnicodeScalar(13)!)
                case 116: result.unicodeScalars.append(UnicodeScalar(9)!)
                case 117:
                    var scalar = try hexQuad()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard take(92), take(117) else { throw SyncWireError.invalidJSON }
                        let low = try hexQuad()
                        guard (0xDC00...0xDFFF).contains(low) else { throw SyncWireError.invalidJSON }
                        scalar = 0x10000 + (scalar - 0xD800) * 1024 + (low - 0xDC00)
                    }
                    guard let unicode = UnicodeScalar(scalar) else { throw SyncWireError.invalidJSON }
                    result.unicodeScalars.append(unicode)
                default: throw SyncWireError.invalidJSON
                }
                segmentStart = offset
            }
            throw SyncWireError.invalidJSON
        }
    }
}
