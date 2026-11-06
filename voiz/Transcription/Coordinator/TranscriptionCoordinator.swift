import Foundation

// O dono único dos motores de transcrição (T2.3).
//
// Depende só de Foundation, como os contratos da T1.2 e os dois motores: compila no alvo
// `voizTests` e é exercitado inteiro com motores falsos. Quem monta os motores de verdade é
// `LiveTranscriptionCoordinator.swift`, que não entra nos testes porque importa WhisperKit e o
// serviço do Parakeet.
//
// **Os três view models já passam por aqui**: ditado (T2.4a), tradução (T2.4b) e os lotes do
// transcript oficial da reunião (T2.5). O que continua fora é a prévia ao vivo da reunião, que é
// streaming e é da Onda 4.

/// Quantas vezes tentar de novo, e quando esquecer uma falha.
///
/// A política de retry é **do coordenador**, por decisão registrada (DECISOES, contrato de ciclo
/// de vida, item 7): os motores latcham um modelo que falhou e só esquecem em troca de modelo ou
/// `unload()` — eles reportam a falha, não decidem quando perdoá-la. Sem uma política aqui, uma
/// reunião de 40 lotes tentaria 40 downloads do mesmo modelo quebrado; com uma política ingênua
/// ("sempre tente de novo"), o mesmo.
nonisolated struct TranscriptionRetryPolicy: Sendable, Equatable {
    /// Tentativas do MESMO candidato dentro de uma chamada. `1` = não repete; `2` = uma segunda
    /// tentativa antes de passar para o fallback.
    ///
    /// O default é `1` porque repetir na hora quase nunca ajuda: o que falhou foi download ou
    /// carga, e os dois falham de novo no mesmo segundo. Quem quer a segunda tentativa passa `2`
    /// **no pedido** — ver `transcribe(_:using:retryPolicy:)`.
    var attemptsPerCandidate: Int
    /// Quanto tempo um par motor+modelo que falhou fica fora de cogitação.
    ///
    /// Enquanto vale, o candidato é **pulado** sem tocar no motor — nem `unload`, nem `prepare`,
    /// nem rede. Vencido o prazo, a tentativa seguinte limpa o latch do motor (por `unload()`, o
    /// único caminho que o contrato oferece) antes de preparar de novo.
    ///
    /// O número **300 s é do ditado**, e a Quilha mostrou que ele casa mal com o laço de lotes da
    /// reunião: 40 lotes de ~10 s duram ~7 min, então 5 minutos garantem exatamente uma
    /// retentativa no meio dela — e o `runLoad` dos motores evicta o residente ANTES de tentar
    /// carregar o novo, então o lote que dispara o retry perde o modelo de fallback que estava
    /// servindo e o seguinte paga uma recarga inteira. Como a política agora entra **por pedido**,
    /// a T2.5 escapa disso passando um cooldown maior que a reunião (ou `.greatestFiniteMagnitude`,
    /// que dá "não retente dentro desta reunião" de graça, já que ela reusa o mesmo plano).
    ///
    /// **Cooldown infinito exige uma fronteira externa, e ela não é opcional.** Prazo infinito
    /// significa "esta passagem"; o coordenador, porém, vive enquanto o app vive. Sem alguém
    /// reabrindo, "esta reunião" vira "este processo" — a reunião seguinte e o botão "Reprocessar
    /// transcript" herdariam a supressão sem nunca ter tentado (MAIOR do Farol na T2.5). Quem usa um
    /// cooldown maior que a própria passagem **precisa** chamar `clearFailures(useCase:)` no início
    /// de cada passagem nova, e só aí.
    var failureCooldown: TimeInterval

    /// A falha deste pedido pode virar estado **do coordenador**?
    ///
    /// `true` (o normal) é o que faz a supressão existir: o registro fica gravado por caso de uso +
    /// motor + modelo e faz o pedido seguinte **deste mesmo caso de uso** pular o candidato sem
    /// tocar no motor.
    ///
    /// `false` é para quem falha **em silêncio e sem fallback** — hoje só a tradução, que roda
    /// `strict`. O nome do campo é da época em que o registro era global; desde a T2.5 ele é
    /// particionado por caso de uso, e o vazamento que a Quilha achou na T2.4b (uma falha da
    /// tradução mudando o roteamento do ditado) deixou de ser possível por construção. O campo
    /// continua valendo pela **outra** metade do motivo, que a partição não cobre: sem ele, os
    /// pedidos seguintes do MESMO consumidor veriam a marca de latch e fariam `unload` + `prepare`
    /// a cada trecho de 1,2 s. Ver `noteFailure`.
    ///
    /// Não sair caro para quem escolhe `false` é consequência do contrato dos motores: o latch é
    /// **deles** e sobrevive à chamada, então o pedido seguinte bate num `prepare` que re-lança na
    /// hora, sem disco e sem rede. É a mesma economia que o `initializationFailed` do
    /// `TranscriptionService` legado dava — e, como lá, ela só sai com troca de modelo ou `unload`.
    var recordsGlobalFailure: Bool

    init(
        attemptsPerCandidate: Int = 1,
        failureCooldown: TimeInterval = 300,
        recordsGlobalFailure: Bool = true
    ) {
        self.attemptsPerCandidate = max(1, attemptsPerCandidate)
        self.failureCooldown = max(0, failureCooldown)
        self.recordsGlobalFailure = recordsGlobalFailure
    }

    static let `default` = TranscriptionRetryPolicy()

    /// O que a T2.5 usa por lote: uma segunda tentativa do mesmo candidato antes do fallback, e
    /// supressão que dura a reunião inteira em vez de reabrir no meio dela.
    ///
    /// Só é "a reunião inteira", e não "o app inteiro", porque quem usa esta política reabre a
    /// supressão do próprio caso de uso no início de cada passagem — ver `failureCooldown`.
    static let meetingBatch = TranscriptionRetryPolicy(
        attemptsPerCandidate: 2,
        failureCooldown: .greatestFiniteMagnitude
    )

    /// O que a tradução ao vivo (T2.4b) usa: uma tentativa, e a falha **não** sai da tela.
    ///
    /// A tradução roda `strict`, então ela nunca cai para outro motor e a falha dela é silenciosa
    /// para o usuário (só console de debug). Deixá-la escrever no registro global fazia essa falha
    /// privada mudar o roteamento de outra tela — ver `recordsGlobalFailure`.
    static let silentInteractive = TranscriptionRetryPolicy(recordsGlobalFailure: false)
}

/// Um dono de pesos que **não** é motor deste coordenador.
///
/// Existe por causa da janela das instâncias legadas: o PLANO liga o coordenador na T2.4a e na
/// T2.4b, que são merges **anteriores** à T2.5 — durante três merges o app terá o
/// `TranscriptionService.shared`, os dois `ParakeetTranscriptionService` dos view models e o
/// WhisperKit próprio do `MeetingLivePreviewService` segurando pesos fora dos livros do
/// coordenador. Sem esta ponte, "um modelo pesado residente" seria uma promessa só sobre a metade
/// do app que já migrou.
///
/// O coordenador não conhece nenhum desses tipos e não quer conhecer: ele só sabe pedir que
/// liberem o que for pesado antes de ele carregar um pesado. Quem implementa e injeta são a
/// T2.4a/T2.4b, para cada instância legada que sobreviver ao merge delas.
nonisolated protocol TranscriptionForeignWeightOwner: Sendable {
    /// Descrição técnica para log — nunca texto transcrito.
    var ownerDescription: String { get }

    /// Libera os pesos pesados que este dono mantiver. No-op quando não há nenhum.
    func releaseHeavyWeights() async
}

