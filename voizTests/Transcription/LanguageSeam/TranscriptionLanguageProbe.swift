import Foundation

// A guarda de idioma do plano de transcrição, metade (a): o **probe** (Q2).
//
// Depende só de Foundation e é `nonisolated` de ponta a ponta, como os contratos da T1.2: compila
// no alvo `voizTests` (por symlink, no padrão da T3.2) e é exercitado inteiro sem áudio real, sem
// motor e sem view model.
//
// ## Por que este arquivo existe
//
// A Q2 promoveu o Apple SpeechAnalyzer a rank 0 do `.meetingFinal`. O motor é bom e é ~20× mais
// barato, mas o locale dele é **fixo**: fala que não é do locale não sai degradada, sai **ausente**.
// Na reunião real 7FCA o `transcriptionPlan` estava em `language=en` com fala pt-BR nos dois canais
// — o Whisper produziu uma quasi-tradução inglesa plausível e infiel (ruim, porém invisível), e o
// Apple, no mesmo material, devolveria vazio (pior, porém visível). A promoção do rank 0 foi
// aprovada **condicionada** a esta guarda; sem ela, a Q2 troca um erro silencioso por um transcript
// em branco.
//
// A guarda tem duas metades independentes, e é de propósito que sejam duas:
// - **(a) probe**, aqui: mede o idioma **antes** de o plano valer, sobre os primeiros ~30 s de fala.
//   Com `selectedLanguage` **explícito** a medição é só diagnóstico: o idioma do usuário é
//   soberano (Daily B5ACC / 7FCA com pt explícito). Auto (`language == nil`) **não** gera
//   probe — detecção por lote, reunião bilíngue intacta. Um locale já adotado
//   (`languageOrigin == .autoAdopted`) ainda pode ser corrigido.
// - **(b) evidência**, em `TranscriptionLanguageGuard`: reage ao que o pós-call já observou (lote
//   com fala medida e texto vazio) e tenta o outro locale antes de aceitar o vazio. Também só
//   adota quando a origem não é explícita.
//
// ## O que NÃO mora aqui
//
// I/O, `Task`, coordenador e sessão. Este arquivo decide; quem executa é o fluxo da reunião, cujos
// arquivos (`Meeting*`) estão sob mutex de outro executor. O ponto de integração está descrito em
// `TranscriptionLanguagePass`.
//
// ## A promoção do Apple e esta guarda são UM pacote
//
// A ordem nova do `.meetingFinal` (Apple rank 0) e esta guarda **não podem chegar separadas**, e
// isso é desenho, não detalhe de processo: sem chamador da guarda, o contraexemplo real da 7FCA
// (plano gravado em `en`, fala pt-BR) faz o Apple devolver **vazio como sucesso** — o coordenador
// não cai para o Whisper, porque texto vazio não é falha, e a reunião inteira pode terminar em
// branco sem um único erro. Foi o CRITICO da review do Farol em `dca8229`; a resposta é integrar
// atomicamente, com a integração do fluxo de reunião pousando em cima deste branch.

