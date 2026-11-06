import Testing
import Foundation

/// Testes do `TranscriptionModelStore`.
///
/// O que está sob teste é **ordem** e **o que sobra no disco depois que dá errado**: conferir
/// espaço antes de baixar, validar antes de instalar, instalar antes de apagar. Um teste que só
/// verificasse "instalou" passaria com um store que apaga a revisão antiga antes de saber se a
/// nova presta.
@Suite("Depósito de modelos — download atômico, SHA-256 e espaço")
struct TranscriptionModelStoreTests {

    private let root = URL(fileURLWithPath: "/voiz-modelos", isDirectory: true)

    private func makeStore(
        storage: FakeModelStorage,
        downloader: FakeModelDownloader,
        freeSpaceRatio: Double = TranscriptionModelStore.defaultFreeSpaceRatio
    ) -> TranscriptionModelStore {
        TranscriptionModelStore(
            root: root,
            storage: storage,
            downloader: downloader,
            freeSpaceRatio: freeSpaceRatio
        )
    }

    // MARK: - Caminho feliz

    @Test("Instala: baixa no staging, valida o SHA e move para a revisão")
    func installsThroughStaging() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        let url = try await store.install(artifact)

        #expect(url.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin")
        #expect(storage.contents(at: url.path) == Data("pesos".utf8))
        // O recibo é o que carimba "esta revisão está boa".
        #expect(storage.contents(at: "/voiz-modelos/fake-alpha/fake-heavy/r1/.voiz-model-receipt.json") != nil)

