import SwiftUI

/// Renderiza o Markdown "de chat" que os LLMs costumam devolver — títulos,
/// **negrito**/*itálico*/`código` inline, links, listas com marcador, checkboxes
/// (`- [ ]` / `- [x]`) e listas numeradas — sem mostrar os caracteres crus.
///
/// O `Text` do SwiftUI só entende Markdown **inline** (e só quando recebe um
/// `AttributedString`). Ele não quebra em títulos/listas nem preserva parágrafos.
/// Por isso quebramos o texto em **blocos** e renderizamos cada um, deixando o
/// inline a cargo do `AttributedString`.
struct MarkdownText: View {
    let markdown: String
    var font: Font = .system(size: 15)
    var color: Color = VoizTheme.primaryText
    var lineSpacing: CGFloat = 5
    /// Como resolver e abrir as marcas de citação (`[[m:1a2b3c4d]]`). `nil` — o caso de todo mundo
    /// que não é o Chat — apenas remove as marcas, para nunca sobrar sintaxe crua na tela.
    var citations: MarkdownCitations?

    var body: some View {
        let numbering = citations.map { CitationNumbering(text: markdown, source: $0) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block, numbering: numbering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Render

    @ViewBuilder
    private func blockView(_ block: MDBlock, numbering: CitationNumbering?) -> some View {
        switch block {
        case let .heading(level, text, _):
            // Títulos não recebem chip de propósito: o prompt pede a marca no fim da frase, e um
            // chip dentro de um título quebraria a hierarquia visual.
            inline(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text, refs):
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                inline(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                chips(refs, numbering: numbering)
            }

        case let .bullets(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(for: item)
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            inline(item.text)
                                .font(font)
                                .foregroundColor(color)
                                .lineSpacing(lineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                            chips(item.refs, numbering: numbering)
                        }
                    }
                }
            }

        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(font)
                            .foregroundColor(color.opacity(0.7))
                            .monospacedDigit()
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            inline(item.text)
                                .font(font)
                                .foregroundColor(color)
                                .lineSpacing(lineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                            chips(item.refs, numbering: numbering)
                        }
                    }
                }
            }
        }
    }

    /// Chips das marcas de uma linha. Uma marca que não resolve (o modelo inventou, ou a reunião
    /// foi apagada depois) simplesmente não vira chip — melhor faltar um número do que abrir um
    /// item errado ou mostrar um chip morto.
    @ViewBuilder
    private func chips(_ refs: [CitationRef], numbering: CitationNumbering?) -> some View {
        if let numbering, !refs.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                    if let citation = numbering.citation(for: ref) {
                        ChatCitationChip(citation: citation) {
                            numbering.source.open(citation)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: BulletItem) -> some View {
        switch item.checkbox {
        case .none:
            Text("•")
                .font(font)
                .foregroundColor(color.opacity(0.6))
        case .unchecked:
            Image(systemName: "square")
                .font(.system(size: 12))
                .foregroundColor(color.opacity(0.6))
        case .checked:
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.accent)
        }
    }

    /// Converte uma linha em `Text` interpretando o Markdown **inline**
    /// (negrito, itálico, código, links). Preserva os espaços do original.
    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        default: return 15
        }
    }
}

// MARK: - Citações

/// Uma marca encontrada no texto, antes de virar chip.
struct CitationRef: Equatable {
    let kind: VoizSearchKind
    let handle: String
}

/// O item do app para o qual uma marca aponta, já pronto para exibir.
struct MarkdownCitation: Identifiable, Equatable {
    let id: UUID
    let kind: VoizSearchKind
    let title: String
    let detail: String
    let snippet: String
    var number: Int = 0
}

/// Ligação entre o texto do modelo e o app: resolve marcas e abre o item clicado.
struct MarkdownCitations {
    var resolve: (CitationRef) -> MarkdownCitation?
    var open: (MarkdownCitation) -> Void
}

/// Numera as citações **por mensagem**, na ordem em que aparecem no texto.
///
/// A numeração é da mensagem inteira, não de cada bloco: citar a mesma reunião no primeiro e no
/// último item de uma lista tem que dar o mesmo número nos dois lugares, como numa nota de rodapé.
struct CitationNumbering {
    let source: MarkdownCitations
    private var byHandle: [String: MarkdownCitation] = [:]

    init(text: String, source: MarkdownCitations) {
        self.source = source
        var next = 1
        for match in ChatCitation.matches(in: text) {
            let key = "\(ChatCitation.letter(for: match.kind)):\(match.handle)"
            guard byHandle[key] == nil else { continue }
            guard var citation = source.resolve(CitationRef(kind: match.kind, handle: match.handle)) else { continue }
            citation.number = next
            next += 1
            byHandle[key] = citation
        }
    }

    func citation(for ref: CitationRef) -> MarkdownCitation? {
        byHandle["\(ChatCitation.letter(for: ref.kind)):\(ref.handle)"]
    }
}

