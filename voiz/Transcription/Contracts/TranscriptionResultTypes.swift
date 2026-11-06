import Foundation

/// Um trecho reconhecido, com os tempos relativos ao início do áudio pedido.
///
/// Os tempos são do **áudio**, não do relógio da captura: quem precisa de horário de parede
/// (os turns da reunião) soma o instante em que o lote começou. Guardar `Date` aqui obrigaria
/// todo motor a conhecer o momento da gravação, que ele não tem.
nonisolated struct TranscriptionTextSegment: Sendable, Equatable, Hashable, Codable {
    var text: String
    /// Início em segundos, relativo ao começo do áudio do pedido.
    var start: TimeInterval
    var end: TimeInterval
    /// Confiança do motor, quando ele reporta alguma. Escalas diferentes entre motores —
    /// serve para ordenar dentro do mesmo motor, não para comparar motores.
    var confidence: Float?

    init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    var duration: TimeInterval { max(0, end - start) }
}

/// De onde veio um texto: qual motor, qual modelo, se foi a primeira escolha ou um fallback.
///
/// Existe para o app conseguir responder "por que este trecho saiu pior que o outro?" meses
/// depois — por isso é `Codable` e usa ids estáveis. **Não** contém texto transcrito: ela vai
/// para logs e telemetria local, onde transcript é proibido.
nonisolated struct TranscriptionProvenance: Sendable, Equatable, Hashable, Codable {
    var engine: TranscriptionEngineID
    var model: TranscriptionModelID
    var useCase: TranscriptionUseCase
    /// A escolha veio do usuário ou da política automática?
    var origin: TranscriptionSelectionOrigin
    /// Posição do candidato no plano do roteador: 0 é a primeira escolha, 1+ é fallback.
    var candidateRank: Int
    /// Actual recognition module when an engine has more than one implementation.
    var recognizer: String?

    init(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID,
        useCase: TranscriptionUseCase,
        origin: TranscriptionSelectionOrigin,
        candidateRank: Int,
        recognizer: String? = nil
    ) {
        self.engine = engine
        self.model = model
        self.useCase = useCase
        self.origin = origin
        self.candidateRank = candidateRank
        self.recognizer = recognizer
    }

    /// A proveniência de um candidato que o coordenador de fato executou.
    init(candidate: TranscriptionRoutingCandidate, useCase: TranscriptionUseCase) {
        self.init(
            engine: candidate.engine,
            model: candidate.model,
            useCase: useCase,
            origin: candidate.origin,
            candidateRank: candidate.rank
        )
    }

    /// O resultado veio de um fallback, e não da primeira escolha do plano. É o que acende o
    /// aviso na UI ("transcrito com X porque Y falhou") na Onda 2.
    var isFallback: Bool { candidateRank > 0 }
}

/// Quem escolheu o motor: o usuário (seleção manual nas Configurações) ou a política automática.
nonisolated enum TranscriptionSelectionOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case userSelection
    case automatic
}

/// O que um motor em lote devolve.
///
/// `text` é o texto final já pronto para a tela; `segments` é o detalhamento opcional (alguns
/// motores não segmentam). Manter os dois evita que cada chamador remonte o texto por conta
/// própria e chegue a resultados diferentes.
nonisolated struct TranscriptionEngineResult: Sendable, Equatable {
    var text: String
    var segments: [TranscriptionTextSegment]
    /// Idioma que o motor diz ter ouvido; `nil` quando ele não detecta idioma.
    var detectedLanguage: TranscriptionLanguage?
    var provenance: TranscriptionProvenance
    /// Tempo de parede gasto pelo motor. Alimenta o RTFx do benchmark da Onda 3.
    var processingTime: TimeInterval
    /// Count only, never vocabulary contents in provenance/logs. Nil = unsupported/not used.
    var vocabularyTermsUsed: Int?
    var unadaptedText: String?

    init(
        text: String,
        segments: [TranscriptionTextSegment] = [],
        detectedLanguage: TranscriptionLanguage? = nil,
        provenance: TranscriptionProvenance,
        processingTime: TimeInterval = 0,
        vocabularyTermsUsed: Int? = nil,
        unadaptedText: String? = nil
    ) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.provenance = provenance
        self.processingTime = processingTime
        self.vocabularyTermsUsed = vocabularyTermsUsed
        self.unadaptedText = unadaptedText
    }
}

