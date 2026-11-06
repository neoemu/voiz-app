import Testing
import Foundation

/// A guarda da regra 7 do PLANO **no caminho real da reunião**: nada do que foi falado chega ao log.
///
/// Terceira da série (ditado na T2.4a, tradução na T2.4b), e a que o Maestro agendou nominalmente
/// para esta tarefa: `MeetingViewModel` imprimia `"\(speakerName): \(text.prefix(80))"` a cada turno
/// do transcript oficial. Era a boca mais larga das três — um pós-call de reunião longa produz
/// dezenas de linhas, e cada uma levava 80 caracteres de fala real para `debugLogs` (visível na UI)
/// **e** para o stdout.
///
/// A varredura do arquivo inteiro, que a lição das duas tarefas anteriores exigia, achou mais três:
///
/// - as linhas do `trimLog` do `MeetingEchoReconciler`, que trazem `prefix(60)` do texto recortado;
/// - o mapa `rótulo → nome` do passo de nomes, que sai da conversa (é o que aquela camada faz: ler o
///   transcript e achar como as pessoas se chamam) e ainda identifica gente;
/// - as falhas de resumo/nomes/capítulos, onde `AICompletionService` embrulha o **corpo da resposta
///   HTTP** na mensagem — e num 400 de filtro de conteúdo esse corpo devolve o prompt, que numa
///   reunião é o transcript inteiro. É exatamente a armadilha que a re-review r2 da T2.4b encontrou
///   uma camada abaixo do view model da tradução.
@Suite("Log sem transcript — o caminho da reunião")
struct MeetingLogRedactionTests {

    /// Palavras distintas o bastante para não aparecerem por acaso, e curtas o bastante para caber
    /// nos prefixos que o código vazava (80 no turno, 60 no recorte de eco).
    private let sentinelWords = ["ABRACADABRA", "XYZZY", "PLUGH", "SEGREDO"]

    private var sentinel: String {
        sentinelWords.joined(separator: " ") + " tudo que foi dito na reunião e jamais pode ser logado"
    }

    private var provenance: TranscriptionProvenance {
        TranscriptionProvenance(
            engine: .whisperKit,
            model: .whisperMedium,
            useCase: .meetingFinal,
            origin: .userSelection,
            candidateRank: 0
        )
    }

    /// Os construtores desta tarefa que recebem texto do usuário.
    private var redactors: [(name: String, build: (String) -> String)] {
        [
            ("meetingTurn", { TranscriptionLogRedaction.meetingTurn($0, source: "Microfone", provenance: self.provenance) }),
            // O detalhe do provedor pode ser o prompt de volta — e o prompt do resumo é o transcript.
            ("meetingAssistantFailed", { TranscriptionLogRedaction.meetingAssistantFailed(kind: "Resumo", detail: $0) })
        ]
    }

    // MARK: - Sentinela nos construtores

    @Test("Nenhum construtor da reunião deixa passar uma palavra sequer do que foi dito")
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

