import Testing
import Foundation

/// O campo novo de proveniência no histórico do ditado (T2.4a).
///
/// A disciplina é a da T1.4: campo novo **nunca** derruba o que já está no disco. Aqui o risco é
/// concreto — o `TranscriptionHistoryStore` decodifica o array inteiro com `try?`, então uma chave
/// obrigatória a mais apagaria silenciosamente **todo** o histórico do usuário na primeira abertura.
@Suite("TranscriptionEntry — proveniência opcional")
struct TranscriptionEntryProvenanceTests {

    /// Uma entrada gravada por qualquer versão anterior à T2.4a: sem `provenance`.
    private static let legacyJSON = """
    [
      {
        "id": "6C7C4C1E-6E1B-4C2B-9A1E-2C1D0B7A5F31",
        "text": "bom dia",
        "language": "pt",
        "timestamp": 771000000,
        "duration": 3.5
      },
      {
        "id": "0B9A1B2C-3D4E-4F50-8A9B-0C1D2E3F4A5B",
        "text": "hello there",
        "language": "en",
        "timestamp": 771000100,
        "duration": 1.25,
        "title": "saudação"
      }
    ]
    """

    @Test("Histórico antigo (sem proveniência) continua decodificando inteiro")
    func legacyHistoryStillDecodes() throws {
        let entries = try JSONDecoder().decode(
            [TranscriptionEntry].self,
            from: Data(Self.legacyJSON.utf8)
        )

        #expect(entries.count == 2)
        #expect(entries[0].text == "bom dia")
        #expect(entries[0].language == .portuguese)
        #expect(entries[0].provenance == nil)
        // O campo novo não pode ter comido nenhum dos antigos.
        #expect(entries[1].title == "saudação")
        #expect(entries[1].duration == 1.25)
        #expect(entries[1].provenance == nil)
    }

    @Test("Entrada nova guarda e devolve a proveniência inteira")
    func provenanceSurvivesRoundTrip() throws {
        let provenance = TranscriptionProvenance(
            engine: .parakeet,
            model: .parakeetTDT06BV3,
            useCase: .dictation,
            origin: .userSelection,
            candidateRank: 2
        )
        let entry = TranscriptionEntry(
            text: "olá",
            language: .portuguese,
            duration: 2,
            provenance: provenance
        )

        let decoded = try JSONDecoder().decode(
            TranscriptionEntry.self,
            from: JSONEncoder().encode(entry)
        )

        #expect(decoded.provenance == provenance)
        #expect(decoded.provenance?.isFallback == true)
        #expect(decoded == entry)
    }

    @Test("Sem proveniência, a chave nem é gravada")
    func absentProvenanceIsNotEncoded() throws {
        let entry = TranscriptionEntry(text: "olá", language: .portuguese)

        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(entry)
        ) as? [String: Any]

        #expect(json?["provenance"] == nil)
        #expect(json?["text"] as? String == "olá")
    }

    @Test("Proveniência é gravada com os ids estáveis, não com o nome do produto")
    func provenanceIsStoredWithStableIdentifiers() throws {
        let entry = TranscriptionEntry(
            text: "olá",
            language: .portuguese,
            provenance: TranscriptionProvenance(
                engine: .whisperKit,
                model: .whisperLargeV3Turbo,
                useCase: .dictation,
                origin: .automatic,
                candidateRank: 0
            )
        )

        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(entry)
        ) as? [String: Any]
        let provenance = json?["provenance"] as? [String: Any]

        #expect(provenance?["engine"] as? String == "whisperkit")
        #expect(provenance?["model"] as? String == "openai_whisper-large-v3_turbo")
        #expect(provenance?["useCase"] as? String == "dictation")
        #expect(provenance?["origin"] as? String == "automatic")
        #expect(provenance?["candidateRank"] as? Int == 0)
    }

    @Test("Entrada com proveniência lida por uma versão que não a conhece não quebra nada")
    func unknownFutureFieldsDoNotBreakDecoding() throws {
        // O simétrico do teste de cima: JSON com proveniência **e** uma chave que este app não
        // conhece (gravada por uma versão futura). O decode sintetizado ignora o que sobra.
        let json = """
        {
          "id": "6C7C4C1E-6E1B-4C2B-9A1E-2C1D0B7A5F31",
          "text": "bom dia",
          "language": "pt",
          "timestamp": 771000000,
          "duration": 3.5,
          "provenance": {
            "engine": "whisperkit",
            "model": "openai_whisper-small",
            "useCase": "dictation",
            "origin": "automatic",
            "candidateRank": 1
          },
          "campoDoFuturo": 42
        }
        """

        let entry = try JSONDecoder().decode(TranscriptionEntry.self, from: Data(json.utf8))

        #expect(entry.provenance?.engine == .whisperKit)
        #expect(entry.provenance?.candidateRank == 1)
        #expect(entry.provenance?.isFallback == true)
    }
}
