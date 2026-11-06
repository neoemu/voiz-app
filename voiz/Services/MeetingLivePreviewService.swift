import Accelerate
import Combine
import Foundation
import WhisperKit

/// Prévia opcional do modo Qualidade. Tenta primeiro uma sessão Apple SpeechAnalyzer por
/// canal; se o analisador não estiver disponível, cai para uma janela deslizante do Whisper
/// `small`. Este texto é apenas visual: o transcript oficial é reconstruído no pós-call.
///
/// Por que janela, e não chunks isolados: um chunk de 1–2s não dá contexto nenhum ao
/// Whisper (palavras cortadas no meio → texto inventado). Re-transcrever a janela custa o
/// MESMO que o chunk (o Whisper preenche tudo até 30s), então o contexto sai de graça.
/// `small` em vez de `base`: PT-BR do base alucina demais; o small custa ~100–200ms por
/// passe no ANE — leve o bastante pra rodar a reunião inteira junto do app de chamada.
/// O Whisper grande só entra depois que a captura termina.
///
/// FONTE DOMINANTE, nunca mix: com alto-falante a mesma fala existe no mic (eco) e no
/// áudio do sistema — somar os dois vira áudio embolado que degrada o ASR (validado na
/// prática). A janela segue a fonte mais audível do momento (seu mic quando você fala, o
/// sistema quando participantes falam) e troca na virada de turno, com um pre-roll de ~2s
/// pra não perder o começo de quem entra.
///
/// É o "tier rápido": o transcript oficial é reconstruído dos dois arquivos de áudio
/// pela engine escolhida no pós-call e depois passa pela diarização. Nada daqui é persistido.
final class MeetingLivePreviewService: ObservableObject {
    /// Motivo técnico que encerrou a janela do Whisper. Só uma pausa longa representa
    /// também uma quebra visual; limite de contexto e troca de fonte devem ser costurados
    /// pelo view model no mesmo bloco que já está na tela.
    enum CommitReason {
        case silence
        case windowLimit
        case sourceSwitch
    }

    /// true = modelo leve carregado e loop rodando; o VM usa pra escolher a fonte do painel.
    @Published private(set) var isActive = false

    /// O texto entregue já é o BLOCO inteiro, e não uma janela deslizante.
    ///
    /// Muda o contrato do `onWindowText` e por isso é publicado: com o analisador do sistema junto,
    /// o texto vem do `MeetingPreviewComposer`, que garante por construção que um bloco não repete
    /// áudio de outro. Quem recebe deve CONCATENAR, não costurar por sobreposição de palavras — a
    /// costura foi escrita para a janela do Whisper, onde cada hipótese repete o fim da anterior,
    /// e aplicada a um bloco inteiro ela não acha sobreposição e anexa tudo de novo (defeito visto
    /// em reunião real em 27/08/2026).
    @Published private(set) var emitsWholeBlockText = false

    /// Texto (reescrito) da janela corrente — o VM substitui o parágrafo em crescimento.
    var onWindowText: ((String) -> Void)?
    /// A janela interna fechou. O motivo permite não expor os resets técnicos como
    /// quebras de parágrafo na prévia.
    var onWindowCommitted: ((String, CommitReason) -> Void)?
    /// Chamado quando o serviço desiste sozinho (falhas em série). NÃO é chamado no stop()
    /// normal. O áudio continua íntegro para o transcript oficial no pós-call.
    var onDeactivated: ((String) -> Void)?

