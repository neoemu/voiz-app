import Testing
import Foundation

/// A regra de gravação do histórico de tradução (`TranslationEntry.applying(_:to:limit:)`).
///
/// O que está sendo protegido é dado do usuário. O `TranslationHistoryStore` lê o histórico uma vez
/// no `init` e regrava o array inteiro a cada mudança, então duas instâncias do Voiz abertas ao
/// mesmo tempo se apagavam em silêncio. A **primeira** correção mesclava os dois snapshots com a
/// memória vencendo, e o Farol derrubou com contraexemplos que não precisam de concorrência nenhuma
/// — só de duas instâncias e duas ações em sequência. Os dois estão aqui como teste, porque são
/// exatamente os casos que a versão anterior passava e errava:
///
/// - `deletionByAnotherInstanceIsNotUndone`
/// - `renameByAnotherInstanceIsNotOverwritten`
///
/// A regra que passou a valer: o disco é a verdade compartilhada, e esta instância só aplica o
/// delta que ela acabou de produzir.
@Suite("Histórico de tradução — a gravação é um delta sobre o disco")
struct TranslationHistoryReconcileTests {

    private static let base = Date(timeIntervalSince1970: 1_770_000_000)

    private static func entry(
        _ id: UUID = UUID(),
        minutes: Double,
        title: String? = nil
    ) -> TranslationEntry {
        TranslationEntry(
            id: id,
            sourceText: "source",
            translatedText: "traduzido",
            sourceLanguage: .english,
            targetLanguage: .portuguese,
            timestamp: base.addingTimeInterval(minutes * 60),
            title: title
        )
    }

    // MARK: - A recusa de gravar (o fail-safe que precisa ser confirmável)

    /// O `nil` aqui é o que impede o `stopListening` de limpar as caixas: enquanto ele existir e
    /// for propagado, "não gravou" nunca vira "Salvo em Recentes".
    @Test("Blob ilegível: NÃO grava e NÃO confirma, para nenhuma mudança")
    func unreadableDiskRefusesEveryWrite() {
        let entry = Self.entry(minutes: 10)

        #expect(TranslationEntry.write(.add(entry), onto: .unreadable, limit: 100) == nil)
        #expect(TranslationEntry.write(.remove(entry.id), onto: .unreadable, limit: 100) == nil)
        #expect(TranslationEntry.write(.rename(entry.id, title: "x"), onto: .unreadable, limit: 100) == nil)
        #expect(TranslationEntry.write(.clear, onto: .unreadable, limit: 100) == nil)
    }

    @Test("Disco vazio e disco legível gravam normalmente — a recusa é só do ilegível")
    func readableDiskWritesNormally() {
        let stored = Self.entry(minutes: 5)
        let entry = Self.entry(minutes: 10)

        let ontoEmpty = TranslationEntry.write(.add(entry), onto: .empty, limit: 100)
        let ontoDecoded = TranslationEntry.write(.add(entry), onto: .decoded([stored]), limit: 100)

        #expect(ontoEmpty?.map(\.id) == [entry.id])
        #expect(ontoDecoded?.map(\.id) == [entry.id, stored.id])
    }

    @Test("A leitura distingue vazio de ilegível — colapsar os dois era a perda total")
    func readingTellsEmptyApartFromUnreadable() {
        let good = try? JSONEncoder().encode([Self.entry(minutes: 10)])

        if case .empty = TranslationHistoryDisk.read(nil) {} else {
            Issue.record("sem blob tem que ser .empty")
        }
        if case .unreadable = TranslationHistoryDisk.read(Data("nem json é".utf8)) {} else {
            Issue.record("blob que não decodifica tem que ser .unreadable, não .empty")
        }
        if case .decoded(let entries) = TranslationHistoryDisk.read(good) {
            #expect(entries.count == 1)
        } else {
            Issue.record("blob válido tem que decodificar")
        }
    }

    /// O que **não** torna um blob ilegível: campo novo.
    ///
    /// A primeira versão deste teste (e da documentação que ele sustentava) dizia que o cenário era
    /// "build novo grava um campo obrigatório que o build velho não conhece". Está errado, e o
    /// Farol pegou: o `JSONDecoder` **ignora chaves desconhecidas**, então acrescentar campo é
    /// justamente o caso SEGURO — o build velho lê normalmente. O fixture antigo só falhava porque
    /// eu tinha escrito um objeto sem NENHUM dos campos obrigatórios, o que testava outra coisa.
    ///
    /// Este teste passou a afirmar as duas coisas certas, e a primeira existe para ninguém
    /// re-derivar a premissa errada.
    @Test("Campo desconhecido a mais NÃO quebra a leitura; o que quebra é o esquema mudar")
    func unreadableIsAboutSchemaChangesNotAboutExtraFields() throws {
        let entry = Self.entry(minutes: 10)
        let canonical = try JSONEncoder().encode([entry])
        var object = try #require(
            try JSONSerialization.jsonObject(with: canonical) as? [[String: Any]]
        ).first!

