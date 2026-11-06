import Foundation
import Testing


/// Guardas da busca dos pesos pt-BR do Parakeet.
///
/// Nenhuma delas toca a rede: o que prende bug aqui é a **forma** — o caminho que o
/// `AsrModels.load(from:)` exige, a ordem em que os arquivos entram no disco e o que fica de fora.
@Suite("Pesos pt-BR do Parakeet")
struct ParakeetPTBRWeightsTests {

    @Test("O caminho termina no nome do repositório que o FluidAudio reanexa")
    func directoryEndsInRepoFolder() {
        let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)

        let directory = ParakeetPTBRWeights.directory(inside: support)

        // `AsrModels.load(from:)` remove o último componente e o reanexa a partir do `version.repo`.
        // Terminar em outra coisa faz ele procurar no lugar errado e usar os pesos do modelo base
        // sem avisar — foi assim que três medições diferentes deram o mesmo número.
        #expect(directory.lastPathComponent == "parakeet-tdt-0.6b-v3")
    }

    @Test("O sentinela é o último a entrar, para pasta incompleta não parecer pronta")
    func sentinelIsWrittenLast() {
        let listed = [
            "Encoder.mlmodelc/weights/weight.bin",
            "Decoder.mlmodelc/model.mil",
            "parakeet_vocab.json",
            "JointDecisionv3.mlmodelc/model.mil",
        ]

        let ordered = ParakeetPTBRWeights.modelFiles(from: listed)

        let sentinelIndexes = ordered.enumerated()
            .filter { $0.element.hasPrefix(ParakeetPTBRWeights.sentinelName) }
            .map(\.offset)
        #expect(sentinelIndexes.isEmpty == false, "sem sentinela a ordem não guarda nada")
        for index in sentinelIndexes {
            #expect(index >= ordered.count - sentinelIndexes.count)
        }
    }

    @Test("Model card e checksums não entram no download")
    func documentationIsNotDownloaded() {
        let listed = [
            "README.md",
            "SHA256SUMS.txt",
            ".gitattributes",
            "conversion-metadata.json",
            "parakeet_vocab.json",
            "Encoder.mlmodelc/coremldata.bin",
        ]

        let files = ParakeetPTBRWeights.modelFiles(from: listed)

        #expect(files.contains("README.md") == false)
        #expect(files.contains("SHA256SUMS.txt") == false)
        #expect(files.contains(".gitattributes") == false)
        // Metadata da conversão é para quem lê a página, não para o runtime.
        #expect(files.contains("conversion-metadata.json") == false)
        #expect(files.contains("parakeet_vocab.json"))
        #expect(files.contains("Encoder.mlmodelc/coremldata.bin"))
    }

    @Test("A URL de download aponta para o arquivo publicado, preservando subpastas")
    func downloadURLKeepsNestedPath() throws {
        let url = try #require(ParakeetPTBRWeights.fileURL(path: "Encoder.mlmodelc/weights/weight.bin"))

        #expect(
            url.absoluteString
                == "https://huggingface.co/\(ParakeetPTBRWeights.repoID)/resolve/main/Encoder.mlmodelc/weights/weight.bin"
        )
    }

    @Test("Pasta sem o sentinela não conta como instalada")
    func missingSentinelMeansNotInstalled() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = ParakeetPTBRWeights.directory(inside: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Um arquivo qualquer no lugar não basta: só o sentinela decide.
        try Data().write(to: directory.appendingPathComponent("parakeet_vocab.json"))
        #expect(ParakeetPTBRWeights.isInstalled(at: directory) == false)

        try Data().write(to: directory.appendingPathComponent(ParakeetPTBRWeights.sentinelName))
        #expect(ParakeetPTBRWeights.isInstalled(at: directory))
    }
}

/// O que o Parakeet declara saber falar.
///
/// Suíte separada porque não é sobre a busca dos pesos, e sim sobre a consequência de tê-los
/// trocado: o catálogo continuou anunciando inglês depois que o modelo deixou de saber inglês.
@Suite("Idiomas declarados pelo Parakeet")
struct ParakeetLanguageClaimsTests {

    @Test("O Parakeet não se anuncia em inglês nem como detector de idioma")
    func parakeetIsPortugueseOnly() {
        let parakeet = TranscriptionEngineDescriptor.parakeet

        // Os pesos que o app carrega são um fine-tune pt-BR que esqueceu as outras línguas: em
        // 27/08/2026, áudio em inglês voltou transcrito como português fonético. Enquanto for esse
        // o modelo, anunciar inglês aqui manda quem fala inglês para o motor errado — e anunciar
        // detecção de idioma o coloca como escolha do modo automático, que é o default do app.
        #expect(parakeet.supportedLanguages == [.portuguese])
        #expect(parakeet.detectsLanguageAutomatically == false)
    }

}
