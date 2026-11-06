import Testing
import Foundation

/// A guarda da regra 7 do PLANO **no caminho real do ditado**: nenhum texto reconhecido chega ao log.
///
/// A suíte da T2.4b (`TranscriptionLogRedactionTests`) cobre o caminho da tradução. Esta cobre o do
/// ditado, e existe porque a review do Farol de 2026-08-10 mostrou que o `logSummary` seguro que a
/// T2.4a introduziu **não eliminava** as duas bocas que realmente vazavam:
///
/// - `TranscriptionViewModel.insertTextAtCursor` mandava os primeiros 50 caracteres do que o usuário
///   acabou de ditar para `addDebugLog` — que guarda em `debugLogs` (visível na UI) e repete em
///   stdout. Rodava em **todo** ditado com auto-inserção ligada, que é o default.
/// - `ParakeetTranscriptionService.transcribe` imprimia os primeiros 60 caracteres do texto
///   reconhecido. É o caminho real: o holder (`AppTranscriptionCoordinator`) constrói **este**
///   serviço, `ParakeetTranscriptionServiceCalls` o encaminha e `ParakeetServiceRuntime` o executa
///   sempre que o plano do ditado escolhe Parakeet.
///
/// A lição que a re-review r2 da T2.4b deixou e que esta suíte aplica desde o começo: testar só os
/// construtores prova o que **eles** fazem, e os dois defeitos acima estavam em `print`s que não
/// passavam por construtor nenhum. Por isso há duas camadas aqui — sentinela nos construtores e
/// leitura mecânica dos dois arquivos de produção.
@Suite("Log sem transcript — o caminho do ditado")
struct DictationLogRedactionTests {

    /// Palavras distintas o bastante para não aparecerem por acaso, e curtas o bastante para caber
    /// nos prefixos que o código vazava (50 no view model, 60 no serviço do Parakeet).
    private let sentinelWords = ["ABRACADABRA", "XYZZY", "PLUGH", "SEGREDO"]

    private var sentinel: String {
        sentinelWords.joined(separator: " ") + " frase inteira que o usuário ditou e jamais pode ser logada"
    }

    /// Os construtores que carregam texto do ditado, um por boca fechada.
    private var redactors: [(name: String, build: (String) -> String)] {
        [
            // A boca do view model: o texto que acabou de ir para a área de transferência.
            ("copiedToPasteboard", { TranscriptionLogRedaction.copiedToPasteboard($0) }),
            // A boca do serviço do Parakeet: o texto que o motor acabou de reconhecer.
            ("engineFinishedBatch", {
                TranscriptionLogRedaction.engineFinishedBatch(
                    $0,
                    engine: "Parakeet v3",
                    processingTime: 0.42,
                    realTimeFactor: 118
                )
            })
        ]
    }

    /// As mensagens do serviço do motor que não tocam em texto do usuário. Entram na suíte assim
    /// mesmo: a guarda mecânica exige que **todo** `print` do arquivo seja uma chamada de redação, e
    /// um construtor sem teste é o buraco por onde o próximo `print` se pendura.
    private var operationalBuilders: [(name: String, build: () -> String)] {
        [
            ("engineCreated", { TranscriptionLogRedaction.engineCreated("Parakeet v3") }),
            ("engineLoadStarted", { TranscriptionLogRedaction.engineLoadStarted("Parakeet v3") }),
            ("engineLoadFinished", { TranscriptionLogRedaction.engineLoadFinished("Parakeet v3") })
        ]
    }

    // MARK: - Sentinela nos construtores