        // (a) campo a mais: continua legível.
        var withExtra = object
        withExtra["campoQueEsteBuildNaoConhece"] = 1
        let extraBlob = try JSONSerialization.data(withJSONObject: [withExtra])
        if case .decoded(let decoded) = TranslationHistoryDisk.read(extraBlob) {
            #expect(decoded.map(\.id) == [entry.id])
        } else {
            Issue.record("chave desconhecida a mais tem que continuar decodificando")
        }

        // (b) campo obrigatório que sumiu (renomeado ou removido por outra versão): ilegível.
        var missing = object
        missing.removeValue(forKey: "sourceText")
        let missingBlob = try JSONSerialization.data(withJSONObject: [missing])
        if case .unreadable = TranslationHistoryDisk.read(missingBlob) {} else {
            Issue.record("campo obrigatório ausente tem que ser .unreadable, não .empty")
        }

        // (c) tipo de um campo existente mudou: ilegível.
        object["timestamp"] = "2026-08-14T19:31:05Z"
        let retypedBlob = try JSONSerialization.data(withJSONObject: [object])
        if case .unreadable = TranslationHistoryDisk.read(retypedBlob) {} else {
            Issue.record("tipo trocado tem que ser .unreadable, não .empty")
        }

        // E, nos dois casos ilegíveis, a decisão é não gravar.
        #expect(
            TranslationEntry.write(
                .add(Self.entry(minutes: 20)),
                onto: TranslationHistoryDisk.read(missingBlob),
                limit: 100
            ) == nil
        )
        #expect(
            TranslationEntry.write(
                .add(Self.entry(minutes: 20)),
                onto: TranslationHistoryDisk.read(retypedBlob),
                limit: 100
            ) == nil
        )
    }

    // MARK: - Os dois contraexemplos do Farol

    @Test("A apaga X, B depois adiciona Y: X NÃO ressuscita")
    func deletionByAnotherInstanceIsNotUndone() {
        // Disco [X]; A e B abrem e carregam [X]; A apaga X e grava []; agora B adiciona Y.
        let x = Self.entry(minutes: 10)
        let y = Self.entry(minutes: 20)
        let diskAfterA: [TranslationEntry] = []

        let written = TranslationEntry.applying(.add(y), to: diskAfterA, limit: 100)

        #expect(written.map(\.id) == [y.id])
        #expect(written.contains { $0.id == x.id } == false)
    }

    @Test("A renomeia X, B depois adiciona Y: o nome de A sobrevive")
    func renameByAnotherInstanceIsNotOverwritten() {
        // O snapshot de B ainda tem X sem título; o disco já tem X renomeado por A.
        let id = UUID()
        let diskAfterA = [Self.entry(id, minutes: 10, title: "Reunião com o cliente")]
        let y = Self.entry(minutes: 20)

        let written = TranslationEntry.applying(.add(y), to: diskAfterA, limit: 100)

        #expect(written.first(where: { $0.id == id })?.title == "Reunião com o cliente")
    }

    // MARK: - O que a correção original já protegia, e continua protegendo

    @Test("Apagar não leva junto o que outra instância adicionou")
    func removingDoesNotDropWhatAnotherInstanceAdded() {
        let mine = Self.entry(minutes: 10)
        let theirs = Self.entry(minutes: 5)

        let written = TranslationEntry.applying(.remove(mine.id), to: [mine, theirs], limit: 100)

        #expect(written.map(\.id) == [theirs.id])
    }

    @Test("Adicionar preserva o que já estava no disco, inclusive de outra instância")
    func addingKeepsWhatIsAlreadyStored() {
        let theirs = Self.entry(minutes: 5)
        let mine = Self.entry(minutes: 10)

        let written = TranslationEntry.applying(.add(mine), to: [theirs], limit: 100)

        #expect(written.map(\.id) == [mine.id, theirs.id])
    }

    // MARK: - Renomear

    @Test("Renomear uma entrada que outra instância apagou é no-op, e não a ressuscita")
    func renamingAnEntryDeletedElsewhereIsANoOp() {
        let survivor = Self.entry(minutes: 5)
        let goneID = UUID()

        let written = TranslationEntry.applying(
            .rename(goneID, title: "Nome novo"),
            to: [survivor],
            limit: 100
        )

        #expect(written.map(\.id) == [survivor.id])
    }

    @Test("Renomear aplica sobre a versão do DISCO, não sobre um snapshot antigo")
    func renamingAppliesOnTopOfTheStoredVersion() {
        let id = UUID()
        let stored = Self.entry(id, minutes: 10, title: "Antigo")

        let written = TranslationEntry.applying(.rename(id, title: "Novo"), to: [stored], limit: 100)

        #expect(written.first?.title == "Novo")
    }

    @Test("Título vazio vira nil, para a lista voltar ao preview do texto")
    func clearingTheTitleFallsBackToThePreview() {
        let id = UUID()
        let stored = Self.entry(id, minutes: 10, title: "Antigo")

        let written = TranslationEntry.applying(.rename(id, title: nil), to: [stored], limit: 100)

        #expect(written.first?.title == nil)
    }

    // MARK: - Forma da lista

    @Test("Adicionar com o mesmo id substitui em vez de duplicar")
    func addingWithTheSameIDUpserts() {
        let id = UUID()
        let stored = Self.entry(id, minutes: 10, title: nil)
        let updated = Self.entry(id, minutes: 10, title: "Renomeada")

        let written = TranslationEntry.applying(.add(updated), to: [stored], limit: 100)

        #expect(written.count == 1)
        #expect(written.first?.title == "Renomeada")
    }

    @Test("Ordena por data, mais nova primeiro")
    func ordersByTimestampNewestFirst() {
        let newest = Self.entry(minutes: 30)
        let middle = Self.entry(minutes: 20)
        let oldest = Self.entry(minutes: 10)

        let written = TranslationEntry.applying(.add(middle), to: [newest, oldest], limit: 100)

        #expect(written.map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test("O teto corta depois de ordenar: quem cai fora é o mais antigo")
    func capsAfterOrderingSoTheOldestIsDropped() {
        let newest = Self.entry(minutes: 30)
        let added = Self.entry(minutes: 20)
        let oldest = Self.entry(minutes: 10)

        let written = TranslationEntry.applying(.add(added), to: [newest, oldest], limit: 2)

        #expect(written.map(\.id) == [newest.id, added.id])
    }

    @Test("Empate de data desempata pelo id, para o resultado não depender da ordem de leitura")
    func breaksTimestampTiesDeterministically() {
        let a = Self.entry(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, minutes: 10)
        let b = Self.entry(UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, minutes: 10)

        let oneWay = TranslationEntry.applying(.add(a), to: [b], limit: 100)
        let theOther = TranslationEntry.applying(.add(b), to: [a], limit: 100)

        #expect(oneWay.map(\.id) == theOther.map(\.id))
        #expect(oneWay.map(\.id) == [b.id, a.id])
    }

    @Test("Apagar tudo esvazia, inclusive o que outra instância gravou no meio")
    func clearAllBeatsWhateverIsStored() {
        let mine = Self.entry(minutes: 10)
        let theirs = Self.entry(minutes: 5)

        #expect(TranslationEntry.applying(.clear, to: [mine, theirs], limit: 100).isEmpty)
    }

    @Test("A entrada recém-adicionada NUNCA é a descartada pelo teto, nem com relógio atrasado")
    func theJustAddedEntryIsNeverTheOneDroppedByTheCap() {
        // Duas entradas mais NOVAS já no disco, teto de 2, e a que o usuário acabou de gravar tem
        // data mais antiga (relógio da máquina atrasado, ou histórico vindo de outro lugar).
        // Ordenar tudo e cortar faria a ação do usuário sumir na hora.
        let newer = Self.entry(minutes: 100)
        let alsoNewer = Self.entry(minutes: 90)
        let justRecorded = Self.entry(minutes: 1)

        let written = TranslationEntry.applying(
            .add(justRecorded),
            to: [newer, alsoNewer],
            limit: 2
        )

        #expect(written.contains { $0.id == justRecorded.id })
        #expect(written.count == 2)
    }

    @Test("Com teto 1, sobra exatamente a entrada recém-adicionada")
    func aCapOfOneKeepsTheJustAddedEntry() {
        let stored = Self.entry(minutes: 100)
        let justRecorded = Self.entry(minutes: 1)

        let written = TranslationEntry.applying(.add(justRecorded), to: [stored], limit: 1)

        #expect(written.map(\.id) == [justRecorded.id])
    }

    @Test("Teto zero ou negativo devolve lista vazia em vez de estourar no prefix")
    func nonPositiveLimitIsEmpty() {
        #expect(
            TranslationEntry.applying(
                .add(Self.entry(minutes: 10)),
                to: [],
                limit: 0
            ).isEmpty
        )
    }
}