/// As mensagens de log que falam **sobre** texto reconhecido, sem carregar o texto.
///
/// A regra 7 do PLANO é "logs sem texto transcrito", e a review da T2.4b mostrou que o caminho
/// legado a violava de três jeitos ao mesmo tempo: a transcrição inteira, um prefixo dela e um
/// prefixo da tradução iam para o console de debug **e** para o stdout. Paridade de log não vale
/// mais que a regra (decisão do Maestro registrada em DECISOES) — o que a migração preserva é a
/// informação operacional (houve texto? quanto? quanto demorou? qual motor?), não o conteúdo.
///
/// Cobre a **tradução** também, e não só a transcrição, porque a regra é sobre conteúdo e não
/// sobre procedência: o texto traduzido é derivado palavra a palavra do que o usuário falou.
///
/// Existir como funções puras aqui — e não como interpolação solta no view model — é o que torna a
/// regra **testável**: a suíte manda um texto-sentinela por cada construtor e reprova se qualquer
/// pedaço dele aparecer na saída. Um construtor novo sem guarda é um buraco, então todo construtor
/// que aceite texto do usuário entra aqui e ganha um caso no teste.
///
/// Cobre o **caminho inteiro**, não só a camada de cima: as mensagens do `TranslationService` (o
/// serviço que fala com o provedor) nascem aqui pelo mesmo motivo que as do view model — foi
/// exatamente uma camada abaixo que o vazamento sobreviveu à primeira correção.
nonisolated enum TranscriptionLogRedaction {

    /// A única forma em que texto do usuário pode aparecer num log: o tamanho dele.
    static func redacted(_ text: String) -> String {
        "\(text.count) caracteres"
    }

    /// Trecho transcrito com sucesso, com a proveniência de quem o produziu.
    ///
    /// A proveniência é só id de motor/modelo e posição no plano — por contrato ela nunca carrega
    /// texto (ver `TranscriptionProvenance`).
    static func transcribedChunk(_ text: String, provenance: TranscriptionProvenance) -> String {
        "✅ Trecho transcrito: \(redacted(text)) — \(provenance.engine)/\(provenance.model) rank \(provenance.candidateRank)"
    }

    /// Um trecho entrou na fila de tradução.
    static func translating(_ text: String) -> String {
        "🌐 Traduzindo trecho: \(redacted(text))"
    }

    /// Um trecho voltou traduzido, com a latência do provedor.
    static func translated(_ text: String, latency: TimeInterval) -> String {
        "✅ Trecho traduzido: \(redacted(text)) em \(Int(latency * 1000))ms"
    }

    /// O texto final foi para a área de transferência.
    static func copiedToPasteboard(_ text: String) -> String {
        "📋 Texto copiado para a área de transferência: \(redacted(text))"
    }

    // MARK: - O caminho do provedor de tradução

    // A re-review r2 do Farol mostrou que redigir o view model não bastava: o vazamento tinha
    // descido uma camada. `TranslationService.translate` — que é quem o view model migrado chama a
    // cada trecho de 1,2 s — imprimia em stdout o `prefix(50)` do transcript, o `prefix(50)` da
    // tradução derivada dele e o `prefix(10)` da chave do provedor. Toda tradução real vazava, e a
    // suíte não via porque testava só os construtores novos, sem atravessar as mensagens que o
    // serviço de fato imprime.
    //
    // Por isso TODA mensagem do serviço nasce aqui, mesmo as que hoje não tocariam em texto nenhum
    // (troca de modelo, troca de provedor, rota de idiomas): a guarda que o `TranslationService`
    // ganhou é "todo `print` do arquivo é uma chamada de redação, sem interpolação solta", e ela só
    // é verificável se não sobrar nenhuma exceção para o próximo `print` se pendurar.

    /// O modelo de tradução mudou nas Configurações. Id de modelo não é conteúdo do usuário.
    static func translationModelChanged(to model: String) -> String {
        "🔄 Modelo de tradução: \(model)"
    }

    /// O provedor de tradução mudou nas Configurações.
    static func translationProviderChanged(to provider: String) -> String {
        "🔄 Provedor de tradução: \(provider)"
    }

    /// Um trecho foi entregue ao provedor de tradução.
    static func translationRequested(_ text: String, provider: String, model: String) -> String {
        "🌐 [TRADUÇÃO] Provedor: \(provider), modelo: \(model), texto: \(redacted(text))"
    }

    /// A chave do provedor, como presença e tamanho — nunca em prefixo mascarado (ver
    /// `SecretLogRedaction`).
    static func translationKey(_ key: String) -> String {
        "🔑 [TRADUÇÃO] Chave do provedor: \(SecretLogRedaction.presence(of: key))"
    }

    /// O par de idiomas do pedido. Nomes de idioma são constantes do app.
    static func translationRoute(from source: String, to target: String) -> String {
        "🌍 [TRADUÇÃO] De: \(source) → Para: \(target)"
    }

    /// O pedido saiu para a rede.
    static func translationSending(to provider: String) -> String {
        "📡 [TRADUÇÃO] Enviando pedido para \(provider)…"
    }

    /// O provedor devolveu a tradução. O texto traduzido é derivado palavra a palavra do que o
    /// usuário falou, então ele obedece à mesma regra do transcript.
    static func translationSucceeded(_ text: String) -> String {
        "✅ [TRADUÇÃO] Tradução recebida: \(redacted(text))"
    }

    /// Uma tradução falhou.
    ///
    /// `kind` é rótulo escrito pelo app (o caso do erro), e é ele que torna a linha acionável.
    /// `detail` é a mensagem que **veio do provedor**, e por isso só o tamanho dela sobrevive: num
    /// erro 400 de filtro de conteúdo o corpo da resposta costuma devolver o prompt que o causou —
    /// e o prompt carrega o transcript inteiro. É conteúdo não confiável no sentido da regra 7:
    /// ninguém no app controla o que o servidor decide ecoar de volta.
    static func translationFailed(kind: String, detail: String) -> String {
        detail.isEmpty
            ? "❌ [TRADUÇÃO] Falhou: \(kind)"
            : "❌ [TRADUÇÃO] Falhou: \(kind) — detalhe do provedor: \(redacted(detail))"
    }

    // MARK: - O caminho do motor local (ditado)

    // A review da T2.4a encontrou o mesmo padrão da T2.4b uma camada abaixo do view model: o
    // `ParakeetTranscriptionService` — que é quem o adapter da T2.2 chama a cada ditado com Parakeet
    // — imprimia `prefix(60)` do texto reconhecido em stdout, e o `TranscriptionViewModel` imprimia
    // `prefix(50)` do mesmo texto ao copiá-lo para a área de transferência. Redigir só o resumo de
    // proveniência não fechava nenhuma das duas bocas.
    //
    // Como no serviço de tradução, TODA mensagem do serviço do motor nasce aqui, inclusive as que
    // hoje não tocam em texto nenhum (criação, carga, carga concluída): a guarda é "todo `print` do
    // arquivo é uma chamada de redação, sem interpolação solta", e ela só é verificável se não
    // sobrar exceção onde o próximo `print` se pendure.

    /// O serviço de um motor local foi criado, ainda sem carregar pesos.
    static func engineCreated(_ engine: String) -> String {
        "🦜 \(engine): serviço criado (carga preguiçosa)"
    }

    /// Começou a carga dos pesos (que na primeira vez inclui download).
    static func engineLoadStarted(_ engine: String) -> String {
        "⏳ \(engine): carregando pesos (download na 1ª vez)…"
    }

    /// Os pesos ficaram residentes.
    static func engineLoadFinished(_ engine: String) -> String {
        "✅ \(engine): pesos carregados"
    }

    /// Os pesos vieram de uma pasta local em vez do download padrão.
    ///
    /// Sem argumento de texto livre e sem o caminho: quem chama informa só o motor. O path expõe o
    /// container do app e não acrescenta nada ao diagnóstico que o próprio fato de ter carregado
    /// local já dá — e é por linhas assim, montadas com interpolação livre, que transcript vaza.
    static func engineUsingLocalWeights(_ engine: String) -> String {
        "📦 \(engine): pesos locais em uso, sem download"
    }

    /// Os pesos específicos não vieram e a carga seguiu com o modelo base.
    ///
    /// Existe para que essa troca NUNCA seja silenciosa: um fallback mudo foi o que fez três
    /// medições de modelos diferentes devolverem o mesmo número na Onda 5. O erro entra como
    /// `any Error` pelo mesmo motivo do `engineLoadFailed`: transcript não cabe num `Error` sem
    /// alguém embrulhar de propósito.
    static func engineLocalWeightsUnavailable(_ engine: String, error: any Error) -> String {
        "⚠️ \(engine): pesos pt-BR indisponíveis (\(error.localizedDescription)); usando o modelo base"
    }

    /// Começou o download dos pesos específicos.
    static func engineDownloadingLocalWeights(_ engine: String) -> String {
        "⬇️ \(engine): baixando pesos pt-BR (só na 1ª vez)…"
    }

    /// A carga falhou.
    ///
    /// O argumento é `any Error`, e não `String`, de propósito: é o que impede que texto reconhecido
    /// caiba aqui por descuido — para vazar, alguém teria que embrulhar o transcript num `Error`.
    /// A descrição sobrevive inteira (ao contrário do `detail` de `translationFailed`) porque ela vem
    /// do carregador de modelos local — caminho de arquivo, espaço em disco, URL do checkpoint —, e
    /// não de um servidor que pode ecoar de volta o prompt que recebeu.
    static func engineLoadFailed(_ engine: String, error: any Error) -> String {
        "❌ \(engine): falha ao carregar — \(error.localizedDescription)"
    }

    /// Um motor terminou um lote: quanto demorou, quão rápido, e **quanto** texto saiu.
    ///
    /// `realTimeFactor` é o RTFx que o motor reporta (segundos de áudio por segundo de trabalho); é
    /// medida de desempenho e não diz nada sobre o conteúdo.
    static func engineFinishedBatch(
        _ text: String,
        engine: String,
        processingTime: TimeInterval,
        realTimeFactor: Double
    ) -> String {
        "⏱️ \(engine): \(String(format: "%.2f", processingTime))s — RTFx "
            + "\(String(format: "%.0f", realTimeFactor))× — \(redacted(text))"
    }

    // MARK: - O caminho da reunião

    // Terceira camada do mesmo padrão, agendada pelo Maestro para a T2.5 depois da review da T2.4a:
    // `MeetingViewModel` imprimia `"\(speakerName): \(text.prefix(80))"` a cada turno do transcript
    // oficial — a violação mais larga das três, porque um pós-call de reunião longa produz dezenas
    // de linhas e cada uma leva 80 caracteres de fala real.

    /// Um turno do transcript oficial da reunião entrou na sessão.
    ///
    /// O **nome do falante saiu** da linha, e a troca por `source` não é cosmética: a Camada 2 do
    /// pós-call (`MeetingSpeakerNamingService`) extrai nomes reais **da conversa** e os escreve em
    /// `speakerName`, então o nome é conteúdo derivado do transcript tanto quanto o texto. A fonte
    /// (microfone × áudio do sistema) responde o que a linha precisava responder — de qual canal o
    /// turno veio — sem carregar nada que a regra 7 proíba.
    static func meetingTurn(
        _ text: String,
        source: String,
        provenance: TranscriptionProvenance
    ) -> String {
        "✅ Turno (\(source)): \(redacted(text)) — "
            + "\(provenance.engine)/\(provenance.model) rank \(provenance.candidateRank)"
    }

    /// Quantos turnos o reconciliador de eco recortou ou removeu.
    ///
    /// O `trimLog` do `MeetingEchoReconciler` traz `prefix(60)` do texto removido em cada linha, e o
    /// view model as imprimia uma a uma. A contagem é a informação operacional (houve recorte? e
    /// quanto?); o conteúdo do que foi recortado é transcript.
    static func meetingEchoTrims(_ count: Int) -> String {
        "✂️ Eco: \(count) turno(s) recortado(s) ou removido(s)"
    }

    /// Finais de mic suprimidos ao vivo (Granola WYSIWYG). Só a contagem —
    /// o texto da fala não entra no log.
    static func meetingLiveEchoSuppressed(_ count: Int) -> String {
        "🔇 Eco ao vivo: \(count) final(is) de mic suprimido(s)"
    }

    /// Quantos falantes o passo de nomes renomeou.
    ///
    /// O mapa `rótulo → nome` ia inteiro para o log. Os nomes saem da conversa (é literalmente o que
    /// aquela camada faz: ler o transcript e achar como as pessoas se chamam), então são conteúdo
    /// derivado — e, ao contrário do texto, são conteúdo que identifica gente.
    static func meetingNamesApplied(_ count: Int) -> String {
        "🙋 Nomes sugeridos: \(count) participante(s)"
    }

    /// Uma etapa de IA da reunião (resumo, nomes, capítulos) falhou.
    ///
    /// Mesmo raciocínio de `translationFailed`, e o mesmo provedor por baixo: `AICompletionService`
    /// embrulha o **corpo da resposta HTTP** na mensagem de erro, e num 400 de filtro de conteúdo
    /// esse corpo costuma devolver o prompt que o causou — que numa reunião é o transcript inteiro.
    /// `kind` é rótulo escrito pelo app e é o que torna a linha acionável; do detalhe só sobrevive o
    /// tamanho.
    static func meetingAssistantFailed(kind: String, detail: String) -> String {
        detail.isEmpty
            ? "❌ \(kind) indisponível"
            : "❌ \(kind) indisponível — detalhe do provedor: \(redacted(detail))"
    }
}