    private static let previewModelName = "openai_whisper-small"
    /// Tick curto reduz a quantização entre o áudio ficar pronto e o próximo passe.
    /// A inferência continua estritamente serial: nunca há duas Tasks disputando ANE/GPU.
    private static let tickInterval: TimeInterval = 0.25
    /// ~0,75s de fala nova por hipótese: com os ~100–200ms do small, deixa a atualização
    /// perto de 1s sem voltar ao custo explosivo de inferências paralelas.
    private static let minNewSamplesPerPass = 12_000
    /// Janela máxima: cabe com folga nos 30s do Whisper e limita o contexto de cada passe.
    /// O bloco visual pode atravessar várias destas janelas.
    private static let windowCapSamples = 16_000 * 15
    /// Só uma pausa realmente longa fecha o bloco visual, como no Granola.
    private static let silenceCommitSamples = 16_000 * 7 / 2
    private static let audibleRMS: Float = 0.003
    private static let maxConsecutiveFailures = 3
    /// Fonte da janela calada por ≥ ~0.9s com a OUTRA fonte audível = virada de turno.
    private static let switchSilenceSamples = 14_400
    /// Pre-roll por fonte: ao abrir janela, começa com os últimos ~2s daquela fonte pra
    /// não decapitar a primeira palavra de quem entra falando.
    private static let preRollSamples = 16_000 * 2

    private let bufferLock = NSLock()
    private var stagingBuffers: [MeetingCaptureSource: [Float]] = [:]

    private var whisper: WhisperKit?
    private var language: Language = .portuguese
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// Invalida um start() que ainda estava baixando/carregando quando o stop() chegou.
    private var sessionToken = 0

    // Estado da janela corrente (main actor, só o loop mexe)
    private var windowBuffer: [Float] = []
    private var windowSource: MeetingCaptureSource?
    private var trailingSilence = 0
    private var samplesSinceLastPass = 0
    private var lastEmittedText = ""
    /// Virada de turno detectada: fecha a janela no próximo passe e abre na outra fonte.
    private var switchRequested = false
    /// Ticks seguidos com o sistema audível enquanto a janela está no mic (confirmação).
    private var systemAudibleTicks = 0
    /// Últimos ~2s de cada fonte, pro pre-roll na abertura de janela.
    private var preRoll: [MeetingCaptureSource: [Float]] = [:]

    // MARK: - Segundo motor da prévia (Onda 4)

    /// Uma sessão do analisador POR CANAL, quando o idioma é explícito.
    ///
    /// Uma por canal, e não uma só alimentada pela fonte da janela: alimentar pela seleção de
    /// janela foi o defeito da reunião com fone de 27/08, em que o microfone quase mudo prendeu o
    /// analisador no canal errado enquanto os participantes falavam pelo áudio do sistema.
    ///
    /// Cada sessão recebe o canal dela CONTINUAMENTE, silêncio inclusive, então o relógio de cada
    /// uma é o relógio da reunião e os trechos dos dois canais se ordenam por tempo entre si.
    private var appleSessions: [MeetingCaptureSource: AppleSpeechPreviewSession] = [:]
    private var appleBuffers: [MeetingCaptureSource: MeetingPreviewAppleBuffer] = [:]
    private var appleFedSamples: [MeetingCaptureSource: Int] = [:]
    private var lastAudibleSeconds: TimeInterval = 0
    private var analyzerLoopTask: Task<Void, Never>?

    /// Teto do bloco visual no modo analisador.
    ///
    /// A janela do Whisper fechava por limite técnico de 15s; o analisador não tem esse limite, e
    /// sem um teto um monólogo viraria um parágrafo interminável.
    private static let analyzerBlockCapSeconds: TimeInterval = 45
    /// Instante do relógio da reunião em que o bloco visual corrente começou.
    private var blockStartSeconds: TimeInterval = 0

    @MainActor
    func start(language: Language) async {
        guard !running else { return }
        self.language = language
        let token = sessionToken

        clearStagingBuffer()
        preRoll = [:]
        resetWindow()
        blockStartSeconds = 0
        lastAudibleSeconds = 0

        // Um motor OU o outro, nunca os dois. Enquanto a prévia juntava os dois, todo defeito que
        // apareceu na tela veio da emenda entre eles: bloco repetido, palavra picada na costura,
        // palavras perdidas quando um alcançava o outro. Sem emenda não há o que costurar.
        if await startAnalyzerSessions(locale: Self.analyzerLocale(for: language), token: token) {
            return
        }
        // Analisador indisponível (asset do locale ausente, pool de reservas cheio): a prévia cai
        // para a janela do Whisper em vez de sumir.
        print("🎤 Prévia: analisador indisponível; usando a janela do Whisper")

        await startWhisperWindow(token: token)
    }

