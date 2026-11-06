import Foundation

// Adapter da T3.3: liga o `SpeechAnalyzer`/`SpeechTranscriber` do macOS 26 ao contrato
// `BatchTranscriptionEngine` da Onda 1, sob o mesmo contrato de ciclo de vida dos outros dois
// motores (DECISOES, 2026-08-07, itens 1–16).
//
// Este arquivo depende **só de Foundation**, igual a `Transcription/Contracts/` e ao adapter do
// Parakeet. É isso que permite compilá-lo no alvo `voizTests` e exercitar o motor inteiro com
// dublê, sem `Speech`, sem reservar locale e sem baixar asset do sistema. Quem fala com o
// framework de verdade é `AppleSpeechAssetRuntime` (também puro, também testado) sobre
// `AppleSpeechCalls`, cuja única implementação de produção — a que precisa de `Speech` e
// `AVFAudio` — mora em `AppleSpeechAnalyzerCalls.swift`, fora dos testes.
//
// Nada no app instancia este motor: quem constrói motores é o coordenador da T2.3. Até lá o
// comportamento do app é exatamente o de hoje.

// MARK: - Locale fixo

/// Os locales que o Voiz usa neste motor.
///
/// O `SpeechTranscriber` fixa o locale na construção do módulo: não existe "detecte o idioma".
/// Por isso o locale é **modelo** no vocabulário do contrato — um `TranscriptionModelID` por
/// locale — e não um parâmetro do pedido. Assim a proveniência gravada diz qual locale produziu
/// o texto, o roteador consegue escolher entre eles pelo idioma pedido, e um pedido com
/// `language == nil` (detecção automática) não tem para onde ir neste motor.
///
/// O catálogo pode oferecer mais locales do que o limite simultâneo do pool do
/// `AssetInventory`: a reserva continua sendo feita apenas para os modelos em uso.
nonisolated enum AppleSpeechLocale: String, Sendable, Equatable, Hashable, CaseIterable {
    case portugueseBrazil = "pt-BR"
    case englishUS = "en-US"
    case spanishSpain = "es-ES"
    case frenchFrance = "fr-FR"
    case germanGermany = "de-DE"
    case japaneseJapan = "ja-JP"
    case chineseChina = "zh-CN"

    /// O locale do modelo, ou `nil` quando o id não é deste motor.
    init?(model: TranscriptionModelID) {
        switch model {
        case .appleSystemSpeechPTBR: self = .portugueseBrazil
        case .appleSystemSpeechENUS: self = .englishUS
        case .appleSystemSpeechESES: self = .spanishSpain
        case .appleSystemSpeechFRFR: self = .frenchFrance
        case .appleSystemSpeechDEDE: self = .germanGermany
        case .appleSystemSpeechJAJP: self = .japaneseJapan
        case .appleSystemSpeechZHCN: self = .chineseChina
        default: return nil
        }
    }

    var model: TranscriptionModelID {
        switch self {
        case .portugueseBrazil: return .appleSystemSpeechPTBR
        case .englishUS: return .appleSystemSpeechENUS
        case .spanishSpain: return .appleSystemSpeechESES
        case .frenchFrance: return .appleSystemSpeechFRFR
        case .germanGermany: return .appleSystemSpeechDEDE
        case .japaneseJapan: return .appleSystemSpeechJAJP
        case .chineseChina: return .appleSystemSpeechZHCN
        }
    }

    /// O idioma que este locale atende, no vocabulário do contrato.
    var language: TranscriptionLanguage {
        switch self {
        case .portugueseBrazil: return .portugueseBrazil
        case .englishUS: return .englishUS
        case .spanishSpain: return .spanishSpain
        case .frenchFrance: return .frenchFrance
        case .germanGermany: return .germanGermany
        case .japaneseJapan: return .japaneseJapan
        case .chineseChina: return .chineseChina
        }
    }

    /// Identificador BCP-47 para construir o `Locale` do sistema. Fica como `String` para este
    /// arquivo não precisar de nada além de Foundation.
    var identifier: String { rawValue }

    /// Verdadeiro apenas para um dos locales explicitamente oferecidos pelo app.
    static func supports(_ locale: Locale) -> Bool {
        let requested = locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return allCases.contains { $0.identifier.lowercased() == requested }
    }
}

// MARK: - Seam do runtime