// MARK: - Block model

private enum MDBlock {
    case heading(level: Int, text: String, refs: [CitationRef])
    case paragraph(String, [CitationRef])
    case bullets([BulletItem])
    case ordered([OrderedItem])
}

private struct BulletItem {
    enum Checkbox { case none, unchecked, checked }
    let text: String
    let checkbox: Checkbox
    let refs: [CitationRef]
}

private struct OrderedItem {
    let text: String
    let refs: [CitationRef]
}

/// Tira as marcas da linha e devolve o texto limpo junto com o que foi tirado. O texto que chega
/// ao `AttributedString` nunca contém `[[m:...]]` — mesmo quando não há quem renderize chip.
private func extractRefs(_ line: String) -> (text: String, refs: [CitationRef]) {
    let matches = ChatCitation.matches(in: line)
    guard !matches.isEmpty else { return (line, []) }
    var text = line
    for match in matches.reversed() {
        text.replaceSubrange(match.range, with: "")
    }
    let refs = matches.map { CitationRef(kind: $0.kind, handle: $0.handle) }
    let cleaned = text
        .replacingOccurrences(of: "  ", with: " ")
        .replacingOccurrences(of: " .", with: ".")
        .replacingOccurrences(of: " ,", with: ",")
        .trimmingCharacters(in: .whitespaces)
    return (cleaned, refs)
}

// MARK: - Parser

/// Quebra o Markdown em blocos. Linhas em branco separam blocos; itens de lista
/// consecutivos são agrupados. O inline (negrito etc.) fica para o `AttributedString`.
private func parseBlocks(_ markdown: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var paragraph: [String] = []
    var paragraphRefs: [CitationRef] = []
    var bullets: [BulletItem] = []
    var ordered: [OrderedItem] = []

    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n"), paragraphRefs))
        paragraph = []
        paragraphRefs = []
    }
    func flushBullets() {
        guard !bullets.isEmpty else { return }
        blocks.append(.bullets(bullets))
        bullets = []
    }
    func flushOrdered() {
        guard !ordered.isEmpty else { return }
        blocks.append(.ordered(ordered))
        ordered = []
    }
    func flushAll() { flushParagraph(); flushBullets(); flushOrdered() }

    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    for rawLine in normalized.components(separatedBy: "\n") {
        let (lineText, lineRefs) = extractRefs(rawLine.trimmingCharacters(in: .whitespaces))
        let trimmed = lineText

        if trimmed.isEmpty {
            flushAll()
            continue
        }

        if let heading = headingMatch(trimmed) {
            flushAll()
            blocks.append(.heading(level: heading.level, text: heading.text, refs: lineRefs))
            continue
        }

        if let item = bulletMatch(trimmed, refs: lineRefs) {
            flushParagraph(); flushOrdered()
            bullets.append(item)
            continue
        }

        if let item = orderedMatch(trimmed) {
            flushParagraph(); flushBullets()
            ordered.append(OrderedItem(text: item, refs: lineRefs))
            continue
        }

        flushBullets(); flushOrdered()
        paragraph.append(trimmed)
        paragraphRefs.append(contentsOf: lineRefs)
    }
    flushAll()
    return blocks
}

private func headingMatch(_ line: String) -> (level: Int, text: String)? {
    guard line.hasPrefix("#") else { return nil }
    var level = 0
    var rest = Substring(line)
    while rest.first == "#" {
        level += 1
        rest = rest.dropFirst()
    }
    guard level <= 6, rest.first == " " else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (min(level, 3), text)
}

private func bulletMatch(_ line: String, refs: [CitationRef]) -> BulletItem? {
    for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
        let body = String(line.dropFirst(prefix.count))
        // Checkbox: "[ ]" / "[x]" / "[X]"
        if body.hasPrefix("[ ] ") {
            return BulletItem(text: String(body.dropFirst(4)), checkbox: .unchecked, refs: refs)
        }
        if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
            return BulletItem(text: String(body.dropFirst(4)), checkbox: .checked, refs: refs)
        }
        return BulletItem(text: body, checkbox: .none, refs: refs)
    }
    return nil
}

private func orderedMatch(_ line: String) -> String? {
    // "1. texto", "12) texto"
    var digits = ""
    var rest = Substring(line)
    while let c = rest.first, c.isNumber {
        digits.append(c)
        rest = rest.dropFirst()
    }
    guard !digits.isEmpty, let sep = rest.first, sep == "." || sep == ")" else { return nil }
    rest = rest.dropFirst()
    guard rest.first == " " else { return nil }
    let text = rest.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return text
}

// MARK: - Chip de citação