    /// O locale do analisador para o idioma escolhido.
    ///
    /// Nunca é `nil` desde que o seletor perdeu o automático: todo idioma do app tem locale no
    /// `SpeechTranscriber`. A janela do Whisper deixou de ser a prévia de quem não fixou idioma e
    /// passou a ser só o **fallback** de quando o analisador não sobe (asset ausente, pool de
    /// reservas cheio) — ver `startAnalyzerSessions`.
    private static func analyzerLocale(for language: Language) -> Locale {
        Locale(identifier: language.appleSpeechLocale.rawValue)
    }

    /// Sobe uma sessão por canal. Devolve `false` quando nenhuma subiu.
    @MainActor
    private func startAnalyzerSessions(locale: Locale, token: Int) async -> Bool {
        for source in MeetingCaptureSource.allCases {
            let sessao = AppleSpeechPreviewSession()
            sessao.onUpdate = { [weak self] update in
                Task { @MainActor in self?.appleBuffers[source]?.apply(update) }
            }
            sessao.onFailure = { [weak self] error in
                Task { @MainActor in self?.dropAnalyzerSession(source, reason: "\(type(of: error))") }
            }
            do {
                try await sessao.start(locale: locale)
                guard token == sessionToken else { await sessao.stop(); return false }
                appleSessions[source] = sessao
                appleBuffers[source] = MeetingPreviewAppleBuffer()
                appleFedSamples[source] = 0
            } catch {
                print("🎤 Prévia: canal \(source.rawValue) sem analisador (\(type(of: error)))")
            }
        }
        guard !appleSessions.isEmpty else { return false }

        running = true
        isActive = true
        emitsWholeBlockText = true
        print("🎤 Prévia ao vivo ligada (analisador do sistema, \(appleSessions.count) canal(is))")
        analyzerLoopTask = Task { @MainActor [weak self] in
            await self?.runAnalyzerLoop()
        }
        return true
    }