/// O que uma sessão de streaming emite enquanto o usuário fala.
///
/// `partial` é hipótese: **substitui** a hipótese anterior ainda não confirmada. `final`
/// é estável: acrescenta ao texto e nunca volta atrás. Essa separação é o que impede o
/// preview da reunião de repetir frases quando a fonte de áudio troca.
nonisolated enum TranscriptionStreamEvent: Sendable, Equatable {
    case partial(TranscriptionTextSegment)
    case final(TranscriptionTextSegment)
}

/// Falhas que um motor pode reportar de forma que o coordenador entenda.
///
/// O ponto de existir um enum comum é `allowsFallback`: sem ele, o coordenador teria que
/// adivinhar por string de erro se vale tentar o próximo candidato. `engineInternal` leva
/// só uma descrição técnica — nunca texto transcrito.
nonisolated enum TranscriptionEngineFailure: Error, Sendable, Equatable {
    /// Os pesos não estão disponíveis (não baixados, corrompidos, asset do sistema ausente).
    case modelUnavailable(TranscriptionModelID)
    /// O motor não fala o idioma pedido.
    case languageUnsupported(TranscriptionLanguage)
    /// O Mac não atende o mínimo do motor (sem Apple Silicon, sem memória).
    case hardwareUnsupported
    /// Áudio vazio, curto demais ou em taxa que o motor não aceita.
    case invalidAudio(String)
    /// O trabalho foi cancelado (usuário parou a gravação, sessão encerrada).
    case cancelled
    /// Qualquer outra falha do motor, com descrição técnica sem transcript.
    case engineInternal(String)

    /// Vale tentar o próximo candidato do plano?
    ///
    /// `cancelled` não: quem cancelou não quer o texto de outro motor. `invalidAudio` também
    /// não: o áudio ruim seguiria ruim no próximo motor, e reprocessar custa bateria à toa.
    var allowsFallback: Bool {
        switch self {
        case .modelUnavailable, .languageUnsupported, .hardwareUnsupported, .engineInternal:
            return true
        case .invalidAudio, .cancelled:
            return false
        }
    }
}
