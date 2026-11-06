import Foundation
import Testing

@Suite("Sync canonical JSON and closed contracts")
struct SyncCanonicalJSONTests {
    @Test func sharedBackendFixturesMatchBytesHashAndQuota() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("service/sync/fixtures/canonical-v1.json"))
        let object = try #require(try SyncCanonicalJSON.decode(data).object)
        guard case .array(let fixtures) = object["fixtures"] else { Issue.record("Missing shared fixtures"); return }
        #expect(fixtures.count >= 10)
        for fixture in fixtures {
            let fields = try #require(fixture.object)
            let rawType = try #require(fields["entity_type"]?.string)
            let type = try #require(SyncEntityType(rawValue: rawType))
            let document = try SyncDocument(entityType: type, value: #require(fields["payload"]))
            #expect(String(data: try document.canonicalData(), encoding: .utf8) == fields["canonical"]?.string)
            #expect(try document.sha256 == fields["sha256"]?.string)
            #expect(Int64(try document.quotaBytes) == fields["quota_bytes"]?.integer)
            try SyncStreamedPayload.validate(document.canonicalData(), type: type, id: document.entityID)
        }
    }

    @Test func rejectsAmbiguousJSONBeforeFoundationCanDiscardInformation() {
        for input in ["{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "1.0", "1e2", "-0", "01", "9007199254740992", "\"\\uD800\"", "\"\\uDC00\"", "[1,]", "{}false"] {
            #expect(throws: (any Error).self) { try SyncCanonicalJSON.decode(Data(input.utf8)) }
        }
        #expect(throws: (any Error).self) { try SyncCanonicalJSON.decode(Data([34, 0xff, 34])) }
    }

    @Test func unicodeEscapingAndUTF16OrderingAreStable() throws {
        let input = Data("{\"\":\"é\",\"😀\":\"\\ud83d\\ude00\\n\\u0000/\"}".utf8)
        let canonical = try SyncCanonicalJSON.canonicalize(input)
        #expect(String(data: canonical, encoding: .utf8) == "{\"😀\":\"😀\\n\\u0000/\",\"\":\"é\"}")
        #expect(try SyncCanonicalJSON.canonicalize(canonical) == canonical)
        #expect(try SyncCanonicalJSON.encode(.string("é")) != SyncCanonicalJSON.encode(.string("é")))
    }

    @Test func portableEqualityPreservesUnicodeScalarChangesWithoutNormalization() throws {
        let composed = SyncJSONValue.string("é")
        let decomposed = SyncJSONValue.string("e\u{301}")
        #expect(composed != decomposed)
        #expect(SyncJSONValue.array([composed]) != .array([decomposed]))
        let first = try SyncTestFixtures.folder(name: "é")
        let second = try SyncTestFixtures.folder(name: "e\u{301}")
        #expect(first != second)
        #expect(try first.sha256 != second.sha256)
        #expect(try SyncDocument(entityType: .folder, data: first.canonicalData()) == first)
    }

    @Test func closedPayloadRejectsNestedAudioAndUnsafeNumbers() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        var fields: [String: SyncJSONValue] = ["schema_version": .integer(1), "id": .string(id), "name": .string("Synthetic"), "details": .string(""), "created_at_ms": .integer(0)]
        _ = try SyncDocument(entityType: .folder, value: .object(fields))
        fields["audio_path"] = .string("PRIVATE_SENTINEL")
        #expect(throws: (any Error).self) { try SyncDocument(entityType: .folder, value: .object(fields)) }
        fields.removeValue(forKey: "audio_path")
        fields["created_at_ms"] = .integer(-1)
        #expect(throws: (any Error).self) { try SyncDocument(entityType: .folder, value: .object(fields)) }
        fields["created_at_ms"] = .integer(0)
        fields["id"] = .string(id.uppercased().replacingOccurrences(of: "0001", with: "ABC1"))
        #expect(throws: (any Error).self) { try SyncDocument(entityType: .folder, value: .object(fields)) }
    }

    @Test func streamedValidationRejectsMalformedAndNoncanonicalPayloads() throws {
        let document = try SyncTestFixtures.folder(name: "é🙂\n\t\u{0000}\u{001f}/\\\"")
        let bytes = try document.canonicalData()
        try SyncStreamedPayload.validate(bytes, type: .folder, id: document.entityID)
        let text = try #require(String(data: bytes, encoding: .utf8))
        let invalid = [
            " " + text, text + " ",
            text.replacingOccurrences(of: "é", with: "\\u00e9"),
            text.replacingOccurrences(of: "\\n", with: "\\u000a"),
            text.replacingOccurrences(of: "\\u001f", with: "\\u001F"),
            text.replacingOccurrences(of: "\"created_at_ms\":0", with: "\"created_at_ms\":-0"),
            text.replacingOccurrences(of: "\"created_at_ms\":0", with: "\"created_at_ms\":01"),
            text.replacingOccurrences(of: "\"details\":\"\"", with: "\"details\":\"\",\"details\":\"\""),
            text.replacingOccurrences(of: "schema_version", with: "unknown_field")
        ]
        for input in invalid {
            #expect(throws: (any Error).self) { try SyncStreamedPayload.validate(Data(input.utf8), type: .folder, id: document.entityID) }
        }
        for malformed: [UInt8] in [[0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x82], [0xff]] {
            let range = try #require(bytes.range(of: Data("é".utf8)))
            var corrupted = bytes
            corrupted.replaceSubrange(range, with: malformed)
            #expect(throws: (any Error).self) { try SyncStreamedPayload.validate(corrupted, type: .folder, id: document.entityID) }
        }
    }

    @Test func mutationHashAndPayloadIdentityAreChecked() throws {
        let document = try SyncTestFixtures.folder()
        let envelope = try SyncTestFixtures.mutation(document)
        #expect(try SyncMutationEnvelope.decode(envelope.canonicalData()) == envelope)
        var fields = try #require(try SyncCanonicalJSON.decode(envelope.canonicalData()).object)
        fields["payload_sha256"] = .string(String(repeating: "0", count: 64))
        #expect(throws: SyncWireError.invalidHash) { try SyncMutationEnvelope.decode(SyncCanonicalJSON.encode(.object(fields))) }
        #expect(throws: (any Error).self) {
            try SyncMutationEnvelope(collectionGeneration: SyncTestFixtures.generation, entityType: .folder,
                                     entityID: UUID().uuidString.lowercased(), baseRevision: 0, mutation: .upsert, document: document)
        }
    }
    @Test func documentsBeyondHTTPBudgetUseSmallDeterministicManifestEnvelopes() throws {
        let large = try SyncTestFixtures.folder(name: String(repeating: "x", count: SyncCanonicalJSON.maximumBytes + 1))
        #expect(try large.quotaBytes > SyncCanonicalJSON.maximumBytes)
        let mutation = try SyncTestFixtures.mutation(large)
        #expect(try mutation.canonicalData().count > SyncCanonicalJSON.maximumBytes)
        #expect(try SyncMutationEnvelope.decode(mutation.canonicalData()) == mutation)
        let transport = try mutation.transportData()
        #expect(transport.count < SyncCanonicalJSON.maximumBytes)
        #expect(try transport == mutation.transportData())
        let fields = try #require(try SyncCanonicalJSON.decode(transport).object)
        #expect(fields["payload"] == .null)
        #expect(fields["payload_manifest"]?.object?["total_bytes"]?.integer == Int64(try large.quotaBytes))
    }
}

nonisolated enum SyncTestFixtures {
    static let generation = "00000000-0000-0000-0000-000000000002"
    static func folder(id: String = "00000000-0000-0000-0000-000000000001", name: String = "Synthetic") throws -> SyncDocument {
        try SyncDocument(entityType: .folder, value: .object([
            "schema_version": .integer(1), "id": .string(id), "name": .string(name), "details": .string(""), "created_at_ms": .integer(0)
        ]))
    }
    static func mutation(_ document: SyncDocument, baseRevision: Int64 = 0) throws -> SyncMutationEnvelope {
        try SyncMutationEnvelope(collectionGeneration: generation, entityType: document.entityType,
                                 entityID: document.entityID, baseRevision: baseRevision, mutation: .upsert, document: document)
    }
}