    @MainActor
    private func startWhisperWindow(token: Int) async {
        if whisper == nil {
            do {
                // O small é o modelo padrão do app — na maioria das máquinas já está no
                // disco; senão baixa (~480MB) e a prévia liga sozinha quando pronta.
                let folder = try await WhisperKit.download(variant: Self.previewModelName)
                let loaded = try await WhisperKit(modelFolder: folder.path, verbose: false)
                whisper = loaded
            } catch {
                print("🎤 Prévia: falha ao carregar o modelo leve (\(Self.previewModelName)): \(error)")
                isActive = false
                return
            }
        }

        // stop() chegou enquanto o modelo carregava — não liga o loop de uma reunião morta.
        guard token == sessionToken else { return }

        running = true
        consecutiveFailures = 0
        isActive = true
        emitsWholeBlockText = false
        print("🎤 Prévia ao vivo ligada (Whisper \(Self.previewModelName), janela deslizante)")

        loopTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    /// Descarta a sessão de um canal. A prévia continua com o que sobrou.
    @MainActor
    private func dropAnalyzerSession(_ source: MeetingCaptureSource, reason: String) {
        guard let sessao = appleSessions.removeValue(forKey: source) else { return }
        appleBuffers[source] = nil
        print("🎤 Prévia: canal \(source.rawValue) caiu (\(reason))")
        Task { await sessao.stop() }
        if appleSessions.isEmpty {
            let motivo = "todas as sessões do analisador caíram"
            stop()
            print("🎤 Prévia ao vivo desligada: \(motivo)")
            onDeactivated?(motivo)
        }
    }

    @MainActor
    func stop() {
        sessionToken += 1
        running = false
        let sessoes = appleSessions.values
        appleSessions = [:]
        appleBuffers = [:]
        appleFedSamples = [:]
        emitsWholeBlockText = false
        blockStartSeconds = 0
        lastAudibleSeconds = 0
        analyzerLoopTask?.cancel()
        analyzerLoopTask = nil
        Task { for sessao in sessoes { await sessao.stop() } }
        loopTask?.cancel()
        loopTask = nil
        isActive = false
        clearStagingBuffer()
        preRoll = [:]
        resetWindow()
    }

    private func clearStagingBuffer() {
        bufferLock.lock()
        stagingBuffers = [:]
        bufferLock.unlock()
    }

    /// Recebe o áudio bruto de uma fonte (16kHz mono) da fila de captura. Thread: qualquer.
    func append(source: MeetingCaptureSource, samples: [Float]) {
        // No modo analisador cada canal vai direto para a sessão dele, silêncio inclusive: é isso
        // que mantém o relógio das duas sessões igual ao relógio da reunião.
        if let sessao = appleSessions[source], !samples.isEmpty {
            sessao.append(samples: samples)
            appleFedSamples[source, default: 0] += samples.count
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
            if rms > Self.audibleRMS {
                lastAudibleSeconds = Double(appleFedSamples[source] ?? 0) / 16_000
            }
            return
        }

        guard !samples.isEmpty else { return }
        bufferLock.lock()
        stagingBuffers[source, default: []].append(contentsOf: samples)
        // Proteção: se o loop travar, não reter áudio sem limite.
        let cap = 16_000 * 60
        if let count = stagingBuffers[source]?.count, count > cap {
            stagingBuffers[source]?.removeFirst(count - cap)
        }
        bufferLock.unlock()
    }

    // MARK: - Loop da janela (main actor; uma inferência por vez, por construção)

    @MainActor
    private func runLoop() async {
        while running {
            try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            guard running, let whisper else { break }

            ingestStagedAudio()

            let windowFull = windowBuffer.count >= Self.windowCapSamples
            let speechEnded = !windowBuffer.isEmpty && trailingSilence >= Self.silenceCommitSamples
            let commitReason: CommitReason? = if speechEnded {
                .silence
            } else if switchRequested {
                .sourceSwitch
            } else if windowFull {
                .windowLimit
            } else {
                nil
            }
            let shouldPass = samplesSinceLastPass >= Self.minNewSamplesPerPass || commitReason != nil
            guard !windowBuffer.isEmpty, shouldPass else { continue }

            do {
                let text = try await transcribeWindow(with: whisper)
                consecutiveFailures = 0
                samplesSinceLastPass = 0

                if let commitReason {
                    let final = text.isEmpty ? lastEmittedText : text
                    // Entrega também commit vazio: o view model pode ter um prefixo de
                    // janelas anteriores que precisa ser fechado quando o motivo é pausa.
                    onWindowCommitted?(final, commitReason)
                    // No limite de contexto, continua seguindo a mesma fonte e carrega o
                    // silêncio já observado. Assim uma pausa que cruza exatamente a
                    // fronteira dos 15s ainda fecha o bloco após 3,5s no total.
                    let continuationSource = commitReason == .windowLimit ? windowSource : nil
                    let inheritedSilence = commitReason == .windowLimit ? trailingSilence : 0
                    resetWindow(
                        continuing: continuationSource,
                        inheritedSilence: inheritedSilence
                    )
                } else if !text.isEmpty, text != lastEmittedText {
                    lastEmittedText = text
                    onWindowText?(text)
                }
            } catch {
                consecutiveFailures += 1
                samplesSinceLastPass = 0
                print("🎤 Prévia: passe da janela falhou (\(consecutiveFailures)×): \(error)")
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    let reason = "modelo leve falhou \(consecutiveFailures)× seguidas"
                    stop()
                    print("🎤 Prévia ao vivo desligada: \(reason)")
                    onDeactivated?(reason)
                    return
                }
            }
        }
    }

