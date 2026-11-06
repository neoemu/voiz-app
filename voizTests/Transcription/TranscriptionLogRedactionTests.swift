import Testing
import Foundation

/// A guarda da regra 7 do PLANO: **nenhum texto reconhecido (nem derivado dele) chega ao log**.
///
/// Cada construtor recebe um texto-sentinela e a suíte reprova se qualquer pedaço dele sobreviver
/// na saída. É por isso que os construtores aceitam o texto em vez de já receberem o tamanho: um
/// construtor que só recebesse `Int` tornaria o teste vazio — ele passaria sem provar nada sobre o
/// que o chamador faz com o texto. Aqui o texto entra, e o teste prova que ele não sai.
///
/// Se um construtor novo aceitar texto do usuário, ele entra em `redactors` — senão a guarda não o
/// cobre, e esse é o único jeito de furar esta suíte.
@Suite("Log sem transcript — redação de texto reconhecido")
struct TranscriptionLogRedactionTests {

    /// Palavras distintas o bastante para não aparecerem por acaso, e curtas o bastante para caber
    /// num `prefix(20)` — que é exatamente como o código legado vazava.
    private let sentinelWords = ["ABRACADABRA", "XYZZY", "PLUGH", "SEGREDO"]

    private var sentinel: String {
        sentinelWords.joined(separator: " ") + " frase inteira do usuário que jamais pode ser logada"
    }

    private var provenance: TranscriptionProvenance {
        TranscriptionProvenance(
            engine: .whisperKit,
            model: .whisperSmall,
            useCase: .translationChunk,
            origin: .userSelection,
            candidateRank: 0
        )
    }

    /// Todo construtor que aceita texto do usuário, com um nome para a mensagem de falha.
    ///
    /// Os cinco primeiros são as bocas do `TranslationViewModel`; os de baixo são o **caminho real
    /// do `TranslationService`**, uma por `print` do serviço, na ordem em que `translate` os emite.
    /// A re-review r2 mostrou por que a distinção importa: redigir só a camada de cima deixou o
    /// vazamento vivo uma camada abaixo, e esta suíte não via porque não atravessava as mensagens
    /// que o serviço de fato imprime.
    private var redactors: [(name: String, build: (String) -> String)] {
        let provenance = provenance
        return [
            ("redacted", { TranscriptionLogRedaction.redacted($0) }),
            ("transcribedChunk", { TranscriptionLogRedaction.transcribedChunk($0, provenance: provenance) }),
            ("translating", { TranscriptionLogRedaction.translating($0) }),
            ("translated", { TranscriptionLogRedaction.translated($0, latency: 0.42) }),
            ("copiedToPasteboard", { TranscriptionLogRedaction.copiedToPasteboard($0) }),

            // TranslationService.translate — o transcript que entra.
            ("translationRequested", {
                TranscriptionLogRedaction.translationRequested($0, provider: "OpenAI", model: "gpt-5.6-luna")
            }),
            // TranslationService.translate — a chave do provedor.
            ("translationKey", { TranscriptionLogRedaction.translationKey($0) }),
            // TranslationService.translate — a tradução que sai, derivada do transcript.
            ("translationSucceeded", { TranscriptionLogRedaction.translationSucceeded($0) }),
            // TranslationService.translate — o corpo de erro devolvido pelo provedor.
            ("translationFailed(detail:)", {
                TranscriptionLogRedaction.translationFailed(kind: "provedor recusou o pedido", detail: $0)
            })
        ]
    }

