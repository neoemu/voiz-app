import Foundation

// A guarda de idioma do plano de transcrição, metade (b) e as peças comuns (Q2).
//
// Só Foundation, `nonisolated` de ponta a ponta, compila no alvo `voizTests` por symlink (padrão da
// T3.2) — o motivo está no cabeçalho de `TranscriptionLanguageProbe.swift`.
//
// Aqui moram três coisas:
// 1. **Retargeting**: reescrever um `TranscriptionPlanSnapshot` para outro idioma sem re-rotear.
// 2. **Evidência**: medir fala num lote e decidir se um texto vazio merece uma tentativa no outro
//    locale antes de ser aceito.
// 3. **A passagem** (`TranscriptionLanguagePass`): o estado das duas metades da guarda numa
//    passagem pelo áudio, para que o fluxo da reunião só faça I/O.

/// As decisões de idioma que não dependem de tela, de áudio nem de disco.
nonisolated enum TranscriptionLanguageGuard {

    // MARK: - Medida de fala

    /// O limiar de RMS que separa fala de silêncio. É o `audibleRMSThreshold` que o leitor de lotes
    /// da reunião já usa (0,003); ver a nota em `TranscriptionLanguageProbeAccumulator`.
    static let defaultAudibleRMSThreshold: Float = 0.003

    /// O frame da decisão audível/silencioso. 100 ms é curto o bastante para uma frase curta no meio
    /// de um lote de 26 s aparecer, e longo o bastante para um clique não virar "fala".
    static let defaultFrameSeconds: TimeInterval = 0.1

    /// Este trecho tem energia de fala?
    ///
    /// A soma dos quadrados é acumulada em `Double` **por regra do módulo de áudio** (DECISOES,
    /// 2026-08-14, item 4): acumulador que anda com o tamanho do material tem que ser `Double`, e
    /// foi um acumulador `Float` que fez o `microphone-clean.caf` de uma reunião de 79 min virar
    /// silêncio absoluto. Aqui o trecho é curto, então a saturação não chegaria — a regra vale de
    /// todo modo, porque quem copiar este laço para um arquivo inteiro não vai reler o comentário.
    static func isAudible(_ samples: ArraySlice<Float>, threshold: Float) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumOfSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        return (sumOfSquares / Double(samples.count)).squareRoot() >= Double(threshold)
    }

    /// Quantos segundos deste bloco são fala.
    ///
    /// Contagem por frame, e não RMS global do bloco: num lote de 26 s com 3 s de fala e o resto de
    /// respiração, o RMS global fica abaixo de qualquer limiar útil e a fala desapareceria da conta.
    /// É exatamente o caso que a metade (b) precisa reconhecer — o lote **tem** fala e o motor
    /// devolveu vazio.
    static func speechSeconds(
        in samples: [Float],
        sampleRate: Double = TranscriptionAudio.defaultSampleRate,
        audibleRMSThreshold: Float = defaultAudibleRMSThreshold,
        frameSeconds: TimeInterval = defaultFrameSeconds
    ) -> TimeInterval {
        guard !samples.isEmpty, sampleRate > 0, frameSeconds > 0 else { return 0 }
        let framesPerChunk = max(1, Int(frameSeconds * sampleRate))
        var audibleSeconds: TimeInterval = 0
        var index = 0
        while index < samples.count {
            let end = min(index + framesPerChunk, samples.count)
            if isAudible(samples[index..<end], threshold: audibleRMSThreshold) {
                // A duração REAL do frame, não `frameSeconds`: o último frame de um bloco costuma
                // ser parcial, e contá-lo cheio inflaria a medida na direção errada (a de disparar
                // uma tentativa extra).
                audibleSeconds += TimeInterval(Double(end - index) / sampleRate)
            }
            index = end
        }
        return audibleSeconds
    }

    // MARK: - Idiomas que o catálogo sabe servir

    /// O idioma no vocabulário canônico do plano: só o código primário (`pt`, `en`).
    ///
    /// O plano da reunião nasce de `Language.transcriptionLanguage`, que dá `pt`/`en`; os motores
    /// declaram desde `pt` até `pt-BR`. Normalizar num lugar só é o que faz `ruledOut` funcionar:
    /// sem isso, um `en-US` marcado como reprovado não impediria uma nova tentativa em `en`.
    static func canonical(_ language: TranscriptionLanguage) -> TranscriptionLanguage {
        TranscriptionLanguage(language.primaryCode)
    }

    /// Os idiomas que **algum** motor do catálogo fala, canônicos e sem repetição, na ordem de
    /// declaração do catálogo.
    ///
    /// Sai do catálogo, e não do `Language` das Configurações, para a guarda não depender de um tipo
    /// de UI — e para que acrescentar um idioma a um motor na Onda 5 já apareça aqui.
    static func servableLanguages(in catalog: TranscriptionCatalog = .shipping) -> [TranscriptionLanguage] {
        var seen: Set<String> = []
        var result: [TranscriptionLanguage] = []
        for engine in catalog.engines {
            for language in engine.supportedLanguages {
                let canonicalLanguage = canonical(language)
                guard !canonicalLanguage.rawValue.isEmpty else { continue }
                if seen.insert(canonicalLanguage.rawValue).inserted {
                    result.append(canonicalLanguage)
                }
            }
        }
        return result
    }

    /// O alvo de uma correção para `detected`, ou `nil` quando nenhum motor fala esse idioma.
    static func correctionTarget(
        for detected: TranscriptionLanguage,
        in catalog: TranscriptionCatalog = .shipping
    ) -> TranscriptionLanguage? {
        let target = canonical(detected)
        guard !target.rawValue.isEmpty else { return nil }
        return catalog.engines.contains { $0.supports(language: target) } ? target : nil
    }

    /// Os outros idiomas que dá para tentar, dado o que o plano usa agora.
    ///
    /// Hoje o catálogo tem dois (`pt`, `en`), então a lista tem um item — mas ela é lista de
    /// propósito: com um terceiro idioma, `ruledOut` faz a guarda tentar o próximo em vez de
    /// desistir, sem mudar uma linha de decisão.
    static func alternates(
        to planned: TranscriptionLanguage,
        in catalog: TranscriptionCatalog = .shipping
    ) -> [TranscriptionLanguage] {
        let current = canonical(planned)
        return servableLanguages(in: catalog).filter { $0.rawValue != current.rawValue }
    }

    // MARK: - Retargeting do plano

    /// O mesmo plano, no outro idioma.
    ///
    /// ## Por que reescrever o snapshot em vez de re-rotear
    ///
    /// Re-rotear leria os Ajustes **de agora**, e o snapshot existe justamente para que uma mudança
    /// nas Configurações durante (ou depois) da call não parta o transcript em dois motores — é a
    /// promessa da T2.5. A correção de idioma precisa mudar **uma** coisa: o locale. Tudo o mais —
    /// a ordem dos motores, o `origin` de cada candidato, o `isStrict`, e portanto a decisão que
    /// foi congelada no início da reunião — continua valendo.
    ///
    /// ## O que muda em cada candidato
    ///
    /// - **Motor multilíngue** (Whisper, Parakeet): o modelo não muda; o idioma viaja no pedido.
    /// - **Motor de locale fixo** (Apple SpeechAnalyzer): o modelo **é** o locale, então o candidato
    ///   troca de modelo (`apple-system-speech.pt-BR` → `…en-US`). Sem esta troca, corrigir o idioma
    ///   deixaria o rank 0 pedindo pt-BR a um pedido em inglês, que é o vazio que a guarda existe
    ///   para evitar.
    /// - **Motor sem modelo para o idioma novo**: o candidato **sai**, e os ranks são renumerados.
    ///   Um plano menor é honesto; um plano com candidato impossível gasta uma tentativa por lote.
    /// - **Motor que este app não conhece** (snapshot escrito por uma versão futura): fica como
    ///   está. Não temos como reescolher o modelo dele, e removê-lo encolheria o plano por
    ///   ignorância. O coordenador já trata isso como `engineMissing` e segue ao próximo.
    ///
    /// ## `origin` só sobrevive se o modelo sobreviver
    ///
    /// É a regra 3 do `TranscriptionRouter` aplicada aqui: quando o modelo que o usuário pinou não
    /// serve, o motor continua no plano mas com `origin == .automatic`, porque o que vai rodar já
    /// não é exatamente o que ele pediu. Mesma situação, mesma resposta — do contrário a
    /// proveniência gravada diria `userSelection` para um modelo que o usuário nunca escolheu.
    ///
    /// - Parameter createdAt: `nil` preserva o instante do congelamento original, que é o que o
    ///   campo significa ("quando esta decisão foi tomada"): o retarget corrige o locale, não
    ///   retoma a decisão. Quem quiser marcar a correção passa uma data.
    static func retargeting(
        _ snapshot: TranscriptionPlanSnapshot,
        to language: TranscriptionLanguage,
        in catalog: TranscriptionCatalog = .shipping,
        createdAt: Date? = nil
    ) -> TranscriptionPlanSnapshot {
        let retargeted = snapshot.candidates
            .sorted { $0.rank < $1.rank }
            .compactMap { candidate -> TranscriptionPlanSnapshot.Candidate? in
                guard let descriptor = catalog.descriptor(for: candidate.engine) else { return candidate }
                if let current = descriptor.model(candidate.model), current.supports(language: language) {
                    return candidate
                }
                guard let replacement = model(of: descriptor, for: language) else { return nil }
                return TranscriptionPlanSnapshot.Candidate(
                    engine: candidate.engine,
                    model: replacement,
                    rank: candidate.rank,
                    origin: .automatic
                )
            }
            .enumerated()
            .map { index, candidate in
                TranscriptionPlanSnapshot.Candidate(
                    engine: candidate.engine,
                    model: candidate.model,
                    rank: index,
                    origin: candidate.origin
                )
            }

        return TranscriptionPlanSnapshot(
            useCase: snapshot.useCase,
            language: language,
            languageOrigin: snapshot.languageOrigin,
            candidates: retargeted,
            isStrict: snapshot.isStrict,
            createdAt: createdAt ?? snapshot.createdAt
        )
    }

    /// O modelo deste motor que serve o idioma: o padrão declarado, se servir; senão o primeiro que
    /// sirva. É a mesma preferência do `automaticModel(of:in:)` do roteador.
    private static func model(
        of descriptor: TranscriptionEngineDescriptor,
        for language: TranscriptionLanguage
    ) -> TranscriptionModelID? {
        let usable = descriptor.models.filter { $0.supports(language: language) }
        if let preferred = descriptor.defaultModel, usable.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return usable.first?.id
    }

    /// A política de retry da **tentativa em outro locale**.
    ///
    /// Uma tentativa, porque ela é experiência e não o transcript: o lote já tem uma resposta (vazia)
    /// e o que se está perguntando é "seria outro locale?". Duas tentativas dobrariam o custo de uma
    /// pergunta.
    ///
    /// ## `recordsGlobalFailure: false`, e a premissa falsa que estava aqui antes
    ///
    /// A primeira versão desta política **registrava** a falha, com este argumento: "a supressão é
    /// por (caso de uso, motor, MODELO), e o candidato da tentativa é outro modelo". A premissa é
    /// falsa, e o contraexemplo estava no arquivo ao lado: `retargeting(_:to:in:)` **preserva** o
    /// modelo dos motores multilíngues — Whisper small e Parakeet mantêm o mesmo `TranscriptionModelID`
    /// quando o locale muda; só o Apple, cujo modelo **é** o locale, troca. E a `FailureKey` do
    /// coordenador não tem idioma nenhum.
    ///
    /// Consequência medida (sonda comportamental do Farol, travada em teste nesta suíte): uma
    /// tentativa em inglês que falhe no Whisper small escreve supressão em `(.meetingFinal,
    /// whisperkit, openai_whisper-small)` com o `failureCooldown` infinito — e o lote **normal**
    /// seguinte, em português, pula o próprio rank 1 do plano como `.suppressed`. Com o Apple no
    /// locale errado devolvendo vazio como sucesso, a passagem inteira pode terminar em branco
    /// depois de gastar o orçamento. Ou seja: a guarda que existe para salvar o transcript passava a
    /// derrubar o fallback dele.
    ///
    /// O que protege sem o registro:
    /// - **o latch interno do motor** (contrato T2.1/T2.2): um modelo cuja carga falhou é re-lançado
    ///   na hora, sem disco nem rede, até troca de modelo ou `unload()`. É ele que faz "não repita o
    ///   download que acabou de falhar" continuar valendo — de graça e sem opinar sobre o plano;
    /// - **o orçamento** de tentativas por passagem, que limita a repetição mesmo no caso em que a
    ///   falha não deixa evidência (`TrialResult.failed`).
    ///
    /// Fica simétrico com `TranscriptionLanguageProbe.retryPolicy`, e pelo mesmo motivo: as duas
    /// são **perguntas**, e pergunta não pode gastar a política de retry de quem vai transcrever. O
    /// `failureCooldown` fica declarado mas inerte — sem registro, não há o que expirar.
    ///
    /// Nunca usar `MeetingTranscription.batchRetryPolicy` aqui: ela existe para o transcript, com
    /// duas tentativas por candidato e supressão que dura a reunião.
    static let trialRetryPolicy = TranscriptionRetryPolicy(
        attemptsPerCandidate: 1,
        failureCooldown: .greatestFiniteMagnitude,
        recordsGlobalFailure: false
    )

    /// A linha de log de um retarget. Só idiomas e ids de motor/modelo (PLANO, regra 7).
    static func retargetLogSummary(
        from previous: TranscriptionPlanSnapshot,
        to corrected: TranscriptionPlanSnapshot
    ) -> String {
        let before = previous.language?.rawValue ?? "automático"
        let after = corrected.language?.rawValue ?? "automático"
        return "Plano da reunião reapontado: \(before) → \(after) (\(corrected.logSummary))"
    }
}