/// Uma tentativa que **não** deu certo, com o motivo.
///
/// É isto que faz o fallback ser "com proveniência fiel" e não só "deu certo no segundo motor":
/// a proveniência do resultado diz *quem* transcreveu e em que posição do plano; a lista de
/// tentativas diz *por que* os anteriores não transcreveram. A UI da T2.4a monta o aviso
/// ("transcrito com X porque Y falhou") com os dois.
nonisolated struct TranscriptionAttempt: Sendable, Equatable {
    /// Em que ponto a tentativa morreu.
    nonisolated enum Stage: Sendable, Equatable {
        /// Não existe motor montado para este id (catálogo à frente do que foi injetado).
        case engineMissing
        /// Pulada sem tocar no motor: este par motor+modelo falhou há pouco e ainda está de
        /// molho (`failureCooldown`).
        case suppressed
        /// Falhou ao preparar os pesos (download/carga).
        case preparation
        /// Os pesos carregaram e a inferência falhou.
        case inference
    }

    var candidate: TranscriptionRoutingCandidate
    var stage: Stage
    var failure: TranscriptionEngineFailure

    init(candidate: TranscriptionRoutingCandidate, stage: Stage, failure: TranscriptionEngineFailure) {
        self.candidate = candidate
        self.stage = stage
        self.failure = failure
    }
}

/// O que o coordenador devolve: o resultado, o plano que o produziu e o que falhou no caminho.
nonisolated struct TranscriptionOutcome: Sendable, Equatable {
    var result: TranscriptionEngineResult
    /// O plano que o roteador montou para este pedido. A T2.5 guarda o plano da reunião e o
    /// reusa nos lotes seguintes; o resto do app pode ignorá-lo.
    var plan: TranscriptionRoutingPlan
    /// Tentativas que falharam antes desta, na ordem em que foram tentadas. Vazio no caminho
    /// feliz.
    var failedAttempts: [TranscriptionAttempt]

    init(
        result: TranscriptionEngineResult,
        plan: TranscriptionRoutingPlan,
        failedAttempts: [TranscriptionAttempt] = []
    ) {
        self.result = result
        self.plan = plan
        self.failedAttempts = failedAttempts
    }

    var provenance: TranscriptionProvenance { result.provenance }
    var text: String { result.text }
    /// O texto veio de um fallback, e não da primeira escolha do plano.
    var usedFallback: Bool { result.provenance.isFallback }
}

/// O primeiro dos dois desfechos de uma preparação: ela terminou, ou quem esperava desistiu.
///
/// Ator (e não continuation solta) porque os dois lados correm: o relé da carga e o `onCancel` da
/// espera podem chegar juntos, e só o primeiro pode valer. É o mesmo princípio de posse que os
/// motores usam na vaga — decidir por efeito colateral perde a corrida.
private actor PreparationHandoff {
    enum Outcome: Sendable {
        case finished((any Error)?)
        case abandoned
    }

    private var settled: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func settle(_ outcome: Outcome) {
        guard settled == nil else { return }
        settled = outcome
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: outcome)
        }
    }

    func wait() async -> Outcome {
        if let settled { return settled }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

/// Quantos trabalhos estão esperando a vaga do coordenador, por classe de prioridade.
nonisolated struct TranscriptionCoordinatorQueue: Sendable, Equatable {
    var interactive: Int
    var batch: Int

    var total: Int { interactive + batch }
}

/// As falhas do coordenador — as que não são de um motor específico.
nonisolated enum TranscriptionCoordinatorError: Error, Sendable, Equatable {
    /// O roteador não encontrou nenhum candidato. Em `strictEngineSelection` é o desfecho
    /// esperado quando a escolha do usuário não é viável: o plano carrega a rejeição que explica.
    case noCandidate(TranscriptionRoutingPlan)
    /// Todos os candidatos do plano falharam. As tentativas vêm na ordem em que aconteceram.
    case allCandidatesFailed([TranscriptionAttempt])
    /// O plano recebido não é deste pedido. Acontece se a T2.5 reusar o plano da reunião num
    /// pedido de outro caso de uso — o que trocaria o motor por baixo do snapshot persistido.
    case planMismatch(planUseCase: TranscriptionUseCase, requestUseCase: TranscriptionUseCase)
    /// Caso de uso de streaming (a prévia da reunião) mandado para o caminho em lote. O
    /// streaming é a Onda 4.
    case streamingUnsupported(TranscriptionUseCase)
    case cancelled
}

/// Descrição **técnica** da falha, para console de debug e log.
///
/// Sem isto, `localizedDescription` de um erro de enum devolve "A operação não pôde ser concluída.
/// (voiz.TranscriptionCoordinatorError erro 2.)" — foi o que a T2.4b encontrou ao trocar o
/// `TranscriptionError` legado (que tinha mensagens) pelo coordenador. A primeira versão resolveu
/// isso com um formatter privado dentro do view model; a review do Farol apontou o defeito: ele
/// serve um consumidor só e diverge em silêncio quando o enum ganha um caso. Aqui o `switch` é
/// exaustivo, então um caso novo **não compila** sem uma descrição.
///
/// Duas propriedades que a implementação garante e a suíte trava:
/// - **nunca há texto transcrito**. Tudo que entra aqui é id de motor, id de modelo, caso de uso,
///   estágio e falha — e `TranscriptionEngineFailure.engineInternal` já carrega, por contrato, só
///   descrição técnica.
/// - **não é copy de UI**. São diagnósticos, e por isso não entram no `Localizable.xcstrings`:
///   ids de motor e modelo não se traduzem, e a mensagem que o usuário lê quando a transcrição
///   falha é assunto da tela de Ajustes da Onda 6, que tem contexto para escrevê-la.
extension TranscriptionCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noCandidate(let plan):
            let reasons = plan.rejections
                .map { "\($0.engine)=\($0.reason)" }
                .joined(separator: ", ")
            let scope = plan.isStrict ? "seleção estrita" : "roteamento"
            return "nenhum motor viável para \(plan.useCase.rawValue) (\(scope)) [\(reasons)]"
        case .allCandidatesFailed(let attempts):
            guard !attempts.isEmpty else { return "todos os candidatos falharam (nenhuma tentativa registrada)" }
            let detail = attempts
                .map { "\($0.candidate.engine)/\($0.candidate.model) \($0.stage)=\($0.failure)" }
                .joined(separator: " | ")
            return "todos os candidatos falharam: \(detail)"
        case .planMismatch(let planUseCase, let requestUseCase):
            return "plano de \(planUseCase.rawValue) usado num pedido de \(requestUseCase.rawValue)"
        case .streamingUnsupported(let useCase):
            return "\(useCase.rawValue) exige streaming e foi mandado para o caminho em lote"
        case .cancelled:
            return "transcrição cancelada"
        }
    }
}

