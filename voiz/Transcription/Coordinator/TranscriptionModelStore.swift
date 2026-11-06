import Foundation

// O depósito de pesos que **nós** distribuímos (T2.3).
//
// Escopo, para não haver engano: hoje o WhisperKit baixa pelo `HubApi` dele e o Parakeet pelo
// ModelHub do FluidAudio — os dois motores continuam donos do próprio download, e este store não
// se mete nisso. Ele existe para os artefatos que o Voiz publica e valida por conta própria: o
// TAGARELA CoreML da Onda 5 (`AsrModels.load(from:)` + manifesto com SHA-256 e atribuições) é o
// primeiro cliente. Escrevê-lo agora, junto do coordenador, é o que evita que a Onda 5 invente
// uma segunda política de download com outras garantias.
//
// Depende só de Foundation: compila no alvo `voizTests` e é exercitado inteiro com dublês. Quem
// fala com o disco de verdade é `LiveTranscriptionModelStorage`.

/// Um artefato de modelo baixável, com tudo que o valida.
///
/// A `revision` faz parte do caminho no disco de propósito: é ela que permite a revisão nova
/// coexistir com a antiga enquanto está sendo validada — e a antiga só é apagada depois.
nonisolated struct TranscriptionModelArtifact: Sendable, Equatable, Hashable {
    var engine: TranscriptionEngineID
    var model: TranscriptionModelID
    /// Revisão dos pesos (commit/tag do repositório de origem). Duas revisões do mesmo modelo
    /// podem existir ao mesmo tempo no disco; só uma sobrevive ao fim de uma instalação.
    var revision: String
    /// Nome do arquivo baixado dentro da pasta da revisão.
    var fileName: String
    var source: URL
    /// SHA-256 esperado do arquivo baixado, em hex. A comparação é case-insensitive.
    var sha256: String
    /// Tamanho declarado no manifesto, em bytes. É a base do cálculo de espaço livre.
    var expectedBytes: Int64

    init(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID,
        revision: String,
        fileName: String,
        source: URL,
        sha256: String,
        expectedBytes: Int64
    ) {
        self.engine = engine
        self.model = model
        self.revision = revision
        self.fileName = fileName
        self.source = source
        self.sha256 = sha256
        self.expectedBytes = expectedBytes
    }
}

/// Falhas do depósito, no vocabulário do coordenador.
nonisolated enum TranscriptionModelStoreError: Error, Sendable, Equatable {
    /// Não há espaço para a exigência de 120%. Carrega os números para a UI poder dizer quanto
    /// falta em vez de só "sem espaço".
    case insufficientSpace(required: Int64, available: Int64)
    /// O que chegou não é o que o manifesto prometeu. O artefato baixado é descartado e a
    /// revisão que já estava instalada continua intacta.
    case checksumMismatch(model: TranscriptionModelID, expected: String, actual: String)
    case downloadFailed(String)
    /// O disco recusou uma operação (criar pasta, mover, apagar).
    case storageFailed(String)
    /// O artefato do manifesto não é instalável com segurança — `fileName` que navega para fora
    /// do depósito, SHA ausente. Recusa explícita, e não normalização silenciosa: o manifesto
    /// está errado, e quem o publicou precisa saber.
    case invalidArtifact(String)
    case cancelled

    /// Como o coordenador reporta isto para o resto do app.
    ///
    /// Tudo que não é cancelamento vira `modelUnavailable`: do ponto de vista de quem ia
    /// transcrever, um SHA errado e um disco cheio dão no mesmo — estes pesos não servem, tente
    /// o próximo candidato. Cancelamento continua sem fallback.
    func engineFailure(model: TranscriptionModelID) -> TranscriptionEngineFailure {
        self == .cancelled ? .cancelled : .modelUnavailable(model)
    }
}