    @Test("Prefixos também não passam — 80 e 60 são exatamente como estas bocas vazavam")
    func noBuilderLeaksAPrefix() {
        for redactor in redactors {
            let message = redactor.build(sentinel)
            for size in [20, 50, 60, 80] {
                #expect(
                    message.contains(String(sentinel.prefix(size))) == false,
                    "\(redactor.name) vazou prefix(\(size))"
                )
            }
        }
    }

    @Test("O nome do falante saiu da linha do turno — a fonte é que ficou")
    func theTurnLineNamesTheSourceAndNotTheSpeaker() {
        // A Camada 2 do pós-call escreve nomes **extraídos da conversa** em `speakerName`, então o
        // nome é conteúdo derivado do transcript tanto quanto o texto — e conteúdo que identifica
        // gente. A fonte responde o que a linha precisava responder: de qual canal veio o turno.
        let message = TranscriptionLogRedaction.meetingTurn(
            "qualquer coisa",
            source: "Áudio do sistema",
            provenance: provenance
        )
        #expect(message.contains("Áudio do sistema"))
        #expect(message.contains("whisperkit"))
        #expect(message.contains("openai_whisper-medium"))
        #expect(message.contains("rank 0"))
    }

    @Test("O que sobra é operacional: tamanho, fonte, motor, modelo e contagens")
    func theOperationalMetadataSurvives() {
        let text = String(repeating: "a", count: 42)
        #expect(TranscriptionLogRedaction.meetingTurn(text, source: "Microfone", provenance: provenance).contains("42"))
        #expect(TranscriptionLogRedaction.meetingEchoTrims(7).contains("7"))
        #expect(TranscriptionLogRedaction.meetingLiveEchoSuppressed(4).contains("4"))
        #expect(TranscriptionLogRedaction.meetingNamesApplied(3).contains("3"))

        let failed = TranscriptionLogRedaction.meetingAssistantFailed(kind: "Capítulos", detail: text)
        #expect(failed.contains("Capítulos"))
        #expect(failed.contains("42"))
        #expect(TranscriptionLogRedaction.meetingAssistantFailed(kind: "Resumo", detail: "").isEmpty == false)
    }

    @Test("Texto vazio ou só de espaços não vira caso especial que vaze")
    func emptyAndBlankTextsAreSafe() {
        for redactor in redactors {
            #expect(redactor.build("").isEmpty == false, "\(redactor.name) devolveu vazio")
            #expect(redactor.build("   ").contains("   ") == false, "\(redactor.name) ecoou o texto")
        }
    }

    // MARK: - O caminho real: leitura do fonte do view model

    /// O `MeetingViewModel` não compila no alvo `voizTests` (é `@MainActor`, fala com AppKit,
    /// EventKit e com os serviços de captura), então a ligação entre construtor testado e `print`
    /// real se prova lendo o arquivo — como na suíte do ditado.
    ///
    /// Duas listas travadas, e as duas precisam existir:
    ///
    /// - **as interpolações**: `\(...)` dentro de chamada de log. Pega `addDebugLog("... \(text)")`.
    /// - **os argumentos sem literal**: chamadas de log cujo argumento é uma expressão pura. Pega
    ///   `addDebugLog(text)`, que não tem interpolação nenhuma e passaria batido pela primeira lista.
    ///
    /// Qualquer log novo reprova até alguém revisar e incluir — que é o ponto.
    @Test("O MeetingViewModel só interpola em log o que já foi revisado")
    func theMeetingViewModelInterpolatesOnlyReviewedExpressions() throws {
        let source = try #require(
            Self.sourceOfFile("voiz/ViewModels/MeetingViewModel.swift"),
            "não consegui ler o view model: a guarda não pode ser dada como cumprida"
        )

        let expected = [
            // Permissão de calendário: concedida ou não.
            #"granted ? "concedido" : "negado/indisponível""#,
            // Nome do app de reunião detectado (Teams/Meet/Zoom).
            "app.appName",
            // Por que a prévia ao vivo se desligou — motivo do serviço, sem texto.
            "reason",
            // Título da reunião no início: vem do calendário, do app da chamada ou do template. É
            // metadado que o usuário vê na lista, e nesse ponto nenhum resumo rodou ainda.
            "session.title",
            // O plano congelado: no início da reunião, no reprocessamento, nos dois ramos de
            // "sessão sem plano / plano ilegível" e no começo do pós-call. Só ids de motor e modelo
            // (ver `TranscriptionPlanSnapshot.logSummary`).
            "planSnapshot.logSummary",
            "snapshot.logSummary",
            "snapshot.logSummary",
            "snapshot.logSummary",
            "snapshot.logSummary",
            // Reprocessar manual (LANG r5): o plano reconstruído com os Ajustes atuais.
            "snapshot.logSummary",
            // Falha ao iniciar a gravação — erro de sistema/framework.
            // (start do transcritor ao vivo agora decide o modo sem logar o Error.)
            "error.localizedDescription",
            // Falha de canal no transcritor ao vivo: enum e canal sem texto livre.
            "channel.rawValue",
            "failure",
            // Falhas de leitura dos .caf (abrir, ler, continuar lendo): erro de arquivo.
            "source.displayName",
            "error.localizedDescription",
            "source.displayName",
            "error.localizedDescription",
            "source.displayName",
            "error.localizedDescription",
            // Falha de um lote: `TranscriptionCoordinatorError` é `LocalizedError` (T2.4b) e
            // descreve motor, modelo, estágio e falha — vocabulário técnico, sem transcript.
            "chunk.source.displayName",
            "error.localizedDescription",
            // Lote cancelado: só a fonte, e o laço para aí.
            "chunk.source.displayName",
            // Tentativa alternativa: o mesmo vocabulário, sem texto reconhecido.
            "chunk.source.displayName",
            "error.localizedDescription",
            "chunk.source.displayName",
            // Contagens do pós-call, nos dois desfechos (concluído e interrompido). O flush do
            // acumulador (AUDIT r2) relê a sessão fresca — a contagem continua sendo só número.
            "fresh.turns.count",
            "fresh.turns.count",
            "chapters.count",
            "count",
            // Nota do reconciliador de eco: correlação e segundos, sem texto (as linhas do
            // `trimLog`, que trazem `prefix(60)` do recorte, saíram do log e viraram contagem).
            "result.note",
            // Cortes de lote do O2: quantas trocas de falante a diarização
            // produziu. Número, e nada além dele — a lista de instantes não
            // entra no log.
            "speakerBoundaries.count",
            // Falha da diarização: FluidAudio local, sem provedor que ecoe prompt de volta.
            "error.localizedDescription",
            // Nome do template do resumo — constante do app.
            "template.name"
        ].sorted()

        let logLines = Self.logStatements(in: source)
        let found = Self.interpolations(in: logLines).sorted()

        #expect(
            found == expected,
            """
            a lista de interpolações em log da reunião mudou — revise antes de liberar.
            novas: \(Set(found).subtracting(expected).sorted())
            sumiram: \(Set(expected).subtracting(found).sorted())
            """
        )
    }

    @Test("Log com argumento sem literal também é lista travada — é por onde passaria um addDebugLog(text)")
    func theMeetingViewModelLogsOnlyReviewedBareArguments() throws {
        let source = try #require(Self.sourceOfFile("voiz/ViewModels/MeetingViewModel.swift"))

        let expected = [
            // Aviso de áudio do sistema ausente: string do serviço de captura, já localizada.
            "addDebugLog(warning)",
            // O turno do transcript: o texto entra pelo construtor coberto pela sentinela.
            "addDebugLog( TranscriptionLogRedaction.meetingTurn( text, source: chunk.source.displayName, provenance: provenance ) )",
            "addDebugLog( TranscriptionLanguageProbe.logSummary( decision, planned: plannedBeforeProbe, speechSeconds: accumulator.speechSeconds ) )",
            "addDebugLog(TranscriptionLanguageEvidenceGuard.logSummary(verdict, planned: pass.language))",
            "addDebugLog( TranscriptionLanguageGuard.retargetLogSummary(from: previous, to: pass.snapshot) )",
            // Rebaixamento do plano: só ids (ver `MeetingTranscription.downgradeLogSummary`).
            "addDebugLog( MeetingTranscription.downgradeLogSummary(from: currentBatchCandidate, to: next) )",
            // Recorte de eco e nomes: contagens.
            "addDebugLog(TranscriptionLogRedaction.meetingEchoTrims(result.droppedCount + result.trimmedCount))",
            "addDebugLog(TranscriptionLogRedaction.meetingLiveEchoSuppressed(liveSuppressedMicFinals))",
            "addDebugLog(TranscriptionLogRedaction.meetingNamesApplied(names.count))",
            // O corpo do próprio `addDebugLog`, que ecoa em stdout o que já foi montado acima.
            "print(message)"
        ].sorted()

        let found = Self.bareArgumentLogStatements(in: source).sorted()
        #expect(
            found == expected,
            """
            a lista de logs com argumento sem literal mudou — revise antes de liberar.
            novos: \(Set(found).subtracting(expected).sorted())
            sumiram: \(Set(expected).subtracting(found).sorted())
            """
        )
    }

    @Test("Nenhum prefix( dentro de chamada de log — era literalmente a forma do vazamento")
    func noLogStatementSlicesText() throws {
        let source = try #require(Self.sourceOfFile("voiz/ViewModels/MeetingViewModel.swift"))
        let offenders = Self.logStatements(in: source).filter { $0.contains(".prefix(") }
        #expect(offenders.isEmpty, "voltou um prefix( em log do MeetingViewModel: \(offenders)")

        // A checagem é sobre **log**, e não sobre o arquivo: a costura da prévia ao vivo usa
        // `prefix`/`suffix` em arrays de palavras legitimamente, e proibir o arquivo inteiro
        // (como a suíte do ditado pode) reprovaria código que não tem nada a ver com log.
        #expect(source.contains(".prefix(") , "a costura da prévia sumiu — reveja esta guarda")
    }

    @Test("As três bocas novas passam pelos construtores cobertos pela sentinela")
    func theNewCallSitesGoThroughTheCoveredBuilders() throws {
        let source = try #require(Self.sourceOfFile("voiz/ViewModels/MeetingViewModel.swift"))
        let logLines = Self.logStatements(in: source)

        #expect(
            logLines.contains { $0.contains("TranscriptionLogRedaction.meetingTurn(") && $0.contains("text,") },
            "o turno do transcript não passa mais pelo construtor coberto pela sentinela"
        )
        #expect(
            logLines.contains { $0.contains("meetingEchoTrims(result.droppedCount + result.trimmedCount)") },
            "as linhas de recorte de eco voltaram a ir para o log uma a uma"
        )
        #expect(
            logLines.contains { $0.contains("meetingNamesApplied(names.count)") },
            "o mapa de nomes voltou para o log"
        )
        // As três falhas de provedor (resumo, nomes, capítulos) — todas pelo mesmo construtor.
        let assistantFailures = logLines.filter { $0.contains("meetingAssistantFailed(") }
        #expect(assistantFailures.count == 3, "faltou redigir uma falha de provedor: \(assistantFailures.count)")
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
    /// linhas (o `MeetingViewModel` tem várias assim depois desta tarefa).
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

    /// As chamadas de log **sem nenhum literal de string** — as que a lista de interpolações não vê.
    private static func bareArgumentLogStatements(in source: String) -> [String] {
        logStatements(in: source)
            .filter { !$0.contains("\"") }
            .map { statement in
                statement
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
    }

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