        // O arquivo NUNCA foi escrito direto no destino: passou pelo staging.
        let moves = storage.operations.compactMap { operation -> (String, String)? in
            guard case .moveItem(let from, let to) = operation else { return nil }
            return (from, to)
        }
        #expect(moves.count == 1)
        let move = try #require(moves.first)
        #expect(move.0.contains("/.staging/"))
        #expect(move.1 == "/voiz-modelos/fake-alpha/fake-heavy/r1")
    }

    @Test("Já instalado e validado: nem rede, nem disco")
    func installedRevisionIsAFastPath() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        _ = try await store.install(artifact)
        let operationsAfterFirst = storage.operations.count

        let url = try await store.install(artifact)

        #expect(url.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin")
        #expect(downloader.downloads.count == 1)
        #expect(storage.operations.count == operationsAfterFirst)
    }

    @Test("Pasta sem recibo não conta como instalada: é lixo de download interrompido")
    func revisionWithoutReceiptIsNotInstalled() async throws {
        let storage = FakeModelStorage()
        let artifact = TranscriptionModelArtifact.test()
        // Um app morto no meio do download deixou o payload sem recibo.
        storage.seed(
            file: "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin",
            contents: Data("meio download".utf8)
        )
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        #expect(await store.installedURL(for: artifact) == nil)

        let url = try await store.install(artifact)

        #expect(downloader.downloads.count == 1)
        #expect(storage.contents(at: url.path) == Data("pesos".utf8))
    }

    @Test("Recibo de OUTRA revisão não vale por esta")
    func receiptFromAnotherRevisionDoesNotCount() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, payloads: [Data("v1".utf8)])
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test(revision: "r1", payload: Data("v1".utf8)))
        // Mesmo caminho de revisão, SHA diferente: o recibo antigo não pode carimbar o artefato
        // novo (é o caso de um manifesto republicado com os mesmos nomes).
        let republished = TranscriptionModelArtifact.test(revision: "r1", payload: Data("v2".utf8))

        #expect(await store.installedURL(for: republished) == nil)
    }

    // MARK: - SHA-256

    @Test("SHA errado: lança, apaga o staging e NÃO toca na revisão antiga")
    func checksumMismatchKeepsThePreviousRevision() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(
            storage: storage,
            payloads: [Data("v1".utf8), Data("corrompido".utf8)]
        )
        let store = makeStore(storage: storage, downloader: downloader)

        let old = TranscriptionModelArtifact.test(revision: "r1", payload: Data("v1".utf8))
        _ = try await store.install(old)

        // A revisão nova promete um SHA que o download não entrega.
        let broken = TranscriptionModelArtifact.test(revision: "r2", payload: Data("outra coisa".utf8))

        do {
            _ = try await store.install(broken)
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionModelStoreError {
            guard case .checksumMismatch(let model, let expected, let actual) = error else {
                Issue.record("erro inesperado: \(error)")
                return
            }
            #expect(model == .fakeHeavy)
            #expect(expected != actual)
        }

        // A antiga continua instalada e utilizável — é a regra do plano, e a razão dela é que um
        // download corrompido não pode deixar o usuário sem transcrever.
        #expect(await store.installedURL(for: old)?.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin")
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1"])
        // E o staging não ficou para trás.
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    @Test("A comparação do SHA ignora a caixa, e só ela")
    func checksumComparisonIsCaseInsensitive() async throws {
        let storage = FakeModelStorage()
        let payload = Data("pesos".utf8)
        let downloader = FakeModelDownloader(storage: storage, payload: payload)
        let store = makeStore(storage: storage, downloader: downloader)

        var artifact = TranscriptionModelArtifact.test(payload: payload)
        artifact.sha256 = artifact.sha256.uppercased()

        let url = try await store.install(artifact)
        #expect(storage.contents(at: url.path) == payload)
    }

    // MARK: - Espaço

    @Test("Exige 120% do tamanho declarado antes de gastar rede")
    func requires120PercentOfFreeSpace() async throws {
        let storage = FakeModelStorage(availableCapacity: 1_100)
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test(expectedBytes: 1_000)

        do {
            _ = try await store.install(artifact)
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionModelStoreError {
            #expect(error == .insufficientSpace(required: 1_200, available: 1_100))
        }

        // Falha limpa: nada baixado, e nada escrito no disco.
        #expect(downloader.downloads.isEmpty)
        #expect(storage.allPaths.isEmpty)
        // As únicas operações antes da medição são preparar a raiz e podar staging — nenhuma
        // toca revisão instalada.
        let measured = try #require(storage.operations.firstIndex(of: .availableCapacity))
        #expect(storage.operations.count == measured + 1)
        #expect(storage.operations.allSatisfy { operation in
            switch operation {
            case .createDirectory(let path): return path == self.root.path
            case .removeItem(let path): return path.contains("/.staging")
            case .availableCapacity: return true
            case .moveItem, .write, .sha256: return false
            }
        })
    }

    @Test("Com exatamente 120% disponíveis, instala")
    func exactly120PercentIsEnough() async throws {
        let storage = FakeModelStorage(availableCapacity: 1_200)
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        let url = try await store.install(.test(expectedBytes: 1_000))
        #expect(storage.contents(at: url.path) != nil)
    }

    @Test("A exigência arredonda para cima: 1,2 × N truncado deixaria passar por um byte")
    func requiredBytesRoundsUp() {
        #expect(TranscriptionModelStore.requiredBytes(for: 1_001, ratio: 1.2) == 1_202)
        #expect(TranscriptionModelStore.requiredBytes(for: 1_000, ratio: 1.2) == 1_200)
        #expect(TranscriptionModelStore.requiredBytes(for: 0, ratio: 1.2) == 0)
    }

    @Test("Espaço insuficiente não apaga a revisão que já estava instalada")
    func insufficientSpaceKeepsThePreviousRevision() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, payloads: [Data("v1".utf8)])
        let store = makeStore(storage: storage, downloader: downloader)

        let old = TranscriptionModelArtifact.test(revision: "r1", payload: Data("v1".utf8))
        _ = try await store.install(old)

        storage.setAvailableCapacity(10)
        await #expect(throws: TranscriptionModelStoreError.self) {
            try await store.install(.test(revision: "r2", payload: Data("v2".utf8)))
        }

        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1"])
    }

    // MARK: - A revisão antiga

    @Test("A revisão antiga só é apagada DEPOIS de a nova estar validada e instalada")
    func oldRevisionIsRemovedOnlyAfterTheNewOneIsInstalled() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(
            storage: storage,
            payloads: [Data("v1".utf8), Data("v2".utf8)]
        )
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test(revision: "r1", payload: Data("v1".utf8)))
        let boundary = storage.operations.count

        _ = try await store.install(.test(revision: "r2", payload: Data("v2".utf8)))

        let second = Array(storage.operations.dropFirst(boundary))
        let hashIndex = try #require(second.firstIndex { operation in
            if case .sha256 = operation { return true }
            return false
        })
        let installIndex = try #require(second.firstIndex { operation in
            guard case .moveItem(_, let to) = operation else { return false }
            return to == "/voiz-modelos/fake-alpha/fake-heavy/r2"
        })
        let removalIndex = try #require(second.firstIndex(of: .removeItem("/voiz-modelos/fake-alpha/fake-heavy/r1")))

        #expect(hashIndex < installIndex)
        #expect(installIndex < removalIndex)
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r2"])
    }

    @Test("Falha ao instalar (mover) deixa a revisão antiga no lugar")
    func failedInstallKeepsTheOldRevision() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(
            storage: storage,
            payloads: [Data("v1".utf8), Data("v2".utf8)]
        )
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test(revision: "r1", payload: Data("v1".utf8)))
        storage.failMove(with: CocoaError(.fileWriteNoPermission))

        await #expect(throws: TranscriptionModelStoreError.self) {
            try await store.install(.test(revision: "r2", payload: Data("v2".utf8)))
        }

        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1"])
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    @Test("Download que falha não deixa staging para trás nem mexe no que estava instalado")
    func failedDownloadCleansUp() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, payloads: [Data("v1".utf8)])
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test(revision: "r1", payload: Data("v1".utf8)))
        downloader.failNext(with: URLError(.networkConnectionLost))

        do {
            _ = try await store.install(.test(revision: "r2", payload: Data("v2".utf8)))
            Issue.record("deveria ter lançado")
        } catch let error as TranscriptionModelStoreError {
            guard case .downloadFailed = error else {
                Issue.record("erro inesperado: \(error)")
                return
            }
        }

        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1"])
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    @Test("removeAll apaga o modelo inteiro")
    func removeAllDeletesTheModel() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        _ = try await store.install(artifact)
        try await store.removeAll(engine: .fakeAlpha, model: .fakeHeavy)

        #expect(await store.installedURL(for: artifact) == nil)
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy).isEmpty)
    }

    // MARK: - Caminhos

    @Test("Ids e revisões de manifesto não escapam do depósito")
    func pathComponentsAreSanitized() async throws {
        // Manifesto é dado externo: uma barra ou um `..` viraria escrita fora do depósito.
        #expect(TranscriptionModelStore.sanitize("../../etc/passwd") == ".._.._etc_passwd")
        #expect(TranscriptionModelStore.sanitize("..") == "__")
        #expect(TranscriptionModelStore.sanitize(".") == "_")
        #expect(TranscriptionModelStore.sanitize("openai_whisper-large-v3_turbo") == "openai_whisper-large-v3_turbo")

        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        let url = try await store.install(.test(revision: "../fora"))

        // O que importa não é o texto sumir: é a barra sumir. Sem separador, `..` deixa de ser um
        // componente de caminho e vira um nome de pasta comum, dentro do depósito.
        #expect(url.path == "/voiz-modelos/fake-alpha/fake-heavy/.._fora/pesos.bin")
        #expect(!url.pathComponents.contains(".."))
    }

    // MARK: - Primeira instalação numa máquina limpa (CRÍTICO do Farol)

    @Test("Primeira instalação da vida do app: a raiz não existe e ela é criada antes de medir")
    func firstInstallCreatesTheRootBeforeMeasuring() async throws {
        // O CRÍTICO: `make` só monta a URL ~/Library/Application Support/Voiz/Models, não cria a
        // pasta; medir capacidade numa URL inexistente devolve Cocoa 260 e a instalação morria
        // antes de qualquer rede. O dublê agora modela isso — `availableCapacity` falha se o
        // caminho não existe.
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        #expect(storage.fileExists(at: root) == false)

        let url = try await store.install(.test())

        #expect(storage.contents(at: url.path) == Data("pesos".utf8))
        // A raiz é criada ANTES da medição — a ordem é o que estava errado.
        let createdRoot = try #require(storage.operations.firstIndex(of: .createDirectory(root.path)))
        let measured = try #require(storage.operations.firstIndex(of: .availableCapacity))
        #expect(createdRoot < measured)
    }

    @Test("A raiz é criada sem apagar o que já estiver nela")
    func preparingTheRootIsNotDestructive() async throws {
        let storage = FakeModelStorage()
        storage.seed(file: "/voiz-modelos/outro-motor/outro-modelo/r9/pesos.bin", contents: Data("v9".utf8))
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test())

        #expect(storage.contents(at: "/voiz-modelos/outro-motor/outro-modelo/r9/pesos.bin") != nil)
    }

    @Test("O .staging órfão é podado na abertura, e antes da conta de espaço")
    func orphanStagingIsPrunedAtStartup() async throws {
        // Duas coisas ao mesmo tempo: um crash durante o download deixava `.staging/<chave>` no
        // disco para sempre se aquele artefato nunca mais fosse instalado, e o staging órfão
        // contava contra os 120% — podendo dar `insufficientSpace` num disco com folga de sobra.
        let storage = FakeModelStorage()
        storage.seed(
            file: "/voiz-modelos/.staging/motor-morto~modelo~r0/meio-download.bin",
            contents: Data("lixo".utf8)
        )
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test())

        #expect(storage.contents(at: "/voiz-modelos/.staging/motor-morto~modelo~r0/meio-download.bin") == nil)
        let pruned = try #require(storage.operations.firstIndex(of: .removeItem("/voiz-modelos/.staging")))
        let measured = try #require(storage.operations.firstIndex(of: .availableCapacity))
        #expect(pruned < measured)
    }

    @Test("O staging desta instalação é limpo ANTES da conta de espaço, não depois")
    func staleStagingIsClearedBeforeCountingSpace() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test())

        // O caminho do staging carrega o id da instalação, então a asserção é estrutural: alguma
        // limpeza de staging DESTA instalação acontece antes de a capacidade ser medida.
        let cleared = try #require(storage.operations.firstIndex { operation in
            guard case .removeItem(let path) = operation else { return false }
            return path.hasPrefix("/voiz-modelos/.staging/fake-alpha~fake-heavy~r1~")
        })
        let measured = try #require(storage.operations.lastIndex(of: .availableCapacity))
        #expect(cleared < measured)
    }

    @Test("Crash entre o move e a poda não deixa a revisão antiga para sempre")
    func fastPathAlsoPrunesOldRevisions() async throws {
        // O caminho rápido devolvia na hora e nunca chegava ao `removeOtherRevisions`: uma revisão
        // antiga sobrevivente a um crash ficava no disco para sempre, corroendo a folga de 120%.
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, payloads: [Data("v2".utf8)])
        let store = makeStore(storage: storage, downloader: downloader)
        let current = TranscriptionModelArtifact.test(revision: "r2", payload: Data("v2".utf8))

        _ = try await store.install(current)
        // Simula o crash: a revisão antiga reaparece no disco sem passar pelo store.
        storage.seed(file: "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin", contents: Data("v1".utf8))
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1", "r2"])

        // A instalação seguinte sai pelo caminho rápido — e agora também limpa.
        _ = try await store.install(current)

        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r2"])
    }

    // MARK: - fileName que escapa (CRÍTICO do Farol)

    @Test("fileName com ../ é RECUSADO, não normalizado em silêncio")
    func fileNameThatEscapesIsRejected() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        for escaping in ["../../escaped.bin", "../vizinho.bin", "sub/dir.bin", "/etc/passwd", "..", ".", ""] {
            let artifact = TranscriptionModelArtifact.test(fileName: escaping)
            do {
                _ = try await store.install(artifact)
                Issue.record("deveria ter recusado o fileName \(escaping)")
            } catch let error as TranscriptionModelStoreError {
                guard case .invalidArtifact = error else {
                    Issue.record("erro inesperado para \(escaping): \(error)")
                    continue
                }
            }
        }

        // Recusa é ANTES de tocar em qualquer coisa: nada baixado, nada criado, nada apagado.
        #expect(downloader.downloads.isEmpty)
        #expect(storage.operations.isEmpty)
        #expect(storage.allPaths.isEmpty)
    }

    @Test("Nenhum caminho escrito sai do depósito, para qualquer fileName aceito")
    func acceptedFileNamesStayInsideTheStore() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        // Nomes esquisitos mas legítimos: um ponto no começo, espaços, unicode.
        for accepted in [".oculto.bin", "pesos v2.mlmodelc", "modelo-ptBR.bin", "..pesos"] {
            let artifact = TranscriptionModelArtifact.test(revision: accepted, fileName: accepted)
            let url = try await store.install(artifact)
            #expect(url.path.hasPrefix(root.path + "/"))
            #expect(!url.pathComponents.contains(".."))
        }

        // E, no fim, tudo que existe no disco está sob a raiz.
        #expect(storage.allPaths.allSatisfy { $0.hasPrefix(root.path + "/") })
    }

    @Test("A validação de componente conhece os separadores que importam")
    func componentValidationCoversTheRealSeparators() {
        for unsafe in ["a/b", "a\\b", "a:b", "..", ".", "", "~/coisa", "a\0b"] {
            #expect(TranscriptionModelStore.isSafePathComponent(unsafe) == false, "aceitou \(unsafe)")
        }
        for safe in ["pesos.bin", ".oculto", "..pesos", "modelo v2.mlmodelc", "a-b_c.1"] {
            #expect(TranscriptionModelStore.isSafePathComponent(safe), "recusou \(safe)")
        }
    }

    @Test("A contenção é verificada no caminho resolvido, não na aparência da string")
    func containmentIsCheckedOnTheResolvedPath() throws {
        let base = URL(fileURLWithPath: "/deposito/staging", isDirectory: true)
        #expect(throws: Never.self) {
            try TranscriptionModelStore.requireContainment(
                of: base.appendingPathComponent("pesos.bin"),
                in: base
            )
        }
        #expect(throws: TranscriptionModelStoreError.self) {
            try TranscriptionModelStore.requireContainment(
                of: URL(fileURLWithPath: "/deposito/staging/../vizinho/pesos.bin"),
                in: base
            )
        }
        // Prefixo textual não é contenção: `/deposito/staging-outro` começa com `/deposito/staging`.
        #expect(throws: TranscriptionModelStoreError.self) {
            try TranscriptionModelStore.requireContainment(
                of: URL(fileURLWithPath: "/deposito/staging-outro/pesos.bin"),
                in: base
            )
        }
    }

    @Test("Artefato sem SHA declarado é recusado")
    func artifactWithoutChecksumIsRejected() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)
        var artifact = TranscriptionModelArtifact.test()
        artifact.sha256 = ""

        await #expect(throws: TranscriptionModelStoreError.self) {
            try await store.install(artifact)
        }
        #expect(downloader.downloads.isEmpty)
    }

    // MARK: - Single-flight (MAIOR do Farol e da Quilha)

    @Test("Instalações concorrentes do MESMO artefato baixam uma vez só")
    func concurrentInstallsOfTheSameArtifactShareOneDownload() async throws {
        // Sem single-flight, as duas derivavam o mesmo staging e a segunda apagava a pasta em que
        // a primeira estava baixando — o `try? removeItem(at: staging)` da entrada.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        async let first = store.install(artifact)
        async let second = store.install(artifact)
        async let third = store.install(artifact)

        // Alguém já chegou ao download: as outras só podem estar aguardando a MESMA instalação.
        await gate.waitForArrivals(1)
        gate.open()

        let urls = try await [first, second, third]

        #expect(Set(urls.map(\.path)).count == 1)
        #expect(downloader.downloads.count == 1)
        // Uma pasta de staging criada, uma movida: ninguém apagou o trabalho de ninguém.
        let moves = storage.operations.filter { operation in
            if case .moveItem = operation { return true }
            return false
        }
        #expect(moves.count == 1)
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1"])
    }

    @Test("Instalações concorrentes de artefatos DIFERENTES na mesma revisão serializam")
    func concurrentInstallsOfDifferentArtifactsSerialize() async throws {
        // Revisão republicada com outro SHA: não dá para dividir a carga, mas as duas disputam a
        // mesma pasta de staging — então uma espera a outra em vez de atropelá-la.
        let storage = FakeModelStorage()
        // Downloader honesto: cada artefato recebe o conteúdo que ele declara. Sem isto, quem
        // rodasse primeiro levava o payload da outra instalação e o teste virava moeda.
        let downloader = FakeModelDownloader(
            storage: storage,
            honestFor: [Data("v1".utf8), Data("v2".utf8)]
        )
        let store = makeStore(storage: storage, downloader: downloader)

        async let first = store.install(.test(revision: "r1", payload: Data("v1".utf8)))
        async let second = store.install(.test(revision: "r1", payload: Data("v2".utf8)))

        let results = try await [first, second]

        #expect(results.count == 2)
        #expect(downloader.downloads.count == 2)
        // A última instalação é a que fica: uma revisão só, e o payload é o de quem terminou.
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r1"])
    }

    @Test("A falha de uma instalação compartilhada é a falha de todos os que a esperavam")
    func sharedInstallFailureReachesEveryWaiter() async throws {
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(
            storage: storage,
            payloads: [Data("corrompido".utf8)],
            gate: gate
        )
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test(payload: Data("bom".utf8))

        async let first: URL? = try? await store.install(artifact)
        async let second: URL? = try? await store.install(artifact)
        await gate.waitForArrivals(1)
        gate.open()

        let results = await [first, second]
        #expect(results.allSatisfy { $0 == nil })
        #expect(downloader.downloads.count == 1)
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    // MARK: - Cancelamento do install (MAIOR da re-review)

    @Test("Cancelar quem espera devolve .cancelled NA HORA, com o download ainda preso")
    func cancellingAWaiterReturnsImmediately() async throws {
        // O MAIOR: `install` devolvia `await task.value` de uma Task não estruturada — cancelar o
        // chamador não cancelava a Task nem terminava a espera, então ele ficava preso até o fim do
        // download e ainda recebia SUCESSO. `.cancelled` virou caso quase inalcançável.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)

        let doomed = Task { try await store.install(.test()) }
        await gate.waitForArrivals(1)

        doomed.cancel()

        // Devolve NA HORA, com o download ainda parado no portão.
        let outcome = try await withDeadline(seconds: 30) { () -> String in
            do {
                _ = try await doomed.value
                return "sucesso"
            } catch let error as TranscriptionModelStoreError {
                return error == .cancelled ? "cancelado" : "outro: \(error)"
            }
        }
        #expect(outcome == "cancelado")
        #expect(gate.arrivals == 1)

        gate.open()
    }

    @Test("O último aguardante a desistir cancela a instalação compartilhada e limpa o staging")
    func lastWaiterLeavingCancelsTheSharedInstall() async throws {
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)

        let first = Task { try await store.install(.test()) }
        await gate.waitForArrivals(1)
        let second = Task { try await store.install(.test()) }
        #expect(await waitUntil { await store.waiterCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 2 })

        // O primeiro desiste: a instalação CONTINUA, porque o segundo ainda a quer.
        first.cancel()
        await #expect(throws: TranscriptionModelStoreError.cancelled) { try await first.value }
        #expect(await store.waiterCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 1)

        // O segundo também desiste: não sobra ninguém, e a carga compartilhada morre.
        second.cancel()
        await #expect(throws: TranscriptionModelStoreError.cancelled) { try await second.value }

        // Destrava o download para a tarefa cancelada chegar ao `checkCancelled` e limpar.
        gate.open()
        #expect(await waitUntil { storage.allPaths.allSatisfy { !$0.contains("/.staging/") } })
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy).isEmpty)
    }

    @Test("Um aguardante que desiste NÃO mata a instalação de quem ficou")
    func abandoningWaiterDoesNotKillTheInstallForTheOthers() async throws {
        // O outro lado da moeda: cancelar a carga compartilhada enquanto alguém ainda a espera
        // trocaria um problema por outro.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)

        let doomed = Task { try await store.install(.test()) }
        await gate.waitForArrivals(1)
        let survivor = Task { try await store.install(.test()) }
        #expect(await waitUntil { await store.waiterCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 2 })

        doomed.cancel()
        await #expect(throws: TranscriptionModelStoreError.cancelled) { try await doomed.value }

        gate.open()
        let url = try await survivor.value

        #expect(url.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin")
        #expect(storage.contents(at: url.path) == Data("pesos".utf8))
        #expect(downloader.downloads.count == 1)
    }

    @Test("Cancela-último → chega-novo: o novo NÃO herda o cancelamento e instala")
    func newCallerAfterLastWaiterLeftStartsAFreshInstall() async throws {
        // O achado: a instalação que perdia o último aguardante continuava REGISTRADA enquanto a
        // Task cancelada drenava, e ainda aceitava aderentes. Um chamador novo — que ninguém
        // cancelou — encontrava a Task irreversivelmente cancelada, se registrava nela e recebia
        // `.cancelled` alheio em vez de começar a própria instalação.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        // A instala e fica presa no portão; A cancela, e é o último (e único) aguardante.
        let doomed = Task { try await store.install(artifact) }
        await gate.waitForArrivals(1)
        #expect(await store.hasActiveInstall(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1"))

        doomed.cancel()
        await #expect(throws: TranscriptionModelStoreError.cancelled) { try await doomed.value }

        // A decisão de cancelar DESREGISTRA na hora: a chave está livre, e a moribunda drena fora
        // do registro. É esta janela — antes de o portão abrir — que o achado descreve.
        #expect(await store.hasActiveInstall(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == false)
        #expect(await store.drainingInstallCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 1)
        #expect(gate.arrivals == 1)

        // B chega AGORA, sem ter sido cancelado, e abre uma instalação NOVA em vez de aderir à
        // moribunda.
        let newcomer = Task { try await store.install(artifact) }
        #expect(await waitUntil { await store.hasActiveInstall(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") })
        try #require(await gate.waitForArrivals(2))

        gate.open()
        let url = try await newcomer.value

        // B não recebeu cancelamento alheio: ele instalou.
        #expect(url.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin")
        #expect(storage.contents(at: url.path) == Data("pesos".utf8))
        #expect(await store.installedURL(for: artifact) == url)
        // Dois downloads: o da moribunda (descartado) e o de B.
        #expect(downloader.downloads.count == 2)

        // E a moribunda não deixou rastro: staging limpo, e nada do dreno sobrou registrado.
        #expect(await waitUntil { await store.drainingInstallCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 0 })
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    @Test("A moribunda que termina depois não desregistra a instalação nova que assumiu a chave")
    func drainingInstallDoesNotUnregisterTheNewOne() async throws {
        // O outro lado do mesmo achado: sem identidade, o `finish` da abandonada removeria do mapa
        // a entrada de quem acabou de começar, e os aguardantes da NOVA ficariam pendurados.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        let doomed = Task { try await store.install(artifact) }
        await gate.waitForArrivals(1)
        doomed.cancel()
        await #expect(throws: TranscriptionModelStoreError.cancelled) { try await doomed.value }

        // A nova assume a chave, e ganha um segundo aguardante.
        let first = Task { try await store.install(artifact) }
        try #require(await gate.waitForArrivals(2))
        let second = Task { try await store.install(artifact) }
        #expect(await waitUntil { await store.waiterCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 2 })

        gate.open()

        // Os dois aguardantes da NOVA recebem o resultado — nenhum fica pendurado.
        let urls = try await withDeadline(seconds: 30) { try await [first.value, second.value] }
        #expect(urls?.count == 2)
        #expect(urls?.allSatisfy { $0.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin" } == true)
    }

    @Test("Um aguardante cancelado nunca recebe sucesso, mesmo com a instalação terminando")
    func cancelledWaiterNeverGetsSuccess() async throws {
        // Fecha a corrida cancelamento × finish: se o `finish` vencer o hop do `onCancel`, quem
        // desistiu ainda assim não pode receber os pesos como se tivesse esperado por eles. O
        // sobrevivente instala normalmente, então a instalação de fato terminou.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)
        let artifact = TranscriptionModelArtifact.test()

        let survivor = Task { try await store.install(artifact) }
        await gate.waitForArrivals(1)
        let quitter = Task { try await store.install(artifact) }
        #expect(await waitUntil { await store.waiterCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 2 })

        quitter.cancel()
        gate.open()

        let installed = try await survivor.value
        #expect(installed.path == "/voiz-modelos/fake-alpha/fake-heavy/r1/pesos.bin")

        do {
            _ = try await quitter.value
            Issue.record("quem cancelou não pode receber sucesso")
        } catch let error as TranscriptionModelStoreError {
            #expect(error == .cancelled)
        }
    }

    // MARK: - removeAll × instalação em voo (MAIOR da re-review)

    @Test("removeAll drena a instalação em voo: o modelo não ressuscita depois")
    func removeAllDrainsInFlightInstalls() async throws {
        // O MAIOR: o ator reentra no `await` do downloader, então `removeAll` apagava a pasta e
        // devolvia sucesso, e a instalação retomava depois, recriava o diretório e movia o staging
        // para o destino — ressuscitando o modelo que a UI acabou de remover.
        // O portão começa ABERTO para a pré-instalação passar, e fecha em seguida: é a instalação
        // nova que precisa ficar presa no download.
        let gate = TestGate(open: true)
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)

        // Uma revisão já instalada, para a remoção ter o que apagar.
        _ = try await store.install(.test(revision: "r0"))
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r0"])

        // E uma instalação nova, presa no download.
        gate.close()
        let installing = Task { try await store.install(.test(revision: "r1")) }
        await gate.waitForArrivals(2)

        let removing = Task { try await store.removeAll(engine: .fakeAlpha, model: .fakeHeavy) }
        #expect(await waitUntil { await store.isRemoving(engine: .fakeAlpha, model: .fakeHeavy) })

        // Destrava o download: a instalação cancelada chega ao `checkCancelled`, limpa e morre.
        gate.open()
        try await removing.value
        await #expect(throws: (any Error).self) { try await installing.value }

        // Nada ressuscitou, e nada ficou para trás.
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy).isEmpty)
        #expect(storage.allPaths.allSatisfy { !$0.hasPrefix("/voiz-modelos/fake-alpha/fake-heavy/") })
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    @Test("Instalação que chega durante a remoção espera o dreno e instala limpo depois")
    func installStartedDuringRemovalWaitsForIt() async throws {
        let gate = TestGate(open: true)
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test(revision: "r0"))
        gate.close()
        let blocking = Task { try await store.install(.test(revision: "r1")) }
        await gate.waitForArrivals(2)

        let removing = Task { try await store.removeAll(engine: .fakeAlpha, model: .fakeHeavy) }
        #expect(await waitUntil { await store.isRemoving(engine: .fakeAlpha, model: .fakeHeavy) })

        // Chega uma instalação NOVA com a remoção drenando: ela espera, não corre.
        let late = Task { try await store.install(.test(revision: "r2")) }
        #expect(await waitUntil { await store.installsWaitingForRemoval() == 1 })

        gate.open()
        try await removing.value
        _ = try? await blocking.value
        let url = try await late.value

        // A tardia instalou DEPOIS da remoção, e é a única revisão que sobrou.
        #expect(url.path == "/voiz-modelos/fake-alpha/fake-heavy/r2/pesos.bin")
        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy) == ["r2"])
    }

    @Test("removeAll também espera a instalação ABANDONADA que ainda drena")
    func removeAllDrainsAbandonedInstalls() async throws {
        // Uma instalação que perdeu o último aguardante sai do registro de ativas, mas continua
        // viva até drenar. Se `removeAll` só olhasse as ativas, voltaria a devolver sucesso com
        // trabalho vivo por baixo — o mesmo defeito de antes, por outra porta.
        let gate = TestGate()
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage, gate: gate)
        let store = makeStore(storage: storage, downloader: downloader)

        let doomed = Task { try await store.install(.test()) }
        await gate.waitForArrivals(1)
        doomed.cancel()
        await #expect(throws: TranscriptionModelStoreError.cancelled) { try await doomed.value }
        #expect(await store.drainingInstallCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 1)

        let finished = CompletionFlag()
        let removing = Task {
            try await store.removeAll(engine: .fakeAlpha, model: .fakeHeavy)
            await finished.set()
        }

        // A remoção chega até o dreno e PARA lá: com o download ainda preso no portão, ela não
        // pode ter terminado.
        #expect(await waitUntil { await store.isRemoving(engine: .fakeAlpha, model: .fakeHeavy) })
        #expect(await waitUntil(seconds: 0.5) { await finished.isSet } == false)

        gate.open()
        try await removing.value

        #expect(await finished.isSet)
        #expect(await store.drainingInstallCount(engine: .fakeAlpha, model: .fakeHeavy, revision: "r1") == 0)
        #expect(storage.allPaths.allSatisfy { !$0.contains("/.staging/") })
    }

    @Test("removeAll de um modelo que não existe é sucesso")
    func removeAllIsIdempotent() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test())
        try await store.removeAll(engine: .fakeAlpha, model: .fakeHeavy)
        try await store.removeAll(engine: .fakeAlpha, model: .fakeHeavy)

        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy).isEmpty)
    }

    @Test("Duas remoções concorrentes do mesmo modelo não se atropelam")
    func concurrentRemovalsSerialize() async throws {
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        _ = try await store.install(.test())

        async let first: Void = store.removeAll(engine: .fakeAlpha, model: .fakeHeavy)
        async let second: Void = store.removeAll(engine: .fakeAlpha, model: .fakeHeavy)
        _ = try await [first, second]

        #expect(await store.installedRevisions(engine: .fakeAlpha, model: .fakeHeavy).isEmpty)
        #expect(await store.isRemoving(engine: .fakeAlpha, model: .fakeHeavy) == false)
    }

    // MARK: - MENORES da Quilha

    @Test("fileName igual ao nome do recibo é recusado")
    func fileNameCollidingWithTheReceiptIsRejected() async throws {
        // Sem esta recusa: o payload é baixado nesse caminho, passa no SHA e é SOBRESCRITO pela
        // escrita do recibo; depois `installedURL` acha payload e recibo no mesmo arquivo, o
        // `matches` bate, e a instalação é reportada como sucesso devolvendo um JSON no lugar dos
        // pesos — corrupção silenciosa carimbada como válida.
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let store = makeStore(storage: storage, downloader: downloader)

        do {
            _ = try await store.install(.test(fileName: ".voiz-model-receipt.json"))
            Issue.record("deveria ter recusado")
        } catch let error as TranscriptionModelStoreError {
            guard case .invalidArtifact = error else {
                Issue.record("erro inesperado: \(error)")
                return
            }
        }
        #expect(downloader.downloads.isEmpty)
        #expect(storage.allPaths.isEmpty)
    }

    @Test("shared(root:) devolve o MESMO store para a mesma raiz")
    func sharedStoreHasASingleOwnerPerRoot() {
        // As garantias do store são por instância (instalações em voo, remoções, poda de abertura),
        // mas a raiz é do processo: dois stores sobre a mesma pasta colidiriam no staging e a poda
        // de um apagaria o download em voo do outro.
        let storage = FakeModelStorage()
        let downloader = FakeModelDownloader(storage: storage)
        let root = URL(fileURLWithPath: "/voiz-modelos-compartilhado", isDirectory: true)

        let first = TranscriptionModelStore.shared(root: root, storage: storage, downloader: downloader)
        let second = TranscriptionModelStore.shared(root: root, storage: storage, downloader: downloader)
        // Caminho equivalente, não idêntico: a chave é canônica.
        let third = TranscriptionModelStore.shared(
            root: URL(fileURLWithPath: "/voiz-modelos-compartilhado/./", isDirectory: true),
            storage: storage,
            downloader: downloader
        )
        let other = TranscriptionModelStore.shared(
            root: URL(fileURLWithPath: "/outra-raiz-de-teste", isDirectory: true),
            storage: storage,
            downloader: downloader
        )

        #expect(first === second)
        #expect(first === third)
        #expect(first !== other)
    }

    // MARK: - Erros para o coordenador

    @Test("Toda falha que não é cancelamento vira modelUnavailable para o coordenador")
    func errorsMapToEngineFailures() {
        #expect(
            TranscriptionModelStoreError.insufficientSpace(required: 2, available: 1)
                .engineFailure(model: .fakeHeavy) == .modelUnavailable(.fakeHeavy)
        )
        #expect(
            TranscriptionModelStoreError.checksumMismatch(model: .fakeHeavy, expected: "a", actual: "b")
                .engineFailure(model: .fakeHeavy) == .modelUnavailable(.fakeHeavy)
        )
        // Cancelamento continua sem fallback.
        #expect(TranscriptionModelStoreError.cancelled.engineFailure(model: .fakeHeavy) == .cancelled)
        #expect(TranscriptionEngineFailure.cancelled.allowsFallback == false)
    }
}