    @Test("Nenhum construtor do ditado deixa passar uma palavra sequer do texto")
    func noBuilderLeaksTheSentinel() {
        for redactor in redactors {
            let message = redactor.build(sentinel)
            #expect(message.contains(sentinel) == false, "\(redactor.name) vazou a frase inteira")
            for word in sentinelWords {
                #expect(
                    message.localizedCaseInsensitiveContains(word) == false,
                    "\(redactor.name) vazou o trecho '\(word)'"
                )
            }
        }
    }

    @Test("Prefixos também não passam — 50 e 60 são exatamente como estas duas bocas vazavam")
    func noBuilderLeaksAPrefix() {
        for redactor in redactors {
            let message = redactor.build(sentinel)
            for size in [20, 50, 60] {
                #expect(
                    message.contains(String(sentinel.prefix(size))) == false,
                    "\(redactor.name) vazou prefix(\(size))"
                )
            }
        }
    }

    @Test("Texto vazio ou só de espaços não vira caso especial que vaze")
    func emptyAndBlankTextsAreSafe() {
        for redactor in redactors {
            #expect(redactor.build("").isEmpty == false, "\(redactor.name) devolveu vazio")
            #expect(redactor.build("   ").contains("   ") == false, "\(redactor.name) ecoou o texto")
        }

        for builder in operationalBuilders {
            let message = builder.build()
            #expect(message.isEmpty == false, "\(builder.name) devolveu vazio")
            for word in sentinelWords {
                #expect(message.localizedCaseInsensitiveContains(word) == false, "\(builder.name) vazou '\(word)'")
            }
        }
    }

    @Test("O que sobra é operacional: tamanho do texto, motor, tempo e RTFx")
    func theOperationalMetadataSurvives() {
        // A regra é "sem transcript", não "sem log": tirar a informação junto com o texto deixaria o
        // console inútil e a próxima review pediria de volta — e alguém devolveria o texto junto.
        let text = String(repeating: "a", count: 37)

        #expect(TranscriptionLogRedaction.copiedToPasteboard(text).contains("37"))

        let batch = TranscriptionLogRedaction.engineFinishedBatch(
            text,
            engine: "Parakeet v3",
            processingTime: 1.5,
            realTimeFactor: 118
        )
        #expect(batch.contains("37"))
        #expect(batch.contains("Parakeet v3"))
        #expect(batch.contains("1.50"))
        #expect(batch.contains("118"))
    }

    @Test("A falha de carga aceita Error, e não String — o transcript não cabe nela por tipo")
    func theLoadFailureKeepsTheLoaderDescription() {
        // A descrição sobrevive inteira, ao contrário do `detail` de `translationFailed`: ela vem do
        // carregador local (disco, checkpoint, CoreML) e não de um servidor que pode ecoar de volta o
        // prompt que recebeu. A garantia aqui é de tipo — para vazar texto do usuário alguém teria
        // que embrulhar o transcript num `Error`, o que não acontece por descuido.
        struct LoaderFailure: LocalizedError {
            var errorDescription: String? { "sem espaço em disco para o checkpoint" }
        }

        let message = TranscriptionLogRedaction.engineLoadFailed("Parakeet v3", error: LoaderFailure())
        #expect(message.contains("Parakeet v3"))
        #expect(message.contains("sem espaço em disco para o checkpoint"))
        for word in sentinelWords {
            #expect(message.localizedCaseInsensitiveContains(word) == false)
        }
    }

    // MARK: - O caminho real: leitura dos arquivos de produção

    /// Todo `print` do serviço do Parakeet é uma chamada de redação inteira, sem interpolação solta.
    ///
    /// Os construtores acima só provam o que **eles** fazem, e o defeito estava num `print` que não
    /// passava por construtor nenhum. `ParakeetTranscriptionService.swift` não compila no alvo
    /// `voizTests` (importa `FluidAudio`), então a ligação entre o construtor testado e o `print`
    /// real se prova lendo o arquivo.
    @Test("Todo print do ParakeetTranscriptionService é uma chamada de redação")
    func everyPrintInTheParakeetServiceIsRedacted() throws {
        let source = try #require(
            Self.sourceOfFile("voiz/Services/ParakeetTranscriptionService.swift"),
            "não consegui ler o serviço: a guarda não pode ser dada como cumprida"
        )

        let logLines = Self.logStatements(in: source)
        #expect(logLines.isEmpty == false, "nenhum print no serviço — a guarda ficou sem objeto")

        for line in logLines {
            #expect(
                line.hasPrefix("print(TranscriptionLogRedaction."),
                "print sem redação no ParakeetTranscriptionService: \(line)"
            )
        }

        #expect(
            Self.interpolations(in: logLines).isEmpty,
            "interpolação solta em print do serviço: \(Self.interpolations(in: logLines))"
        )

        // `prefix(60)` era literalmente a forma do vazamento, e não há uso legítimo dele aqui.
        #expect(source.contains(".prefix(") == false, "voltou um prefix( ao ParakeetTranscriptionService")

        // E o `print` do lote é o construtor que a sentinela cobre, com o texto reconhecido dentro —
        // sem isto a guarda aceitaria uma chamada de redação com o argumento errado (o `fullText` é
        // o que ia para o `prefix(60)`).
        #expect(
            logLines.contains { $0.contains("engineFinishedBatch(") && $0.contains("fullText") },
            "o print do lote não passa o texto reconhecido pelo construtor coberto pela sentinela"
        )
    }

    /// O mesmo para o view model do ditado, com uma diferença: lá há `print`s legítimos que
    /// interpolam idioma, contadores de amostras e tempos de espera, então a guarda não pode exigir
    /// construtor em tudo. Ela trava a **lista** exata de expressões interpoladas em log — qualquer
    /// `print`/`addDebugLog` novo que interpole algo reprova até alguém revisar e incluir.
    @Test("O TranscriptionViewModel só interpola em log o que já foi revisado")
    func theDictationViewModelInterpolatesOnlyReviewedExpressions() throws {
        let source = try #require(
            Self.sourceOfFile("voiz/ViewModels/TranscriptionViewModel.swift"),
            "não consegui ler o view model: a guarda não pode ser dada como cumprida"
        )

        let expected = [
            // Início da gravação: o idioma escolhido nas Configurações.
            "settings.selectedLanguage.displayName",
            // Falha ao abrir o microfone — erro do AVAudioEngine, não texto.
            "errorMsg",
            // O desfecho da transcrição: proveniência (só ids) e contagem de caracteres.
            "DictationTranscription.logSummary(for: outcome.provenance)",
            "text.count",
            // O aviso de fallback: a mesma proveniência sem texto.
            "DictationTranscription.logSummary(for: provenance)",
            // Auto-colagem: se o app anterior voltou à frente (Bool) e a espera antes de colar.
            "targetAppWasRestored",
            #"String(format: "%.1f", delay)"#
        ].sorted()

        let logLines = Self.logStatements(in: source)
        let found = Self.interpolations(in: logLines).sorted()

        #expect(
            found == expected,
            """
            a lista de interpolações em log do ditado mudou — revise antes de liberar.
            novas: \(Set(found).subtracting(expected).sorted())
            sumiram: \(Set(expected).subtracting(found).sorted())
            """
        )
        #expect(source.contains(".prefix(") == false, "voltou um prefix( ao TranscriptionViewModel")

        // O texto copiado passa pelo construtor que a sentinela cobre. A lista de interpolações
        // sozinha não pegaria um `addDebugLog(text)` cru — sem interpolação, ele não aparece nela.
        #expect(
            logLines.contains { $0.contains("TranscriptionLogRedaction.copiedToPasteboard(text)") },
            "a cópia para a área de transferência não passa mais pelo construtor coberto pela sentinela"
        )
    }

    // MARK: - Leitura do fonte (a guarda mecânica)

    /// O arquivo de produção, lido do próprio checkout. `#filePath` é o único ponto fixo que um
    /// bundle de teste sem host app tem para achar a árvore de fontes.
    private static func sourceOfFile(_ relativePath: String) -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Transcription/
            .deletingLastPathComponent()   // voizTests/
            .deletingLastPathComponent()   // raiz do repositório
        return try? String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    /// As chamadas de log do arquivo, uma por elemento e **inteiras**, mesmo quebradas em várias
    /// linhas.
    ///
    /// A versão por linha da suíte da T2.4b perderia a chamada de várias linhas de
    /// `processAudio` — as interpolações dela moram nas linhas de continuação, que não contêm
    /// `addDebugLog(`. Aqui a chamada é acumulada até os parênteses fecharem. Se um literal tiver
    /// parêntese desbalanceado, o recorte vai longe demais e a lista de interpolações reprova: o
    /// desfecho certo para uma guarda, que é falhar em vez de passar sem olhar.
    private static func logStatements(in source: String) -> [String] {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var statements: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }

            guard !line.hasPrefix("//") else { continue }
            guard line.contains("print(") || line.contains("addDebugLog(") else { continue }
            // A declaração de `addDebugLog` não é uma chamada.
            guard !line.contains("func addDebugLog(") else { continue }

            var statement = line
            while Self.openParentheses(in: statement) > 0, index + 1 < lines.count {
                index += 1
                statement += "\n" + lines[index]
            }
            statements.append(statement)
        }
        return statements
    }

    /// Quantos parênteses continuam abertos a partir da chamada de log da linha.
    private static func openParentheses(in statement: String) -> Int {
        guard let start = statement.range(of: "print(") ?? statement.range(of: "addDebugLog(") else {
            return 0
        }
        return statement[start.lowerBound...].reduce(0) { depth, character in
            switch character {
            case "(": return depth + 1
            case ")": return depth - 1
            default: return depth
            }
        }
    }

    /// Cada `\(expressão)` que aparece nas chamadas dadas, já sem espaços nas pontas.
    private static func interpolations(in statements: [String]) -> [String] {
        // Um nível de parênteses aninhados basta para o que existe nestes dois arquivos; um nível a
        // mais sai recortado diferente e reprova a lista, que é o desfecho certo.
        let regex = try! NSRegularExpression(pattern: #"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#)
        return statements.flatMap { statement -> [String] in
            let range = NSRange(statement.startIndex..., in: statement)
            return regex.matches(in: statement, range: range).compactMap { match in
                guard let captured = Range(match.range(at: 1), in: statement) else { return nil }
                return String(statement[captured]).trimmingCharacters(in: .whitespaces)
            }
        }
    }
}