/// A metade (b) da guarda: lote com fala e texto vazio tenta o outro locale antes de aceitar o
/// vazio.
///
/// ## O sinal, e por que ele é confiável
///
/// "Texto vazio" sozinho não diz nada: silêncio também produz texto vazio, e o pós-call inteiro é
/// cheio de trechos assim. O sinal é a **conjunção** — fala medida no áudio (`speechSeconds`) e
/// nenhum texto de volta. Num motor de locale fixo isso é a assinatura exata do locale errado, que
/// é o modo de falhar que a Q2 introduziu ao promover o Apple a rank 0.
///
/// ## As três travas contra ping-pong, em ordem de força
///
/// 1. **`ruledOut` por evidência.** Um locale que já foi tentado e não devolveu nada sai da lista.
///    Até 29/08/2026 o app tinha dois idiomas e uma tentativa frustrada esgotava a lista sozinha;
///    com sete, `ruledOut` deixou de ser o teto e virou só o que impede repetir a MESMA pergunta.
///    Quem limita passou a ser o orçamento, item 3.
/// 2. **Adoção marca o antigo como reprovado.** Quando a tentativa no outro locale **produz** texto,
///    o plano adota o novo e o antigo entra em `ruledOut`. Não existe caminho de volta, então não
///    existe oscilação.
/// 3. **Orçamento por passagem** (`alternateAttemptBudget`). Deixou de ser cinto e passou a ser a
///    trava principal: com sete idiomas servíveis, é ele que impede a passagem de varrer a lista
///    inteira quando há fala e **nenhum** locale devolve texto (música, ruído, um idioma que o app
///    não oferece). Cada tentativa custa uma inferência inteira de lote; dois continua sendo o
///    default, e o custo máximo por passagem segue o mesmo de quando havia dois idiomas.
///
/// A ordem em que os alternativos são tentados é a de declaração do catálogo — português e inglês
/// primeiro. Não é estética: com orçamento 2, os dois primeiros da lista são os únicos que chegam
/// a ser tentados.
///
/// **Este caminho só existe para sessão gravada em automático** (`languageOrigin == .autoAdopted`).
/// Idioma explícito é soberano, e desde 29/08/2026 nenhuma escolha de usuário produz outra coisa.
nonisolated struct TranscriptionLanguageEvidenceGuard: Sendable, Equatable {
    /// Quanta fala um lote precisa ter para que o vazio dele seja suspeito. 1,5 s é mais que uma
    /// interjeição e menos que uma frase.
    var minimumSpeechSeconds: TimeInterval
    var audibleRMSThreshold: Float
    var frameSeconds: TimeInterval
    /// Quantas tentativas em outro locale esta passagem pode gastar.
    var alternateAttemptBudget: Int

    private(set) var spentAttempts: Int = 0
    /// Locales que já se provaram silenciosos neste material, canônicos.
    private(set) var ruledOut: Set<TranscriptionLanguage> = []

    init(
        minimumSpeechSeconds: TimeInterval = 1.5,
        audibleRMSThreshold: Float = TranscriptionLanguageGuard.defaultAudibleRMSThreshold,
        frameSeconds: TimeInterval = TranscriptionLanguageGuard.defaultFrameSeconds,
        alternateAttemptBudget: Int = 2
    ) {
        self.minimumSpeechSeconds = max(0, minimumSpeechSeconds)
        self.audibleRMSThreshold = audibleRMSThreshold
        self.frameSeconds = frameSeconds > 0 ? frameSeconds : TranscriptionLanguageGuard.defaultFrameSeconds
        self.alternateAttemptBudget = max(0, alternateAttemptBudget)
    }

    /// Por que este vazio foi aceito sem tentar outro locale.
    nonisolated enum AcceptReason: Sendable, Equatable {
        /// O lote não tem fala suficiente — vazio é a resposta certa. Carrega os segundos medidos.
        case noSpeechEvidence(TimeInterval)
        /// O plano está em detecção automática: não há locale para trocar.
        case planHasNoLanguage
        /// O usuário escolheu pt/en: lote vazio não autoriza outro locale.
        case explicitLanguageIsSovereign
        /// O catálogo não tem outro idioma para oferecer.
        case noAlternateLanguage
        /// Todos os alternativos já se provaram silenciosos nesta passagem.
        case everyAlternateRuledOut
        /// O orçamento de tentativas da passagem acabou. Carrega quantas foram gastas.
        case budgetSpent(Int)
    }

    nonisolated enum Verdict: Sendable, Equatable {
        /// Rode **o mesmo lote** neste outro idioma antes de aceitar o vazio.
        case tryAlternate(TranscriptionLanguage)
        case acceptEmpty(AcceptReason)
    }

    /// O veredito para um lote que voltou vazio.
    ///
    /// Consome orçamento **só** quando devolve `.tryAlternate` — um veredito que não vira tentativa
    /// não pode gastar o que a próxima tentativa vai precisar.
    mutating func verdict(
        forEmptyBatch samples: [Float],
        sampleRate: Double = TranscriptionAudio.defaultSampleRate,
        planned: TranscriptionLanguage?,
        catalog: TranscriptionCatalog = .shipping
    ) -> Verdict {
        let speech = TranscriptionLanguageGuard.speechSeconds(
            in: samples,
            sampleRate: sampleRate,
            audibleRMSThreshold: audibleRMSThreshold,
            frameSeconds: frameSeconds
        )
        guard speech >= minimumSpeechSeconds, speech > 0 else {
            return .acceptEmpty(.noSpeechEvidence(speech))
        }
        guard let planned else { return .acceptEmpty(.planHasNoLanguage) }

        let alternates = TranscriptionLanguageGuard.alternates(to: planned, in: catalog)
        guard !alternates.isEmpty else { return .acceptEmpty(.noAlternateLanguage) }
        guard let next = alternates.first(where: { !ruledOut.contains(TranscriptionLanguageGuard.canonical($0)) }) else {
            return .acceptEmpty(.everyAlternateRuledOut)
        }
        guard spentAttempts < alternateAttemptBudget else {
            return .acceptEmpty(.budgetSpent(spentAttempts))
        }

        spentAttempts += 1
        return .tryAlternate(next)
    }

    /// O que aconteceu com a tentativa em outro locale.
    ///
    /// Três casos, e não um `Bool`, porque "não veio texto" tem **duas** causas com significados
    /// opostos. Vazio é evidência sobre o idioma; erro é evidência sobre o **motor**. Com um `Bool`,
    /// uma tentativa que lança (asset do locale ausente, falha de preparação, cancelamento) chegaria
    /// aqui como "vazio" e marcaria o locale alternativo como `ruledOut` — fechando pelo resto da
    /// passagem a porta do idioma que pode ser justamente o certo, por um motivo que nada tem a ver
    /// com idioma. Achado da combinação do contrato com o dono do fluxo de reunião.
    nonisolated enum TrialResult: Sendable, Equatable {
        /// Saiu texto: o locale alternativo é o certo.
        case producedText
        /// Rodou e voltou vazio: este locale também não rende neste material.
        case empty
        /// Não rodou (erro do motor, asset ausente, cancelamento). Não diz nada sobre o idioma.
        case failed
    }

    /// O que a tentativa em `alternate` provou.
    nonisolated enum Outcome: Sendable, Equatable {
        /// A tentativa produziu texto: o idioma da passagem passa a ser este.
        case adopts(TranscriptionLanguage)
        /// O plano segue como estava. O vazio deste lote é para valer.
        case keepsPlan
    }

    /// Registra o resultado de uma tentativa em outro locale.
    ///
    /// - Parameter result: o que o chamador observou — só ele viu o resultado. Ver `TrialResult`.
    /// - Parameter replacing: o idioma que estava no plano. Entra em `ruledOut` quando a troca é
    ///   adotada, e é isso que fecha o caminho de volta.
    ///
    /// O que NÃO muda em nenhum dos casos: o orçamento. Ele foi gasto no veredito que autorizou a
    /// tentativa, e é ele que limita a repetição quando o motivo do fracasso foi `.failed` — o único
    /// caso que não deixa evidência nenhuma.
    mutating func note(
        alternate: TranscriptionLanguage,
        result: TrialResult,
        replacing planned: TranscriptionLanguage?
    ) -> Outcome {
        switch result {
        case .producedText:
            if let planned {
                ruledOut.insert(TranscriptionLanguageGuard.canonical(planned))
            }
            return .adopts(TranscriptionLanguageGuard.canonical(alternate))
        case .empty:
            ruledOut.insert(TranscriptionLanguageGuard.canonical(alternate))
            return .keepsPlan
        case .failed:
            return .keepsPlan
        }
    }

    /// A linha de log de um veredito. Idiomas, segundos e contagens — nunca texto.
    static func logSummary(_ verdict: Verdict, planned: TranscriptionLanguage?) -> String {
        let plannedText = planned?.rawValue ?? "automático"
        switch verdict {
        case .tryAlternate(let language):
            return "Lote com fala e texto vazio em \(plannedText): tentando \(language.rawValue) antes de aceitar o vazio"
        case .acceptEmpty(let reason):
            let why: String
            switch reason {
            case .noSpeechEvidence(let seconds):
                why = String(format: "sem fala medida (%.1f s)", seconds)
            case .planHasNoLanguage:
                why = "plano em detecção automática"
            case .explicitLanguageIsSovereign:
                why = "idioma explícito do usuário é soberano"
            case .noAlternateLanguage:
                why = "sem outro idioma no catálogo"
            case .everyAlternateRuledOut:
                why = "os outros idiomas já voltaram vazios nesta passagem"
            case .budgetSpent(let spent):
                why = "orçamento de tentativas esgotado (\(spent))"
            }
            return "Lote vazio aceito em \(plannedText): \(why)"
        }
    }
}