/// O SHA-256 de verdade, sobre o disco de verdade.
///
/// Os testes acima usam um digest falso de propósito — o que eles exercitam é a **decisão** do
/// store diante de um digest que bate ou não bate. Mas comparar duas strings inventadas pelo
/// próprio teste não diz nada sobre o hash: esta suíte fecha esse buraco com o vetor conhecido do
/// NIST e um arquivo maior que o bloco de leitura, para o caminho em blocos também ser exercido.
@Suite("Depósito de modelos — SHA-256 de produção")
struct LiveTranscriptionModelStorageTests {

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiz-model-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Vetor conhecido: sha256(\"abc\")")
    func knownVector() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let digest = try LiveTranscriptionModelStorage().sha256(at: file)

        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Arquivo maior que o bloco de leitura tem o mesmo digest do arquivo inteiro")
    func chunkedReadMatchesWholeFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("grande.bin")
        // 10 blocos de 1 KB, com um bloco de leitura de 1 KB: o hash tem que ser o mesmo de quem
        // lê tudo de uma vez.
        try Data((0..<10_240).map { UInt8($0 % 251) }).write(to: file)

        let chunked = try LiveTranscriptionModelStorage(chunkBytes: 1_024).sha256(at: file)
        let whole = try LiveTranscriptionModelStorage(chunkBytes: 1_024 * 1_024).sha256(at: file)