/// Junta áudio até ter **fala** suficiente para valer a pena perguntar o idioma.
///
/// ## Por que contar fala, e não tempo
///
/// Um probe de 30 s de relógio numa reunião que começa com "só um minuto, deixa eu compartilhar a
/// tela" mede silêncio, e silêncio não tem idioma: o Whisper responde qualquer coisa com confiança,
/// e uma correção errada de plano é pior que nenhuma. Então o critério é **segundos de fala**,
/// medidos por frame com o mesmo limiar de RMS que o leitor de lotes da reunião já usa para descartar
/// silêncio (0,003).
///
/// ## Por que os frames audíveis são concatenados
///
/// O que sobra no buffer é a fala, colada, sem os silêncios. Para reconhecimento isso seria uma
/// falsificação do tempo; para **detecção de idioma** é melhor material pelo mesmo motivo que
/// motiva o corte: o Whisper decide o idioma na primeira janela de mel, e 30 s de fala real
/// informam mais que 30 s com 25 s de silêncio. Os offsets do probe não são usados por ninguém —
/// ele devolve um idioma, não texto.
///
/// ## Os três desfechos
///
/// - `isReady` com `targetSpeechSeconds` de fala: o caso normal.
/// - `isReady` porque a **janela** expirou e há ao menos `minimumSpeechSeconds`: reunião com muita
///   pausa. Probe com menos material é pior que com 30 s e melhor que nenhum.
/// - `isExhausted`: a janela expirou sem fala suficiente. Não há o que medir, e insistir só
///   atrasaria o plano; quem fica de guarda nesse caso é a metade (b).
///
/// ## A janela conta TIMELINE, a fala conta áudio — e a reunião tem dois canais
///
/// O pós-call alimenta este acumulador com lotes de **duas** fontes (microfone e áudio do sistema)
/// que cobrem o MESMO intervalo de tempo. Se a janela somasse a duração dos blocos, 26 s de reunião
/// contariam como 52 s e a janela de 120 s fecharia na metade do tempo real (achado do Pistão na
/// combinação do contrato de integração). Por isso `append(_:timeline:)`: com a posição do bloco, a
/// janela é a **extensão** coberta (maior fim menos menor início), e dois canais no mesmo intervalo
/// contam uma vez.
///
/// A **fala**, ao contrário, soma os dois canais de propósito: material de detecção é melhor com as
/// duas vozes que com uma, e alimentar só o microfone jogaria fora justamente a reunião em que quem
/// fala primeiro é o participante remoto. O alvo de 30 s corta o excesso sozinho.
///
/// Sem `timeline` (o caminho ao vivo: um canal, tempo real, blocos pequenos) a soma das amostras
/// **é** o tempo de timeline, e o comportamento é o mesmo de antes.
nonisolated struct TranscriptionLanguageProbeAccumulator: Sendable, Equatable {
    /// Quanta fala o probe quer antes de rodar. 30 s é a janela de contexto do Whisper: mais que
    /// isso não melhora a detecção, só ocupa memória.
    var targetSpeechSeconds: TimeInterval
    /// O mínimo aceitável quando a janela expira antes de juntar o alvo.
    var minimumSpeechSeconds: TimeInterval
    /// Quanto áudio (fala **e** silêncio) pode passar antes de o probe parar de esperar mais fala.
    var windowSeconds: TimeInterval
    var sampleRate: Double
    /// O mesmo limiar do leitor de lotes da reunião (`audibleRMSThreshold = 0.003`). O número é
    /// repetido aqui, e não referenciado, porque lá ele é privado de um arquivo que não compila no
    /// alvo de testes; se um dia divergirem, o sintoma é o probe medir fala onde o leitor mediu
    /// silêncio.
    var audibleRMSThreshold: Float
    /// Tamanho do frame da decisão audível/silencioso.
    var frameSeconds: TimeInterval

    /// Só os frames audíveis, na ordem em que chegaram. Limitado a `targetSpeechSeconds`.
    private(set) var speech: [Float] = []
    /// Áudio observado **sem** posição na timeline (caminho ao vivo).
    private(set) var untimedSeconds: TimeInterval = 0
    /// Menor início e maior fim entre os blocos que trouxeram posição.
    private(set) var timelineStart: TimeInterval?
    private(set) var timelineEnd: TimeInterval?

    init(
        targetSpeechSeconds: TimeInterval = 30,
        minimumSpeechSeconds: TimeInterval = 8,
        windowSeconds: TimeInterval = 120,
        sampleRate: Double = TranscriptionAudio.defaultSampleRate,
        audibleRMSThreshold: Float = TranscriptionLanguageGuard.defaultAudibleRMSThreshold,
        frameSeconds: TimeInterval = TranscriptionLanguageGuard.defaultFrameSeconds
    ) {
        self.targetSpeechSeconds = max(0, targetSpeechSeconds)
        self.minimumSpeechSeconds = max(0, min(minimumSpeechSeconds, max(0, targetSpeechSeconds)))
        self.windowSeconds = max(0, windowSeconds)
        self.sampleRate = sampleRate > 0 ? sampleRate : TranscriptionAudio.defaultSampleRate
        self.audibleRMSThreshold = audibleRMSThreshold
        self.frameSeconds = frameSeconds > 0 ? frameSeconds : TranscriptionLanguageGuard.defaultFrameSeconds
    }

    /// Segundos de fala já acumulados. Soma os canais — ver a nota da janela acima.
    var speechSeconds: TimeInterval {
        TimeInterval(Double(speech.count) / sampleRate)
    }

    /// Quanto tempo de reunião este acumulador já viu. É o que faz a janela expirar.
    ///
    /// Extensão da timeline coberta pelos blocos posicionados, mais o áudio que veio sem posição.
    /// As duas parcelas coexistem porque cada caminho usa uma só; somar mantém a resposta correta
    /// nos dois em vez de exigir um modo.
    var observedSeconds: TimeInterval {
        let span: TimeInterval
        if let start = timelineStart, let end = timelineEnd {
            span = max(0, end - start)
        } else {
            span = 0
        }
        return span + untimedSeconds
    }

    /// Já dá para perguntar o idioma?
    var isReady: Bool {
        if speechSeconds >= targetSpeechSeconds && targetSpeechSeconds > 0 { return true }
        return observedSeconds >= windowSeconds && speechSeconds >= minimumSpeechSeconds
    }

    /// A janela acabou sem fala suficiente — este probe não vai acontecer.
    var isExhausted: Bool {
        observedSeconds >= windowSeconds && speechSeconds < minimumSpeechSeconds
    }

    /// O áudio do probe, quando há o bastante. `nil` = continue alimentando (ou desista, se
    /// `isExhausted`).
    var probeAudio: TranscriptionAudio? {
        guard isReady else { return nil }
        return TranscriptionAudio(samples: speech, sampleRate: sampleRate)
    }

    /// Acumula um bloco de áudio, guardando só os frames audíveis.
    ///
    /// Idempotente em relação ao alvo: depois de `targetSpeechSeconds` de fala nada mais é copiado,
    /// então alimentar o acumulador em excesso custa a medição do RMS e não memória. Isso importa
    /// porque o chamador natural é um callback de captura que roda durante a reunião inteira.
    ///
    /// - Parameter timeline: a posição do bloco na reunião (`início..<fim`). Passe sempre que ela
    ///   existir — no pós-call ela existe, e é o que impede dois canais de dobrarem a janela. `nil`
    ///   é para o caminho ao vivo, onde a duração do bloco é o próprio avanço do relógio.
    mutating func append(_ samples: [Float], timeline: Range<TimeInterval>? = nil) {
        guard !samples.isEmpty else { return }
        if let timeline {
            timelineStart = min(timelineStart ?? timeline.lowerBound, timeline.lowerBound)
            timelineEnd = max(timelineEnd ?? timeline.upperBound, timeline.upperBound)
        } else {
            untimedSeconds += TimeInterval(Double(samples.count) / sampleRate)
        }
        guard speechSeconds < targetSpeechSeconds else { return }

        let framesPerChunk = max(1, Int(frameSeconds * sampleRate))
        let limit = Int(targetSpeechSeconds * sampleRate)
        var index = 0
        while index < samples.count, speech.count < limit {
            let end = min(index + framesPerChunk, samples.count)
            if TranscriptionLanguageGuard.isAudible(
                samples[index..<end],
                threshold: audibleRMSThreshold
            ) {
                let room = limit - speech.count
                let taken = min(room, end - index)
                speech.append(contentsOf: samples[index..<(index + taken)])
            }
            index = end
        }
    }

    /// O áudio disponível quando **não vai chegar mais** (a gravação parou, o arquivo acabou).
    ///
    /// Aceita a partir de `minimumSpeechSeconds`, sem esperar a janela: a espera existia para dar
    /// chance de juntar mais fala, e agora não há mais de onde.
    var finalProbeAudio: TranscriptionAudio? {
        guard speechSeconds >= minimumSpeechSeconds, !speech.isEmpty else { return nil }
        return TranscriptionAudio(samples: speech, sampleRate: sampleRate)
    }
}