/// O estado das duas metades da guarda numa passagem pelo áudio da reunião.
///
/// Existe para que o fluxo da reunião — que é I/O, `@MainActor` e está sob mutex de outro executor —
/// não precise guardar nem um `Bool` de decisão. Mesma divisão de `MeetingTranscription` e
/// `DictationTranscription`: a decisão sai de lá e vem para cá, e o que sobra lá é chamada de motor
/// e escrita em disco.
///
/// ## A receita de integração (ponto ÚNICO, `transcribeRecordedAudio`)
///
/// Combinada com o dono do `MeetingViewModel` e escrita no vocabulário do contrato **r5** dele: nada
/// aqui grava sessão inteira, e toda escrita é delta sobre releitura por id.
///
/// ```swift
/// // ORDEM OBRIGATÓRIA: a reabertura da passagem vem ANTES do probe. `recordsGlobalFailure: false`
/// // impede o probe de ESCREVER supressão, não de LER a que sobrou de uma passagem anterior — e um
/// // candidato suprimido é pulado sem tocar no motor, o que faria o probe voltar mudo.
/// await coordinator.clearFailures(useCase: .meetingFinal)
///
/// var pass = TranscriptionLanguagePass(snapshot: snapshot)
///
/// // 1. BUFFER + REPLAY. Os leitores são one-pass, então o começo do áudio não pode ser "lido de
/// //    novo": guarde os lotes que você leu, alimente o acumulador com os DOIS canais passando a
/// //    posição de cada um, e depois processe os mesmos lotes bufferizados, na ordem.
/// var buffered: [MeetingAudioChunk] = []
/// var accumulator = TranscriptionLanguageProbeAccumulator()
/// while !accumulator.isReady, !accumulator.isExhausted, let chunk = nextChunkInTimeOrder() {
///     buffered.append(chunk)
///     accumulator.append(chunk.samples, timeline: chunk.startTime..<chunk.endTime)
/// }
///
/// // 2. O probe, UMA vez, com `language: nil` (é assim que o Whisper devolve detecção de verdade).
/// if let probePlan = pass.probePlan,
///    let audio = accumulator.probeAudio ?? accumulator.finalProbeAudio {
///     let probe = try? await coordinator.transcribe(
///         TranscriptionRequest(useCase: .meetingFinal, language: nil, audio: audio),
///         using: probePlan,
///         retryPolicy: TranscriptionLanguageProbe.retryPolicy
///     )
///     let decision = pass.applyProbe(
///         detected: probe?.result.detectedLanguage,
///         reportedBy: probe?.provenance.engine ?? .whisperKit
///     )
///     addDebugLog(TranscriptionLanguageProbe.logSummary(
///         decision, planned: plannedBefore, speechSeconds: accumulator.speechSeconds
///     ))
/// } else {
///     pass.skipProbe()
/// }
/// persistPlanIfCorrected(&pass, sessionId)   // ver abaixo
///
/// // 3. O laço LÊ a passagem a cada lote — `pass.language` e `pass.batchPlan`, nunca um `let`
/// //    capturado antes, senão uma correção adotada no meio não vale para os lotes seguintes.
/// //    `processChunk` precisa DISTINGUIR "veio texto" de "veio vazio" (e de cancelamento) para o
/// //    laço poder repetir exatamente o mesmo lote.
/// case .empty:
///     guard case .tryAlternate(let other) = pass.verdictForEmptyBatch(samples: chunk.samples),
///           let trial = pass.trialPlan(for: other) else { break }   // vazio aceito
///     let result: TranscriptionLanguageEvidenceGuard.TrialResult
///     do {
///         let retry = try await coordinator.transcribe(
///             TranscriptionRequest(useCase: .meetingFinal, language: other, audio: audio),
///             using: trial,
///             retryPolicy: TranscriptionLanguageGuard.trialRetryPolicy
///         )
///         result = retry.text.trimmed.isEmpty ? .empty : .producedText
///         // Persista o turno UMA vez, com a proveniência de QUEM produziu texto (a da tentativa).
///     } catch {
///         result = .failed   // erro não é evidência sobre idioma — ver `TrialResult`
///     }
///     if case .adopts = pass.note(alternate: other, result: result) {
///         persistPlanIfCorrected(&pass, sessionId)
///     }
///
/// // A ÚNICA forma de persistir o plano corrigido: releitura por id + delta de UM campo.
/// func persistPlanIfCorrected(_ pass: inout TranscriptionLanguagePass, _ id: UUID) {
///     guard pass.isCorrected, var fresh = sessionForEditing(id: id) else { return }
///     fresh.transcriptionPlan = pass.snapshot     // e NADA mais
///     updateSession(fresh)
/// }
/// ```
///
/// **Por que a persistência é assim, e não `updateSession(session)`:** entre o começo da passagem e
/// o retorno de um `await` o usuário pode ter digitado notas, renomeado a reunião, movido de pasta
/// ou renomeado um falante. Gravar a cópia anterior ao `await` devolve todos esses campos ao valor
/// velho — é a classe de defeito que consumiu quatro rodadas de review no fluxo de reunião, e a
/// primeira versão desta receita a reintroduzia (MAIOR do Farol em `dca8229`).
///
/// **Uma inferência por vez continua valendo**: probe e tentativa alternativa são `await`
/// sequenciais no mesmo laço, e o coordenador serializa por vaga única. A guarda não cria `Task`
/// nenhuma — de propósito.
///
/// **Modo Granola (Apple streaming) fica FORA deste pacote**, por combinado: lá o locale tem que
/// estar certo no `start` da sessão, e a correção vale para o streaming, não para lotes. A API já
/// serve os dois caminhos — `append` sem `timeline` é o caso ao vivo, com teste de blocos de 50 ms.
///
/// ## O que esta passagem NÃO faz
///
/// Persistir. Ela devolve o snapshot corrigido em `snapshot` e marca `isCorrected`; quem grava na
/// sessão é o fluxo da reunião, que é o dono do store. Foi assim de propósito: escrever em disco a
/// partir de um tipo puro seria o mesmo erro que fez o `TranslationHistoryStore` precisar de quatro
/// rodadas de review.
nonisolated struct TranscriptionLanguagePass: Sendable {
    let catalog: TranscriptionCatalog
    /// O plano vigente. Começa como o snapshot da sessão e muda quando a guarda corrige o idioma.
    private(set) var snapshot: TranscriptionPlanSnapshot
    private(set) var evidence: TranscriptionLanguageEvidenceGuard
    /// Lê `snapshot.languageOrigin`, nunca `language != nil`. Um locale adotado
    /// no auto e persistido continua corrigível após crash/retomada.
    let languageIsExplicit: Bool
    /// O probe desta passagem já foi consumido? Um por passagem, sempre.
    private(set) var hasProbed: Bool = false
    /// O snapshot vigente difere do que a sessão tem gravado — quem persiste é o chamador.
    private(set) var isCorrected: Bool = false

    init(
        snapshot: TranscriptionPlanSnapshot,
        catalog: TranscriptionCatalog = .shipping,
        evidence: TranscriptionLanguageEvidenceGuard = TranscriptionLanguageEvidenceGuard()
    ) {
        self.snapshot = snapshot
        self.catalog = catalog
        self.evidence = evidence
        self.languageIsExplicit = snapshot.languageOrigin == .explicit
    }

    /// O idioma que os pedidos desta passagem devem usar.
    var language: TranscriptionLanguage? { snapshot.language }

    /// O plano que os lotes devem executar; `nil` = snapshot inutilizável (sessão legada), que é o
    /// mesmo critério do `MeetingTranscription.batchPlan(from:)` — de propósito a mesma função, para
    /// não existirem duas definições de "plano utilizável".
    var batchPlan: TranscriptionRoutingPlan? {
        MeetingTranscription.batchPlan(from: snapshot)
    }

    /// O plano do probe, ou `nil` quando ele já rodou (ou não há o que corrigir).
    var probePlan: TranscriptionRoutingPlan? {
        guard !hasProbed else { return nil }
        return TranscriptionLanguageProbe.plan(from: snapshot, catalog: catalog)
    }

    /// Aplica a resposta do probe. Marca o probe como consumido **haja o que houver**: probe que
    /// falha, não conclui ou confirma o plano não pode ser repetido a cada lote.
    @discardableResult
    mutating func applyProbe(
        detected: TranscriptionLanguage?,
        reportedBy engine: TranscriptionEngineID
    ) -> TranscriptionLanguageProbe.Decision {
        hasProbed = true
        let decision = TranscriptionLanguageProbe.decision(
            detected: detected,
            reportedBy: engine,
            planned: snapshot.language,
            languageIsExplicit: languageIsExplicit,
            catalog: catalog
        )
        if let corrected = decision.correctedLanguage {
            adopt(corrected)
        }
        return decision
    }

    /// O probe não vai acontecer (sem fala suficiente, sem motor, erro). Fecha a porta sem mexer no
    /// plano, para a metade (b) assumir daqui.
    mutating func skipProbe() {
        hasProbed = true
    }

    /// O veredito da metade (b) para um lote que voltou vazio.
    mutating func verdictForEmptyBatch(
        samples: [Float],
        sampleRate: Double = TranscriptionAudio.defaultSampleRate
    ) -> TranscriptionLanguageEvidenceGuard.Verdict {
        if languageIsExplicit {
            return .acceptEmpty(.explicitLanguageIsSovereign)
        }
        return evidence.verdict(
            forEmptyBatch: samples,
            sampleRate: sampleRate,
            planned: snapshot.language,
            catalog: catalog
        )
    }

    /// O plano para **experimentar** um lote em outro idioma, sem adotar nada.
    ///
    /// Separado da adoção porque a evidência é o resultado: só depois de ver se saiu texto é que se
    /// sabe qual dos dois locales estava certo. Adotar antes de saber seria trocar o plano da
    /// reunião por um palpite.
    func trialPlan(for language: TranscriptionLanguage) -> TranscriptionRoutingPlan? {
        MeetingTranscription.batchPlan(
            from: TranscriptionLanguageGuard.retargeting(snapshot, to: language, in: catalog)
        )
    }

    /// Registra o resultado da tentativa e adota o idioma novo quando ele produziu texto.
    ///
    /// Idioma explícito nunca adota, mesmo que o chamador ignore o veredito e registre um
    /// trial — a soberania não depende de um único gate.
    @discardableResult
    mutating func note(
        alternate: TranscriptionLanguage,
        result: TranscriptionLanguageEvidenceGuard.TrialResult
    ) -> TranscriptionLanguageEvidenceGuard.Outcome {
        guard !languageIsExplicit else { return .keepsPlan }
        let outcome = evidence.note(
            alternate: alternate,
            result: result,
            replacing: snapshot.language
        )
        if case .adopts(let language) = outcome {
            adopt(language)
        }
        return outcome
    }

    private mutating func adopt(_ language: TranscriptionLanguage) {
        var next = TranscriptionLanguageGuard.retargeting(snapshot, to: language, in: catalog)
        next.languageOrigin = .autoAdopted
        snapshot = next
        isCorrected = true
    }
}