    /// Move o áudio recém-chegado pra janela, seguindo a fonte dominante do momento e
    /// rastreando silêncio no rabo pra fechar o parágrafo/trocar de fonte.
    @MainActor
    private func ingestStagedAudio() {
        bufferLock.lock()
        let stagedBySource = stagingBuffers
        stagingBuffers = [:]
        bufferLock.unlock()

        var rmsBySource: [MeetingCaptureSource: Float] = [:]
        for (source, staged) in stagedBySource where !staged.isEmpty {
            var rms: Float = 0
            vDSP_rmsqv(staged, 1, &rms, vDSP_Length(staged.count))
            rmsBySource[source] = rms

            // Pre-roll sempre atualizado (mesmo da fonte fora da janela).
            preRoll[source, default: []].append(contentsOf: staged)
            if let count = preRoll[source]?.count, count > Self.preRollSamples {
                preRoll[source]?.removeFirst(count - Self.preRollSamples)
            }
        }

        func audible(_ source: MeetingCaptureSource) -> Bool {
            (rmsBySource[source] ?? 0) > Self.audibleRMS
        }

        guard let currentSource = windowSource else {
            // Sem janela: sistema audível tem prioridade ABSOLUTA — é participante falando,
            // e o sinal digital é limpo. O mic pode estar "audível" só pelo ECO dos
            // alto-falantes (às vezes com RMS maior que o do sistema — domínios diferentes
            // não se comparam), e transcrever eco reverberado é o que gerava lixo.
            // Mic só abre janela com o sistema mudo (= você falando).
            let chosen: MeetingCaptureSource? = audible(.systemAudio)
                ? .systemAudio
                : (audible(.microphone) ? .microphone : nil)
            guard let chosen else { return }
            windowSource = chosen
            windowBuffer = preRoll[chosen] ?? []
            trailingSilence = 0
            samplesSinceLastPass = windowBuffer.count
            systemAudibleTicks = 0
            return
        }

        guard let staged = stagedBySource[currentSource], !staged.isEmpty else { return }
        windowBuffer.append(contentsOf: staged)
        if audible(currentSource) {
            trailingSilence = 0
            samplesSinceLastPass += staged.count
        } else {
            trailingSilence += staged.count
        }

        switch currentSource {
        case .microphone:
            // Sistema ficou audível com a janela no mic: participante começou a falar (o
            // que o mic ouve dali em diante tende a ser eco). Prioridade do sistema: fecha
            // a janela após 2 ticks de confirmação — sem esperar o mic "calar", porque o
            // eco mantém o mic audível indefinidamente.
            if audible(.systemAudio) {
                systemAudibleTicks += 1
                if systemAudibleTicks >= 2 {
                    switchRequested = true
                }
            } else {
                systemAudibleTicks = 0
            }
        case .systemAudio:
            // Sistema → mic só quando o sistema cala de fato e o mic segue falando.
            if trailingSilence >= Self.switchSilenceSamples, audible(.microphone) {
                switchRequested = true
            }
        }
    }

    /// O relógio da reunião: o canal que mais áudio recebeu.
    private var meetingSeconds: TimeInterval {
        Double(appleFedSamples.values.max() ?? 0) / 16_000
    }

    /// Os trechos dos dois canais no bloco corrente, ordenados por tempo.
    private var currentBlockSegments: [MeetingPreviewComposer.Segment] {
        appleBuffers.values
            .flatMap(\.segments)
            .filter { $0.end > blockStartSeconds }
            .sorted { $0.start < $1.start }
    }

    #if DEBUG
    /// Os trechos que compõem a emissão atual — só para a sonda de diagnóstico.
    var debugBlockSegments: [MeetingPreviewComposer.Segment] { currentBlockSegments }
    #endif