/// O `SpeechAnalyzer` reduzido ao que o motor precisa.
///
/// Parametrizado por `TranscriptionModelID` pelo mesmo motivo do seam do Parakeet: é o modelo que
/// escolhe o locale, e um runtime que carregasse "o SpeechTranscriber" sem dizer qual deixaria a
/// proveniência mentir sobre o locale que produziu o texto. Quem não sabe atender um id **recusa**.
nonisolated protocol AppleSpeechRuntime: Sendable {
    /// Deixa o locale de `model` utilizável: reserva o locale, garante o asset (baixando e
    /// instalando quando preciso) e aquece o analyzer.
    ///
    /// Lança `AppleSpeechRuntimeError`. Cancelamento chega como `.cancelled`, nunca disfarçado de
    /// falha de asset — é o que impede o coordenador de tratar um cancelamento como locale
    /// indisponível e cair para outro motor.
    func load(model: TranscriptionModelID) async throws

    /// Transcreve um bloco de áudio mono a 16 kHz com o analyzer de `model` já ativo.
    func transcribe(
        samples: [Float],
        sampleRate: Double,
        model: TranscriptionModelID,
        context: TranscriptionContext
    ) async throws -> AppleSpeechRuntimeOutput

    /// Solta o analyzer e a retenção dos modelos do sistema.
    ///
    /// **Não libera a reserva do locale** — ver `AppleSpeechAssetRuntime.release()` para o porquê.
    func release() async
}