/// As operações de disco de que o store precisa.
///
/// Seam porque o que está sendo testado aqui é a **ordem** das operações — validar antes de
/// apagar, conferir espaço antes de baixar —, e provar ordem contra o disco de verdade exigiria
/// encher um volume.
nonisolated protocol TranscriptionModelStorage: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func moveItem(from source: URL, to destination: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func read(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    /// Bytes livres no volume que contém `url`.
    func availableCapacity(at url: URL) throws -> Int64
    /// SHA-256 do arquivo, em hex minúsculo.
    func sha256(at url: URL) throws -> String
}

/// Quem busca os bytes. Separado do disco porque a rede é a parte que muda entre produção
/// (URLSession) e teste (arquivo escrito na hora).
nonisolated protocol TranscriptionModelDownloading: Sendable {
    /// Baixa `artifact` e deixa o arquivo exatamente em `destination`.
    ///
    /// `destination` está dentro de uma pasta de staging que o store acabou de criar e vai
    /// apagar se algo der errado — o downloader não precisa limpar nada.
    func download(
        _ artifact: TranscriptionModelArtifact,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// O depósito local dos pesos: baixa, valida e instala — nessa ordem, sempre.
///
/// ## As três garantias
///
/// 1. **120% de espaço livre.** Antes de baixar qualquer coisa, o volume precisa ter 1,2× o
///    tamanho declarado. A folga não é superstição: o arquivo baixado e a revisão antiga
///    convivem no disco até a validação terminar, e um disco que enche no meio do download
///    deixaria as duas revisões quebradas.
/// 2. **Instalação atômica.** O download vai para uma pasta de staging; só depois de o SHA-256
///    bater é que ela é movida para o lugar definitivo. Um crash no meio nunca deixa uma pasta
///    de revisão pela metade que a próxima abertura do app confundiria com pesos válidos —
///    quem carimba "esta revisão está boa" é o recibo, escrito por último.
/// 3. **A revisão antiga só é apagada depois que a nova está validada e instalada.** É a regra
///    explícita do plano, e a razão dela é simples: um usuário que perde os pesos antigos por
///    causa de um download corrompido fica sem transcrever até baixar tudo de novo.
///
/// Nada no app usa este store ainda.
actor TranscriptionModelStore {

    /// Quanto espaço livre exigir, em múltiplos do tamanho declarado.
    ///
    /// Configurável só para o teste conseguir descrever o limite sem depender do valor de
    /// produção; o default é a regra do plano.
    static let defaultFreeSpaceRatio = 1.2

    private let root: URL
    private let storage: any TranscriptionModelStorage
    private let downloader: any TranscriptionModelDownloading
    private let freeSpaceRatio: Double

    /// Instalações em voo, por chave de staging. É o single-flight do download — ver `install`.
    ///
    /// Só instalações **ativas** moram aqui: uma que perdeu o último aguardante sai deste mapa no
    /// mesmo instante em que a decisão de cancelar é tomada, para que ninguém adira a ela.
    private var inflightInstalls: [InstallKey: InflightInstall] = [:]

    /// Instalações abandonadas que ainda estão drenando, por chave e por id.
    ///
    /// Elas não aceitam mais aguardantes — quem chega abre uma instalação nova —, mas continuam
    /// existindo para `removeAll` poder esperá-las: uma remoção que ignorasse o dreno de uma
    /// abandonada voltaria a devolver sucesso com trabalho vivo por baixo.
    private var drainingInstalls: [InstallKey: [Int: Task<URL, any Error>]] = [:]

    private var installIDCounter = 0

    /// A raiz já foi criada e o lixo de execuções anteriores já foi podado nesta sessão?
    private var rootIsPrepared = false

    /// Modelos com remoção em curso. Enquanto o modelo estiver aqui, nenhuma instalação nova dele
    /// começa — é o dreno da remoção, e é o que impede uma instalação de ressuscitar o que a UI
    /// acabou de mandar apagar.
    private var removalsInFlight: Set<ModelKey> = []

    /// Quem está esperando uma remoção terminar (instaladores barrados, ou uma segunda remoção do
    /// mesmo modelo).
    private var removalWaiters: [ModelKey: [Int: CheckedContinuation<Void, Never>]] = [:]

    private var waiterTicketCounter = 0

    /// Duas instalações com a mesma chave disputam a MESMA pasta de staging, então não podem
    /// correr juntas — mesmo quando os artefatos são diferentes (revisão republicada).
    private struct InstallKey: Hashable {
        var engine: TranscriptionEngineID
        var model: TranscriptionModelID
        var revision: String

        init(_ artifact: TranscriptionModelArtifact) {
            self.engine = artifact.engine
            self.model = artifact.model
            self.revision = artifact.revision
        }

        init(engine: TranscriptionEngineID, model: TranscriptionModelID, revision: String) {
            self.engine = engine
            self.model = model
            self.revision = revision
        }
    }

    /// Uma instalação em voo e **quem ainda a quer**.
    ///
    /// A contagem de aguardantes é o que torna o cancelamento honesto nos dois sentidos: quem
    /// cancela sai na hora (a espera dele é uma continuation nossa, não `task.value`), e a carga
    /// compartilhada só morre quando o ÚLTIMO interessado desiste — cancelar o download de quem
    /// ainda espera por ele seria pior que não cancelar nada.
    private struct InflightInstall {
        /// Identidade desta instalação. Serve ao "esta instalação ainda é a corrente?" — quando uma
        /// abandonada drena enquanto uma nova assume a mesma chave, é o `id` que impede a
        /// moribunda de desregistrar a nova ao terminar.
        var id: Int
        var artifact: TranscriptionModelArtifact
        var task: Task<URL, any Error>
        /// Aguardantes por ticket. A posse é o valor da retomada: `nil` = você desistiu (foi
        /// cancelado) e não recebe resultado; `.some` = o desfecho da instalação é seu. É o mesmo
        /// protocolo da vaga dos motores, e existe pela mesma razão — decidir por efeito colateral
        /// perde a corrida entre o `onCancel` e a conclusão.
        var waiters: [Int: CheckedContinuation<Result<URL, any Error>?, Never>] = [:]
    }

    /// Um modelo, sem a revisão. É a granularidade da remoção: `removeAll` apaga o modelo inteiro.
    private struct ModelKey: Hashable {
        var engine: TranscriptionEngineID
        var model: TranscriptionModelID
    }

    init(
        root: URL,
        storage: any TranscriptionModelStorage,
        downloader: any TranscriptionModelDownloading,
        freeSpaceRatio: Double = TranscriptionModelStore.defaultFreeSpaceRatio
    ) {
        self.root = root
        self.storage = storage
        self.downloader = downloader
        self.freeSpaceRatio = freeSpaceRatio
    }

    // MARK: - Dono único por raiz

    /// O store **desta raiz**, criando-o na primeira chamada.
    ///
    /// As garantias deste tipo são por instância — `inflightInstalls`, `removalsInFlight` e
    /// `rootIsPrepared` vivem aqui dentro —, mas a raiz é do processo: dois stores sobre a mesma
    /// pasta voltariam a colidir no staging, e a poda de abertura de um apagaria o download em voo
    /// do outro. Como o construtor continua público (os testes montam stores sobre raízes falsas),
    /// quem constrói o store de produção passa por aqui.
    ///
    /// A caixa é estática com `NSLock`, e não um ator, para a fábrica poder ser síncrona — é a
    /// mesma forma que a T3.3 usou depois do mesmo achado.
    static func shared(
        root: URL,
        storage: @autoclosure () -> any TranscriptionModelStorage,
        downloader: @autoclosure () -> any TranscriptionModelDownloading
    ) -> TranscriptionModelStore {
        SharedStores.box.store(for: root) {
            TranscriptionModelStore(root: root, storage: storage(), downloader: downloader())
        }
    }

    /// Os stores vivos, por raiz canônica.
    private enum SharedStores {
        static let box = Box()

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stores: [String: TranscriptionModelStore] = [:]

            func store(
                for root: URL,
                make: () -> TranscriptionModelStore
            ) -> TranscriptionModelStore {
                let key = URL(fileURLWithPath: root.path).standardizedFileURL.path
                lock.lock()
                defer { lock.unlock() }
                if let existing = stores[key] { return existing }
                let created = make()
                stores[key] = created
                return created
            }
        }
    }

    // MARK: - Consulta

    /// O arquivo instalado desta revisão, ou `nil` se ela não está instalada **e validada**.
    ///
    /// "Validada" quer dizer: existe o recibo e ele descreve este artefato. Uma pasta com o
    /// payload mas sem recibo é lixo de uma instalação interrompida — para este store ela não
    /// existe, e a próxima instalação a substitui.
    func installedURL(for artifact: TranscriptionModelArtifact) -> URL? {
        // Artefato inválido nunca foi instalado por este store — e não vale montar caminho com
        // um `fileName` que navega, nem para só ler.
        guard (try? Self.validate(artifact)) != nil else { return nil }
        let payload = payloadURL(for: artifact)
        guard storage.fileExists(at: payload), let receipt = receipt(for: artifact) else { return nil }
        guard receipt.matches(artifact) else { return nil }
        return payload
    }

    // MARK: - Diagnóstico
    //
    // Os três acessores abaixo existem para os testes poderem afirmar "a instalação continuou viva
    // porque alguém ainda a esperava" e "a instalação nova ficou barrada pela remoção" sem dormir e
    // torcer. Sem eles, um teste de interleaving dependeria do escalonador do dia.

    /// Quantos chamadores ainda esperam esta instalação. `0` = nenhuma em voo para esta chave.
    func waiterCount(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID,
        revision: String
    ) -> Int {
        inflightInstalls[InstallKey(engine: engine, model: model, revision: revision)]?.waiters.count ?? 0
    }

    /// Quantas instalações abandonadas ainda drenam nesta chave. Diagnóstico e teste.
    func drainingInstallCount(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID,
        revision: String
    ) -> Int {
        drainingInstalls[InstallKey(engine: engine, model: model, revision: revision)]?.count ?? 0
    }

    /// Há uma instalação ATIVA (aceitando aguardantes) nesta chave?
    func hasActiveInstall(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID,
        revision: String
    ) -> Bool {
        inflightInstalls[InstallKey(engine: engine, model: model, revision: revision)] != nil
    }

    /// Há uma remoção deste modelo drenando agora?
    func isRemoving(engine: TranscriptionEngineID, model: TranscriptionModelID) -> Bool {
        removalsInFlight.contains(ModelKey(engine: engine, model: model))
    }

    /// Quantas instalações estão barradas esperando alguma remoção terminar.
    func installsWaitingForRemoval() -> Int {
        removalWaiters.values.reduce(0) { $0 + $1.count }
    }

    /// As revisões instaladas de um modelo, em ordem alfabética. Em regime normal tem uma só —
    /// mais de uma significa que uma instalação anterior morreu antes de limpar.
    func installedRevisions(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID
    ) -> [String] {
        let directory = modelURL(engine: engine, model: model)
        guard let entries = try? storage.contentsOfDirectory(at: directory) else { return [] }
        return entries.map { $0.lastPathComponent }.sorted()
    }

    // MARK: - Instalação

    /// Garante que `artifact` esteja instalado, baixando se preciso, e devolve o arquivo local.
    ///
    /// A ordem das etapas é o contrato:
    /// 1. já instalado e validado → devolve na hora, sem tocar em disco nem em rede;
    /// 2. espaço livre (120%) → falha **antes** de baixar e sem apagar nada;
    /// 3. download para staging;
    /// 4. SHA-256 → não bateu: apaga só o staging e lança; a revisão antiga continua lá;
    /// 5. move o staging para o lugar definitivo e escreve o recibo;
    /// 6. **só agora** apaga as outras revisões do mesmo modelo.
    @discardableResult
    func install(
        _ artifact: TranscriptionModelArtifact,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try checkCancelled()
        // Validação do artefato ANTES de tocar em disco: um `fileName` que escapa não pode chegar
        // nem ao staging, e um artefato inválido não pode criar pasta nem apagar nada.
        try Self.validate(artifact)

        let key = InstallKey(artifact)
        let modelKey = ModelKey(engine: artifact.engine, model: artifact.model)

        while true {
            try checkCancelled()

            // Uma remoção deste modelo está drenando: instalar agora seria correr para ressuscitar
            // o que a UI mandou apagar. Espera a remoção terminar e reavalia.
            if removalsInFlight.contains(modelKey) {
                try await waitForRemoval(of: modelKey)
                continue
            }

            if let inflight = inflightInstalls[key] {
                // Single-flight: sem isto, a segunda chamada apagaria a pasta de staging em que a
                // primeira está baixando (as duas derivam o mesmo caminho de
                // engine+model+revision) e as duas escreveriam no mesmo arquivo.
                let isSameArtifact = inflight.artifact == artifact
                do {
                    let outcome = try await join(key: key)
                    // Mesma instalação: o desfecho dela é o nosso. Artefato diferente com a mesma
                    // chave de staging (revisão republicada com outro SHA): não dá para dividir a
                    // carga, então reavaliamos do zero.
                    if isSameArtifact { return try outcome.get() }
                } catch is InstallVanished {
                    // Acabou antes de nos registrarmos: reavalia.
                }
                continue
            }

            // Daqui até registrar a instalação não há `await`: decidir abrir e registrar são
            // atômicos do ponto de vista do ator, então nunca há duas para a mesma chave.
            let id = nextInstallID()
            let task = Task<URL, any Error> {
                let outcome: Result<URL, any Error>
                do {
                    outcome = .success(try await self.runInstall(artifact, id: id, onProgress: onProgress))
                } catch {
                    outcome = .failure(error)
                }
                // A baixa do registro e a entrega aos aguardantes moram DENTRO da tarefa, e não num
                // `defer` de quem a criou: quem espera acorda quando a tarefa termina, e se a
                // limpeza dependesse do `defer` do criador (que roda depois), o laço acima
                // encontraria a entrada ainda lá e giraria para sempre.
                self.finish(key: key, id: id, outcome: outcome)
                return try outcome.get()
            }
            inflightInstalls[key] = InflightInstall(id: id, artifact: artifact, task: task)
            // O criador é só o primeiro aguardante: o cancelamento dele vale igual ao dos outros,
            // e se for o único a instalação compartilhada morre junto.
            return try await join(key: key).get()
        }
    }

    /// Espera a instalação registrada em `key`, de um jeito que o cancelamento de QUEM ESPERA
    /// termina a espera na hora.
    ///
    /// Era o MAIOR da re-review: `await task.value` numa `Task` não estruturada não devolve cedo
    /// para quem foi cancelado, e o `Task.isCancelled` lá dentro é o da tarefa compartilhada — que
    /// segue viva. Resultado: o chamador cancelado ficava preso até o fim do download e ainda
    /// recebia sucesso, e `.cancelled` virava caso quase inalcançável.
    ///
    /// A instalação compartilhada só é cancelada quando o **último** aguardante desiste: matá-la
    /// enquanto alguém ainda a quer trocaria um problema por outro.
    private func join(key: InstallKey) async throws -> Result<URL, any Error> {
        let ticket = nextWaiterTicket()
        let outcome: Result<URL, any Error>? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, any Error>?, Never>) in
                guard inflightInstalls[key] != nil else {
                    // A instalação terminou entre a decisão e o registro do aguardante. Não é
                    // desistência: o laço de `install` reavalia e encontra o resultado no disco.
                    continuation.resume(returning: nil)
                    return
                }
                inflightInstalls[key]?.waiters[ticket] = continuation
            }
        } onCancel: {
            Task { await self.abandonWait(key: key, ticket: ticket) }
        }

        guard let outcome else {
            // `nil` chega por dois caminhos: desistimos por cancelamento, ou a instalação já tinha
            // acabado quando fomos registrar. Cancelamento manda no desfecho.
            try checkCancelled()
            // Não fomos cancelados: a instalação sumiu do mapa antes de nos registrarmos. Devolver
            // um "resultado" seria mentira; quem chamou reavalia no laço.
            throw InstallVanished()
        }

        // Borda POSTERIOR de cancelamento, igual à dos dois motores depois da inferência: o
        // `finish` pode ter vencido o hop do `onCancel` e nos entregado um desfecho real depois de
        // já termos sido cancelados. Entregar sucesso a quem desistiu seria mentira — e os pesos
        // ficaram instalados de qualquer forma, então a chamada seguinte os encontra no caminho
        // rápido.
        try checkCancelled()
        return outcome
    }

    /// Sai da fila de espera de uma instalação. Se ninguém mais a quer, ela é **desregistrada e
    /// cancelada, nessa ordem e sem `await` no meio**.
    ///
    /// A ordem é o achado: enquanto a instalação cancelada continuava registrada durante o dreno,
    /// um chamador NOVO — que ninguém cancelou — encontrava a `Task` já irreversivelmente
    /// cancelada, se registrava nela e recebia `.cancelled` alheio em vez de começar a própria
    /// instalação. Desregistrar no instante da decisão faz quem chegar depois cair no ramo de
    /// criação e abrir uma instalação nova; a moribunda drena **fora do registro**.
    ///
    /// A moribunda não some do mapa e pronto: ela vai para `drainingInstalls`, porque `removeAll`
    /// precisa esperá-la também — uma remoção que ignorasse o dreno de uma instalação abandonada
    /// voltaria a poder devolver sucesso com trabalho vivo por baixo.
    private func abandonWait(key: InstallKey, ticket: Int) {
        guard var inflight = inflightInstalls[key] else { return }
        guard let continuation = inflight.waiters.removeValue(forKey: ticket) else { return }

        if inflight.waiters.isEmpty {
            // Desregistra ANTES de cancelar, e sem suspender: a partir daqui a chave está livre.
            inflightInstalls[key] = nil
            drainingInstalls[key, default: [:]][inflight.id] = inflight.task
            inflight.task.cancel()
        } else {
            inflightInstalls[key] = inflight
        }

        continuation.resume(returning: nil)
    }

    /// Entrega o desfecho aos aguardantes e desregistra a instalação — **se ela ainda for a
    /// corrente**.
    ///
    /// O `id` é o que impede uma moribunda de arrastar consigo a instalação nova que assumiu a
    /// mesma chave: sem ele, o `finish` da abandonada removeria a entrada de quem acabou de
    /// começar, e os aguardantes da nova ficariam pendurados para sempre. É o mesmo `isCurrent(id)`
    /// que os dois motores usam para saber se a carga em voo ainda vale.
    private func finish(key: InstallKey, id: Int, outcome: Result<URL, any Error>) {
        drainingInstalls[key]?[id] = nil
        if drainingInstalls[key]?.isEmpty == true { drainingInstalls[key] = nil }

        guard let inflight = inflightInstalls[key], inflight.id == id else { return }
        inflightInstalls[key] = nil
        for continuation in inflight.waiters.values {
            continuation.resume(returning: outcome)
        }
    }

    /// A instalação que esperávamos desapareceu do mapa antes de nos registrarmos — sinal interno
    /// para o laço de `install` reavaliar, nunca visto por quem chama.
    private struct InstallVanished: Error {}

    private func nextWaiterTicket() -> Int {
        waiterTicketCounter += 1
        return waiterTicketCounter
    }

    private func nextInstallID() -> Int {
        installIDCounter += 1
        return installIDCounter
    }

    /// A instalação de fato, com no máximo uma em voo por chave de staging.
    private func runInstall(
        _ artifact: TranscriptionModelArtifact,
        id: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // Cria a raiz (sem apagar nada) e poda o lixo de execuções anteriores. Tem que vir antes
        // de medir o volume por dois motivos: numa máquina limpa a raiz **não existe**, e medir
        // capacidade numa URL inexistente falha com Cocoa 260 — a primeira instalação da vida do
        // app morria aí, antes de qualquer rede; e um staging órfão conta contra o espaço livre,
        // podendo produzir `insufficientSpace` num disco que teria folga de sobra depois da poda.
        try prepareRootIfNeeded()

        if let installed = installedURL(for: artifact) {
            // Caminho rápido, mas não cego: um crash entre o `moveItem` e a poda deixava a revisão
            // antiga no disco **para sempre**, porque toda instalação seguinte saía por aqui e
            // nunca chegava ao `removeOtherRevisions`. Custa uma listagem de diretório.
            removeOtherRevisions(of: artifact)
            return installed
        }

        let staging = stagingURL(for: artifact, id: id)
        // Restos de uma tentativa anterior que morreu no meio: o staging é sempre nosso e sempre
        // começa vazio. **Antes** da conta de espaço — ver `prepareRootIfNeeded`.
        try? storage.removeItem(at: staging)

        try requireFreeSpace(for: artifact)

        do {
            try storage.createDirectory(at: staging)
        } catch {
            throw TranscriptionModelStoreError.storageFailed("não foi possível criar o staging: \(error)")
        }

        let stagedPayload = staging.appendingPathComponent(artifact.fileName)
        // Cinto e suspensório sobre a validação de `fileName`: se algum dia um componente escapar
        // da validação, ele não sai do depósito em silêncio.
        try Self.requireContainment(of: stagedPayload, in: staging)
        do {
            try await downloader.download(artifact, to: stagedPayload, onProgress: onProgress)
            try checkCancelled()

            let digest = try storage.sha256(at: stagedPayload).lowercased()
            let expected = artifact.sha256.lowercased()
            guard digest == expected else {
                throw TranscriptionModelStoreError.checksumMismatch(
                    model: artifact.model,
                    expected: expected,
                    actual: digest
                )
            }

            // O recibo é escrito no staging, antes do move: assim a pasta chega ao destino já
            // completa, e não existe instante em que a pasta definitiva esteja sem carimbo.
            let receipt = Receipt(artifact: artifact)
            try storage.write(try receipt.encoded(), to: staging.appendingPathComponent(Receipt.fileName))
        } catch {
            try? storage.removeItem(at: staging)
            throw Self.storeError(from: error)
        }

        do {
            let destination = revisionURL(for: artifact)
            try storage.createDirectory(at: modelURL(engine: artifact.engine, model: artifact.model))
            // Uma pasta já no destino é, por definição, uma instalação interrompida (a validada
            // teria sido devolvida lá em cima pelo caminho rápido).
            try? storage.removeItem(at: destination)
            try storage.moveItem(from: staging, to: destination)
        } catch {
            try? storage.removeItem(at: staging)
            throw TranscriptionModelStoreError.storageFailed("não foi possível instalar a revisão: \(error)")
        }

        // Só agora: a revisão nova está no disco, validada e com recibo.
        removeOtherRevisions(of: artifact)

        return payloadURL(for: artifact)
    }

    /// Apaga todas as revisões de um modelo. É a limpeza explícita da UI ("remover modelo"), não
    /// parte de nenhuma instalação.
    ///
    /// **Exclusiva com as instalações do modelo, e ela drena.** Era o segundo MAIOR da re-review:
    /// o ator reentra no `await` do downloader, então a remoção podia apagar a pasta, devolver
    /// sucesso, e a instalação retomar depois, recriar o diretório e mover o staging para o
    /// destino — ressuscitando exatamente o modelo que a UI acabou de remover. A garantia agora é
    /// a mesma dos motores no `unload`: quando esta função devolve, não há instalação deste modelo
    /// viva, e nenhuma que tenha começado antes dela pode commitar depois.
    ///
    /// A ordem é: marca o modelo como em remoção (o que barra instalações NOVAS na entrada do
    /// `install`), cancela as instalações em voo dele, **espera cada uma terminar de verdade**, e
    /// só então apaga. Idempotente: remover o que não existe é sucesso.
    func removeAll(engine: TranscriptionEngineID, model: TranscriptionModelID) async throws {
        let modelKey = ModelKey(engine: engine, model: model)

        // Duas remoções do mesmo modelo não se atropelam: a segunda espera a primeira.
        while removalsInFlight.contains(modelKey) {
            await waitForRemovalUncancellably(of: modelKey)
        }

        removalsInFlight.insert(modelKey)
        defer { finishRemoval(of: modelKey) }

        // Cancela e AGUARDA cada instalação deste modelo — as ativas E as abandonadas que ainda
        // drenam. O `await` aqui é o dreno: sem ele, "removi" seria só "mandei remover"; e ignorar
        // as abandonadas deixaria trabalho vivo por baixo de uma remoção que devolveu sucesso.
        while let task = anyInstallTask(engine: engine, model: model) {
            task.cancel()
            _ = try? await task.value
            // O laço reavalia: `removalsInFlight` barra instalações novas, mas mantê-lo explícito
            // vale mais que assumir a invariante.
        }

        let directory = modelURL(engine: engine, model: model)
        guard storage.fileExists(at: directory) else { return }
        do {
            try storage.removeItem(at: directory)
        } catch {
            throw TranscriptionModelStoreError.storageFailed("não foi possível remover o modelo: \(error)")
        }
    }

    /// Qualquer instalação daquele modelo — ativa ou drenando. `nil` = não há nenhuma.
    private func anyInstallTask(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID
    ) -> Task<URL, any Error>? {
        if let active = inflightInstalls.first(where: {
            $0.key.engine == engine && $0.key.model == model
        }) {
            return active.value.task
        }
        for (key, tasks) in drainingInstalls where key.engine == engine && key.model == model {
            if let task = tasks.values.first { return task }
        }
        return nil
    }

    /// Espera a remoção em curso deste modelo terminar. **Cancelável de verdade**: o aguardante é
    /// registrado por ticket, e o `onCancel` o tira da lista — quem instala e é cancelado enquanto
    /// espera uma remoção sai na hora, sem depender de a remoção acabar.
    private func waitForRemoval(of modelKey: ModelKey) async throws {
        let ticket = nextWaiterTicket()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard removalsInFlight.contains(modelKey) else {
                    continuation.resume()
                    return
                }
                removalWaiters[modelKey, default: [:]][ticket] = continuation
            }
        } onCancel: {
            Task { await self.abandonRemovalWait(of: modelKey, ticket: ticket) }
        }
        try checkCancelled()
    }

    /// Sai da fila de uma remoção. Retomar a continuation aqui é seguro porque `finishRemoval`
    /// remove o ticket antes de retomar — só um dos dois encontra a entrada.
    private func abandonRemovalWait(of modelKey: ModelKey, ticket: Int) {
        guard let continuation = removalWaiters[modelKey]?.removeValue(forKey: ticket) else { return }
        continuation.resume()
    }

    /// A versão sem cancelamento, para uma remoção esperar a outra: desistir no meio deixaria o
    /// modelo em estado indefinido para quem pediu a remoção.
    private func waitForRemovalUncancellably(of modelKey: ModelKey) async {
        let ticket = nextWaiterTicket()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard removalsInFlight.contains(modelKey) else {
                continuation.resume()
                return
            }
            removalWaiters[modelKey, default: [:]][ticket] = continuation
        }
    }

    private func finishRemoval(of modelKey: ModelKey) {
        removalsInFlight.remove(modelKey)
        let waiters = removalWaiters.removeValue(forKey: modelKey) ?? [:]
        for continuation in waiters.values { continuation.resume() }
    }

    // MARK: - Validação do artefato

    /// Recusa artefatos que não podem ser instalados com segurança.
    ///
    /// `fileName` é **rejeitado**, e não normalizado em silêncio, ao contrário do trio
    /// engine/model/revision. A diferença é deliberada: o trio nomeia **pastas que só o store
    /// enxerga**, então dobrar um caractere ilegal para `_` é uma identidade interna e nada mais.
    /// O `fileName` é o nome do arquivo que o motor vai **abrir** — renomeá-lo por baixo faria o
    /// payload instalado divergir do manifesto, e o defeito só apareceria na hora de carregar os
    /// pesos. Um manifesto com `../../escaped.bin` não é um nome feio: é um manifesto errado, e a
    /// resposta certa é dizer isso.
    nonisolated static func validate(_ artifact: TranscriptionModelArtifact) throws {
        guard isSafePathComponent(artifact.fileName) else {
            throw TranscriptionModelStoreError.invalidArtifact(
                "fileName inválido: precisa ser um componente de caminho único, sem separadores e sem '..'"
            )
        }
        // O payload não pode se chamar como o recibo: ele seria baixado nesse caminho, passaria no
        // SHA e seria SOBRESCRITO pela escrita do recibo logo em seguida — e aí `installedURL`
        // acharia payload e recibo no mesmo arquivo, o `matches` bateria, e a instalação seria
        // reportada como sucesso devolvendo um JSON no lugar dos pesos. Corrupção silenciosa
        // carimbada como válida. O manifesto é nosso, então é improvável; SHA vazio e tamanho
        // negativo também são, e estão recusados aqui pela mesma razão declarada.
        guard artifact.fileName != Receipt.fileName else {
            throw TranscriptionModelStoreError.invalidArtifact(
                "fileName colide com o nome do recibo (\(Receipt.fileName))"
            )
        }
        guard !artifact.sha256.isEmpty else {
            throw TranscriptionModelStoreError.invalidArtifact("artefato sem SHA-256 declarado")
        }
        guard artifact.expectedBytes >= 0 else {
            throw TranscriptionModelStoreError.invalidArtifact("tamanho declarado negativo")
        }
    }

    /// Um nome de arquivo é seguro quando é **um** componente e não navega.
    ///
    /// Barra e contrabarra saem juntas: no HFS antigo o separador era `:` e o Foundation ainda
    /// traduz `:`↔`/` em algumas conversões de caminho, então ele também não passa.
    nonisolated static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        guard !component.contains("/"), !component.contains("\\"), !component.contains(":") else {
            return false
        }
        guard !component.hasPrefix("~"), !component.contains("\0") else { return false }
        return true
    }

    /// Garante que `url` fica **dentro** de `container` depois de resolvido.
    ///
    /// A validação de componente já barra o que se conhece; esta checagem é a rede embaixo dela,
    /// e responde à pergunta que interessa de verdade — "o caminho final está contido no
    /// depósito?" — em vez de confiar na enumeração de caracteres proibidos.
    nonisolated static func requireContainment(of url: URL, in container: URL) throws {
        let resolved = URL(fileURLWithPath: url.path).standardizedFileURL.path
        let base = URL(fileURLWithPath: container.path).standardizedFileURL.path
        guard resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw TranscriptionModelStoreError.invalidArtifact(
                "caminho resolvido para fora do depósito"
            )
        }
    }

    // MARK: - Raiz e coleta de lixo

    /// Cria a raiz do depósito (sem apagar conteúdo) e poda o lixo de execuções anteriores.
    ///
    /// Roda uma vez por instância do store, e **inteira dentro do ator**, sem `await` no meio:
    /// podar o `.staging` enquanto uma instalação estivesse baixando apagaria a pasta dela.
    ///
    /// O que é podado: o `.staging` inteiro. Ele só contém trabalho em voo — e como esta função
    /// roda antes de qualquer staging desta sessão existir, tudo que estiver lá é resto de um
    /// processo que morreu. Sem esta poda, um crash durante o download deixava
    /// `.staging/<chave>` no disco **para sempre** se aquele artefato específico nunca mais fosse
    /// instalado, corroendo exatamente a folga de 120% que o store existe para proteger.
    private func prepareRootIfNeeded() throws {
        guard !rootIsPrepared else { return }
        do {
            try storage.createDirectory(at: root)
        } catch {
            throw TranscriptionModelStoreError.storageFailed("não foi possível criar o depósito: \(error)")
        }
        // Falha na poda não impede instalar: sobrar lixo é ruim, não instalar é pior.
        try? storage.removeItem(at: root.appendingPathComponent(".staging", isDirectory: true))
        rootIsPrepared = true
    }

    // MARK: - Espaço

    /// Exige 120% do tamanho declarado antes de gastar rede.
    ///
    /// Falha aqui é falha **limpa**: nada foi baixado, nada foi apagado, a revisão que estava
    /// instalada continua utilizável.
    private func requireFreeSpace(for artifact: TranscriptionModelArtifact) throws {
        let required = Self.requiredBytes(for: artifact.expectedBytes, ratio: freeSpaceRatio)
        let available: Int64
        do {
            available = try storage.availableCapacity(at: root)
        } catch {
            throw TranscriptionModelStoreError.storageFailed("não foi possível medir o espaço livre: \(error)")
        }
        guard available >= required else {
            throw TranscriptionModelStoreError.insufficientSpace(required: required, available: available)
        }
    }

    /// Arredonda para cima: exigir 1,2 × N com truncamento deixaria passar por um byte.
    nonisolated static func requiredBytes(for declaredBytes: Int64, ratio: Double) -> Int64 {
        guard declaredBytes > 0 else { return 0 }
        return Int64((Double(declaredBytes) * ratio).rounded(.up))
    }

    // MARK: - Limpeza

    /// Apaga as revisões do mesmo modelo que não são a recém-instalada.
    ///
    /// Uma falha aqui é ignorada de propósito: o modelo novo já está instalado e funcionando, e
    /// transformar "sobrou lixo no disco" em "a instalação falhou" seria pior para quem só queria
    /// transcrever. A próxima instalação tenta de novo.
    private func removeOtherRevisions(of artifact: TranscriptionModelArtifact) {
        let directory = modelURL(engine: artifact.engine, model: artifact.model)
        guard let entries = try? storage.contentsOfDirectory(at: directory) else { return }
        for entry in entries where entry.lastPathComponent != Self.sanitize(artifact.revision) {
            try? storage.removeItem(at: entry)
        }
    }

    // MARK: - Caminhos

    private func modelURL(engine: TranscriptionEngineID, model: TranscriptionModelID) -> URL {
        root
            .appendingPathComponent(Self.sanitize(engine.rawValue), isDirectory: true)
            .appendingPathComponent(Self.sanitize(model.rawValue), isDirectory: true)
    }

    private func revisionURL(for artifact: TranscriptionModelArtifact) -> URL {
        modelURL(engine: artifact.engine, model: artifact.model)
            .appendingPathComponent(Self.sanitize(artifact.revision), isDirectory: true)
    }

    private func payloadURL(for artifact: TranscriptionModelArtifact) -> URL {
        revisionURL(for: artifact).appendingPathComponent(artifact.fileName)
    }

    /// A pasta de staging **desta instalação**, e não da chave.
    ///
    /// O `id` no nome é o que elimina por construção a corrida de pasta entre uma instalação
    /// abandonada que ainda drena e a nova que assumiu a mesma chave: com um caminho só, a nova
    /// apagaria o staging em que a moribunda ainda escreve, e o `catch` da moribunda apagaria
    /// depois o staging da nova, que morreria no SHA por arquivo ausente. Com caminhos distintos,
    /// cada uma só limpa o que é dela — e nenhuma precisa esperar a outra.
    ///
    /// Lixo de processos anteriores (onde os ids recomeçam do 1) não é problema: `.staging` inteiro
    /// é podado na abertura do store, antes de qualquer instalação desta sessão.
    private func stagingURL(for artifact: TranscriptionModelArtifact, id: Int) -> URL {
        root
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(
                [artifact.engine.rawValue, artifact.model.rawValue, artifact.revision]
                    .map(Self.sanitize)
                    .joined(separator: "~") + "~\(id)",
                isDirectory: true
            )
    }

    /// Ids e revisões vêm de manifesto, que é dado externo: uma barra ou um `..` no meio viraria
    /// escrita fora do depósito. Tudo que não é alfanumérico, ponto, hífen ou sublinhado vira `_`.
    nonisolated static func sanitize(_ component: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let mapped = String(component.map { allowed.contains($0) ? $0 : "_" })
        // "." e ".." são caminhos, não nomes.
        return mapped.allSatisfy { $0 == "." } ? String(repeating: "_", count: max(1, mapped.count)) : mapped
    }

    // MARK: - Recibo

    /// O carimbo de "esta revisão foi baixada inteira e validada".
    ///
    /// Sem ele, "a pasta existe" seria o critério de instalação — e uma pasta existe também
    /// quando o app morreu no meio de um download.
    private struct Receipt: Codable, Equatable {
        static let fileName = ".voiz-model-receipt.json"

        var revision: String
        var sha256: String
        var fileName: String
        var expectedBytes: Int64

        init(artifact: TranscriptionModelArtifact) {
            self.revision = artifact.revision
            self.sha256 = artifact.sha256.lowercased()
            self.fileName = artifact.fileName
            self.expectedBytes = artifact.expectedBytes
        }

        func matches(_ artifact: TranscriptionModelArtifact) -> Bool {
            revision == artifact.revision
                && sha256 == artifact.sha256.lowercased()
                && fileName == artifact.fileName
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    private func receipt(for artifact: TranscriptionModelArtifact) -> Receipt? {
        let url = revisionURL(for: artifact).appendingPathComponent(Receipt.fileName)
        guard let data = try? storage.read(at: url) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    // MARK: - Erro e cancelamento

    private func checkCancelled() throws {
        if Task.isCancelled { throw TranscriptionModelStoreError.cancelled }
    }

    private static func storeError(from error: any Error) -> TranscriptionModelStoreError {
        if let store = error as? TranscriptionModelStoreError { return store }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        return .downloadFailed(error.localizedDescription)
    }
}