    /// Laço do modo analisador: só decide quando o parágrafo fecha e quando reemitir.
    ///
    /// Não há inferência aqui — o analisador entrega sozinho, por streaming. É a diferença para o
    /// `runLoop()` da janela deslizante, que precisa chamar o Whisper a cada passe.
    @MainActor
    private func runAnalyzerLoop() async {
        while running {
            try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            guard running else { break }

            let texto = MeetingPreviewComposer.compose(segments: currentBlockSegments, tail: nil)
            let agora = meetingSeconds
            let pausaLonga = agora - lastAudibleSeconds
                >= Double(Self.silenceCommitSamples) / 16_000
            let blocoLongo = agora - blockStartSeconds >= Self.analyzerBlockCapSeconds

            if !texto.isEmpty, pausaLonga || blocoLongo {
                onWindowCommitted?(texto, pausaLonga ? .silence : .windowLimit)
                lastEmittedText = ""
                blockStartSeconds = agora
                for (source, var buffer) in appleBuffers {
                    buffer.commitFrontier(at: agora)
                    appleBuffers[source] = buffer
                }
            } else if !texto.isEmpty, texto != lastEmittedText {
                lastEmittedText = texto
                onWindowText?(texto)
            }
        }
    }

    @MainActor
    private func transcribeWindow(with whisper: WhisperKit) async throws -> String {
        let results = try await whisper.transcribe(
            audioArray: windowBuffer,
            decodeOptions: DecodingOptions(
                language: language.rawValue,
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                // 1 retry: é o que corta os loops de repetição ("vai, vai, vai…") que o
                // decode guloso puro produz — barato e essencial na prévia.
                temperatureFallbackCount: 1,
                sampleLength: 224,
                usePrefillPrompt: true,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
        )

        // Filtros anti-alucinação: descarta segmentos com repetição absurda (compression
        // ratio alto) ou confiança péssima — prévia vazia é melhor que prévia inventada.
        let segments = results.flatMap(\.segments).filter { segment in
            segment.compressionRatio < 2.6 && segment.avgLogprob > -1.3
        }
        let joined = segments.map(\.text).joined(separator: " ")
        let sanitized = Self.sanitize(joined)
        let collapsed = Self.collapseRepeatedPhrases(sanitized)

        // Colapso removeu mais da metade das palavras = a janela era majoritariamente um
        // loop de repetição (alucinação). Melhor prévia vazia que prévia inventada.
        let originalWords = sanitized.split(separator: " ").count
        let collapsedWords = collapsed.split(separator: " ").count
        if originalWords >= 8, Double(collapsedWords) < Double(originalWords) * 0.4 {
            return ""
        }
        return collapsed
    }

    private func resetWindow(
        continuing source: MeetingCaptureSource? = nil,
        inheritedSilence: Int = 0
    ) {
        windowSource = source
        windowBuffer = source.flatMap { preRoll[$0] } ?? []
        trailingSilence = source == nil ? 0 : inheritedSilence
        samplesSinceLastPass = windowBuffer.count
        lastEmittedText = ""
        switchRequested = false
        systemAudibleTicks = 0
    }

    /// Remove tags de som que o Whisper emite em ruído/música ([MÚSICA], (aplausos), ♪).
    private static func sanitize(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\([^\\)]*\\)", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[♪♫♬🎵🎶]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Colapsa FRASES repetidas em sequência (n-gramas de 1 a 4 palavras) — os loops de
    /// alucinação do Whisper costumam ser bigramas ("é que é que é que…"), que um colapso
    /// de palavra única não pega. Se as próximas n palavras repetem as n anteriores, pula.
    private static func collapseRepeatedPhrases(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1 else { return text }

        func normalized(_ word: Substring) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        var output: [Substring] = []
        var index = 0
        while index < words.count {
            var skipped = false
            var n = 4
            while n >= 1 {
                if output.count >= n, index + n <= words.count {
                    let previous = output.suffix(n).map(normalized)
                    let upcoming = words[index..<(index + n)].map(normalized)
                    if previous == upcoming, !upcoming.joined().isEmpty {
                        index += n
                        skipped = true
                        break
                    }
                }
                n -= 1
            }
            if !skipped {
                output.append(words[index])
                index += 1
            }
        }

        return output.joined(separator: " ")
    }
}