/// O balãozinho numerado ao lado de uma frase: hover mostra do que se trata, clique abre o item.
///
/// A prévia **não** é desenhada aqui. O chip só publica, via preferência, quem está sob o mouse e
/// onde ele está na tela; quem desenha é o container da conversa (`citationPreviewOverlay`), que
/// fica por fora do `ScrollView`.
///
/// Foram três tentativas até aqui, e as duas primeiras falharam por motivos opostos: `overlay`
/// dentro da lista saía recortado pelo `ScrollView`, e `popover` resolvia o recorte mas trazia
/// junto dois defeitos do AppKit — a janela órfã quando a view âncora sumia (travava o app) e o
/// primeiro clique sendo consumido para fechar o popover, que era o clique que devia navegar.
/// Sem janela nenhuma, os dois problemas deixam de existir.
struct ChatCitationChip: View {
    let citation: MarkdownCitation
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text("\(citation.number)")
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .foregroundColor(isHovering ? VoizTheme.primaryText : VoizTheme.mutedText)
            .frame(width: 16, height: 16)
            .background(isHovering ? VoizTheme.hoverBackground : VoizTheme.iconBackground)
            .clipShape(Circle())
            .overlay(Circle().stroke(VoizTheme.border))
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            // `onLongPressGesture` com duração zero, e não `onTapGesture`: a mensagem inteira é
            // `.textSelection(.enabled)`, e o gesto de seleção de texto vence o tap — com tap o
            // clique não chegava nunca. O press dispara na descida do mouse, antes disso.
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                guard pressing else { return }
                isHovering = false
                // Fora do callback do gesto: navegar destrói esta view, e mexer no estado de
                // navegação no meio do gesto é pedir para o SwiftUI se perder.
                DispatchQueue.main.async(execute: onOpen)
            }, perform: {})
            .onDisappear { isHovering = false }
            .anchorPreference(key: CitationHoverPreference.self, value: .bounds) { anchor in
                isHovering ? CitationHoverValue(citation: citation, anchor: anchor) : nil
            }
    }
}

/// Quem está sob o mouse e onde — o chip publica, o container desenha.
struct CitationHoverValue: Equatable {
    let citation: MarkdownCitation
    let anchor: Anchor<CGRect>
}

struct CitationHoverPreference: PreferenceKey {
    static let defaultValue: CitationHoverValue? = nil

    /// Só um chip fica sob o mouse por vez; o último não-nulo vence.
    static func reduce(value: inout CitationHoverValue?, nextValue: () -> CitationHoverValue?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Desenha a prévia da citação sob o mouse. Vai **no container** da conversa, por fora do
    /// `ScrollView` — é o que evita o recorte sem precisar de uma janela do AppKit.
    func citationPreviewOverlay() -> some View {
        overlayPreferenceValue(CitationHoverPreference.self) { value in
            GeometryReader { proxy in
                if let value {
                    let rect = proxy[value.anchor]
                    ChatCitationPreview(citation: value.citation)
                        .offset(
                            x: ChatCitationPreview.clampedX(chip: rect, container: proxy.size),
                            y: ChatCitationPreview.offsetY(chip: rect, container: proxy.size)
                        )
                }
            }
            // A prévia é decoração: não pode roubar hover nem clique de nada embaixo dela.
            .allowsHitTesting(false)
        }
    }
}

/// O cartão: ícone, título, data e as primeiras linhas do resumo.
struct ChatCitationPreview: View {
    let citation: MarkdownCitation

    static let width: CGFloat = 300
    /// Altura estimada, usada só para decidir se o cartão cabe abaixo do chip. Com `lineLimit(3)`
    /// e largura fixa, a variação real é de poucos pontos.
    private static let estimatedHeight: CGFloat = 96
    private static let gap: CGFloat = 8

    /// Encosta o cartão no chip, sem deixar ele sair pela lateral do container.
    static func clampedX(chip: CGRect, container: CGSize) -> CGFloat {
        min(max(8, chip.minX - 12), max(8, container.width - width - 8))
    }

    /// Abaixo do chip quando cabe; acima quando não cabe — a última mensagem da conversa é
    /// justamente onde mais aparecem citações.
    static func offsetY(chip: CGRect, container: CGSize) -> CGFloat {
        let below = chip.maxY + gap
        if below + estimatedHeight <= container.height { return below }
        return max(0, chip.minY - gap - estimatedHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: citation.kind.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(citation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(citation.detail)
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText)
            }
            .foregroundColor(VoizTheme.primaryText)

            if !citation.snippet.isEmpty {
                Text(citation.snippet)
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        // Duas camadas: a de elevação (`elevatedBackground`) é branco a 5% e sozinha deixava o
        // texto da conversa aparecer por baixo do cartão. Aqui embaixo dela vai uma cor **opaca**
        // — o cartão flutua sobre a conversa, então precisa de fundo próprio, não de translucidez.
        .background(VoizTheme.elevatedBackground)
        .background(VoizTheme.chatPanelBackground)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}