    /// As mensagens do serviço que não tocam em texto do usuário — id de modelo, nome de provedor,
    /// nomes de idioma. Entram na suíte assim mesmo: é o `print` do arquivo que a guarda mecânica
    /// exige que seja sempre uma chamada de redação, e um construtor sem teste é o buraco por onde
    /// o próximo `print` se pendura.
    private var operationalBuilders: [(name: String, build: () -> String)] {
        [
            ("translationModelChanged", { TranscriptionLogRedaction.translationModelChanged(to: "gpt-5.6-luna") }),
            ("translationProviderChanged", { TranscriptionLogRedaction.translationProviderChanged(to: "OpenAI") }),
            ("translationRoute", { TranscriptionLogRedaction.translationRoute(from: "English", to: "Portuguese (Brazil)") }),
            ("translationSending", { TranscriptionLogRedaction.translationSending(to: "OpenAI") }),
            ("translationFailed(kind:)", { TranscriptionLogRedaction.translationFailed(kind: "texto vazio", detail: "") })
        ]
    }

    @Test("Nenhum construtor deixa passar uma palavra sequer do texto")
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

    @Test("Prefixos também não passam — é assim que o código legado vazava")
    func noBuilderLeaksAPrefix() {
        // `'\(newText.prefix(20))...'` era literalmente o que estava no view model.
        let prefixes = [String(sentinel.prefix(20)), String(sentinel.prefix(50))]

        for redactor in redactors {
            let message = redactor.build(sentinel)
            for leaked in prefixes {
                #expect(message.contains(leaked) == false, "\(redactor.name) vazou um prefixo")
            }
        }
    }

    @Test("Texto vazio ou só de espaços não vira caso especial que vaze")
    func emptyAndBlankTextsAreSafe() {
        for redactor in redactors {
            #expect(redactor.build("").isEmpty == false, "\(redactor.name) devolveu vazio")
            #expect(redactor.build("   ").contains("   ") == false, "\(redactor.name) ecoou o texto")
        }
    }

    // MARK: - O que os logs DEVEM continuar dizendo

    @Test("O que sobra é operacional: tamanho, motor, modelo, posição no plano e latência")
    func theOperationalMetadataSurvives() {
        // A regra é "sem transcript", não "sem log": tirar a informação junto com o texto deixaria
        // o console inútil e a próxima review pediria de volta.
        let text = String(repeating: "a", count: 37)

        #expect(TranscriptionLogRedaction.redacted(text).contains("37"))

        let transcribed = TranscriptionLogRedaction.transcribedChunk(text, provenance: provenance)
        #expect(transcribed.contains("37"))
        #expect(transcribed.contains(TranscriptionEngineID.whisperKit.rawValue))
        #expect(transcribed.contains(TranscriptionModelID.whisperSmall.rawValue))
        #expect(transcribed.contains("rank 0"))

        let translated = TranscriptionLogRedaction.translated(text, latency: 1.5)
        #expect(translated.contains("37"))
        #expect(translated.contains("1500ms"))
    }

    // MARK: - Segredos (chave de API do provedor de tradução)

    /// Uma chave com a cara das de verdade: esquema, projeto e corpo.
    private let sentinelKey = "sk-proj-ABRACADABRA-XYZZY-PLUGH-SEGREDO-0123456789"

    @Test("A chave do provedor não aparece no log — nem inteira, nem em prefixo mascarado")
    func theProviderKeyNeverReachesTheLog() {
        // O `TranslationViewModel` imprimia `Present (sk-proj-AB...)` — 10 caracteres da chave, em
        // stdout, duas vezes (no init e a cada recarga de Configurações). Prefixo de chave não é
        // inofensivo: ele identifica provedor e, em vários deles, projeto ou organização.
        let described = SecretLogRedaction.presence(of: sentinelKey)

        #expect(described.contains(sentinelKey) == false)
        for word in sentinelWords {
            #expect(described.localizedCaseInsensitiveContains(word) == false, "vazou '\(word)'")
        }
        // Os prefixos que o código antigo imprimia — e o esquema sozinho, que também não entra.
        for size in [4, 8, 10, 20] {
            #expect(described.contains(String(sentinelKey.prefix(size))) == false, "vazou prefix(\(size))")
        }
        #expect(described.contains("sk-") == false)
    }

