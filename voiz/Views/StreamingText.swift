import SwiftUI
import Combine

/// Revela um texto que cresce com o tempo, caractere a caractere, com um
/// "rabo" de opacidade suave na borda — efeito parecido com o streaming de
/// LLMs (Gemini/OpenAI). A velocidade é adaptativa: quanto maior o atraso em
/// relação ao texto alvo, mais rápido ele alcança, para acompanhar o áudio ao vivo.
struct StreamingText: View {
    enum Cadence {
        /// Alcança o texto alvo rapidamente (Tradução e usos gerais).
        case responsive
        /// Suaviza a entrada sem segurar o realtime e mantém a ponta não confirmada translúcida.
        case liveTranscript
    }

    let text: String
    var font: Font = .system(size: 16)
    var color: Color = VoizTheme.primaryText
    var lineSpacing: CGFloat = 6
    /// Quando false, mostra o texto inteiro de imediato (modo revisão/estático).
    var animated: Bool = true
    var cadence: Cadence = .responsive

    @State private var revealed: Int = 0
    /// Prefixo que apareceu igual em duas hipóteses consecutivas.
    @State private var confirmedPrefix: Int = 0
    @State private var revealDeadline = Date.distantPast
    @State private var settleDeadline = Date.distantPast
    /// Quando o texto alvo mudou pela última vez — a base da medição do intervalo.
    @State private var lastTargetChangeAt: Date?
    /// O intervalo típico entre duas hipóteses, medido nesta view. `nil` até haver duas.
    @State private var measuredGap: TimeInterval?

    private let fadeWindow = 12
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    /// Quanto tempo a revelação leva quando ainda não há intervalo medido — a primeira hipótese, e
    /// todo texto que só chega uma vez (o balão de turno da reunião).
    private var baseRevealDuration: TimeInterval {
        // O ASR já entrega a hipótese em ~1s. A animação só amacia a entrada; não
        // deve acrescentar outro segundo inteiro de atraso à fala.
        cadence == .liveTranscript ? 0.12 : 0.15
    }

    /// Fração do intervalo entre hipóteses que a revelação ocupa. Menor que 1 de propósito: a
    /// revelação tem que **terminar** antes da próxima chegar, senão o texto passa a atrasar em
    /// relação à fala e o atraso se acumula.
    private let revealDutyCycle: TimeInterval = 0.85
    /// Acima disto o intervalo não é cadência, é uma pausa na fala (ou o usuário voltando à tela).
    /// Uma revelação de 4 segundos seria pior que nenhuma.
    private let maximumMeasuredGap: TimeInterval = 3.0

    /// Quanto a revelação deve durar, dado o ritmo em que as hipóteses estão de fato chegando.
    ///
    /// **É a correção da fluidez que o gate do CHECKLIST-ONDA2 reprovou.** Com duração fixa de
    /// 0,15 s, cada trecho da tradução (que chega a cada ~1,2 s com ~25 caracteres, medido no app
    /// real) aparecia inteiro num piscar e a tela ficava mais de um segundo parada — pisca e
    /// espera, que é exatamente o "chega em blocos grandes" relatado, mesmo com a transcrição
    /// chegando em blocos pequenos e no prazo. O EFEITO_GHOST.md descreve o efeito pretendido como
    /// ~30 ms por caractere, ou seja ~0,75 s para 25 caracteres: uma revelação que ocupa a lacuna.
    ///
    /// Adaptativa, e não constante, porque o intervalo não é uma constante do app: depende do
    /// motor, do tamanho do modelo, da máquina e da própria fala. Amarrar 0,9 s no código faria a
    /// revelação **arrastar** assim que os trechos viessem mais rápidos — trocaria um defeito de
    /// cadência por outro. Aqui o texto acompanha o ritmo que existir.
    private var revealDuration: TimeInterval {
        guard cadence == .responsive, let measuredGap else { return baseRevealDuration }
        return max(baseRevealDuration, measuredGap * revealDutyCycle)
    }
    private var showsProvisionalTail: Bool {
        cadence == .liveTranscript
    }
    private var provisionalSettleDelay: TimeInterval {
        0.9
    }