/// As decisões do probe de idioma: quem pode responder, o que pedir a ele, e o que fazer com a
/// resposta.
nonisolated enum TranscriptionLanguageProbe {

    // MARK: - Quem detecta idioma de verdade

    /// Os motores cuja resposta de idioma é uma **medição**.
    ///
    /// Só o WhisperKit. Não é conservadorismo: é o que o código dos motores diz.
    /// - `WhisperKitTranscriptionEngine.makeResult` reporta `requestedLanguageCode ?? output.language`
    ///   — com `language: nil` no pedido, o que volta é a detecção do próprio Whisper.
    /// - `ParakeetTranscriptionEngine` devolve `request.language ?? .portuguese`, e o descritor dele
    ///   ainda declara `detectsLanguageAutomatically: true`. Ou seja: pedir detecção ao Parakeet
    ///   responde "português" para qualquer áudio, inclusive um inglês perfeito. Tratar isso como
    ///   detecção transformaria a guarda numa máquina de fixar pt-BR.
    /// - `AppleSpeechAnalyzerEngine` devolve o `locale.language` do modelo, que é o que foi pedido.
    ///
    /// Por isso a checagem é por lista explícita, e não por `descriptor.detectsLanguageAutomatically`:
    /// a flag do descritor responde "posso receber um pedido sem idioma?", e não "eu sei dizer qual
    /// idioma ouvi?". As duas perguntas coincidem hoje só no Whisper.
    static let detectingEngines: Set<TranscriptionEngineID> = [.whisperKit]

    /// A política de retry do probe.
    ///
    /// `recordsGlobalFailure: false` é o ponto: o probe é cortesia, exatamente como o `warmUp`, e
    /// não pode gastar a política de retry de quem vai transcrever de verdade. Sem isso, um probe
    /// que falhasse ao preparar o Whisper escreveria supressão em `(.meetingFinal, whisperkit,
    /// small)` com o cooldown da reunião inteira — e derrubaria o **fallback** do plano antes do
    /// primeiro lote. Uma tentativa só, pelo mesmo motivo. O `failureCooldown` fica no default e é
    /// inerte: sem registro, não há o que expirar.
    ///
    /// **O que esta política NÃO faz, e por isso a ordem da integração importa:** ela impede
    /// **escrever** supressão, não **ler**. O laço do coordenador consulta `failures[key]` antes de
    /// tocar no motor e pula o candidato com `stage == .suppressed`, então um registro deixado por
    /// uma passagem anterior faria o probe voltar inconclusivo sem nem tentar — e a guarda ficaria
    /// muda exatamente na segunda tentativa do usuário, que é quando ela mais importa. Por isso
    /// `clearFailures(useCase: .meetingFinal)` **tem** que preceder o probe (achado do Farol; a
    /// reabertura por passagem já existe no topo de `transcribeRecordedAudio` desde a T2.5).
    static let retryPolicy = TranscriptionRetryPolicy(
        attemptsPerCandidate: 1,
        recordsGlobalFailure: false
    )

    /// O plano do probe: **um** candidato, sempre um motor que detecta, sempre `strict`.
    ///
    /// - `strict` porque um probe não pode ter fallback: o segundo candidato do plano da reunião é
    ///   um motor de locale fixo, e mandar a ele um pedido com `language: nil` só produz
    ///   `.languageUnsupported`. Strict transforma "não deu" em "não deu" em vez de numa cascata.
    /// - O modelo sai do **snapshot** quando o Whisper já está no plano da reunião, e é essa linha
    ///   que evita o custo escondido: pedir `small` enquanto o plano usa `large-v3-turbo` faria o
    ///   motor descarregar o residente para carregar o outro (`runLoad` evicta antes de carregar) e
    ///   o primeiro lote pagaria a recarga. Só quando o Whisper não está no plano é que o probe cai
    ///   no `defaultModel` do catálogo.
    /// - `nil` quando não há o que corrigir: plano vazio, ou plano em auto (`language == nil`).
    ///   Auto detecta por lote e não congela um idioma único (reunião bilíngue). Plano com
    ///   idioma explícito gera probe só para logar discrepância; a decisão não adota.
    ///
    /// O `useCase` vem do snapshot, e não fixo em `.meetingFinal`, porque o coordenador rejeita
    /// plano de um caso de uso usado em pedido de outro (`planMismatch`): quem monta o pedido usa
    /// este mesmo campo.
    static func plan(
        from snapshot: TranscriptionPlanSnapshot,
        catalog: TranscriptionCatalog = .shipping
    ) -> TranscriptionRoutingPlan? {
        guard snapshot.language != nil, !snapshot.isEmpty else { return nil }
        guard let candidate = probeCandidate(from: snapshot, catalog: catalog) else { return nil }
        return TranscriptionRoutingPlan(
            useCase: snapshot.useCase,
            candidates: [candidate],
            rejections: [],
            isStrict: true
        )
    }

    /// O motor+modelo que vai responder o idioma.
    private static func probeCandidate(
        from snapshot: TranscriptionPlanSnapshot,
        catalog: TranscriptionCatalog
    ) -> TranscriptionRoutingCandidate? {
        let planned = snapshot.candidates
            .sorted { $0.rank < $1.rank }
            .first { detectingEngines.contains($0.engine) }
        if let planned {
            return TranscriptionRoutingCandidate(
                engine: planned.engine,
                model: planned.model,
                rank: 0,
                origin: .automatic
            )
        }
        for engine in catalog.engines where detectingEngines.contains(engine.engine) {
            guard let model = engine.defaultModel ?? engine.models.first?.id else { continue }
            return TranscriptionRoutingCandidate(
                engine: engine.engine,
                model: model,
                rank: 0,
                origin: .automatic
            )
        }
        return nil
    }

    // MARK: - O que fazer com a resposta

    /// Por que o probe **não** mexeu no plano.
    nonisolated enum KeepReason: Sendable, Equatable {
        /// O idioma medido é o do plano. O caso feliz e o mais comum.
        case detectionMatchesPlan
        /// O plano não fixa idioma e não houve detecção servível para adotar.
        case planHasNoLanguage
        /// O usuário escolheu pt/en: a detecção discordante não manda no plano.
        case explicitLanguageIsSovereign(detected: TranscriptionLanguage)
        /// O motor não devolveu idioma nenhum.
        case noDetection
        /// Quem respondeu não é um detector — ver `detectingEngines`.
        case engineDoesNotDetect(TranscriptionEngineID)
        /// Medimos um idioma que nenhum motor do catálogo fala (um `fr` numa reunião em francês).
        /// Corrigir o plano para ele deixaria a reunião sem candidato nenhum; melhor seguir com o
        /// plano imperfeito, que ao menos transcreve.
        case detectionUnsupported(TranscriptionLanguage)
    }

    nonisolated enum Decision: Sendable, Equatable {
        case keepsPlan(KeepReason)
        case corrects(to: TranscriptionLanguage)

        var correctedLanguage: TranscriptionLanguage? {
            switch self {
            case .corrects(let language): return language
            case .keepsPlan: return nil
            }
        }
    }

    /// A resposta do probe virou correção de plano?
    ///
    /// Idioma **explícito** (`languageOrigin == .explicit`) é soberano: a detecção no máximo
    /// discorda no log. Auto (`planned == nil`) não congela — detecção por lote. Um locale
    /// já adotado (`.autoAdopted`) ainda pode ser corrigido.
    ///
    /// - Parameters:
    ///   - detected: `TranscriptionEngineResult.detectedLanguage` do pedido de probe.
    ///   - reportedBy: o motor que produziu a resposta — a proveniência do resultado, e não o
    ///     candidato que se pretendia usar. É o único jeito honesto de aplicar `detectingEngines`:
    ///     num plano não-strict o coordenador pode ter caído para outro motor, e a resposta dele
    ///     não é uma medição.
    ///   - planned: o idioma que o plano fixou (`nil` = auto).
    ///   - languageIsExplicit: lê `languageOrigin`, nunca `planned != nil`.
    static func decision(
        detected: TranscriptionLanguage?,
        reportedBy engine: TranscriptionEngineID,
        planned: TranscriptionLanguage?,
        languageIsExplicit: Bool = true,
        catalog: TranscriptionCatalog = .shipping
    ) -> Decision {
        guard detectingEngines.contains(engine) else { return .keepsPlan(.engineDoesNotDetect(engine)) }
        guard let detected, !detected.rawValue.isEmpty else {
            return .keepsPlan(planned == nil ? .planHasNoLanguage : .noDetection)
        }
        guard let target = TranscriptionLanguageGuard.correctionTarget(for: detected, in: catalog) else {
            return .keepsPlan(.detectionUnsupported(detected))
        }
        guard let planned else {
            return .keepsPlan(.planHasNoLanguage)
        }
        // `matches` nos dois sentidos: o plano da reunião fala em código primário (`pt`, `en`,
        // vindos de `Language.transcriptionLanguage`) e um motor pode responder com região.
        if planned.matches(detected) || detected.matches(planned)
            || planned.matches(target) || target.matches(planned) {
            return .keepsPlan(.detectionMatchesPlan)
        }
        if languageIsExplicit {
            return .keepsPlan(.explicitLanguageIsSovereign(detected: detected))
        }
        return .corrects(to: target)
    }

    /// A linha de log do probe. Só idiomas, ids e segundos — nunca o texto que o probe produziu.
    ///
    /// O probe transcreve de verdade para descobrir o idioma, então o resultado dele **contém**
    /// fala reconhecida; nada nesta função recebe esse texto, e é por isso que ela existe em vez de
    /// o chamador montar a frase (PLANO, regra 7).
    static func logSummary(
        _ decision: Decision,
        planned: TranscriptionLanguage?,
        speechSeconds: TimeInterval
    ) -> String {
        let material = String(format: "%.0f s de fala", speechSeconds)
        let plannedText = planned?.rawValue ?? "automático"
        switch decision {
        case .corrects(let language):
            return "Idioma da reunião corrigido pelo probe: \(plannedText) → \(language.rawValue) (\(material))"
        case .keepsPlan(let reason):
            let why: String
            switch reason {
            case .detectionMatchesPlan: why = "confirmado"
            case .planHasNoLanguage: why = "plano em detecção automática"
            case .explicitLanguageIsSovereign(let detected):
                why = "seleção explícita (detecção \(detected.rawValue) ignorada)"
            case .noDetection: why = "sem detecção"
            case .engineDoesNotDetect(let engine): why = "\(engine) não detecta idioma"
            case .detectionUnsupported(let language): why = "\(language.rawValue) não é suportado"
            }
            return "Idioma da reunião mantido em \(plannedText): \(why) (\(material))"
        }
    }
}