    @Test("O que sobra da chave é o que serve para depurar: presença e tamanho")
    func theKeyDescriptionKeepsOnlyPresenceAndLength() {
        // Tamanho denuncia o erro mais comum (chave colada pela metade) e não é material secreto.
        let described = SecretLogRedaction.presence(of: sentinelKey)
        #expect(described.contains("\(sentinelKey.count)"))
        #expect(described.contains("presente"))

        #expect(SecretLogRedaction.presence(of: "") == "ausente")
    }

    @Test("A descrição que o AppSettings expõe é a redigida, não a chave")
    func appSettingsExposesTheRedactedDescription() {
        // É esta propriedade que o view model imprime; se ela voltasse a interpolar a chave, o
        // teste acima continuaria passando e o vazamento voltaria.
        var settings = AppSettings()
        settings.translationProvider = .openai
        settings.openAIKey = sentinelKey

        let described = settings.apiKeyLogDescription
        #expect(described.contains(sentinelKey) == false)
        for word in sentinelWords {
            #expect(described.localizedCaseInsensitiveContains(word) == false)
        }
        #expect(described == SecretLogRedaction.presence(of: sentinelKey))
    }

    // MARK: - O caminho real do TranslationService

    @Test("Nenhuma mensagem do serviço de tradução ecoa o sentinela")
    func noTranslationServiceMessageLeaksTheSentinel() {
        // Um por `print` de `TranslationService.translate`. O `translationKey` leva a chave, e os
        // outros três levam, na ordem: o transcript que entra, a tradução que sai e o corpo de erro
        // que o provedor devolve.
        let serviceBuilders = redactors.filter { $0.name.hasPrefix("translation") }
        #expect(serviceBuilders.count == 4, "a lista das mensagens do serviço encolheu")

        for redactor in serviceBuilders {
            let message = redactor.build(sentinel)
            #expect(message.contains(sentinel) == false, "\(redactor.name) vazou a frase inteira")
            for word in sentinelWords {
                #expect(
                    message.localizedCaseInsensitiveContains(word) == false,
                    "\(redactor.name) vazou o trecho '\(word)'"
                )
            }
            for size in [10, 20, 50] {
                #expect(
                    message.contains(String(sentinel.prefix(size))) == false,
                    "\(redactor.name) vazou prefix(\(size))"
                )
            }
        }

        // A chave passa pelo mesmo crivo dos segredos, e não pelo de texto.
        let keyMessage = TranscriptionLogRedaction.translationKey(sentinelKey)
        #expect(keyMessage.contains("sk-") == false)
        for size in [4, 10] {
            #expect(keyMessage.contains(String(sentinelKey.prefix(size))) == false, "vazou prefix(\(size)) da chave")
        }
    }

    @Test("As mensagens operacionais do serviço não têm por onde vazar, e dizem o que precisam")
    func theServiceOperationalMessagesStayUseful() {
        for builder in operationalBuilders {
            let message = builder.build()
            #expect(message.isEmpty == false, "\(builder.name) devolveu vazio")
            for word in sentinelWords {
                #expect(message.localizedCaseInsensitiveContains(word) == false, "\(builder.name) vazou '\(word)'")
            }
        }

        // O que sobra tem que continuar respondendo "para onde foi, com qual modelo, e falhou por
        // quê" — senão a próxima review pede a informação de volta e alguém devolve o texto junto.
        #expect(TranscriptionLogRedaction.translationRequested("abc", provider: "OpenAI", model: "gpt-5.6-luna")
            .contains("OpenAI"))
        #expect(TranscriptionLogRedaction.translationRequested("abc", provider: "OpenAI", model: "gpt-5.6-luna")
            .contains("gpt-5.6-luna"))
        #expect(TranscriptionLogRedaction.translationRequested("abc", provider: "OpenAI", model: "gpt-5.6-luna")
            .contains("3 caracteres"))
        #expect(TranscriptionLogRedaction.translationFailed(kind: "texto vazio", detail: "").contains("texto vazio"))

        // Falha com corpo do provedor: o rótulo do app sobrevive, o corpo vira tamanho.
        let failed = TranscriptionLogRedaction.translationFailed(kind: "provedor recusou o pedido", detail: "12345")
        #expect(failed.contains("provedor recusou o pedido"))
        #expect(failed.contains("5 caracteres"))
        #expect(failed.contains("12345") == false)
    }

    /// A guarda que faltava na r2: os construtores acima só provam o que **eles** fazem, e o defeito
    /// estava em `print`s que não passavam por construtor nenhum. `TranslationService.swift` não
    /// compila no alvo `voizTests` (ele depende de `AICompletionService`, que fala com a rede), e
    /// mexer no `pbxproj` está sob mutex com a T2.4a — então a ligação entre o construtor testado e
    /// o `print` real se prova lendo o arquivo.
    ///
    /// A regra é mecânica de propósito: **todo `print` do serviço é uma chamada de redação inteira,
    /// sem interpolação solta.** Um `print("... \(text)")` novo reprova aqui mesmo que o texto nunca
    /// passe perto de um construtor — que é exatamente como o vazamento sobreviveu à primeira
    /// correção.
    @Test("Todo print do TranslationService é uma chamada de redação — sem interpolação solta")
    func everyPrintInTheTranslationServiceIsRedacted() throws {
        let source = try #require(
            Self.sourceOfFile("voiz/Services/TranslationService.swift"),
            "não consegui ler o serviço: a guarda não pode ser dada como cumprida"
        )

        let logLines = Self.logStatements(in: source)
        #expect(logLines.isEmpty == false, "nenhum print no serviço — a guarda ficou sem objeto")

        for line in logLines {
            #expect(
                line.hasPrefix("print(TranscriptionLogRedaction.") || line.hasPrefix("print(SecretLogRedaction."),
                "print sem redação no TranslationService: \(line)"
            )
        }

        // E nenhuma interpolação em `print` nenhum: o construtor é o argumento inteiro.
        #expect(
            Self.interpolations(in: logLines).isEmpty,
            "interpolação solta em print do TranslationService: \(Self.interpolations(in: logLines))"
        )

        // `prefix(` era literalmente a forma do vazamento (transcript, tradução e chave). Não há uso
        // legítimo dele neste arquivo, então a ausência vale como guarda barata.
        #expect(source.contains(".prefix(") == false, "voltou um prefix( ao TranslationService")
    }

    /// O mesmo para o view model migrado, com uma diferença: lá há `print`s legítimos que
    /// interpolam contadores de áudio e nomes de provedor, então a guarda não pode exigir
    /// construtor em tudo. Ela exige que a **lista** de expressões interpoladas seja exatamente
    /// esta — qualquer `print` novo que interpole algo reprova até alguém revisar e incluir.
    @Test("O TranslationViewModel só interpola em log o que já foi revisado")
    func theTranslationViewModelInterpolatesOnlyReviewedExpressions() throws {
        let source = try #require(
            Self.sourceOfFile("voiz/ViewModels/TranslationViewModel.swift"),
            "não consegui ler o view model: a guarda não pode ser dada como cumprida"
        )

        let expected = [
            // Configurações: provedor, modelo e a chave já redigida (`apiKeyLogDescription`).
            "settings.translationProvider.displayName",
            "settings.apiKeyLogDescription",
            "settings.currentModelId",
            "newSettings.translationProvider.displayName",
            "newSettings.apiKeyLogDescription",
            "newSettings.currentModelId",
            // O mesmo provedor, na linha do console de debug que confirma a recarga.
            "newSettings.translationProvider.displayName",
            // Auto-colagem: se o app anterior voltou à frente (Bool) e a espera antes de colar.
            "targetAppWasRestored",
            #"String(format: "%.1f", delay)"#,
            // A falha do coordenador: `TranscriptionCoordinatorError` é `LocalizedError` no próprio
            // coordenador e, por contrato, descreve motor/modelo/estágio sem texto transcrito. A
            // falha da TRADUÇÃO não está nesta lista de propósito: ela passa por
            // `TranslationError.logMessage(for:)`, porque o corpo de erro do provedor pode devolver
            // o prompt (e com ele o transcript).
            "error.localizedDescription"
        ].sorted()

        let found = Self.interpolations(in: Self.logStatements(in: source)).sorted()

        #expect(
            found == expected,
            "a lista de interpolações em log do view model mudou — revise antes de liberar.\nnovas: \(Set(found).subtracting(expected).sorted())\nsumiram: \(Set(expected).subtracting(found).sorted())"
        )
        #expect(source.contains(".prefix(") == false, "voltou um prefix( ao TranslationViewModel")
    }

    // MARK: - Leitura do fonte (a guarda mecânica)

    /// O arquivo de produção, lido do próprio checkout. `#filePath` é o único ponto fixo que um
    /// bundle de teste sem host tem para achar a árvore de fontes.
    @Test("O WhisperKit não é criado com verbose — verbose manda a FALA para o log do sistema")
    func liveRuntimeNeverEnablesWhisperKitVerbose() throws {
        // Cadeia verificada no WhisperKit 1.0.0: `WhisperKit.swift:72` liga o
        // logger quando `config.verbose`; `TranscribeTask.swift:69` copia isso
        // para `options.verbose`; as linhas 225-232 logam CADA PALAVRA e
        // 251-257 os segmentos; `ArgmaxCore/Logging.swift:123` emite com
        // `privacy: .public`. Ou seja: transcrição bem-sucedida escrevendo o
        // que foi dito no OSLog, retido e legível por fora do app.
        //
        // Guarda de FORMA porque `LiveWhisperKitRuntime.swift` é o único
        // arquivo do motor que importa WhisperKit e não compila no alvo de
        // testes — de propósito.
        let source = try #require(
            Self.sourceOfFile("voiz/Transcription/Engines/LiveWhisperKitRuntime.swift"),
            "não consegui ler o runtime: a guarda não pode ser dada como cumprida"
        )
        #expect(
            source.contains("verbose: true") == false,
            "verbose ligado incondicionalmente manda a fala da reunião para o log do sistema"
        )
        #expect(
            source.contains("verbose: Self.verboseDiagnosticsEnabled"),
            "o único verbose aceito é o portão explícito de diagnóstico"
        )
        #expect(
            source.contains("VOIZ_WHISPERKIT_VERBOSE"),
            "e ele tem que ser opt-in por ambiente"
        )
        #expect(
            source.contains("#if DEBUG"),
            "e só existir em build de DEBUG"
        )
    }

    private static func sourceOfFile(_ relativePath: String) -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Transcription/
            .deletingLastPathComponent()   // voizTests/
            .deletingLastPathComponent()   // raiz do repositório
        let url = repoRoot.appending(path: relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// As linhas de log do arquivo, normalizadas: `print(...)` e `addDebugLog(...)`, sem comentários.
    private static func logStatements(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .filter { $0.contains("print(") || $0.contains("addDebugLog(") }
    }

    /// Cada `\(expressão)` que aparece nas linhas dadas, já sem espaços nas pontas.
    private static func interpolations(in lines: [String]) -> [String] {
        // Sem parênteses aninhados nas interpolações destes dois arquivos; se alguém introduzir um,
        // o recorte sai diferente do esperado e a lista reprova — que é o desfecho certo.
        let regex = try! NSRegularExpression(pattern: #"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#)
        return lines.flatMap { line -> [String] in
            let range = NSRange(line.startIndex..., in: line)
            return regex.matches(in: line, range: range).compactMap { match in
                guard let captured = Range(match.range(at: 1), in: line) else { return nil }
                return String(line[captured]).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    @Test("A proveniência que entra no log nunca carrega texto — é contrato do tipo")
    func provenanceItselfCarriesNoText() {
        // `transcribedChunk` interpola a proveniência inteira, então a garantia do log depende
        // desta: `TranscriptionProvenance` é só ids, caso de uso, origem e rank.
        let described = "\(provenance)"
        for word in sentinelWords {
            #expect(described.localizedCaseInsensitiveContains(word) == false)
        }
    }
}