    var body: some View {
        let chars = Array(text)
        let target = chars.count
        let shown = animated ? min(revealed, target) : target
        let rendered = composed(
            chars: chars,
            count: shown,
            confirmedPrefix: animated ? confirmedPrefix : target,
            fadeLeadingEdge: animated && shown < target
        )

        return ZStack(alignment: .topLeading) {
            // Reserva desde já a altura do texto alvo. Assim o auto-scroll conhece a
            // posição final enquanto a parte visível ainda está sendo preenchida.
            if animated {
                Text(text)
                    .foregroundColor(.clear)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            rendered
        }
            .font(font)
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
            .onReceive(timer) { _ in
                guard animated else { return }
                advance(target: target, now: Date())
            }
            .onChange(of: text) { oldValue, newValue in
                updateTarget(from: oldValue, to: newValue)
            }
            .onAppear {
                if animated {
                    let now = Date()
                    revealed = min(revealed, target)
                    confirmedPrefix = showsProvisionalTail ? 0 : target
                    // A medição não sobrevive a um reaparecimento: o intervalo entre a última
                    // hipótese de antes e a primeira de agora não é cadência de nada.
                    lastTargetChangeAt = nil
                    measuredGap = nil
                    revealDeadline = now.addingTimeInterval(revealDuration)
                    settleDeadline = now.addingTimeInterval(provisionalSettleDelay)
                } else {
                    revealed = target
                    confirmedPrefix = target
                }
            }
    }

    private func updateTarget(from oldValue: String, to newValue: String) {
        let now = Date()
        let newCount = newValue.count

        guard animated else {
            revealed = newCount
            confirmedPrefix = newCount
            return
        }

        measureGap(at: now)

        // Se a hipótese corrigiu/encolheu o rabo, troca o bloco corrigido no lugar;
        // apenas os caracteres realmente novos continuam entrando cadenciados.
        revealed = min(revealed, newCount)
        if showsProvisionalTail {
            confirmedPrefix = Self.stablePrefixLength(previous: oldValue, current: newValue)
            settleDeadline = now.addingTimeInterval(provisionalSettleDelay)
        } else {
            confirmedPrefix = newCount
        }
        revealDeadline = now.addingTimeInterval(revealDuration)
    }

    /// Atualiza o intervalo típico entre hipóteses — ver `revealDuration`.
    ///
    /// Média móvel, e não o último intervalo cru: um trecho que demora (uma pausa curta na fala,
    /// uma inferência mais lenta) não pode fazer a revelação seguinte arrastar. E intervalo acima
    /// de `maximumMeasuredGap` **zera** a medição em vez de entrar na média: aquilo não foi
    /// cadência, foi pausa, e o ritmo depois dela recomeça do zero.
    private func measureGap(at now: Date) {
        defer { lastTargetChangeAt = now }
        guard let lastTargetChangeAt else { return }

        let gap = now.timeIntervalSince(lastTargetChangeAt)
        guard gap > 0, gap <= maximumMeasuredGap else {
            measuredGap = nil
            return
        }
        measuredGap = measuredGap.map { $0 * 0.6 + gap * 0.4 } ?? gap
    }

    private func advance(target: Int, now: Date) {
        if revealed < target {
            let backlog = target - revealed
            let remaining = max(1.0 / 60.0, revealDeadline.timeIntervalSince(now))
            let remainingFrames = max(1, Int(ceil(remaining * 60)))
            let step = max(1, Int(ceil(Double(backlog) / Double(remainingFrames))))
            revealed = min(target, revealed + step)
        }

        // Se não veio outra hipótese, a ponta deixa de parecer eternamente provisória.
        if showsProvisionalTail,
           revealed >= target,
           confirmedPrefix < target,
           now >= settleDeadline {
            confirmedPrefix = target
        }
    }

    private func composed(
        chars: [Character],
        count: Int,
        confirmedPrefix: Int,
        fadeLeadingEdge: Bool
    ) -> Text {
        guard count > 0 else { return Text("") }

        if showsProvisionalTail {
            let solidEnd = min(count, confirmedPrefix)
            var result = Text(String(chars[0..<solidEnd])).foregroundColor(color)
            guard solidEnd < count else { return result }

            let ghostFadeStart = max(solidEnd, count - fadeWindow)
            if solidEnd < ghostFadeStart {
                let ghost = Text(String(chars[solidEnd..<ghostFadeStart]))
                    .foregroundColor(color.opacity(0.62))
                result = Text("\(result)\(ghost)")
            }

            let ghostLength = max(1, count - ghostFadeStart)
            for index in ghostFadeStart..<count {
                let progress = Double(index - ghostFadeStart + 1) / Double(ghostLength)
                let opacity = 0.62 - (0.24 * progress)
                let character = Text(String(chars[index])).foregroundColor(color.opacity(opacity))
                result = Text("\(result)\(character)")
            }
            return result
        }

        guard fadeLeadingEdge else {
            return Text(String(chars[0..<count])).foregroundColor(color)
        }
        let solidEnd = max(0, count - fadeWindow)
        var result = Text(String(chars[0..<solidEnd])).foregroundColor(color)
        for index in solidEnd..<count {
            // Mais novo = mais fraco; vai ganhando opacidade conforme "assenta".
            let opacity = Double(count - index) / Double(fadeWindow)
            let character = Text(String(chars[index])).foregroundColor(color.opacity(opacity))
            result = Text("\(result)\(character)")
        }
        return result
    }

    /// Compara palavras normalizadas (ignorando só pontuação nas bordas) e devolve o
    /// fim da última palavra idêntica. Assim uma correção de pontuação não escurece
    /// novamente uma frase inteira, mas uma palavra realmente corrigida volta ao ghost.
    private static func stablePrefixLength(previous: String, current: String) -> Int {
        let previousWords = wordSpans(in: previous)
        let currentWords = wordSpans(in: current)
        var commonWords = 0

        while commonWords < previousWords.count,
              commonWords < currentWords.count,
              previousWords[commonWords].normalized == currentWords[commonWords].normalized {
            commonWords += 1
        }

        guard commonWords > 0 else { return 0 }
        let chars = Array(current)
        var end = currentWords[commonWords - 1].end
        while end < chars.count, chars[end].isWhitespace {
            end += 1
        }
        return end
    }

    private static func wordSpans(in text: String) -> [(normalized: String, end: Int)] {
        let chars = Array(text)
        var words: [(normalized: String, end: Int)] = []
        var start: Int?

        for index in 0...chars.count {
            let isBoundary = index == chars.count || chars[index].isWhitespace
            if isBoundary {
                if let start {
                    let raw = String(chars[start..<index])
                    let normalized = raw.lowercased()
                        .trimmingCharacters(in: .punctuationCharacters)
                    if !normalized.isEmpty {
                        words.append((normalized, index))
                    }
                }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        return words
    }
}