/// Quem decide qual motor transcreve o quê, e o único dono dos motores.
///
/// ## O que ele resolve
///
/// - **Plano**: pergunta ao `TranscriptionRouter` (função pura) quem tentar e em que ordem.
/// - **Prioridade**: ditado, tradução e prévia passam à frente dos lotes pós-call.
/// - **Fallback**: quando o primeiro candidato falha de um jeito que permite fallback, tenta o
///   próximo — e o resultado sai com a proveniência do candidato que **de fato** transcreveu.
/// - **Strict**: com `strictEngineSelection`, nunca há segundo candidato. Nem por acidente.
/// - **Residência**: no máximo **um** modelo pesado residente entre todos os motores dele.
/// - **Retry**: quando (e como) uma falha latchada num motor é esquecida.
///
/// ## Prioridade: uma vaga, com fila ordenada
///
/// O coordenador tem uma vaga única própria, além das vagas internas dos motores. Não é
/// redundância: a vaga do motor é FIFO pura, e FIFO não sabe que ditado vale mais que lote
/// pós-call. A fila daqui ordena por classe (interativo antes de batch, chegada dentro da classe),
/// e é ela que faz um ditado que chega durante uma reunião entrar antes dos lotes que estão
/// esperando.
///
/// Ela também serializa trabalho de **motores diferentes**, o que é decisão e não descuido: duas
/// inferências simultâneas na Neural Engine são exatamente a regressão de performance já
/// registrada nas reuniões (a câmera do Teams travando com Whisper concorrente a cada 3s).
///
/// O que a fila **não** faz: matar um lote que já está inferindo. A inferência dos dois motores
/// não é interrompível por dentro (`WhisperKit.transcribe` e `AsrManager.transcribe` só terminam),
/// então cancelá-la não devolveria a vaga mais cedo — só jogaria fora trabalho já pago. O ganho
/// real do cancelamento cooperativo está na fila, e ele está implementado: a espera pela vaga é
/// cancelável, e um lote cancelado sai da fila em vez de segurar a vez de quem vem depois.
///
/// **Consequência conhecida, registrada de propósito:** a vaga é tomada antes do `prepare` e só
/// devolvida depois da inferência, então um lote que dispara o **download** de um modelo pesado
/// segura a fila enquanto baixa — e um ditado que chegue nesse meio tempo espera o download
/// inteiro. Tomar a vaga só na inferência resolveria isso e quebraria a regra de um pesado
/// residente (dois `prepare` concorrentes carregariam dois modelos), e um segundo mutex só para a
/// residência não ajudaria: o ditado esbarraria nele do mesmo jeito. Fica assim, com o custo
/// visível, porque o único caminho que de fato o elimina é baixar fora da vaga — o que só faz
/// sentido quando o `TranscriptionModelStore` for o dono do download dos dois motores (hoje cada
/// um baixa pelo hub dele). Enquanto ninguém consome o coordenador, o custo é zero.
///
/// O caso **cancelado** desse mesmo cenário já não custa nada: `prepareCancellably` faz o pedido
/// desistir de esperar a carga na hora em que é cancelado, devolvendo a vaga — sem isso, um ditado
/// desistido no meio do download trancava toda a transcrição do app até ele terminar.
///
/// ## Residência: um pesado por vez, e a prova é o `prepare`
///
/// `Whisper small` **não** conta como pesado — quem diz o peso é o `weight` do descritor no
/// catálogo, não o tamanho em bytes. Antes de preparar um modelo pesado, o coordenador descarrega
/// os pesados dos **outros** motores dele (trocar de modelo dentro do mesmo motor é o próprio
/// motor que resolve, com a vaga na mão).
///
/// `unload()` devolve `Void`: ele **não** é confirmação de nada (Quilha, item 6). O que o
/// coordenador registra depois de um `unload` é "não sei mais o que este motor tem"; quem
/// restabelece a verdade é o `prepare` seguinte, que é a única operação que devolve erro quando
/// não conseguiu deixar o modelo residente.
///
/// ## As instâncias legadas
///
/// A janela dos dois donos de memória era planejada e durou **três merges** (T2.4a, T2.4b, T2.5).
/// Ela **fechou na T2.5**: o `MeetingViewModel` era o último consumidor do
/// `TranscriptionService.shared` e o último view model com um `ParakeetTranscriptionService`
/// próprio. Como `shared` é um `static let` preguiçoso, sem consumidor o singleton legado nem é
/// construído — os ~480 MB duplicados que este doc registrava como consequência aceita deixaram de
/// existir.
///
/// O que sobra fora daqui é **um** runtime: o WhisperKit small interno do
/// `MeetingLivePreviewService` (prévia ao vivo), que é `.light` e é assunto da Onda 4.
///
/// A alavanca `TranscriptionForeignWeightOwner` continua no lugar: antes de tornar residente um
/// modelo **pesado**, o coordenador manda os donos externos injetados liberarem os deles. A lista
/// segue **vazia**, e a T2.5 avaliou enchê-la e decidiu que não — ver `LegacyWhisperWeightOwner`
/// (`AppTranscriptionCoordinator.swift`) para os três motivos, sendo o menos óbvio este: com a
/// lista não vazia, `wouldEvictForeignWeights` responde "sim" para todo candidato pesado e o
/// `warmUp` desiste, o que desligaria o pré-aquecimento de `medium`/`large-v3-turbo`/Parakeet em
/// troca de nenhuma memória.
///
/// De resto, o limite é o de sempre: o coordenador não pode impedir uma instância que não é dele de
/// carregar pesos por conta própria.
actor TranscriptionCoordinator {

    private let router: TranscriptionRouter
    private let hardware: TranscriptionHardwareProfile
    private let engines: [TranscriptionEngineID: any BatchTranscriptionEngine]
    private let retryPolicy: TranscriptionRetryPolicy
    /// Relógio injetável: o cooldown de falha precisa ser testável sem dormir 5 minutos.
    private let now: @Sendable () -> Date

    /// O que o coordenador **acredita** estar residente em cada motor. Vira `nil` em todo
    /// `unload`, porque `unload` não confirma nada; vira valor de novo em todo `prepare` que
    /// devolveu sem erro.
    private var residency: [TranscriptionEngineID: Residency] = [:]

    /// Falhas conhecidas por **caso de uso** + motor + modelo, com o instante em que aconteceram. É
    /// o que decide a **supressão** (cooldown) — e é o que `clearFailures` apaga.
    ///
    /// A partição por caso de uso é da T2.5, e fecha um vazamento que o cooldown infinito dos lotes
    /// tornou grave: com a chave global, uma falha registrada pelo **ditado** (política default,
    /// 300 s) era lida pelo lote da reunião com a política *dele* — `.greatestFiniteMagnitude` —, e
    /// o rank 0 da reunião ficava suprimido **para sempre**, sem nunca ter sido tentado nela. Quem
    /// decide a supressão é a política de quem pergunta (isso não mudou); o que a partição corrige é
    /// *sobre quais fatos* ela decide. Reunião responde por reunião.
    ///
    /// O que **não** é particionado é o latch do motor (`latchedModels`): esse é um fato sobre o
    /// motor, compartilhado por contrato (T2.1/T2.2), e fingir o contrário faria dois consumidores
    /// acreditarem em estados diferentes do mesmo `WhisperKit`.
    ///
    /// Preço aceito da partição: um modelo genuinamente corrompido é descoberto uma vez **por caso
    /// de uso** em vez de uma vez no processo — no pior caso quatro tentativas de carga em vez de
    /// uma. É barato porque a primeira delas já deixa o latch no motor: as seguintes só custam o
    /// `unload` + `prepare` que re-lança, e a supressão do próprio caso de uso segura a repetição
    /// dali em diante.
    private var failures: [FailureKey: FailureRecord] = [:]

    /// Pares motor+modelo que o **motor** pode estar latchando.
    ///
    /// Estado separado do `failures` de propósito, e o MAIOR do Farol é exatamente a diferença
    /// entre os dois: `clearFailures` significa "pode tentar de novo agora", e apagar o registro
    /// de falha não desfaz o latch que vive **dentro do motor** — ele só sai com troca de modelo
    /// ou `unload()`. Quando os dois eram a mesma coisa, `clearFailures` fazia o pedido seguinte
    /// chamar `prepare` sem descarregar antes, e os motores reais re-lançavam a falha antiga na
    /// hora, sem tentar nada. Só o teste com dublê sem latch não via.
    ///
    /// Sem caso de uso na chave, ao contrário do `failures`: o latch é um fato sobre o **motor**, e
    /// o motor é um só para todo mundo.
    private var latchedModels: Set<LatchKey> = []

    /// Donos de pesos fora deste coordenador (as instâncias legadas até a T2.5).
    private let foreignOwners: [any TranscriptionForeignWeightOwner]

    // A vaga do coordenador (ver "Prioridade", acima).
    private var permitBusy = false
    private var permitWaiters: [PermitWaiter] = []
    private var ticketCounter = 0
    /// Concessões consecutivas dadas a trabalho interativo. Zera sempre que um lote é servido.
    /// É o contador da cota de justiça — ver `releasePermit`.
    private var consecutiveInteractiveGrants = 0
    /// Depois de quantas concessões seguidas a interativos a vaga vai para o lote mais antigo.
    private let interactiveGrantsBeforeBatch: Int

    private struct Residency {
        var model: TranscriptionModelID
        var weight: TranscriptionModelWeight
    }

    /// A chave da **supressão**: o que ESTE caso de uso aprendeu sobre este par motor+modelo.
    private struct FailureKey: Hashable {
        var useCase: TranscriptionUseCase
        var engine: TranscriptionEngineID
        var model: TranscriptionModelID
        var requiresVocabulary: Bool

        init(useCase: TranscriptionUseCase, candidate: TranscriptionRoutingCandidate, requiresVocabulary: Bool = false) {
            self.useCase = useCase
            self.engine = candidate.engine
            self.model = candidate.model
            self.requiresVocabulary = requiresVocabulary
        }

        init(useCase: TranscriptionUseCase, engine: TranscriptionEngineID, model: TranscriptionModelID, requiresVocabulary: Bool = false) {
            self.useCase = useCase
            self.engine = engine
            self.model = model
            self.requiresVocabulary = requiresVocabulary
        }
    }

    /// A chave do **latch do motor**: um fato sobre o motor, sem caso de uso.
    private struct LatchKey: Hashable {
        var engine: TranscriptionEngineID
        var model: TranscriptionModelID

        init(_ candidate: TranscriptionRoutingCandidate) {
            self.engine = candidate.engine
            self.model = candidate.model
        }

        init(engine: TranscriptionEngineID, model: TranscriptionModelID) {
            self.engine = engine
            self.model = model
        }
    }

    private struct FailureRecord {
        var failure: TranscriptionEngineFailure
        var at: Date
        /// Onde a falha aconteceu. Decide se o motor ficou com o **latch** deste modelo: só a
        /// falha de preparação latcha (o motor guarda `failedModel` e re-lança na hora até troca
        /// de modelo ou `unload`). Falha de inferência não latcha nada — e descarregar por causa
        /// dela jogaria fora pesos que estão perfeitos.
        var stage: TranscriptionAttempt.Stage
    }

    /// Alguém esperando a vaga do coordenador.
    ///
    /// A posse da vaga é o valor com que a continuation é retomada — `true` = a vaga é sua e você
    /// a devolve; `false` = você saiu da fila por cancelamento e não a tem. É o mesmo protocolo
    /// dos dois motores, e pela mesma razão: o `onCancel` do `withTaskCancellationHandler` não
    /// pode tocar o ator direto, então ele agenda um hop — e o `releasePermit()` pode servir este
    /// waiter antes de o hop rodar. Decidir a posse por efeito colateral perde essa corrida e
    /// vaza a vaga (foi o CRÍTICO da rodada 3 da T2.1).
    private struct PermitWaiter {
        var ticket: Int
        var isInteractive: Bool
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// Sem instância default e sem singleton: o coordenador é dono dos motores, e um construtor
    /// de conveniência criaria um segundo dono. A fábrica com os motores de produção é
    /// `make(parakeetService:runtimeStore:)`, em `LiveTranscriptionCoordinator.swift`.
    ///
    /// - Parameter engines: os motores em lote, por id. O plano do roteador pode citar um motor
    ///   que não está aqui (o Apple SpeechAnalyzer só chega na Onda 3): isso não é erro, é um
    ///   candidato que falha com `engineMissing` e deixa o próximo tentar.
    /// - Parameter foreignOwners: donos de pesos que não são motores deste coordenador — as
    ///   instâncias legadas que sobrevivem até a T2.5. Vazio por enquanto: quem as liga são a
    ///   T2.4a/T2.4b.
    /// - Parameter interactiveGrantsBeforeBatch: a cota de justiça da fila. `3` significa "no
    ///   máximo três interativos seguidos antes de o lote mais antigo ser servido".
    init(
        engines: [TranscriptionEngineID: any BatchTranscriptionEngine],
        router: TranscriptionRouter = TranscriptionRouter(),
        hardware: TranscriptionHardwareProfile = .detected(),
        retryPolicy: TranscriptionRetryPolicy = .default,
        foreignOwners: [any TranscriptionForeignWeightOwner] = [],
        interactiveGrantsBeforeBatch: Int = 3,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engines = engines
        self.router = router
        self.hardware = hardware
        self.retryPolicy = retryPolicy
        self.foreignOwners = foreignOwners
        self.interactiveGrantsBeforeBatch = max(1, interactiveGrantsBeforeBatch)
        self.now = now
    }

    // MARK: - Plano

    /// O plano para este pedido, sem executar nada.
    ///
    /// A T2.5 chama isto no início da gravação e guarda o resultado: os lotes seguintes usam o
    /// mesmo plano, para uma mudança nas Configurações no meio da reunião não trocar o motor entre
    /// dois lotes do mesmo transcript.
    func plan(
        for useCase: TranscriptionUseCase,
        language: TranscriptionLanguage?,
        selection: TranscriptionUserSelection = .automatic,
        requiresVocabulary: Bool = false
    ) -> TranscriptionRoutingPlan {
        router.plan(
            for: TranscriptionRoutingContext(
                useCase: useCase,
                language: language,
                hardware: hardware,
                selection: selection,
                requiresVocabulary: requiresVocabulary
            )
        )
    }

    // MARK: - Transcrição

    /// Transcreve, roteando na hora.
    ///
    /// - Parameter retryPolicy: `nil` = a política do coordenador. Passar uma aqui é o que permite
    ///   a mesma instância servir ditado (sem repetição) e os lotes da reunião (`.meetingBatch`)
    ///   sem dois coordenadores — e sem dois donos dos motores.
    @discardableResult
    func transcribe(
        _ request: TranscriptionRequest,
        selection: TranscriptionUserSelection = .automatic,
        retryPolicy: TranscriptionRetryPolicy? = nil
    ) async throws -> TranscriptionOutcome {
        let plan = plan(for: request.useCase, language: request.language, selection: selection,
                        requiresVocabulary: request.context.requiresVocabulary)
        return try await transcribe(request, using: plan, retryPolicy: retryPolicy)
    }

    /// Transcreve usando um plano já montado (o snapshot da reunião).
    ///
    /// - Parameter retryPolicy: `nil` = a política do coordenador. É por aqui que a T2.5 pede o
    ///   "retry 1× por lote" (`TranscriptionRetryPolicy.meetingBatch`) sem dobrar a tentativa do
    ///   ditado e da tradução, onde repetir na hora não ajuda.
    @discardableResult
    func transcribe(
        _ request: TranscriptionRequest,
        using plan: TranscriptionRoutingPlan,
        retryPolicy: TranscriptionRetryPolicy? = nil
    ) async throws -> TranscriptionOutcome {
        guard !request.useCase.requiresStreaming else {
            throw TranscriptionCoordinatorError.streamingUnsupported(request.useCase)
        }
        guard plan.useCase == request.useCase else {
            throw TranscriptionCoordinatorError.planMismatch(
                planUseCase: plan.useCase,
                requestUseCase: request.useCase
            )
        }
        guard !plan.isEmpty else {
            throw TranscriptionCoordinatorError.noCandidate(plan)
        }
        try checkCancelled()

        // A fila com prioridade. Interativo entra à frente do batch que ainda espera.
        guard await acquirePermit(isInteractive: request.useCase.isInteractive) else {
            throw TranscriptionCoordinatorError.cancelled
        }
        defer { releasePermit() }

        try checkCancelled()
        return try await run(request, plan: plan, policy: retryPolicy ?? self.retryPolicy)
    }

    /// O laço de candidatos, já com a vaga na mão.
    private func run(
        _ request: TranscriptionRequest,
        plan: TranscriptionRoutingPlan,
        policy: TranscriptionRetryPolicy
    ) async throws -> TranscriptionOutcome {
        var failedAttempts: [TranscriptionAttempt] = []

        for candidate in plan.candidates {
            guard let engine = engines[candidate.engine] else {
                failedAttempts.append(
                    TranscriptionAttempt(
                        candidate: candidate,
                        stage: .engineMissing,
                        failure: .modelUnavailable(candidate.model)
                    )
                )
                // Motor ausente é indisponibilidade: permite fallback, mas não sob strict.
                if plan.isStrict { break }
                continue
            }

            // Stored plans also obey the request's feature requirements. A fallback must not
            // silently drop vocabulary just because the preferred engine failed.
            if request.context.requiresVocabulary && !engine.descriptor.supportsVocabulary {
                failedAttempts.append(TranscriptionAttempt(candidate: candidate, stage: .inference,
                    failure: .engineInternal("Motor sem suporte ao vocabulário personalizado")))
                if plan.isStrict { break }
                continue
            }
            let key = FailureKey(useCase: request.useCase, candidate: candidate, requiresVocabulary: request.context.requiresVocabulary)
            if let record = failures[key], !isCooledDown(record, policy: policy) {
                // De molho: nem `unload`, nem `prepare`, nem rede. É isto que impede os 40 lotes
                // de uma reunião de tentarem 40 downloads do mesmo modelo quebrado.
                failedAttempts.append(
                    TranscriptionAttempt(candidate: candidate, stage: .suppressed, failure: record.failure)
                )
                if plan.isStrict { break }
                continue
            }

            switch try await attempt(
                request,
                candidate: candidate,
                engine: engine,
                plan: plan,
                policy: policy
            ) {
            case .success(let result):
                failures[key] = nil
                latchedModels.remove(LatchKey(candidate))
                return TranscriptionOutcome(
                    result: result,
                    plan: plan,
                    failedAttempts: failedAttempts
                )
            case .failed(let attempts, let allowsFallback):
                failedAttempts.append(contentsOf: attempts)
                // `strict` nunca cai para outro motor — e o plano strict tem no máximo um
                // candidato, então isto é cinto **e** suspensório: mesmo que o roteador um dia
                // devolva dois, esta saída mantém a promessa.
                if plan.isStrict || !allowsFallback {
                    throw TranscriptionCoordinatorError.allCandidatesFailed(failedAttempts)
                }
            }
        }

        throw TranscriptionCoordinatorError.allCandidatesFailed(failedAttempts)
    }

    private enum AttemptOutcome {
        case success(TranscriptionEngineResult)
        /// As tentativas gastas neste candidato, e se vale tentar o próximo.
        case failed([TranscriptionAttempt], allowsFallback: Bool)
    }

    /// Um candidato, com as repetições que a política permitir.
    private func attempt(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate,
        engine: any BatchTranscriptionEngine,
        plan: TranscriptionRoutingPlan,
        policy: TranscriptionRetryPolicy
    ) async throws -> AttemptOutcome {
        var attempts: [TranscriptionAttempt] = []
        let key = FailureKey(useCase: request.useCase, candidate: candidate, requiresVocabulary: request.context.requiresVocabulary)
        let latchKey = LatchKey(candidate)

        for _ in 0..<policy.attemptsPerCandidate {
            try checkCancelled()

            do {
                // `unload()` é o único caminho que o contrato oferece para limpar o latch, e o
                // latch **atravessa chamadas**: sem descarregar antes, `prepare` devolve a falha
                // antiga na hora, sem tentar nada, e a política de retry inteira vira enfeite.
                // Só a falha de preparação latcha — descarregar por causa de uma falha de
                // inferência jogaria fora pesos que estão perfeitos.
                try await ensureResident(
                    candidate,
                    engine: engine,
                    clearingLatch: latchedModels.contains(latchKey)
                )
            } catch let failure as TranscriptionEngineFailure {
                if failure == .cancelled { throw TranscriptionCoordinatorError.cancelled }
                noteFailure(failure, for: candidate, stage: .preparation, key: key, latchKey: latchKey, policy: policy)
                attempts.append(
                    TranscriptionAttempt(candidate: candidate, stage: .preparation, failure: failure)
                )
                if !failure.allowsFallback {
                    return .failed(attempts, allowsFallback: false)
                }
                continue
            } catch is CancellationError {
                throw TranscriptionCoordinatorError.cancelled
            } catch {
                // Motor que lança fora do vocabulário do contrato. Classificar aqui, e não deixar
                // subir cru, é o que mantém a promessa do `TranscriptionOutcome`: quem chama o
                // coordenador só precisa entender `TranscriptionCoordinatorError`.
                let failure = TranscriptionEngineFailure.engineInternal(error.localizedDescription)
                noteFailure(failure, for: candidate, stage: .preparation, key: key, latchKey: latchKey, policy: policy)
                attempts.append(
                    TranscriptionAttempt(candidate: candidate, stage: .preparation, failure: failure)
                )
                continue
            }

            do {
                let result = try await engine.transcribe(request, candidate: candidate)
                guard !request.context.requiresVocabulary || result.vocabularyTermsUsed != nil else {
                    throw TranscriptionEngineFailure.engineInternal("Motor não confirmou suporte ao vocabulário personalizado")
                }
                return .success(Self.stamped(result, candidate: candidate, useCase: request.useCase))
            } catch let failure as TranscriptionEngineFailure {
                if failure == .cancelled { throw TranscriptionCoordinatorError.cancelled }
                // Indisponibilidade **durante** a inferência quer dizer que a residência que
                // achávamos ter não existe mais (alguém descarregou por baixo). Esquecer o que
                // registramos é o que faz a próxima tentativa preparar de novo em vez de bater na
                // mesma pedra.
                if case .modelUnavailable = failure { residency[candidate.engine] = nil }
                noteFailure(failure, for: candidate, stage: .inference, key: key, latchKey: latchKey, policy: policy)
                attempts.append(
                    TranscriptionAttempt(candidate: candidate, stage: .inference, failure: failure)
                )
                if !failure.allowsFallback {
                    return .failed(attempts, allowsFallback: false)
                }
            } catch is CancellationError {
                throw TranscriptionCoordinatorError.cancelled
            } catch {
                let failure = TranscriptionEngineFailure.engineInternal(error.localizedDescription)
                noteFailure(failure, for: candidate, stage: .inference, key: key, latchKey: latchKey, policy: policy)
                attempts.append(
                    TranscriptionAttempt(candidate: candidate, stage: .inference, failure: failure)
                )
            }
        }

        return .failed(attempts, allowsFallback: true)
    }

    /// Deixa `candidate` residente, respeitando a regra de **um** modelo pesado.
    ///
    /// Lança `TranscriptionEngineFailure`.
    private func ensureResident(
        _ candidate: TranscriptionRoutingCandidate,
        engine: any BatchTranscriptionEngine,
        clearingLatch: Bool
    ) async throws {
        let latchKey = LatchKey(candidate)
        if clearingLatch {
            await engine.unload()
            // `unload` não confirma nada: o que sabemos agora é que não sabemos.
            residency[candidate.engine] = nil
            // …e ele limpa o latch do motor INTEIRO, não só o deste modelo.
            latchedModels = latchedModels.filter { $0.engine != candidate.engine }
        }

        let weight = weight(of: candidate)
        if weight == .heavy {
            // Um pesado por vez **entre motores**. Dentro do mesmo motor quem troca é ele, com a
            // vaga na mão — evictar daqui seria soltar pesos por baixo de trabalho vivo.
            for (id, resident) in residency where id != candidate.engine && resident.weight == .heavy {
                await engines[id]?.unload()
                residency[id] = nil
                latchedModels = latchedModels.filter { $0.engine != id }
            }
            // E os pesos que **não** são de motor nenhum daqui: as instâncias legadas que
            // sobrevivem até a T2.5. Sem esta parte, "um modelo pesado residente" seria promessa
            // só sobre a metade do app que já migrou — e a janela dura três merges (T2.4a, T2.4b,
            // T2.5). Vazio hoje; quem injeta os donos é a T2.4a/b.
            for owner in foreignOwners {
                await owner.releaseHeavyWeights()
            }
        }

        try await prepareCancellably(
            engine,
            model: candidate.model,
            weight: weight,
            engineID: candidate.engine
        )
        // A confirmação da residência é este `prepare` ter devolvido sem erro — e não o `unload`
        // de ninguém.
        residency[candidate.engine] = Residency(model: candidate.model, weight: weight)
        latchedModels.remove(latchKey)
    }

    /// `prepare`, mas com uma espera que o cancelamento do PEDIDO interrompe.
    ///
    /// Sem isto, cancelar um pedido durante a preparação não devolvia nada até o download acabar:
    /// os motores delegam a carga a uma `Task` não estruturada (o single-flight que impede dois
    /// downloads do mesmo modelo) e `await task.value` não retorna cedo quando quem espera é
    /// cancelado. Nos motores isoladamente esse custo foi analisado e aceito; é a vaga do
    /// coordenador que o transforma em bloqueio **global** — um ditado que dispara o download de um
    /// modelo pesado e é desistido trancava toda a transcrição do app pelo download inteiro.
    ///
    /// A correção é deixar de **esperar**, não matar a carga: ela segue viva no motor, servindo
    /// quem mais estiver esperando por ela, e um `prepare` posterior do mesmo modelo se junta ao
    /// mesmo single-flight. Quem cancelou sai com `.cancelled` e devolve a vaga na saída de
    /// `transcribe`. (A correção completa — a espera do single-flight virar cancelável dentro dos
    /// motores — é mudança no contrato de ciclo de vida, e portanto do Maestro.)
    ///
    /// O preço de abandonar: a carga pode terminar depois, deixando pesos residentes que não
    /// registramos — e aí dois pesados coexistiriam. Por isso a residência é marcada
    /// **pessimista** antes de sair. Como `ensureResident` sempre chama `prepare` e a residência é
    /// conselho, uma entrada a mais custa no máximo um `unload` inútil; uma a menos custaria a
    /// regra do plano.
    private func prepareCancellably(
        _ engine: any BatchTranscriptionEngine,
        model: TranscriptionModelID,
        weight: TranscriptionModelWeight,
        engineID: TranscriptionEngineID
    ) async throws {
        let load = Task { try await engine.prepare(model: model) }
        let handoff = PreparationHandoff()
        // Relé: transforma o fim da carga num sinal que a espera cancelável enxerga.
        Task {
            do {
                try await load.value
                await handoff.settle(.finished(nil))
            } catch {
                await handoff.settle(.finished(error))
            }
        }

        let outcome = await withTaskCancellationHandler {
            await handoff.wait()
        } onCancel: {
            Task { await handoff.settle(.abandoned) }
        }

        switch outcome {
        case .finished(nil):
            return
        case .finished(let error?):
            throw error
        case .abandoned:
            residency[engineID] = Residency(model: model, weight: weight)
            throw TranscriptionEngineFailure.cancelled
        }
    }

    // MARK: - Aquecimento

    /// Deixa residente o **primeiro** candidato do plano, sem transcrever nada.
    ///
    /// É **cortesia de cadência, nunca corretude**: nada que aconteça aqui — sucesso, falha ou
    /// cancelamento — muda o **desfecho** de um `transcribe` posterior. Quem precisa de garantia de
    /// residência chama `transcribe`, que prepara sozinho e devolve erro quando não consegue.
    ///
    /// "Não muda o desfecho" **não** quer dizer "não toca em nada", e a review da Quilha pediu que
    /// a frase dissesse isso: aquecer mexe na **residência**. No caminho normal ele carrega os
    /// pesos do rank 0 (é o ponto); e quando o coordenador tem marca de latch para esse par
    /// motor+modelo, o `ensureResident` passa por `unload()` antes de tentar — o único caminho
    /// contratual para limpar o latch —, o que **evicta o que estava residente naquele motor**. Na
    /// prática o guard de cooldown estreita muito essa janela (candidato que falhou há pouco é
    /// pulado sem tocar no motor), mas ela existe depois que o cooldown vence. O que continua
    /// valendo é o essencial: o pedido seguinte prepara de novo de qualquer jeito, então uma
    /// residência a mais ou a menos custa tempo, nunca correção.
    ///
    /// Existe por causa da migração dos view models (T2.4a/T2.4b): o `TranscriptionService`
    /// legado era aquecido no `init` da tela e na troca de modelo (`configure` +
    /// `ensureInitialized`), então quando o usuário apertava gravar o modelo já estava na Neural
    /// Engine. Sem um aquecimento, a carga passaria a acontecer dentro do primeiro pedido — e nos
    /// laços que descartam ciclos enquanto um trecho está em voo (o chunking de 1,2 s da tradução)
    /// isso come os primeiros segundos de fala. É regressão de cadência, não de texto, e é por
    /// isso que este método existe em vez de os view models chamarem `transcribe` com áudio falso.
    ///
    /// Três regras, que é o que o torna seguro:
    /// 1. **Só o rank 0.** Aquecer os fallbacks carregaria modelos que ninguém pediu. Como o plano
    ///    sai do mesmo roteador do pedido, `strictEngineSelection` e a escolha do usuário são
    ///    respeitados por construção — não há caminho aqui para aquecer um motor que o plano não
    ///    escolheria.
    /// 2. **Falha é engolida e não vira registro.** Nem falha, nem cooldown, nem marca de latch:
    ///    o aquecimento não pode gastar a política de retry de um pedido que ainda nem existe. O
    ///    latch que fica é o **do motor** (interno a ele, por contrato), e é justamente ele que faz
    ///    o primeiro `transcribe` depois de um aquecimento falho se comportar como o
    ///    `initializationFailed` do serviço legado: falha na hora, sem re-baixar.
    /// 3. **Não fura a supressão.** Candidato em cooldown é pulado sem tocar no motor, igual ao
    ///    laço de `transcribe` — senão o aquecimento seria a porta dos fundos que dispara o
    ///    download que a supressão existe para evitar.
    /// 4. **Nunca evicta.** Se deixar este candidato residente exigisse descarregar o pesado de
    ///    OUTRO motor (ou pedir aos donos externos que soltem os deles), o aquecimento desiste.
    ///    Pagar a eviction de um residente por uma cortesia inverte a relação: com dois consumidores
    ///    cujo rank 0 é pesado em motores diferentes — ditado no Parakeet e tradução no Whisper
    ///    large-v3-turbo, que a T1.4 deixa alcançável —, os dois aquecimentos de boot se evictavam,
    ///    o primeiro download inteiro virava desperdício puro, e o desperdício se repetia a cada
    ///    mudança de configuração. Quem chegou primeiro fica residente; o outro paga a carga no
    ///    primeiro pedido de verdade, que é o que um aquecimento deve fazer quando não pode ajudar.
    ///
    /// Toma a vaga normalmente, na classe de prioridade do caso de uso: aquecer é carregar pesos,
    /// e carregar pesos por baixo de um trabalho vivo é exatamente o que a vaga impede.
    ///
    /// - Parameter retryPolicy: `nil` = a política do coordenador, como em
    ///   `transcribe(_:selection:retryPolicy:)`. A simetria **é** a regra 3: quem lê a supressão
    ///   tem que ler com a mesma política de quem a escreveu. Sem este parâmetro, a T2.5 quebraria
    ///   a regra por omissão — `.meetingBatch` suprime um candidato falho pela reunião inteira
    ///   (`failureCooldown` infinito), mas o aquecimento da reunião releria o mesmo registro com os
    ///   300 s do default, passaria pelo guard e, havendo marca de latch, entraria em
    ///   `ensureResident(clearingLatch: true)` ⇒ `unload()` + `prepare()`, que é a tentativa de
    ///   download que a supressão existia para evitar. Achado da Quilha na re-review r2.
    func warmUp(
        for useCase: TranscriptionUseCase,
        language: TranscriptionLanguage?,
        selection: TranscriptionUserSelection = .automatic,
        retryPolicy: TranscriptionRetryPolicy? = nil,
        requiresVocabulary: Bool = false
    ) async {
        // Streaming é a Onda 4; o caminho em lote não tem o que aquecer para ele.
        guard !useCase.requiresStreaming else { return }
        guard Task.isCancelled == false else { return }

        let plan = plan(for: useCase, language: language, selection: selection, requiresVocabulary: requiresVocabulary)
        guard let candidate = plan.primary, let engine = engines[candidate.engine] else { return }

        // A supressão lida aqui é a **deste** caso de uso, como no `transcribe`: um aquecimento da
        // reunião não pode ser cancelado por uma falha que o ditado registrou, nem vice-versa.
        let key = FailureKey(useCase: useCase, candidate: candidate, requiresVocabulary: requiresVocabulary)
        let latchKey = LatchKey(candidate)
        let policy = retryPolicy ?? self.retryPolicy
        if let record = failures[key], !isCooledDown(record, policy: policy) { return }

        guard await acquirePermit(isInteractive: useCase.isInteractive) else { return }
        defer { releasePermit() }
        guard Task.isCancelled == false else { return }

        // Regra 4, conferida **com a vaga na mão**: entre montar o plano e ser servido, outro
        // trabalho pode ter tornado residente o pesado que este aquecimento evictaria.
        guard !wouldEvictForeignWeights(candidate) else { return }

        // Sem `record(...)` e sem `latchedModels.insert(...)` no `catch`: ver a regra 2. O que o
        // `ensureResident` escreve no caminho feliz (residência, limpeza do latch) continua valendo
        // — isso é conhecimento sobre o motor, não política de retry.
        try? await ensureResident(
            candidate,
            engine: engine,
            clearingLatch: latchedModels.contains(latchKey)
        )
    }

    /// Tornar `candidate` residente custaria os pesos de **outra pessoa**?
    ///
    /// É a pergunta da regra 4 do `warmUp`, e ela só tem resposta afirmativa para modelo pesado:
    /// leve não dispara eviction nenhuma em `ensureResident`. Trocar o modelo **dentro do mesmo
    /// motor** não conta — isso é o motor descartando os pesos dele próprios, não os de outro
    /// consumidor, e é o que qualquer `prepare` faria.
    ///
    /// **Limitação conhecida dessa última frase, e ela tem prazo** (Quilha, T2.5): "o motor
    /// descartando os pesos dele próprios" é verdade para um `transcribe`, que precisa daqueles
    /// pesos, e é falso para um `warmUp`, que é cortesia — aquecimento que desfaz aquecimento é
    /// exatamente o desperdício que a regra 4 nasceu para evitar, e este ramo não o cobre quando os
    /// dois pedidos caem no mesmo motor com modelos diferentes. Hoje é inalcançável: a migração da
    /// T1.4 dá o mesmo modelo aos casos de uso que compartilham motor, então os três aquecimentos de
    /// boot (ditado, tradução, reunião) convergem para a mesma carga. Vira alcançável quando a T6.2
    /// expuser seleção por caso de uso — ditado em `small` e reunião em `large-v3-turbo` fariam dois
    /// downloads em série no boot, um deles jogado fora. A correção é da T6.1/T6.2 (aquecer só o
    /// caso de uso em tela, ou estender a regra 4 para dentro do motor quando quem pede é `warmUp`),
    /// e está registrada em DECISOES.
    ///
    /// `foreignOwners` entra na conta porque `ensureResident` também manda os donos externos
    /// liberarem antes de um pesado: enquanto existir instância legada registrada (T2.5), um
    /// aquecimento pesado desiste em vez de fazer outra tela soltar o modelo dela. Hoje a lista
    /// está vazia por decisão da T2.4a, então este ramo é inerte.
    private func wouldEvictForeignWeights(_ candidate: TranscriptionRoutingCandidate) -> Bool {
        guard weight(of: candidate) == .heavy else { return false }
        if !foreignOwners.isEmpty { return true }
        return residency.contains { id, resident in
            id != candidate.engine && resident.weight == .heavy
        }
    }

    // MARK: - Ciclo de vida

    /// Descarrega tudo que este coordenador tem residente.
    ///
    /// Para o app fechar a reunião, ir para segundo plano ou responder a pressão de memória.
    ///
    /// **Toma a vaga**, e portanto espera o trabalho em voo terminar. A alternativa — descarregar
    /// por baixo de um pedido — cancelava a carga em voo do motor e fazia o pedido morrer com
    /// `.cancelled` (que não permite fallback) sem ninguém ter cancelado nada, além de deixar o
    /// mapa de residência obsoleto pela escrita tardia do pedido. Descarregar memória é a operação
    /// que menos pode ser feita pela metade, então ela entra na fila como todo mundo — em último
    /// lugar, porque não é interativa.
    ///
    /// Não mexe nas instâncias legadas por conta própria: para elas existe
    /// `TranscriptionForeignWeightOwner`, injetado pela T2.4a/b, e este método também as aciona.
    func unloadAll() async {
        _ = await acquirePermit(isInteractive: false, cancellable: false)
        defer { releasePermit() }

        for (id, engine) in engines {
            await engine.unload()
            residency[id] = nil
        }
        latchedModels.removeAll()
        for owner in foreignOwners {
            await owner.releaseHeavyWeights()
        }
    }

    /// O que o coordenador acredita estar residente em `engine`. Diagnóstico e teste — a UI usa o
    /// `TranscriptionRuntimeStore`, que reflete os eventos dos motores.
    func residentModel(of engine: TranscriptionEngineID) -> TranscriptionModelID? {
        residency[engine]?.model
    }

    /// Quantos trabalhos esperam a vaga, por classe.
    ///
    /// Diagnóstico — e o único jeito de um teste afirmar "o interativo entrou na frente" sem
    /// depender do escalonador do dia: sem isto, o teste teria que dormir e torcer para os lotes
    /// já estarem na fila antes de o interativo chegar.
    var queuedWork: TranscriptionCoordinatorQueue {
        TranscriptionCoordinatorQueue(
            interactive: permitWaiters.count { $0.isInteractive },
            batch: permitWaiters.count { !$0.isInteractive }
        )
    }

    /// Esquece a **supressão** das falhas registradas, deixando o próximo pedido tentar de novo
    /// agora em vez de esperar o cooldown.
    ///
    /// É a alavanca explícita para "o usuário mandou tentar de novo".
    ///
    /// O que ela **não** apaga é a marca de latch: o latch mora dentro do motor e só sai com troca
    /// de modelo ou `unload()`. Enquanto os dois estados eram um só, esta função devolvia o
    /// candidato ao jogo e o `prepare` seguinte batia no `failedModel` do motor, que re-lança a
    /// falha antiga na hora, sem tentar nada — "reabrir" não reabria coisa nenhuma. Preservando a
    /// marca, o pedido seguinte descarrega antes de preparar, que é o único caminho que funciona.
    ///
    /// ## A fronteira de "passagem", que é o uso principal desta API
    ///
    /// A T2.5 usa isto para dar ao cooldown infinito de `.meetingBatch` a fronteira que o nome dele
    /// promete. `failureCooldown = .greatestFiniteMagnitude` significa "não retente **dentro desta
    /// reunião**", mas o coordenador é um só e vive enquanto o app vive: sem alguém reabrindo, "esta
    /// reunião" viraria "este processo", e um tropeço na reunião de segunda condenaria a de terça e
    /// o botão "Reprocessar transcript" junto — sem nunca ter tentado de novo. Foi o MAIOR do Farol.
    ///
    /// A regra que fecha isso: reabrir **uma vez no início de cada passagem** (uma nova reunião, um
    /// novo reprocessamento) e nunca entre lotes da mesma passagem. É o que
    /// `MeetingViewModel.transcribeRecordedAudio` faz, com `useCase: .meetingFinal`.
    ///
    /// - Parameters:
    ///   - useCase: `nil` = qualquer caso de uso. Passar um limita a limpeza ao que **aquele**
    ///     consumidor aprendeu — reabrir a reunião não apaga o que o ditado sabe.
    ///   - engine: `nil` = qualquer motor.
    ///   - model: `nil` = qualquer modelo.
    func clearFailures(
        useCase: TranscriptionUseCase? = nil,
        engine: TranscriptionEngineID? = nil,
        model: TranscriptionModelID? = nil
    ) {
        failures = failures.filter { key, _ in
            let matchesUseCase = useCase == nil || key.useCase == useCase
            let matchesEngine = engine == nil || key.engine == engine
            let matchesModel = model == nil || key.model == model
            // Fica quem **não** casa com o filtro inteiro.
            return !(matchesUseCase && matchesEngine && matchesModel)
        }
    }

    /// O coordenador sabe que este par motor+modelo pode estar latchado no motor? Diagnóstico e
    /// teste.
    func knowsLatch(engine: TranscriptionEngineID, model: TranscriptionModelID) -> Bool {
        latchedModels.contains(LatchKey(engine: engine, model: model))
    }

    /// A falha que **este caso de uso** está lembrando agora. Diagnóstico e teste.
    ///
    /// O caso de uso é obrigatório de propósito: com a partição da T2.5, "o coordenador lembra de
    /// uma falha neste motor+modelo" deixou de ser uma pergunta bem formada — a resposta depende de
    /// quem pergunta, e um default aqui esconderia exatamente a distinção que o MAIOR do Farol
    /// pediu.
    func recordedFailure(
        useCase: TranscriptionUseCase,
        engine: TranscriptionEngineID,
        model: TranscriptionModelID,
        requiresVocabulary: Bool = false
    ) -> TranscriptionEngineFailure? {
        failures[FailureKey(useCase: useCase, engine: engine, model: model, requiresVocabulary: requiresVocabulary)]?.failure
    }

    // MARK: - Falhas

    /// Registra a falha nos livros do coordenador — quando a política do pedido permitir.
    ///
    /// Duas escritas, com **alcances diferentes** desde a T2.5: a **supressão** (`failures`, que faz
    /// o próximo pedido pular o candidato sem tocar no motor) é escrita por caso de uso; a **marca
    /// de latch** (`latchedModels`, que faz a tentativa seguinte descarregar antes de preparar de
    /// novo) é global, porque descreve o motor e não o consumidor.
    ///
    /// `recordsGlobalFailure == false` pula as duas, e é de propósito que sejam as duas juntas: se
    /// só a supressão fosse pulada, os pedidos seguintes do MESMO consumidor veriam a marca de
    /// latch, descarregariam e tentariam baixar de novo — a cada 1,2 s, no caso da tradução. Sem
    /// nenhuma das duas, o pedido seguinte bate no latch **interno do motor**, que re-lança na hora
    /// sem disco nem rede: falha barata, repetível e que não sai da tela de quem falhou.
    ///
    /// O que este parâmetro **não** desfaz: o latch do próprio motor é compartilhado por contrato
    /// (T2.1/T2.2), exatamente como o `initializationFailed` do `TranscriptionService` legado era
    /// compartilhado pelas três telas. Se o Whisper está latchado, ele está latchado para todo
    /// mundo — o que muda é que a tradução não acrescenta a isso uma supressão de 300 s escrita nos
    /// livros do coordenador.
    private func noteFailure(
        _ failure: TranscriptionEngineFailure,
        for candidate: TranscriptionRoutingCandidate,
        stage: TranscriptionAttempt.Stage,
        key: FailureKey,
        latchKey: LatchKey,
        policy: TranscriptionRetryPolicy
    ) {
        guard policy.recordsGlobalFailure else { return }
        // Só a falha de preparação latcha no motor; a de inferência não mexe em pesos.
        if stage == .preparation { latchedModels.insert(latchKey) }
        failures[key] = FailureRecord(failure: failure, at: now(), stage: stage)
    }

    private func isCooledDown(_ record: FailureRecord, policy: TranscriptionRetryPolicy) -> Bool {
        now().timeIntervalSince(record.at) >= policy.failureCooldown
    }

    // MARK: - Peso e proveniência

    /// O peso do modelo, segundo o catálogo.
    ///
    /// Modelo desconhecido conta como **pesado**: a regra existe para não estourar memória, e o
    /// erro seguro é manter um só. `Whisper small` é `.light` no descritor — a regra do plano
    /// ("small não conta como pesado") mora lá, em dado, não aqui em código.
    private func weight(of candidate: TranscriptionRoutingCandidate) -> TranscriptionModelWeight {
        router.catalog.weight(of: candidate.model, in: candidate.engine)
    }

    /// Carimba o resultado com a proveniência do candidato que de fato rodou.
    ///
    /// Os dois motores já montam a proveniência a partir do candidato, então em regime normal isto
    /// não muda nada. Ele existe porque a proveniência é o contrato do coordenador com o resto do
    /// app — histórico, aviso de fallback, benchmark da Onda 3 — e um motor de terceiro (ou um
    /// motor com bug) não pode mentir sobre `candidateRank` ou `origin` sem que o coordenador
    /// note. O texto e os segmentos são do motor; a atribuição é do plano.
    private nonisolated static func stamped(
        _ result: TranscriptionEngineResult,
        candidate: TranscriptionRoutingCandidate,
        useCase: TranscriptionUseCase
    ) -> TranscriptionEngineResult {
        var stamped = result
        stamped.provenance = TranscriptionProvenance(candidate: candidate, useCase: useCase)
        stamped.provenance.recognizer = result.provenance.recognizer
        return stamped
    }

    // MARK: - A vaga com prioridade

    /// Conquista a vaga do coordenador. Devolve `false` quando o chamador foi cancelado enquanto
    /// esperava — nesse caso ele **não** tem a vaga e não deve devolvê-la.
    /// - Parameter cancellable: `false` é para o `unloadAll` — descarregar memória é justamente o
    ///   que não pode desistir no meio. É a mesma distinção que os dois motores fazem na vaga
    ///   deles.
    private func acquirePermit(isInteractive: Bool, cancellable: Bool = true) async -> Bool {
        guard permitBusy else {
            permitBusy = true
            return true
        }
        let ticket = nextTicket()
        guard cancellable else {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enqueue(
                    PermitWaiter(ticket: ticket, isInteractive: isInteractive, continuation: continuation)
                )
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enqueue(
                    PermitWaiter(ticket: ticket, isInteractive: isInteractive, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.abandonPermit(ticket: ticket) }
        }
    }

    /// Insere o waiter respeitando a prioridade: todo interativo fica à frente de todo batch, e
    /// dentro de cada classe vale a ordem de chegada.
    ///
    /// Isto sozinho **causa inanição**, e a versão anterior deste arquivo afirmava o contrário
    /// ("um interativo só passa à frente de quem ainda espera") — que é a definição do problema,
    /// não a defesa contra ele. O caso não é hipotético: `.translationChunk` é interativo e chega
    /// continuamente enquanto o usuário fala na tradução ao vivo, e na Onda 4 `.meetingPreview`
    /// também é, a cada poucos segundos, durante a reunião inteira; os lotes `.meetingFinal`
    /// ficariam sem ser servidos enquanto isso durasse. Quem impede é a cota em `releasePermit`.
    private func enqueue(_ waiter: PermitWaiter) {
        guard waiter.isInteractive, let index = permitWaiters.firstIndex(where: { !$0.isInteractive }) else {
            permitWaiters.append(waiter)
            return
        }
        permitWaiters.insert(waiter, at: index)
    }

    /// Sai da fila. Se já tiver sido servido, não faz nada: quem foi servido tem a vaga e é ele
    /// quem a devolve.
    private func abandonPermit(ticket: Int) {
        guard let index = permitWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        permitWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Passa a vaga adiante — respeitando a prioridade **e** a cota de justiça.
    ///
    /// A cota é a defesa contra a inanição que a ordenação por classe cria sozinha: depois de
    /// `interactiveGrantsBeforeBatch` concessões seguidas a trabalho interativo, a próxima vaga vai
    /// para o **lote mais antigo** da fila, mesmo havendo interativo esperando. A garantia que se
    /// quer é "interativo antes de batch", não "batch nunca".
    ///
    /// O número (3) é o que mantém a latência do interativo dominada por, no máximo, uma inferência
    /// de lote a cada três, e ao mesmo tempo garante que os lotes de uma reunião progridam durante
    /// uma tradução ao vivo contínua. É configurável no `init` e está levantado para registro em
    /// DECISOES.
    private func releasePermit() {
        guard !permitWaiters.isEmpty else {
            permitBusy = false
            consecutiveInteractiveGrants = 0
            return
        }

        let oldestBatch = permitWaiters.firstIndex { !$0.isInteractive }
        let index: Int
        if let oldestBatch, consecutiveInteractiveGrants >= interactiveGrantsBeforeBatch {
            index = oldestBatch
        } else {
            index = 0
        }

        let served = permitWaiters.remove(at: index)
        if served.isInteractive {
            // Só conta quem de fato furou a fila: um interativo servido sem lote nenhum atrás não
            // atrasou ninguém, e contá-lo faria a cota disparar na primeira vez que um lote
            // chegasse.
            consecutiveInteractiveGrants += oldestBatch == nil ? 0 : 1
        } else {
            consecutiveInteractiveGrants = 0
        }
        served.continuation.resume(returning: true)
    }

    private func nextTicket() -> Int {
        ticketCounter += 1
        return ticketCounter
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw TranscriptionCoordinatorError.cancelled }
    }
}
