import Foundation

struct TranslationEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let sourceLanguage: Language
    let targetLanguage: Language
    let timestamp: Date
    /// Nome customizado dado pelo usuário (Renomear). `nil` = usa o preview do texto.
    var title: String?

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: Language,
        targetLanguage: Language,
        timestamp: Date = Date(),
        title: String? = nil
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.title = title
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    var preview: String {
        let base = translatedText.isEmpty ? sourceText : translatedText
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 {
            return trimmed
        }
        return String(trimmed.prefix(80)) + "…"
    }

    /// Título exibido na lista: nome customizado, se houver; senão o preview do texto.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return preview
    }
}

/// O que está gravado no disco, com a distinção que decide se é seguro gravar por cima.
///
/// A diferença entre `empty` e `unreadable` é a diferença entre "não há histórico" e "há histórico
/// e eu não sei ler". Colapsar as duas era o último caminho em que este desenho ainda perdia tudo
/// em silêncio — ver `TranslationEntry.write(_:onto:limit:)`.
nonisolated enum TranslationHistoryDisk {
    /// Não há blob: histórico realmente vazio (primeira execução, ou depois de "apagar tudo").
    case empty
    case decoded([TranslationEntry])
    /// Há blob e ele **não** decodifica.
    case unreadable

    /// A leitura, como decisão pura: quem faz I/O só entrega os bytes.
    static func read(_ data: Data?) -> TranslationHistoryDisk {
        guard let data else { return .empty }
        guard let decoded = try? JSONDecoder().decode([TranslationEntry].self, from: data) else {
            return .unreadable
        }
        return .decoded(decoded)
    }

    var entriesOrEmpty: [TranslationEntry] {
        if case .decoded(let entries) = self { return entries }
        return []
    }
}

/// Uma mudança no histórico de tradução, do jeito que ela precisa chegar ao disco: como **delta**.
///
/// O tipo existe porque a primeira versão desta correção reconciliava o SNAPSHOT em memória com o
/// disco, e snapshot não é mudança. Duas instâncias em sequência perfeita (sem colisão nenhuma)
/// bastavam para o snapshot velho de uma desfazer o trabalho da outra — ver
/// `TranslationEntry.applying(_:to:limit:)`.
///
/// Sem `Equatable`: sintetizar `==` aqui puxaria a conformidade do `TranslationEntry`, que é
/// isolada na main actor pelo default do alvo, para um contexto `nonisolated` — e ninguém
/// compara mudanças, só as aplica.
nonisolated enum TranslationHistoryChange {
    /// Uma tradução nova. Também serve de upsert: mesmo `id` substitui em vez de duplicar.
    case add(TranslationEntry)
    case remove(UUID)
    /// `nil` volta ao preview automático.
    case rename(UUID, title: String?)
    case clear
}

extension TranslationEntry {
    /// O que deve ser gravado, ou `nil` para **não gravar e não confirmar**.
    ///
    /// É a decisão inteira do `TranslationHistoryStore`, fora dele de propósito: o store virou
    /// casca de I/O (lê bytes, chama isto, grava bytes) e esta função é o que o alvo de testes
    /// alcança — `Models/TranslationEntry.swift` compila em `voizTests`, o store não.
    ///
    /// **O que torna um blob ilegível, e o que NÃO torna.** Não é "o build novo acrescentou um
    /// campo": o `JSONDecoder` ignora chaves desconhecidas, então acrescentar campo é o caso
    /// seguro — o build velho lê normalmente (achado do Farol; a versão anterior deste doc dizia o
    /// contrário). O que quebra é o esquema mudar de forma: campo obrigatório renomeado ou
    /// removido, tipo de um campo existente trocado, contêiner de fora diferente — ou o blob
    /// simplesmente corrompido. Todos esses caminhos levam ao mesmo lugar, e é ele que importa
    /// aqui: **ilegível não pode ser tratado como vazio.**
    ///
    /// `nil` em `unreadable`, e o `nil` é a metade que faltava. O fail-safe recusava a escrita, mas
    /// o `addEntry` devolvia `Void` e o `saveCurrentTranslationToHistory` devolvia `true` sempre:
    /// o `stopListening` limpava as caixas e anunciava "Salvo em Recentes" tendo perdido a única
    /// cópia da tradução — exatamente a invariante do C3 ("caixas limpas SÓ quando arquivou")
    /// violada pelo próprio mecanismo que existia para proteger dado. Achado do Farol.
    ///
    /// Vale para **toda** mudança, inclusive `clear`: com o blob ilegível o app não encosta nele.
    /// O preço é "Apagar tudo" virar no-op nesse estado — assumido, porque a alternativa é uma
    /// versão que não sabe ler o histórico poder destruí-lo. Hoje `clearAll()` não tem chamador na
    /// UI, então o preço é teórico.
    static func write(
        _ change: TranslationHistoryChange,
        onto stored: TranslationHistoryDisk,
        limit: Int
    ) -> [TranslationEntry]? {
        guard case .unreadable = stored else {
            return applying(change, to: stored.entriesOrEmpty, limit: limit)
        }
        return nil
    }