        #expect(chunked == whole)
        #expect(chunked.count == 64)
    }

    @Test("Medir capacidade numa raiz inexistente falha — o defeito que o dublê mascarava")
    func measuringAMissingRootFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("nunca-criada", isDirectory: true)

        #expect(throws: (any Error).self) {
            try LiveTranscriptionModelStorage().availableCapacity(at: missing)
        }
    }

    @Test("Com a implementação de produção, a primeira instalação numa raiz ausente funciona")
    func firstInstallWorksOnRealDiskWithMissingRoot() async throws {
        // O teste que o Farol pediu: implementação de produção, raiz temporária que **não existe**,
        // e o payload chegando pelo downloader falso (não há rede num teste).
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Voiz/Models", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: root.path) == false)

        let payload = Data("pesos de verdade".utf8)
        let store = TranscriptionModelStore(
            root: root,
            storage: LiveTranscriptionModelStorage(),
            downloader: RealDiskDownloader(payload: payload)
        )
        let artifact = TranscriptionModelArtifact(
            engine: .fakeAlpha,
            model: .fakeHeavy,
            revision: "r1",
            fileName: "pesos.bin",
            source: URL(string: "https://exemplo.invalido/pesos.bin")!,
            // SHA-256 real do payload, calculado pela própria implementação de produção.
            sha256: try Self.sha256(of: payload, in: temporary),
            expectedBytes: Int64(payload.count)
        )

        let url = try await store.install(artifact)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == payload)
        #expect(await store.installedURL(for: artifact) == url)
    }

    /// SHA-256 de `data`, pela implementação de produção — para o artefato do teste acima não
    /// depender de um digest escrito à mão.
    private static func sha256(of data: Data, in directory: URL) throws -> String {
        let scratch = directory.appendingPathComponent("scratch-\(UUID().uuidString)")
        try data.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try LiveTranscriptionModelStorage().sha256(at: scratch)
    }

    @Test("Arquivo vazio tem o digest do vazio")
    func emptyFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("vazio.bin")
        try Data().write(to: file)

        let digest = try LiveTranscriptionModelStorage().sha256(at: file)

        #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
