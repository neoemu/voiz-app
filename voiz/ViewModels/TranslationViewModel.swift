import SwiftUI
import Combine
import AVFoundation
import AppKit

@MainActor
class TranslationViewModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var translatedText: String = ""
    @Published var state: TranscriptionState = .idle
    @Published var sourceLanguage: Language = .english
    @Published var targetLanguage: Language = .portuguese
    @Published var audioLevel: Float = 0.0
    @Published var debugLogs: [String] = []
    @Published var lastTranslationLatency: TimeInterval = 0.0
    @Published var showDebugConsole: Bool = false
    @Published var isTyping: Bool = false
    @Published private(set) var translationIssue: TranslationIssue?
    @Published private var credentialsReady = false
    private var translationFailed = false

    var translationConfigurationIssue: TranslationIssue? {
        return TranslationIssue.configuration(in: settings, credentialsAreReady: credentialsReady)
    }
    var visibleTranslationIssue: TranslationIssue? { translationConfigurationIssue ?? translationIssue }

    /// A última gravação acabou de ser arquivada em Recentes. Some sozinho depois de alguns
    /// segundos — é aviso, não estado.
    ///
    /// Existe porque parar a gravação não confirmava nada: as caixas continuavam cheias, o botão
    /// voltava a "Gravar", e a única prova de que a tradução tinha sido guardada era uma linha nova
    /// numa lista mais abaixo, cujo título é o preview da TRADUÇÃO — texto em português quase igual
    /// ao que estava na caixa da direita. No gate do CHECKLIST-ONDA2 o humano olhou e concluiu que
    /// não tinha salvado; a entrada estava lá. O aviso (com a limpeza das caixas em
    /// `stopListening`) é o que fecha o ciclo na tela.
    ///
    /// Distingue arquivo completo de arquivo **sem o final**: quando o teto da espera estoura, o
    /// rabo da fala fica de fora da entrada, e dizer só "Salvo em Recentes" nesse caso seria a
    /// mesma perda silenciosa que o C3 nasceu para matar — um passo adiante.
    @Published private(set) var archiveNotice: TranslationArchiveNotice?

    let historyStore = TranslationHistoryStore()
    private var translationEntryID = UUID()
    private var translationEntryDate = Date()

    /// De onde veio o texto do último trecho transcrito: motor, modelo e se foi escolha do
    /// usuário. **Só em memória** — o `TranslationEntry` do histórico não ganha campo novo nesta
    /// tarefa (a proveniência persistida é a T6.3, e ela não lista a tradução). Existe para a UI
    /// da Onda 6 ter o que mostrar sem precisar reabrir este arquivo.
    ///
    /// Sob `strict` o `candidateRank` é sempre 0: a tradução não tem fallback (ver
    /// `transcriptionSelection(for:strict:)`).
    @Published private(set) var lastTranscriptionProvenance: TranscriptionProvenance?

    private let audioService = AudioCaptureService()
    /// O dono único dos motores (T2.3). Substitui o `TranscriptionService.shared` mutável: o
    /// modelo deixa de ser estado global trocado por `configure(modelName:)` e passa a viajar
    /// dentro do pedido, na seleção.
    private let coordinator = AppTranscriptionCoordinator.shared.coordinator
    private var cancellables = Set<AnyCancellable>()
    
    private var isProcessing = false
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartID: UUID?
    private var previousActiveApp: NSRunningApplication?
    private var audioBuffer: [Float] = []
    private var lastProcessedIndex = 0
    private var processingTimer: Task<Void, Never>?
    private var processingQueue: [Task<Void, Never>] = []
    private var isProcessingChunk = false
    /// O aquecimento em voo, para que o próximo cancele este — ver `warmUpTranscription()`.
    private var warmUpTask: Task<Void, Never>?
    /// O temporizador do aviso de arquivamento, para duas gravações seguidas não deixarem o aviso
    /// da primeira apagar o da segunda.
    private var archiveNoticeTask: Task<Void, Never>?

    /// As traduções em voo desta sessão. Sem esta lista o `stopListening` arquivava sem elas.
    private var pendingTranslations: [Task<Void, Never>] = []

    /// A gravação corrente, numerada.
    ///
    /// Sobe ao começar a gravar **e** ao terminar de arquivar. Todo trabalho em voo carrega o número
    /// da sessão em que nasceu e confere antes de escrever em `sourceText`/`translatedText`: o que
    /// chega depois do arquivamento — porque estourou o teto da espera, porque a rede demorou, ou
    /// porque foi abandonado — some em vez de repovoar caixas já limpas.
    ///
    /// É o cinto que torna o teto da espera seguro: com ele, "desistir de esperar" nunca vira texto
    /// órfão na tela.
    private var sessionEpoch = 0

    /// Teto da espera pelo trabalho pendente no `stopListening`.
    ///
    /// Generoso de propósito, e não ajustado à mediana medida (~0,15 s por trecho): o que se espera
    /// aqui não é só a inferência — é a vaga do coordenador (que pode estar com um lote de reunião),
    /// a preparação do modelo e, desde a correção do Farol, **o provedor de tradução**, que é rede.
    /// A escolha é entre esperar demais e arquivar sem o rabo da fala; 15 s cobre o pior caso
    /// plausível dos dois e ainda devolve a tela ao usuário num tempo que ele tolera.
    ///
    /// Quando estoura: arquiva o que existe, avisa no console de debug e fecha a sessão — o estado
    /// **sempre** volta para `.idle`, então lentidão do provedor nunca vira UI travada em
    /// "Processando". O preço assumido é o rabo da fala ficar de fora da entrada nesse caso; a
    /// alternativa (completar a entrada depois, quando o texto chegar) é mudança no contrato do
    /// histórico e está registrada em REVISOES como opção, não feita aqui.
    ///
    /// **O teto limita a TELA, não o motor.** Desistir de esperar não cancela nada: a inferência
    /// abandonada continua rodando e a vaga do coordenador segue ocupada até ela voltar. O que o
    /// teto garante é que o usuário recupera a interface — não que a máquina ficou livre.
    private static let archiveDrainTimeout: TimeInterval = 15
    
    private let settingsStore: SettingsStore
    // This screen follows the app settings; reading them must never overwrite a newer selection.
    @Published private(set) var settings: AppSettings
    
    init(settingsStore: SettingsStore? = nil) {
        print("🌐 TranslationViewModel init started")
        let store = settingsStore ?? SettingsStore()
        self.settingsStore = store
        self.settings = store.load()
        self.credentialsReady = store.credentialsAreReady
        
        AccessibilityPermissionService.shared.ensurePrompt()
        setupBindings()
        // setupHotKeyHandling() - Removido para evitar conflito
        
        print("🔌 Provider loaded: \(settings.translationProvider.displayName)")
        print("🔑 Chave do provedor: \(settings.apiKeyLogDescription)")
        print("🤖 Model loaded: \(settings.currentModelId)")
        
        // Observa mudanças de configurações
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SettingsChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSettings()
            }
        }
        
        // Aquece o modelo no boot, como o `ensureInitialized()` do serviço legado fazia: quando o
        // usuário apertar gravar, os pesos já estão na Neural Engine. Sem isto a carga cairia
        // dentro do primeiro trecho e o laço de 1,2 s descartaria os ciclos enquanto ela durasse —
        // os primeiros segundos de fala sumiriam da primeira tradução após abrir o app.
        warmUpTranscription()
        print("✅ TranslationViewModel init completed")
    }
    
    @MainActor
    func reloadSettings() {
        credentialsReady = settingsStore.credentialsAreReady
        let newSettings = settingsStore.load()
        // Access can recover without changing a single preference or key value.
        translationIssue = translationIssue?.afterSettingsReload(
            settingsChanged: newSettings != settings, credentialsAreReady: credentialsReady)
        guard newSettings != settings else { return }
        print("🔄 Reloading settings...")
        print("   - Provider: \(newSettings.translationProvider.displayName)")
        print("   - Chave do provedor: \(newSettings.apiKeyLogDescription)")
        print("   - Model: \(newSettings.currentModelId)")

        settings = newSettings

        addDebugLog("⚙️ Configurações recarregadas - \(newSettings.translationProvider.displayName)")
    }
    
    private func setupBindings() {
        audioService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        // O modelo escolhido nas Configurações não é mais aplicado por `configure(modelName:)`:
        // ele viaja dentro do pedido, na seleção (`transcriptionSelection(for:strict:)`), e é o
        // coordenador que troca os pesos quando o modelo do pedido muda. O que sobra aqui é o
        // outro efeito que o sink legado tinha — aquecer o modelo novo assim que o usuário o
        // escolhe, em vez de deixar a carga para o primeiro trecho da próxima gravação.
        $settings
            .map(\.modelSize)
            .removeDuplicates()
            // O boot já foi aquecido no `init`; aqui interessa só a TROCA.
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` publica em `willSet`: neste instante `self.settings` ainda tem o
                // modelo antigo. O hop garante que o aquecimento use o que o usuário acabou de
                // escolher — que é o que o `configure(modelName:)` legado recebia pronto no
                // parâmetro do sink.
                Task { @MainActor in self?.warmUpTranscription() }
            }
            .store(in: &cancellables)

        audioService.onAudioData = { [weak self] samples in
            guard let self else { return }
            Task { @MainActor in
                guard !samples.isEmpty else {
                    return
                }
                self.audioBuffer.append(contentsOf: samples)
                if self.audioBuffer.count % 16000 == 0 {
                    print("🎙️ Audio buffer: \(self.audioBuffer.count) samples (~\(self.audioBuffer.count / 16000)s)")
                }
            }
        }
    }
    
    /// Quanto áudio novo um ciclo exige para virar trecho.
    ///
    /// **Tem folga de propósito, e a folga é a correção.** O laço dorme 1,2 s e o limiar era
    /// exatamente 1,2 s de áudio (19200 amostras a 16 kHz) — ou seja, o ciclo só era servido se o
    /// microfone tivesse entregue tudo, sem um milissegundo de atraso. Como o `Task.sleep` garante
    /// *pelo menos* 1,2 s e as amostras chegam pela main actor, qualquer atraso derrubava o ciclo
    /// inteiro: `lastProcessedIndex` não andava e o trecho seguinte vinha com 2,4 s de áudio de uma
    /// vez. Medido no app real com a sonda de cadência: **2 de 21 trechos** (~10%) chegavam
    /// dobrados, e um bloco de 2,4 s é literalmente o "bloco grande" que o gate do CHECKLIST-ONDA2
    /// reprovou.
    ///
    /// 1,08 s (90% do ciclo) mantém o trecho na faixa que o Whisper precisa para ter contexto — o
    /// que quebra a transcrição é trecho curto de verdade, da ordem de 0,5 s — e absorve a jitter.
    /// O trecho **não** encolhe: quem chega no prazo continua entregando 1,2 s ou mais, porque o
    /// corte é sempre "todo o áudio ainda não processado".
    private static let minimumChunkSamples = 17_280

    @MainActor
    private func startRealtimeProcessing() {
        translationEntryID = UUID()
        translationEntryDate = Date()
        audioBuffer = []
        lastProcessedIndex = 0
        sourceText = ""
        translatedText = ""
        processingQueue = []
        pendingTranslations = []
        translationFailed = false
        translationIssue = nil
        isProcessingChunk = false
        // Estado que um trecho da sessão anterior pode ter deixado ligado ao ser abandonado: ele
        // não zera nada ao voltar tarde, então quem zera é o começo da sessão nova.
        isTyping = false
        archiveNoticeTask?.cancel()
        archiveNotice = nil
        sessionEpoch += 1

        print("🔄 Starting realtime processing...")

        let epoch = sessionEpoch
        processingTimer = Task { @MainActor in
            while true {
                // Processa a cada 1.2 segundos (sweet spot).
                //
                // **Sem `try?`.** Engolir o `CancellationError` daqui era um trabalho duplicado
                // sobre o MESMO áudio: o `stopRealtimeProcessing` cancela, mas o laço acordava,
                // ignorava a exceção e rodava a volta inteira mais uma vez — só que o rabo já
                // tinha sido montado a partir do `lastProcessedIndex` e a `processingQueue` já
                // tinha sido esvaziada. Com 1,08 s ou mais de áudio pendente, nasciam DOIS
                // trabalhos para o mesmo trecho, um deles fora de qualquer lista que o Parar
                // esperasse. Achado do Farol.
                do {
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                } catch {
                    return
                }

                let newSamples = audioBuffer.count - lastProcessedIndex

                // Chunk de 1.2-1.5s de áudio. Tamanho ideal para Whisper ter contexto suficiente.
                guard newSamples >= Self.minimumChunkSamples else {
                    continue
                }
                
                // Não espera chunk anterior terminar - processa em paralelo!
                guard !isProcessingChunk else {
                    print("⏸️ Previous chunk still processing, will catch up next cycle")
                    continue
                }
                
                let chunk = Array(audioBuffer[lastProcessedIndex...])
                lastProcessedIndex = audioBuffer.count
                
                print("🎤 Processing chunk: \(chunk.count) samples (~\(chunk.count/16000)s)")
                
                // Inicia processamento em paralelo
                isProcessingChunk = true
                let task = Task { @MainActor in
                    await processChunkForRealtimeTranslation(chunk, epoch: epoch)
                    // A flag é da sessão CORRENTE. Um trecho abandonado pelo teto do Parar
                    // limpando-a na gravação seguinte liberaria um segundo trecho concorrente —
                    // duas inferências ao mesmo tempo, que é a regressão de cadência que o
                    // `isProcessingChunk` existe para impedir. Farol e Quilha convergiram aqui.
                    if epoch == sessionEpoch {
                        isProcessingChunk = false
                    }
                }
                processingQueue.append(task)
            }
        }
    }

    /// Encerra o laço e devolve **tudo que ainda pode escrever no texto**, na ordem em que precisa
    /// ser esperado: o trecho periódico em voo primeiro, o rabo da fala depois.
    ///
    /// **Não cancela mais o trecho em voo.** Cancelar era perda de fala silenciosa: quando o laço
    /// serve um ciclo ele já avançou o `lastProcessedIndex`, então o áudio daquele trecho não entra
    /// no "resto do buffer" que vira o trecho final — e o WhisperKit confere cancelamento só
    /// **depois** da inferência, então o texto era produzido e jogado fora. O usuário perdia o
    /// pedaço de fala que estava sendo transcrito no instante em que ele apertou Parar, que é
    /// justamente o pedaço mais recente. Achado do Farol.
    ///
    /// O rabo espera o trecho em voo por dentro, e não em paralelo: sem isso os dois disputariam a
    /// vaga do coordenador e o texto poderia ser concatenado fora de ordem.
    @MainActor
    private func stopRealtimeProcessing() -> [Task<Void, Never>] {
        processingTimer?.cancel()
        processingTimer = nil

        let inFlight = processingQueue
        processingQueue = []
        var pending = inFlight

        // Processa último chunk se houver.
        //
        // **Idempotente:** o índice anda ao montar o rabo, então uma segunda chamada não monta um
        // segundo. Até aqui a única proteção contra rabo duplicado era o `disabled` do botão na
        // View — proteção de tela para uma invariante de modelo (Quilha). Isto também tira o
        // combustível da volta extra do laço, que passa a ver zero amostra nova.
        if !audioBuffer.isEmpty && lastProcessedIndex < audioBuffer.count {
            let remainingChunk = Array(audioBuffer[lastProcessedIndex...])
            lastProcessedIndex = audioBuffer.count
            if remainingChunk.count >= 4000 {
                let epoch = sessionEpoch
                pending.append(
                    Task { @MainActor in
                        for task in inFlight {
                            await task.value
                        }
                        await self.processChunkForRealtimeTranslation(remainingChunk, epoch: epoch)
                    }
                )
            }
        }
        return pending
    }

    /// - Parameter epoch: a sessão de gravação em que este trecho nasceu. Trabalho de uma sessão já
    ///   arquivada **não** escreve mais nas caixas — ver `sessionEpoch`.
    @MainActor
    private func processChunkForRealtimeTranslation(_ chunk: [Float], epoch: Int) async {
        // Antes de QUALQUER escrita de estado e antes do trabalho caro. Um trecho abandonado pelo
        // teto do Parar chega aqui depois de a gravação seguinte já ter começado: sem esta linha
        // ele pediria uma inferência nova e tomaria a vaga do coordenador da sessão 2 — atrasando
        // a fala que o usuário está falando agora por causa de uma que ele já parou. Achado do
        // Farol.
        guard epoch == sessionEpoch else { return }

        // Valida qualidade do áudio
        let rms = sqrt(chunk.map { $0 * $0 }.reduce(0, +) / Float(chunk.count))
        guard rms > 0.001 else {
            addDebugLog("⚠️ Audio too quiet (RMS: \(rms)), skipping")
            return
        }
        
        do {
            isTyping = true

            let outcome = try await coordinator.transcribe(
                TranscriptionRequest(
                    useCase: .translationChunk,
                    language: sourceLanguage.transcriptionLanguage,
                    audio: TranscriptionAudio(samples: chunk)
                ),
                selection: transcriptionSelection(),
                // A falha da tradução é silenciosa e sem fallback: ela não pode virar supressão
                // nos livros do coordenador e mudar o roteamento do ditado a partir da T2.4a.
                retryPolicy: .silentInteractive
            )
            // A sessão pode ter sido arquivada enquanto a inferência rodava. Daqui para baixo
            // **nada** é escrito: nem `isTyping`, nem a proveniência, nem o console de debug —
            // todos são estado da gravação CORRENTE, e a corrente já é outra. Quem zera o
            // `isTyping` desta sessão morta é o `startRealtimeProcessing` da próxima.
            guard epoch == sessionEpoch else {
                addDebugLog("🚪 Trecho de uma gravação já arquivada foi descartado")
                return
            }

            lastTranscriptionProvenance = outcome.provenance

            let newText = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !newText.isEmpty && newText != "..." else {
                addDebugLog("⚠️ Empty/invalid transcription, skipping")
                isTyping = false
                return
            }
            
            addDebugLog(
                TranscriptionLogRedaction.transcribedChunk(newText, provenance: outcome.provenance)
            )

            // Acrescenta o texto de uma vez; o StreamingText na UI faz a
            // revelação suave caractere a caractere com fade.
            if !sourceText.isEmpty {
                sourceText += " "
            }
            sourceText += newText
            isTyping = false

            // Traduz em paralelo (não bloqueia próximo chunk)
            let sourceLang = sourceLanguage
            let targetLang = targetLanguage
            // Read the active app selection at dispatch time. Each request owns its service,
            // so changing provider cannot mutate the transport of an in-flight translation.
            let requestSettings: AppSettings
            do {
                requestSettings = try await settingsStore.settingsForAIUse(resource: .translation)
            } catch {
                guard epoch == sessionEpoch, !Task.isCancelled else { return }
                translationFailed = true
                translationIssue = .credentialsUnavailable
                credentialsReady = false
                return // The original text already appended above remains available for export/retry.
            }
            guard epoch == sessionEpoch, !Task.isCancelled else { return }
            translationIssue = translationIssue?.afterSettingsReload(
                settingsChanged: requestSettings != settings, credentialsAreReady: true)
            settings = requestSettings
            credentialsReady = true
            let requestProvider = requestSettings.translationProvider
            // The source and destination identity survive a crash before the AI reply.
            guard saveCurrentTranslationToHistory() else {
                translationFailed = true; translationIssue = .requestFailed
                return
            }
            let service = TranslationService(settings: requestSettings)

            // **Rastreada**, e não solta: enquanto era um `Task.detached` sem dono, o `stopListening`
            // esperava o trecho e arquivava antes de a tradução dele chegar — a tradução aparecia
            // depois, sozinha, numa caixa que já tinha sido limpa. Era o mesmo órfão de antes, um
            // passo adiante (achado do Farol).
            let translation = Task.detached { [weak self] in
                guard let self = self else { return }

                do {
                    await MainActor.run {
                        self.addDebugLog(TranscriptionLogRedaction.translating(newText))
                    }

                    let startTime = Date()

                    let translation = try await service.translate(
                        text: newText,
                        from: sourceLang,
                        to: targetLang
                    )

                    let latency = Date().timeIntervalSince(startTime)

                    await MainActor.run {
                        // A guarda vem ANTES de tudo, e `lastTranslationLatency` está do lado de
                        // dentro de propósito: ela alimenta o "620ms" na barra de status, que é
                        // leitura da gravação corrente. Deixá-la fora faria a tradução de uma
                        // sessão encerrada reescrever o número de outra — pequeno, mas é mentira
                        // na tela (a Quilha pediu que isto ficasse explícito).
                        guard epoch == self.sessionEpoch else {
                            self.addDebugLog("🚪 Tradução de uma gravação já arquivada foi descartada")
                            return
                        }

                        self.lastTranslationLatency = latency
                        self.addDebugLog(
                            TranscriptionLogRedaction.translated(translation, latency: latency)
                        )

                        if !self.translatedText.isEmpty {
                            self.translatedText += " "
                        }
                        self.translatedText += translation
                        if !self.saveCurrentTranslationToHistory() {
                            self.translationFailed = true; self.translationIssue = .requestFailed
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard epoch == self.sessionEpoch else { return }
                        // Não é `error.localizedDescription`: o `translationFailed` do serviço
                        // carrega o corpo de resposta do provedor, e num erro de filtro de conteúdo
                        // esse corpo devolve o prompt — que leva o transcript inteiro. O vazamento
                        // que a re-review achou no serviço chega aqui pelo mesmo caminho.
                        self.addDebugLog(TranslationService.TranslationError.logMessage(for: error))
                        self.translationFailed = true
                        if case TranslationService.TranslationError.missingAPIKey = error {
                            self.translationIssue = .missingAPIKey(provider: requestProvider.displayName)
                        } else {
                            self.translationIssue = .requestFailed
                        }
                    }
                }
            }
            pendingTranslations.append(translation)

        } catch {
            // `TranscriptionCoordinatorError` é `LocalizedError` (no próprio coordenador), então
            // isto é o motivo técnico de verdade — motor, modelo, estágio e falha — e não o
            // "erro 2" que um enum sem descrição devolveria. Sem texto transcrito, por construção.
            guard epoch == sessionEpoch else { return }
            addDebugLog("❌ Falha na transcrição do trecho: \(error.localizedDescription)")
            isTyping = false
        }
    }
    
    /// A seleção de motor/modelo que a tradução manda ao coordenador.
    ///
    /// `strict: true` de propósito, por decisão do Maestro registrada em DECISOES: a tradução não
    /// tem fallback hoje — se o Whisper falha, ela falha e loga — e a regra 6 do PLANO cita a
    /// tradução nominalmente entre o que não muda até a Onda 6. Sem `strict`, uma falha do Whisper
    /// passaria a carregar o Parakeet (600 MB) no meio de uma tradução ao vivo, que é comportamento
    /// novo. Dar (ou não) fallback à tradução é decisão explícita da Onda 6.
    ///
    /// O modelo é o das Configurações, não `small` fixo: ver
    /// `AppSettings.effectiveTranscriptionChoice(for:)`.
    private func transcriptionSelection() -> TranscriptionUserSelection {
        settings.transcriptionSelection(for: .translationChunk, strict: true)
    }

    /// Deixa o modelo residente antes de o usuário falar. Cortesia de cadência: se falhar, o
    /// primeiro trecho falha como falharia de qualquer jeito — o aquecimento não decide nada
    /// (ver `TranscriptionCoordinator.warmUp`).
    ///
    /// **Supersede o aquecimento anterior.** Sem cancelar o de antes, arrastar o seletor de modelo
    /// por quatro tamanhos viraria quatro cargas completas em série (com download, se faltar o
    /// modelo), das quais só a última interessa — e, como o aquecimento toma a vaga do coordenador
    /// na classe do caso de uso, o primeiro trecho de verdade entraria atrás de todas elas. Seria
    /// regressão de cadência exatamente no cenário que o aquecimento existe para proteger; o
    /// legado colapsava isso por acidente, com o `guard !isInitialized && !isLoading` do
    /// `ensureInitialized()`. O cancelamento é limpo por construção: `warmUp` confere cancelamento
    /// na entrada e depois da vaga, e a espera pela vaga é cancelável — um aquecimento superado
    /// sai da fila sem tocar em motor nenhum.
    private func warmUpTranscription() {
        let selection = transcriptionSelection()
        let language = sourceLanguage.transcriptionLanguage
        warmUpTask?.cancel()
        warmUpTask = Task { [coordinator] in
            await coordinator.warmUp(
                for: .translationChunk,
                language: language,
                selection: selection
            )
        }
    }

    private func addDebugLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLogs.append("[\(timestamp)] \(message)")
        if debugLogs.count > 50 {
            debugLogs.removeFirst()
        }
        print(message)
    }
    
    @MainActor
    func startListening() {
        guard recordingStartID == nil, !isProcessing else { return }
        switch state {
        case .idle, .error: break
        case .listening, .processing: return
        }
        rememberFrontmostApplication()
        let token = UUID()
        recordingStartID = token
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if recordingStartID == token { recordingStartID = nil; recordingStartTask = nil }
            }
            guard await VoizAccessStore.shared.prepareNewOperation(kind: .recording, workID: token) else {
                if !Task.isCancelled, recordingStartID == token {
                    state = .error(VoizAccessStore.shared.lastError ?? VoizAccessMessages.libraryUnavailable)
                }
                return
            }
            guard !Task.isCancelled, recordingStartID == token else { return }
            do {
                settings = try await settingsStore.settingsForAIUse(resource: .translation)
                credentialsReady = true
                translationIssue = nil
            } catch {
                guard !Task.isCancelled, recordingStartID == token else { return }
                credentialsReady = false
                translationIssue = .credentialsUnavailable
                return
            }
            guard !Task.isCancelled, recordingStartID == token else { return }
            guard translationConfigurationIssue == nil else {
                translationIssue = translationConfigurationIssue
                return
            }
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let granted: Bool
            switch status {
            case .authorized: granted = true
            case .notDetermined:
                granted = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
                }
            default: granted = false
            }
            guard !Task.isCancelled, recordingStartID == token else { return }
            guard granted else { handleDeniedPermission(); return }
            await beginRecordingSession(startID: token)
        }
    }

    private func cancelRecordingStart() {
        recordingStartTask?.cancel()
        recordingStartTask = nil
        recordingStartID = nil
    }

    // Atalhos de ditado são geridos só pelo TranscriptionViewModel (DictationHotKeyService).

    @MainActor
    func stopListening() {
        cancelRecordingStart()
        // Só `.listening`. Aceitar `.processing` deixava uma segunda chamada entrar no meio do
        // arquivamento da primeira e abrir um segundo Parar — hoje o que impede isso é o
        // `disabled` do botão na View, ou seja, proteção de tela para uma invariante de modelo
        // (Quilha). Quem já está parando não para de novo.
        guard state == .listening else { return }
        state = .processing
        // RecordingHUD.shared.update(state: .processing)  // Não mostra na tradução
        audioService.stopRecording()
        let pendingChunks = stopRealtimeProcessing()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Tudo que ainda pode virar texto tem que entrar ANTES de arquivar: o trecho em voo, o
            // rabo da fala e as traduções de todos eles. Sem esta espera o arquivamento era uma
            // corrida contra o `sleep` acima — o que perdesse ficava de fora da entrada salva e,
            // com as caixas limpas, ainda voltava a escrever nelas depois, como fragmento órfão.
            let complete = await drainPendingWork(chunks: pendingChunks)
            if !complete {
                addDebugLog("⏳ Parte do último trecho não voltou a tempo e ficou de fora do arquivo")
            }
            if !translatedText.isEmpty {
                insertTextAtCursor(translatedText)
            }
            // Limpa as caixas **só** quando a tradução de fato foi arquivada: se não havia nada
            // para guardar (silêncio, falha de transcrição), apagar a tela seria destruir a única
            // cópia do que o usuário conseguiu.
            if saveCurrentTranslationToHistory() {
                let notice = TranslationArchiveNotice.result(drainCompleted: complete, translationFailed: translationFailed)
                if notice.shouldClearWorkspace { clearTranslation() }
                announceArchive(notice)
            } else if !sourceText.isEmpty || !translatedText.isEmpty {
                // Havia o que guardar e o disco recusou. Não limpa e não anuncia: o que está na
                // tela é a única cópia, e mentir aqui seria a perda que o C3 nasceu para matar.
                addDebugLog("⚠️ Não consegui arquivar em Recentes — o texto continua nas caixas")
            }
            // O `isTyping` é da sessão que acabou. Sem esta linha ele fica `true` até a gravação
            // SEGUINTE zerá-lo, e no caminho do teto pode não haver gravação seguinte (Quilha).
            isTyping = false
            // Fecha a sessão: o que estourou o teto e chegar depois não escreve mais na tela.
            sessionEpoch += 1
            pendingTranslations = []
            state = .idle
            // RecordingHUD.shared.hide()  // Não usado na tradução
        }
    }

    /// Espera o trabalho que ainda pode virar texto, **com teto**.
    ///
    /// Ordem, e ela importa: primeiro os trechos (o em voo e o rabo), porque é a transcrição deles
    /// que cria as traduções; só depois as traduções, lidas **de novo** ao final dos trechos, para a
    /// tradução do rabo — que nem existia quando a espera começou — entrar na conta.
    ///
    /// O teto não sai de graça: `await task.value` de um `Task<Void, Never>` não é cancelável, então
    /// não dá para "desistir" de dentro de um grupo estruturado — o grupo esperaria o filho travado
    /// assim mesmo. Por isso a espera e o relógio conversam por um ator, o primeiro a chegar decide,
    /// e o trabalho que perdeu é **abandonado**, não cancelado. Abandonar é seguro porque o
    /// `sessionEpoch` sobe logo depois do arquivamento: quem chegar atrasado não escreve mais nada.
    /// É o mesmo protocolo de posse do `PreparationHandoff` do coordenador, e pelo mesmo motivo.
    ///
    /// - Returns: `false` se o teto estourou antes de tudo terminar.
    @MainActor
    private func drainPendingWork(chunks: [Task<Void, Never>]) async -> Bool {
        guard !chunks.isEmpty || !pendingTranslations.isEmpty else { return true }

        let gate = PendingWorkGate()
        let work = Task { [weak self] in
            for task in chunks {
                await task.value
            }
            let translations = await MainActor.run { self?.pendingTranslations ?? [] }
            for task in translations {
                await task.value
            }
            await gate.settle(true)
        }
        let clock = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.archiveDrainTimeout * 1_000_000_000)
            )
            await gate.settle(false)
        }

        let completed = await gate.wait()
        work.cancel()
        clock.cancel()
        return completed
    }

    /// - Returns: `true` só quando a entrada **chegou ao disco**. É o que decide, no
    ///   `stopListening`, se as caixas podem ser limpas e se o aviso aparece.
    ///
    /// Devolvia `true` incondicionalmente, e isso valia mais que um detalhe: o store passou a poder
    /// recusar a gravação (blob ilegível, falha de codificação), e com o `true` fixo o
    /// `stopListening` limpava as caixas e anunciava "Salvo em Recentes" tendo perdido a única
    /// cópia da tradução. O fail-safe que existia para proteger dado virava o jeito de perdê-lo.
    /// Achado do Farol; quando isto é `false`, **as caixas preservadas são a cópia do usuário**.
    @MainActor
    @discardableResult
    private func saveCurrentTranslationToHistory() -> Bool {
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty || !translated.isEmpty else { return false }

        return historyStore.addEntry(
            TranslationEntry(
                id: translationEntryID,
                sourceText: source,
                translatedText: translated,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                timestamp: translationEntryDate
            )
        )
    }

    /// Acende o aviso de "arquivado" e o apaga sozinho — ver `archiveNotice`.
    @MainActor
    private func announceArchive(_ notice: TranslationArchiveNotice) {
        addDebugLog("💾 Tradução arquivada em Recentes")
        archiveNotice = notice
        archiveNoticeTask?.cancel()
        archiveNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.archiveNotice = nil
        }
    }
    
    @MainActor
    private func beginRecordingSession(startID: UUID) async {
        guard await VoizAccessStore.shared.authorizeNewOperation(kind: .recording, workID: startID) else {
            guard !Task.isCancelled, recordingStartID == startID else { return }
            state = .error(VoizAccessStore.shared.lastError ?? VoizAccessMessages.libraryUnavailable)
            return
        }
        guard !Task.isCancelled, recordingStartID == startID, !isProcessing else { return }
        switch state {
        case .idle, .error: break
        case .listening, .processing: return
        }
        do {
            try audioService.startRecording()
            state = .listening
            isProcessing = false
            startRealtimeProcessing()
            // NÃO mostra HUD na tab de tradução
            // RecordingHUD.shared.update(state: .listening)
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
            // RecordingHUD.shared.hide()
        }
    }
    
    @MainActor
    private func handleDeniedPermission() {
        state = .error("Microphone permission denied. Please enable in System Settings > Privacy & Security > Microphone")
        // RecordingHUD.shared.hide()  // Não usado na tradução
    }
    

    
    @MainActor
    func toggleRecording() {
        if recordingStartID != nil { cancelRecordingStart(); return }
        switch state {
        case .idle:
            startListening()
        case .listening:
            stopListening()
        case .processing:
            print("⚠️ Still processing translation, ignoring toggle request")
        case .error:
            startListening()
        }
    }
    
    private func insertTextAtCursor(_ text: String) {
        addDebugLog("🔐 Verificando permissões de acessibilidade...")
        
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        addDebugLog(TranscriptionLogRedaction.copiedToPasteboard(text))
        
        guard AccessibilityPermissionService.shared.isTrusted else {
            addDebugLog("❌ Sem permissão de acessibilidade")
            state = .error("Texto copiado! Para colar automaticamente, ative a permissão de Acessibilidade nas Configurações do app.")
            return
        }
        
        addDebugLog("✅ Permissão de acessibilidade concedida")
        let targetAppWasRestored = restorePreviousApplicationIfNeeded()
        addDebugLog("🔄 App anterior restaurado: \(targetAppWasRestored)")
        
        let delay: TimeInterval = targetAppWasRestored ? 0.6 : 0.4
        addDebugLog("⏰ Aguardando \(String(format: "%.1f", delay))s antes de colar...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Tenta método 1: Inserir texto diretamente via Accessibility API
            if self?.insertTextViaAccessibility(text) == true {
                self?.addDebugLog("✅ Texto inserido via Accessibility API!")
                if let previous = previousContents {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        pasteboard.clearContents()
                        pasteboard.setString(previous, forType: .string)
                        self?.addDebugLog("♻️ Clipboard restaurado")
                    }
                }
                return
            }
            
            // Método 2: CGEvent com configurações otimizadas
            self?.addDebugLog("⌨️ Tentando Cmd+V via CGEvent...")
            if self?.simulatePasteWithCGEvent() == true {
                self?.addDebugLog("✅ Cmd+V executado via CGEvent!")
            } else {
                self?.addDebugLog("❌ Falha ao simular Cmd+V - use Cmd+V manualmente")
            }
            
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                    self?.addDebugLog("♻️ Clipboard restaurado")
                }
            }
        }
    }
    
    private func insertTextViaAccessibility(_ text: String) -> Bool {
        addDebugLog("🎯 Tentando inserir via Accessibility API...")
        
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        guard result == .success, let element = focusedElement else {
            addDebugLog("⚠️ Nenhum elemento focado encontrado")
            return false
        }
        
        let focusedUIElement = element as! AXUIElement
        
        // Tenta definir o valor diretamente
        let setValue = AXUIElementSetAttributeValue(focusedUIElement, kAXValueAttribute as CFString, text as CFTypeRef)
        if setValue == .success {
            return true
        }
        
        // Se falhar, tenta obter o valor atual e concatenar
        var currentValue: CFTypeRef?
        let getValue = AXUIElementCopyAttributeValue(focusedUIElement, kAXValueAttribute as CFString, &currentValue)
        
        if getValue == .success, let current = currentValue as? String {
            let newValue = current + text
            let setNewValue = AXUIElementSetAttributeValue(focusedUIElement, kAXValueAttribute as CFString, newValue as CFTypeRef)
            if setNewValue == .success {
                return true
            }
        }
        
        addDebugLog("⚠️ Accessibility API não funcionou")
        return false
    }
    
    private func simulatePasteWithCGEvent() -> Bool {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            addDebugLog("❌ Falha ao criar event source")
            return false
        }
        
        let cmdKey = CGKeyCode(0x37) // Command
        let vKey = CGKeyCode(0x09)    // V
        
        // Command Down
        guard let cmdDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: cmdKey, keyDown: true) else {
            return false
        }
        cmdDownEvent.flags = .maskCommand
        cmdDownEvent.post(tap: .cghidEventTap)
        
        Thread.sleep(forTimeInterval: 0.05)
        
        // V Down
        guard let vDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: true) else {
            return false
        }
        vDownEvent.flags = .maskCommand
        vDownEvent.post(tap: .cghidEventTap)
        
        Thread.sleep(forTimeInterval: 0.05)
        
        // V Up
        guard let vUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: false) else {
            return false
        }
        vUpEvent.post(tap: .cghidEventTap)
        
        Thread.sleep(forTimeInterval: 0.05)
        
        // Command Up
        guard let cmdUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: cmdKey, keyDown: false) else {
            return false
        }
        cmdUpEvent.post(tap: .cghidEventTap)
        
        return true
    }
    
    private func rememberFrontmostApplication() {
        previousActiveApp = NSWorkspace.shared.frontmostApplication
    }
    
    @discardableResult
    private func restorePreviousApplicationIfNeeded() -> Bool {
        guard
            let app = previousActiveApp,
            app != NSRunningApplication.current
        else {
            previousActiveApp = nil
            return false
        }
        
        let options: NSApplication.ActivationOptions
        if #available(macOS 14, *) {
            options = [.activateAllWindows]
        } else {
            options = [.activateAllWindows, .activateIgnoringOtherApps]
        }
        let activated = app.activate(options: options)
        previousActiveApp = nil
        return activated
    }
    
    @MainActor
    func clearTranslation() {
        sourceText = ""
        translatedText = ""
    }
    
    @MainActor
    func swapLanguages() {
        let temp = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = temp
    }
}

/// Quem chegar primeiro decide: o trabalho que terminou, ou o relógio que estourou.
///
/// Ator, e não uma continuation solta, porque os dois lados correm de verdade — e só o primeiro
/// pode valer. Mesmo princípio do `PreparationHandoff` do `TranscriptionCoordinator`.
private actor PendingWorkGate {
    private var settled: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func settle(_ completed: Bool) {
        guard settled == nil else { return }
        settled = completed
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: completed)
        }
    }

    func wait() async -> Bool {
        if let settled { return settled }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