    /// Aplica UMA mudança desta instância sobre o que está gravado no disco **agora**.
    ///
    /// ## Por que delta, e não mesclagem de snapshots
    ///
    /// O `TranslationHistoryStore` lê o histórico uma vez, no `init`. A versão anterior desta
    /// correção usava esse snapshot como autoridade sobre o disco ("memória vence"), e o Farol
    /// derrubou com um contraexemplo que não precisa de concorrência nenhuma — só de duas
    /// instâncias abertas e duas ações em sequência:
    ///
    /// 1. disco `[X]`; as instâncias A e B abrem e ambas carregam `[X]`;
    /// 2. A apaga X e grava `[]`;
    /// 3. B adiciona Y. O snapshot de B ainda tem X, e "memória vence" **ressuscita X**.
    ///
    /// O mesmo mecanismo desfazia um Renomear feito em A: o snapshot velho de B reescrevia o título
    /// mais novo. Ou seja, a versão anterior trocava perda sistemática de ENTRADAS por perda
    /// sistemática de MUTAÇÕES — que é pior, porque apagar é uma decisão explícita do usuário.
    ///
    /// A regra aqui é a única que fecha os dois: **o disco é a verdade compartilhada, e esta
    /// instância só aplica o que ELA acabou de fazer.** Nada que só existe na memória local é
    /// reescrito; o que outra instância adicionou, apagou ou renomeou sobrevive por construção,
    /// porque nunca é tocado.
    ///
    /// Consequências assumidas, e as duas são o comportamento certo:
    /// - Renomear uma entrada que outra instância apagou é **no-op** — não ressuscita.
    /// - `clear` esvazia o histórico inteiro, inclusive o que outra instância gravou no meio.
    ///   "Apagar tudo" é sobre o histórico, não sobre esta cópia dele.
    ///
    /// O que continua **não** sendo resolvido, e está registrado em DECISOES: não há transação
    /// sobre o `UserDefaults`, então duas gravações exatamente simultâneas ainda podem se cruzar. O
    /// que morre é a perda determinística, a de toda gravação. (A frase que estava aqui, "esta
    /// instância só enxerga as outras quando ela própria grava", deixou de valer no r3: quem
    /// fechou isso foi a vigia do `TranslationHistoryStore` — e ela é cosmética, o caminho de dado
    /// continua sendo esta função sobre o disco lido na hora.)
    ///
    /// Pura de propósito: é a parte desta correção que o alvo de testes alcança (o store fala com o
    /// `UserDefaults`, e o view model puxa WhisperKit pelo coordenador, então nenhum dos dois
    /// compila em `voizTests`).
    static func applying(
        _ change: TranslationHistoryChange,
        to stored: [TranslationEntry],
        limit: Int
    ) -> [TranslationEntry] {
        guard limit > 0 else { return [] }

        switch change {
        case .clear:
            return []

        case .remove(let id):
            return ordered(stored.filter { $0.id != id }, limit: limit)

        case .rename(let id, let title):
            guard let index = stored.firstIndex(where: { $0.id == id }) else {
                // Apagada por outra instância enquanto esta tinha a tela aberta. Renomear não é
                // motivo para trazê-la de volta.
                return ordered(stored, limit: limit)
            }
            var updated = stored
            updated[index].title = title
            return ordered(updated, limit: limit)

        case .add(let entry):
            // A entrada recém-pedida **nunca** é a descartada pelo teto. Ordenar tudo junto e
            // cortar faria uma tradução acabada de gravar sumir na hora se o relógio da máquina
            // estivesse atrasado (ou se o histórico tivesse vindo de outro lugar com datas à
            // frente): o usuário pediu esta, e o que envelhece é o resto.
            let others = ordered(stored.filter { $0.id != entry.id }, limit: limit - 1)
            return ordered(others + [entry], limit: limit)
        }
    }

    /// Mais nova primeiro (a ordem que o `insert(at: 0)` mantinha), com o `id` desempatando para o
    /// resultado não depender da ordem de leitura. O teto corta **depois** de ordenar: quem cai fora
    /// é sempre o mais antigo.
    private static func ordered(
        _ entries: [TranslationEntry],
        limit: Int
    ) -> [TranslationEntry] {
        let sorted = entries.sorted { left, right in
            if left.timestamp != right.timestamp {
                return left.timestamp > right.timestamp
            }
            return left.id.uuidString > right.id.uuidString
        }
        return Array(sorted.prefix(limit))
    }
}