/// Um trecho reconhecido como o `SpeechTranscriber` reportou, sem os tipos do contrato.
nonisolated struct AppleSpeechTranscriptSegment: Sendable, Equatable {
    var text: String
    /// Início em segundos, relativo ao começo do áudio entregue. `0` quando o transcritor não
    /// reportou faixa de tempo.
    var start: TimeInterval
    var end: TimeInterval
    /// Confiança reportada pelo atributo `transcriptionConfidence`, quando presente. Escala
    /// própria da Apple.
    var confidence: Float?
    var words: [AppleSpeechTimedWord] = []

    init(text: String, start: TimeInterval = 0, end: TimeInterval = 0, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

nonisolated struct AppleSpeechTimedWord: Sendable, Equatable {
    var text: String
    var range: NSRange
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Float?
}

/// O resultado cru de um lote, sem os tipos de UI do app.
nonisolated struct AppleSpeechRuntimeOutput: Sendable, Equatable {
    /// Trechos finalizados, na ordem em que o transcritor os emitiu.
    var segments: [AppleSpeechTranscriptSegment]
    /// Tempo de parede da análise, medido pela camada de chamadas.
    var processingTime: TimeInterval
    var vocabularyTermsUsed: Int?
    var recognizer: String?
    var unadaptedText: String?

    init(segments: [AppleSpeechTranscriptSegment] = [], processingTime: TimeInterval = 0,
         vocabularyTermsUsed: Int? = nil, recognizer: String? = nil, unadaptedText: String? = nil) {
        self.segments = segments
        self.processingTime = processingTime
        self.vocabularyTermsUsed = vocabularyTermsUsed
        self.recognizer = recognizer
        self.unadaptedText = unadaptedText
    }
}

/// As falhas que o runtime do SpeechAnalyzer sabe distinguir.
///
/// Enum próprio pelo mesmo motivo do Parakeet: o erro do singleton do Whisper não classifica
/// falha deste motor. Nenhum caso carrega texto transcrito — as descrições são técnicas, para log.
nonisolated enum AppleSpeechRuntimeError: Error, Sendable, Equatable {
    /// Este Mac/esta versão do SO não fala o locale (ou o `SpeechTranscriber` nem está disponível).
    case localeUnsupported(String)
    /// O asset do locale não está utilizável: download/instalação falhou, ou o status não chegou
    /// a `installed` depois de instalar.
    case assetUnavailable(String)
    /// O pool de reservas de locale do sistema está cheio, então não dá para reservar este.
    ///
    /// Caso próprio, e não um `assetUnavailable` genérico, porque a causa e a saída são outras: o
    /// asset pode estar perfeito no disco, e quem enche o pool pode ser outro app. Separado, o
    /// coordenador (e a UI da Onda 6) consegue dizer "libere um idioma" em vez de "modelo
    /// quebrado". O Voiz **nunca** libera reserva sozinho para abrir vaga — ver
    /// `AppleSpeechAssetRuntime`.
    case reservationPoolFull(String)
    /// O runtime não sabe atender este id de modelo.
    case unsupportedModel(TranscriptionModelID)
    /// O transcritor recusou o formato de áudio oferecido.
    case audioFormatUnsupported(String)
    /// O analyzer está ativo mas a análise falhou.
    case runtimeFailure(String)
    /// O trabalho foi cancelado. Caso próprio porque cancelamento **não** é defeito do asset:
    /// não permite fallback e não pode entrar no cache negativo.
    case cancelled
}

// MARK: - Motor

/// O `SpeechAnalyzer` do macOS 26 como motor em lote do contrato da Onda 1.
///
/// `actor` porque `TranscriptionEngine` é `Sendable` e o coordenador vai usá-lo de tarefas
/// concorrentes. Atenção ao que o ator **não** dá: ele serializa o acesso ao estado do motor, não
/// ao recurso caro — em todo `await` o executor é liberado. A serialização do runtime é a vaga
/// única explícita, idêntica à do Parakeet.
///
/// O motor é fino de propósito: valida o pedido contra o descritor, controla o ciclo de vida do
/// analyzer e traduz erro. Reserva de locale, asset e reconhecimento moram no runtime.
actor AppleSpeechAnalyzerEngine: BatchTranscriptionEngine {

    /// O que acontece com o analyzer residente, para quem quiser mostrar isso na tela.
    ///
    /// `generation` é o id monotônico da carga que emitiu o evento, com a mesma semântica dos
    /// outros dois motores (DECISOES, itens 6 e 14 reescrito): nasce **com a vaga na mão**, então
    /// a ordem das gerações é a ordem das mutações. Regra do store da T2.3: descartar evento com
    /// geração menor que a última vista, chaveando por motor.
    ///
    /// Não há `downloading(fraction:)` mesmo o `AssetInstallationRequest` reportando `Progress`:
    /// levar a fração até aqui exigiria um canal de progresso no seam que ninguém consome antes da
    /// UI da Onda 6, e a forma do evento pode divergir entre motores sem quebrar o contrato
    /// (DECISOES, item 15). Quando a Onda 6 precisar da barra, o canal entra aqui.
    nonisolated enum LoadEvent: Sendable, Equatable {
        /// Reservando o locale, garantindo o asset e aquecendo o analyzer.
        case loading(model: TranscriptionModelID, generation: Int)
        case ready(model: TranscriptionModelID, generation: Int)
        case failed(model: TranscriptionModelID, failure: TranscriptionEngineFailure, generation: Int)
        /// Analyzer solto; nenhum locale residente. A **reserva** do locale continua de pé.
        case unloaded(generation: Int)
    }

    /// Uma carga em voo.
    ///
    /// `id` é identidade (serve ao "esta carga ainda é a que vale?"); a **geração** do evento é
    /// outra coisa e nasce lá dentro, já com a vaga na mão — ver `runLoad`.
    private struct Load {
        var id: Int
        var model: TranscriptionModelID
        var task: Task<Void, any Error>
    }

    /// Alguém esperando a vaga do runtime.
    private struct SlotWaiter {
        var ticket: Int
        /// `true` = a vaga é sua; `false` = você desistiu (foi cancelado) e não deve devolvê-la.
        var continuation: CheckedContinuation<Bool, Never>
    }

    nonisolated let descriptor: TranscriptionEngineDescriptor

    private let runtime: any AppleSpeechRuntime

    /// Quem observa o ciclo de vida. **Um dono só**: como o motor é único no processo (ver
    /// `shared(descriptor:runtime:)`), o observador também é — instalar outro substitui o
    /// anterior, e é por isso que ele é explícito (`setObserver`) em vez de parâmetro de fábrica,
    /// onde a substituição passaria despercebida.
    private var observer: (@Sendable (LoadEvent) -> Void)?

    /// Modelo (= locale) com analyzer residente. `nil` = nada ativo.
    private var loadedModel: TranscriptionModelID?

    /// A carga em voo, compartilhada por todos que a estiverem esperando. É o single-flight: sem
    /// ela, dois `prepare` concorrentes disputariam a reserva e o download do mesmo asset do
    /// sistema, e o perdedor viraria `modelUnavailable` **espúrio** enquanto a carga certa segue
    /// saudável — no coordenador isso viraria fallback com proveniência mentirosa e, sob
    /// `strictEngineSelection`, falha dura.
    private var loading: Load?

    /// Modelo cuja carga já falhou, com a falha. Enquanto for este o modelo pedido, `prepare`
    /// re-lança na hora em vez de tentar instalar o asset de novo.
    ///
    /// Simétrico ao `failedModel` dos outros dois motores (contrato, item 7) e pelo mesmo motivo:
    /// sem ele, uma reunião de 40 lotes tentaria 40 instalações do mesmo asset quebrado. Política
    /// de retry é da T2.3/T2.5, não daqui. Sai do caminho ao pedir outro modelo ou ao chamar
    /// `unload()` — que é também o que atende a armadilha 5 da T0.2 (instalação de asset é
    /// revogável, então "falhou uma vez" não pode virar veredito permanente do processo).
    private var failedModel: (model: TranscriptionModelID, failure: TranscriptionEngineFailure)?

    private var generationCounter = 0
    private var loadIDCounter = 0
    private var ticketCounter = 0

    // MARK: Vaga única do runtime
    //
    // Mesma construção do Parakeet, pelos mesmos motivos: o ator libera o executor em todo
    // `await`, então sem esta fila FIFO duas análises entrariam juntas no `SpeechAnalyzer` e um
    // `unload` se intercalaria numa carga, soltando o analyzer recém-aquecido enquanto
    // `loadedModel` continuaria apontando para ele.
    //
    // A exclusão é **total** (contrato, item 11): análise × análise, ciclo de vida × análise e
    // ciclo de vida × ciclo de vida.
    private var slotBusy = false
    private var slotWaiters: [SlotWaiter] = []

    /// O descritor entra por parâmetro só para os testes conseguirem descrever um motor
    /// hipotético; em produção é sempre o do catálogo — motor e descritor discordarem é bug.
    ///
    /// O runtime é injeção **obrigatória**: sem construtor default, ninguém cria um segundo
    /// analyzer por engano, e a residência continua sendo do coordenador.
    ///
    /// Este `init` é o caminho dos **testes**. Produção passa por `shared(descriptor:runtime:)`,
    /// que impõe a instância única do processo — ver o porquê logo abaixo.
    init(
        runtime: any AppleSpeechRuntime,
        descriptor: TranscriptionEngineDescriptor = .appleSpeechAnalyzer,
        observer: (@Sendable (LoadEvent) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.descriptor = descriptor
        self.observer = observer
    }

    /// Instala (ou remove) o observador do ciclo de vida.
    ///
    /// Existe porque a fábrica de produção devolve sempre a **mesma** instância: um observador
    /// passado por parâmetro na segunda chamada seria silenciosamente ignorado (ou, pior,
    /// substituiria o do dono anterior sem ninguém notar). Aqui a substituição é um pedido
    /// explícito de quem chama.
    func setObserver(_ observer: (@Sendable (LoadEvent) -> Void)?) {
        self.observer = observer
    }

    // MARK: - Instância única do processo

    /// A instância única do processo, criada na primeira chamada com o que `makeRuntime` devolver.
    /// Chamadas seguintes **ignoram** `makeRuntime` e `descriptor` e devolvem a mesma instância.
    ///
    /// ## Por que a montagem impõe isso, em vez de documentar
    ///
    /// Os recursos que este motor administra não são dele: são **do processo**.
    /// `AssetInventory` guarda um pool global de reservas de locale (5 vagas na máquina medida na
    /// T0.2) e `SpeechModels.endRetention()` é `static`, sem parâmetro de dono — não existe
    /// variante por instância. Duas instâncias deste motor seriam dois punhos sobre o mesmo
    /// recurso: o `unload()` de A encerra a retenção dos modelos de B, e B continua com
    /// `loadedModel` preenchido, afirmando estar preparado sobre modelos que já não estão
    /// retidos. É exatamente a mentira que os itens 3, 4 e 11 do contrato de ciclo de vida
    /// existem para matar — e ela escapa da vaga única, porque a vaga protege o estado da
    /// instância e o recurso não é da instância.
    ///
    /// Documentar não bastaria: um `AppleSpeechAnalyzerCalls()` construído dentro da fábrica
    /// *parece* estado próprio e é só um punho sobre estado global. Por isso a fábrica devolve
    /// a instância compartilhada (DECISOES, T3.3 (a)).
    ///
    /// ## Regra de retenção para a T4.2
    ///
    /// A sessão progressiva do preview vai precisar do mesmo framework. Ela **não pode** registrar
    /// retenção `.processLifetime` própria: um `unload()` deste motor no meio de uma reunião
    /// derrubaria os modelos dela entre um `finish()` e o `restart()` seguinte — falha
    /// intermitente, difícil de reproduzir, e mirando justamente o gate humano da T4.2 (primeiro
    /// parcial p50 ≤ 1,3 s). As saídas, em ordem de preferência:
    ///
    /// 1. a sessão do preview usa **esta mesma instância** (ela já serializa tudo pela vaga única);
    /// 2. a sessão usa `SpeechAnalyzer.Options.ModelRetention.lingering`, que sobrevive ao fim do
    ///    analyzer sem entrar na retenção de processo — **depende de medir** se `endRetention()`
    ///    também a varre; se varrer, esta saída não existe;
    /// 3. a sessão usa `.whileInUse` e paga carga a cada restart.
    ///
    /// O que a T4.2 **não** pode fazer é criar um segundo dono de retenção `.processLifetime`.
    nonisolated static func shared(
        descriptor: TranscriptionEngineDescriptor = .appleSpeechAnalyzer,
        runtime makeRuntime: () -> any AppleSpeechRuntime
    ) -> AppleSpeechAnalyzerEngine {
        processInstance.resolve {
            AppleSpeechAnalyzerEngine(runtime: makeRuntime(), descriptor: descriptor)
        }
    }

    /// A caixa que guarda a instância única. Classe com lock, e não `static var`, porque a
    /// primeira chamada pode vir de qualquer thread e a criação tem de acontecer uma vez só.
    private final class ProcessInstance: @unchecked Sendable {
        private let lock = NSLock()
        private var engine: AppleSpeechAnalyzerEngine?

        func resolve(_ create: () -> AppleSpeechAnalyzerEngine) -> AppleSpeechAnalyzerEngine {
            lock.lock()
            defer { lock.unlock() }
            if let engine { return engine }
            let created = create()
            engine = created
            return created
        }
    }

    private nonisolated static let processInstance = ProcessInstance()

    // MARK: - TranscriptionEngine

    /// Idempotente e single-flight: com o locale já ativo não faz nada; com a carga dele em voo,
    /// **aguarda a mesma carga** em vez de disparar outra.
    ///
    /// Garantia pós-`prepare` (contrato, item 12): quando esta função devolve sem erro, o locale
    /// pedido está reservado, com asset instalado e analyzer aquecido.
    ///
    /// **Quando houve carga** — isto é, em todo caminho que passou por `runLoad`, inclusive o de
    /// quem aguardou a carga de outro —, vale também a parte forte: nenhuma análise anterior a
    /// esta chamada continua em voo, porque carga e análise dividem a mesma vaga.
    ///
    /// No caminho rápido (o locale pedido já é o residente) esta função devolve **sem tomar a
    /// vaga**. É deliberado, e igual nos três motores: fazer o caminho rápido enfileirar
    /// transformaria um `prepare` barato — que o coordenador chama por lote — numa espera pela
    /// análise anterior. Quem precisa de "nada em voo" precisa de `unload()`, que sempre drena.
    func prepare(model: TranscriptionModelID) async throws {
        try checkCancellation()
        // Validação do id ANTES de tocar em qualquer estado (contrato, item 13): um id
        // desconhecido — seleção salva de uma versão antiga, catálogo que mudou — não pode
        // evictar o locale que está funcionando, nem deixar latch.
        guard descriptor.model(model) != nil, AppleSpeechLocale(model: model) != nil else {
            throw TranscriptionEngineFailure.modelUnavailable(model)
        }

        // Carga em voo: ou é a que queremos (e esperamos a MESMA Task), ou ela perde a vez.
        if let inFlight = loading {
            if inFlight.model == model {
                try await inFlight.task.value
                try checkCancellation()
                return
            }
            // Cancela e **espera terminar** fora da vaga — a Task dela é quem segura a vaga, e
            // esperá-la segurando seria travar o motor contra si mesmo.
            loading = nil
            inFlight.task.cancel()
            _ = try? await inFlight.task.value
        }

        // Caminho rápido: já é o residente, devolve sem tomar a vaga.
        if loadedModel == model { return }
        if let failedModel, failedModel.model == model { throw failedModel.failure }
        failedModel = nil

        let id = nextLoadID()
        let load = Load(
            id: id,
            model: model,
            // `Task` herda o isolamento do ator, então `runLoad` roda aqui dentro e a mutação de
            // estado acontece exatamente uma vez, por mais gente que esteja esperando.
            task: Task { try await self.runLoad(model: model, id: id) }
        )
        loading = load

        try await load.task.value
        try checkCancellation()
    }

    /// Solta o analyzer residente. **Não libera a reserva do locale** — ver `runtime.release()`.
    func unload() async {
        // Fora da vaga: matar a carga em voo. A Task dela é quem segura a vaga.
        if let dying = loading {
            loading = nil
            dying.task.cancel()
            // Esperar de verdade: um `unload` que devolve com a carga ainda correndo faz o
            // coordenador achar que abriu espaço e carregar o pesado do outro motor por cima.
            _ = try? await dying.task.value
        }

        // Daqui para baixo, com a vaga na mão: estado, analyzer e evento mudam juntos.
        //
        // O `loadedModel = nil` mora **aqui dentro**, e não lá em cima, de propósito: se um
        // `prepare` se intercalou enquanto esperávamos, a carga dele terminou antes de nós (a fila
        // é FIFO) e deixou `loadedModel` preenchido. Zerar antes e não zerar de novo era o que
        // deixava o motor afirmar estar preparado sobre um analyzer já descartado.
        _ = await acquireSlot()
        defer { releaseSlot() }

        // Geração tirada aqui, e não na entrada: assim a ordem das gerações é a ordem das
        // mutações, e o store nunca recebe um `.unloaded` mais novo que um `.ready` posterior.
        let generation = nextGeneration()
        loadedModel = nil
        failedModel = nil
        await runtime.release()
        observer?(.unloaded(generation: generation))
    }

    // MARK: - BatchTranscriptionEngine

    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult {
        try checkCancellation()
        let locale = try validate(request, model: candidate.model)

        // **Não** prepara sozinho: a residência é decisão do coordenador (T2.3). Um `transcribe`
        // que reserva locale e baixa asset por trás de uma fila de lotes desfaz a prioridade
        // "interativo antes de batch".
        guard loadedModel == candidate.model else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }

        guard await acquireSlot(cancellable: true) else {
            throw TranscriptionEngineFailure.cancelled
        }
        defer { releaseSlot() }

        // Entre a fila e a análise o mundo muda: o coordenador pode ter descarregado para atender
        // um pedido interativo, ou este trabalho pode ter sido abortado.
        try checkCancellation()
        guard loadedModel == candidate.model else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }

        let output: AppleSpeechRuntimeOutput
        do {
            output = try await runtime.transcribe(
                samples: request.audio.samples,
                sampleRate: request.audio.sampleRate,
                model: candidate.model,
                context: request.context
            )
        } catch {
            throw Self.failure(from: error, model: candidate.model)
        }

        // Borda **posterior**: a análise já terminou quando o cancelamento chega tarde. Entregar
        // esse texto como sucesso seria devolver resultado de um trabalho que alguém mandou parar.
        try checkCancellation()

        return Self.result(
            from: output,
            locale: locale,
            request: request,
            candidate: candidate
        )
    }

    // MARK: - Montagem do resultado

    /// Junta os trechos finalizados no texto do contrato.
    ///
    /// O `SpeechTranscriber` emite o transcript em pedaços já espaçados por dentro; o que falta é
    /// a cola entre pedaços. Trechos vazios saem fora — segmento sem texto só polui o transcript
    /// de quem consome o resultado.
    private static func result(
        from output: AppleSpeechRuntimeOutput,
        locale: AppleSpeechLocale,
        request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) -> TranscriptionEngineResult {
        let pieces = output.segments
            .map { segment -> AppleSpeechTranscriptSegment in
                var trimmed = segment
                trimmed.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed
            }
            .filter { !$0.text.isEmpty }

        let segments = pieces.map { piece -> TranscriptionTextSegment in
            // Transcritor que não reportou faixa de tempo (atributo ausente) deixa start == end
            // == 0. Num trecho único isso é indistinguível de "cobre o áudio todo", que é a única
            // informação verdadeira que temos — mesma regra do adapter do Parakeet. Com vários
            // trechos, inventar limites seria pior que reportar o que veio.
            let end = piece.end > piece.start
                ? piece.end
                : (pieces.count == 1 && piece.start == 0 ? request.audio.duration : piece.start)
            return TranscriptionTextSegment(
                text: piece.text,
                start: piece.start,
                end: end,
                confidence: piece.confidence
            )
        }

        var provenance = TranscriptionProvenance(candidate: candidate, useCase: request.useCase)
        provenance.recognizer = output.recognizer
        return TranscriptionEngineResult(
            text: pieces.map(\.text).joined(separator: " "),
            segments: segments,
            // O locale é fixo no modelo: o motor não detecta idioma, ele **sabe** qual pediu.
            detectedLanguage: locale.language,
            provenance: provenance,
            processingTime: output.processingTime,
            vocabularyTermsUsed: output.vocabularyTermsUsed,
            unadaptedText: output.unadaptedText
        )
    }

    // MARK: - Carga

    /// O corpo da carga, rodando dentro do ator. Só ele mexe no estado de carga — por isso a
    /// mutação acontece uma vez só, independentemente de quantos `prepare` estejam esperando.
    private func runLoad(model: TranscriptionModelID, id: Int) async throws {
        guard await acquireSlot(cancellable: true) else {
            // Desistiu da fila por cancelamento. Não conquistou a vaga, então não a devolve.
            if isCurrent(id) { loading = nil }
            throw TranscriptionEngineFailure.cancelled
        }
        defer { releaseSlot() }

        // Superada enquanto esperávamos a vez: nem começa.
        guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }

        // A geração nasce aqui, com a vaga na mão — não na fila. É o que mantém a ordem das
        // gerações igual à ordem das mutações para quem observa de fora.
        let generation = nextGeneration()
        observer?(.loading(model: model, generation: generation))

        do {
            try checkCancellation()
            // Troca de locale: o analyzer antigo sai **aqui**, com a vaga na mão. Fora dela isto
            // seria soltar o analyzer por baixo de uma análise viva.
            if loadedModel != nil {
                loadedModel = nil
                await runtime.release()
            }
            try checkCancellation()
            try await runtime.load(model: model)
        } catch {
            let failure = Self.failure(from: error, model: model)
            guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }
            loading = nil
            // Cancelamento não é defeito do asset: fora do cache negativo, senão a próxima
            // tentativa do usuário nasceria condenada.
            if failure != .cancelled { failedModel = (model, failure) }
            observer?(.failed(model: model, failure: failure, generation: generation))
            throw failure
        }

        guard isCurrent(id) else {
            // Um `unload` (ou uma troca de locale) aconteceu enquanto carregávamos. O analyzer
            // **não** ressuscita: solta o que a carga acabou de deixar pronto.
            await runtime.release()
            throw TranscriptionEngineFailure.cancelled
        }
        loading = nil
        loadedModel = model
        observer?(.ready(model: model, generation: generation))
    }

    /// A carga `id` ainda é a que vale?
    private func isCurrent(_ id: Int) -> Bool {
        loading?.id == id
    }

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    private func nextLoadID() -> Int {
        loadIDCounter += 1
        return loadIDCounter
    }

    // MARK: - Vaga única

    /// Conquista a vaga. Devolve `false` só quando `cancellable` e o chamador foi cancelado
    /// enquanto esperava — nesse caso ele **não** tem a vaga e não deve chamar `releaseSlot()`.
    ///
    /// `cancellable: false` é para o `unload`: soltar o analyzer é justamente o que não pode
    /// desistir no meio.
    private func acquireSlot(cancellable: Bool = false) async -> Bool {
        guard slotBusy else {
            slotBusy = true
            return true
        }
        let ticket = nextTicket()
        guard cancellable else {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                slotWaiters.append(SlotWaiter(ticket: ticket, continuation: continuation))
            }
        }
        // Trabalho cancelado sai da fila em vez de segurar a vez de quem vem depois — com
        // "interativo antes de batch", um lote cancelado segurando a fila é atraso puro.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                slotWaiters.append(SlotWaiter(ticket: ticket, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandonSlot(ticket: ticket) }
        }
    }

    /// Sai da fila. Se já tiver sido servido, não faz nada: quem foi servido tem a vaga e é ele
    /// quem a devolve.
    private func abandonSlot(ticket: Int) {
        guard let index = slotWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        slotWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Passa a vaga adiante em ordem de chegada. Não solta `slotBusy` quando há fila, senão um
    /// recém-chegado furaria a fila de quem já espera.
    private func releaseSlot() {
        if slotWaiters.isEmpty {
            slotBusy = false
        } else {
            slotWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func nextTicket() -> Int {
        ticketCounter += 1
        return ticketCounter
    }

    // MARK: - Validação e erro

    /// Barra o que o motor sabe de antemão que não vai dar certo — antes de gastar a vaga do
    /// runtime com um pedido que não tem como ser atendido. Devolve o locale do modelo pedido.
    @discardableResult
    private func validate(
        _ request: TranscriptionRequest,
        model: TranscriptionModelID
    ) throws -> AppleSpeechLocale {
        // O descritor declara `supportsStreaming` porque a sessão progressiva da T4.2 é do mesmo
        // motor — então `descriptor.supports(useCase:)` sozinho **não** barra a prévia aqui.
        // Este adapter é de lote: a prévia é da T4.2, não dele.
        guard !request.useCase.requiresStreaming else {
            throw TranscriptionEngineFailure.engineInternal(
                "caso de uso \(request.useCase.rawValue) exige streaming; este adapter é de lote"
            )
        }
        guard descriptor.supportedUseCases.contains(request.useCase), descriptor.supportsBatch else {
            throw TranscriptionEngineFailure.engineInternal(
                "caso de uso \(request.useCase.rawValue) fora do SpeechAnalyzer em lote"
            )
        }

        guard let locale = AppleSpeechLocale(model: model) else {
            throw TranscriptionEngineFailure.modelUnavailable(model)
        }

        guard let language = request.language else {
            // O locale é fixo no módulo do `SpeechTranscriber`: não existe "detecte o idioma".
            // O roteador já barra isto pelo `detectsLanguageAutomatically == false`; aqui é a
            // guarda do motor para quem o chamar direto.
            throw TranscriptionEngineFailure.engineInternal(
                "pedido com detecção automática num motor de locale fixo"
            )
        }
        guard descriptor.supports(language: language) else {
            throw TranscriptionEngineFailure.languageUnsupported(language)
        }
        // E o pedido tem de casar com o locale **deste** modelo: pedir en-US ao modelo pt-BR
        // devolveria texto transcrito no locale errado, sem ninguém perceber.
        guard locale.language.matches(language) else {
            throw TranscriptionEngineFailure.languageUnsupported(language)
        }

        guard !request.audio.isEmpty else {
            throw TranscriptionEngineFailure.invalidAudio("áudio vazio")
        }
        guard request.audio.sampleRate == TranscriptionAudio.defaultSampleRate else {
            throw TranscriptionEngineFailure.invalidAudio(
                "áudio a \(Int(request.audio.sampleRate)) Hz; o pipeline do Voiz é 16 kHz mono"
            )
        }

        return locale
    }

    /// Cancelamento cooperativo nas bordas: evita gastar download de asset e análise em trabalho
    /// já descartado — a única alavanca que o coordenador tem para priorizar o interativo.
    private func checkCancellation() throws {
        if Task.isCancelled { throw TranscriptionEngineFailure.cancelled }
    }

    /// Traduz o erro do runtime para o vocabulário que o coordenador entende.
    ///
    /// O que está em jogo é o `allowsFallback`. Locale e asset indisponíveis são **recuperáveis**
    /// de propósito (requisito da T3.3): num Mac sem o asset pt-BR, o coordenador tem de poder
    /// cair para o WhisperKit em vez de deixar o usuário sem texto.
    ///
    /// - `localeUnsupported` → `.languageUnsupported`: é o idioma que este Mac não fala.
    /// - `assetUnavailable`/`unsupportedModel` → `.modelUnavailable`: os "pesos" (o asset do
    ///   sistema para o locale) não estão utilizáveis.
    /// - `audioFormatUnsupported` → `.engineInternal`, e **não** `.invalidAudio`: o áudio é o do
    ///   pipeline de sempre; quem não o aceita é este motor. `.invalidAudio` proíbe fallback, e
    ///   proibir fallback aqui condenaria o pedido por um defeito que é só deste motor.
    private static func failure(
        from error: any Error,
        model: TranscriptionModelID
    ) -> TranscriptionEngineFailure {
        switch error {
        case let failure as TranscriptionEngineFailure:
            return failure
        case let runtime as AppleSpeechRuntimeError:
            switch runtime {
            case .localeUnsupported:
                // Um id que não vira locale não tem idioma para reportar: dizer
                // `.languageUnsupported` com idioma vazio poluiria proveniência e log com um
                // valor que não significa nada. O que o caso significa é o modelo não servir.
                guard let language = AppleSpeechLocale(model: model)?.language else {
                    return .modelUnavailable(model)
                }
                return .languageUnsupported(language)
            case .assetUnavailable, .unsupportedModel:
                return .modelUnavailable(model)
            case .reservationPoolFull:
                // Recuperável de propósito: o pool é do sistema e pode ter sido enchido por outro
                // app. O coordenador cai para o WhisperKit em vez de deixar o usuário sem texto.
                return .modelUnavailable(model)
            case .audioFormatUnsupported(let description):
                return .engineInternal(description)
            case .runtimeFailure(let description):
                return .engineInternal(description)
            case .cancelled:
                return .cancelled
            }
        case is CancellationError:
            return .cancelled
        default:
            return .engineInternal(error.localizedDescription)
        }
    }
}
