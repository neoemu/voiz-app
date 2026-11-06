import SwiftUI
import Combine
import AVFoundation
import AppKit

@MainActor
class TranscriptionViewModel: ObservableObject {
    @Published var transcriptionText: String = ""
    @Published var state: TranscriptionState = .idle
    @Published var settings: AppSettings {
        didSet {
            if !applyingExternalSettings { settingsStore.saveWithSync(settings) }
        }
    }
    @Published var segments: [TranscriptionSegment] = []
    @Published var audioLevel: Float = 0.0
    @Published var debugLogs: [String] = []
    /// Estado do download/carga do modelo do ditado, espelhado do coordenador para a UI.
    ///
    /// Mesmos cinco estágios de antes (a faixa de status das Configurações não mudou); o que
    /// mudou é a fonte: o `TranscriptionRuntimeStore` dos motores do coordenador no lugar do
    /// `TranscriptionService.shared`, que o ditado não usa mais.
    @Published var modelLoadState: DictationTranscription.ModelStatus = .idle

    let historyStore = TranscriptionHistoryStore()

    private let audioService = AudioCaptureService(retention: .entireRecording)
    private var applyingExternalSettings = false
    private let settingsStore: SettingsStore
    private let credentialQueue = DispatchQueue(label: "com.voiz.settings.credentials", qos: .userInitiated)
    @Published private var credentialEdits = SettingsCredentialEditBuffer()
    @Published private var credentialFailures: Set<String> = []
    @Published private var credentialAccessFailed = false
    @Published private var credentialWrites = 0
    private var credentialAccessRevision = UUID()
    var isSavingCredentials: Bool { credentialWrites > 0 }
    var hasCredentialDrafts: Bool { !credentialEdits.values.isEmpty }
    var credentialSaveTitle: String { credentialText("Salvar chaves", "Save keys") }
    var credentialDraftMessage: String {
        credentialText("Alterações nas chaves aguardam confirmação.", "Key changes are waiting for confirmation.")
    }
    var hasCredentialError: Bool { credentialAccessFailed || !credentialFailures.isEmpty }
    var credentialErrorMessage: String {
        credentialText("Não foi possível salvar ou acessar as chaves de API no Keychain. Suas alterações ainda não foram confirmadas. Tente novamente.",
                       "Could not save or access API keys in Keychain. Your changes have not been confirmed. Try again.")
    }
    var credentialRetryTitle: String { credentialText("Tentar novamente", "Try again") }
    var credentialSavingTitle: String { credentialText("Acessando chaves…", "Accessing keys…") }

    private func credentialText(_ portuguese: String, _ english: String) -> String {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("pt") ? portuguese : english
    }

    private func credentialName(_ field: SettingsCredentialField) -> String {
        switch field {
        case .openAIKey: "openAIKey"
        case .anthropicKey: "anthropicKey"
        case .xaiKey: "xaiKey"
        case .geminiKey: "geminiKey"
        case .customKey: "customKey"
        }
    }

    private func credentialPath(_ field: SettingsCredentialField) -> WritableKeyPath<AppSettings, String> {
        switch field {
        case .openAIKey: \.openAIKey
        case .anthropicKey: \.anthropicKey
        case .xaiKey: \.xaiKey
        case .geminiKey: \.geminiKey
        case .customKey: \.customKey
        }
    }

    func credentialBinding(_ field: SettingsCredentialField) -> Binding<String> {
        Binding(get: { self.credentialEdits.values[self.credentialName(field)] ?? self.settings[keyPath: self.credentialPath(field)] },
                set: { self.stageCredential(field, value: $0) })
    }

    private func stageCredential(_ field: SettingsCredentialField, value: String) {
        credentialEdits.stage(field, value: value)
    }

    func saveCredentialEdits() {
        guard !isSavingCredentials else { return }
        credentialAccessRevision = UUID()
        for edit in credentialEdits.pendingEdits { persistCredential(edit) }
    }

    /// Only explicitly confirmed drafts may mutate the vault.
    private func persistCredential(_ edit: SettingsCredentialEditBuffer.Edit) {
        let field = edit.field
        let name = credentialName(field)
        let value = edit.value
        credentialWrites += 1
        let store = settingsStore
        let activity = VoizWorkTracker.shared.beginActivity()
        credentialQueue.async { [weak self] in
            let succeeded: Bool
            do {
                try store.setCredential(field, value: value)
                succeeded = true
            } catch { succeeded = false } // Never display a raw error that could contain a secret.
            Task { @MainActor [weak self] in
                defer { activity.finish() }
                guard let self else { return }
                self.credentialWrites -= 1
                if succeeded {
                    self.credentialEdits.acknowledge(edit)
                    self.credentialFailures.remove(name)
                    self.credentialAccessFailed = false
                    self.applyCredentialSnapshot()
                    NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
                } else {
                    self.credentialFailures.insert(name)
                }
            }
        }
    }

    func retryCredentialAccess() {
        guard !isSavingCredentials else { return }
        if !credentialEdits.values.isEmpty {
            saveCredentialEdits()
            return
        }
        credentialWrites += 1
        let store = settingsStore
        let accessRevision = credentialAccessRevision
        let activity = VoizWorkTracker.shared.beginActivity()
        credentialQueue.async { [weak self] in
            _ = store.reloadCredentials()
            let failed = store.credentialError != nil
            Task { @MainActor [weak self] in
                defer { activity.finish() }
                guard let self else { return }
                self.credentialWrites -= 1
                if self.credentialAccessRevision == accessRevision { self.credentialAccessFailed = failed }
                // Keep preferences and any edit made while the worker was loading.
                // A failed migration can still return a verified last-known vault snapshot.
                self.applyCredentialSnapshot()
                NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
            }
        }
    }

    private func applyCredentialSnapshot() {
        // load() reads preferences and the latest in-memory credential cache, never Security.
        // Read it here rather than capturing a worker snapshot: callbacks delivered out of
        // order cannot restore older credentials. Drafts stay separate in credentialEdits,
        // so cold-start recovery updates the live keys even while the user is typing.
        let confirmed = settingsStore.load()
        var updated = settings
        let fields: [SettingsCredentialField] = [.openAIKey, .anthropicKey, .xaiKey, .geminiKey, .customKey]
        for field in fields {
            updated[keyPath: credentialPath(field)] = confirmed[keyPath: credentialPath(field)]
        }
        settings = updated
    }
    private var cancellables = Set<AnyCancellable>()

    /// O dono único do coordenador no processo (T2.4a/T2.4b). O ditado **não** monta motor nenhum:
    /// dois donos seriam dois WhisperKit e dois `AsrManager`, e a regra de "um modelo pesado
    /// residente" valeria só sobre metade do app.
    private var coordinator: TranscriptionCoordinator { AppTranscriptionCoordinator.shared.coordinator }
    private let runtimeStore = AppTranscriptionCoordinator.shared.runtimeStore

    /// O último contexto de roteamento aplicado — evita refazer plano e pré-aquecimento quando o
    /// usuário mexe em qualquer outra configuração.
    private var dictationRouting: DictationRouting?
    /// O rank 0 do plano atual — **motor e modelo**, os dois. O modelo não é detalhe: o mesmo motor
    /// serve mais de um consumidor e troca de pesos, então a faixa de status precisa saber de qual
    /// modelo ela está falando. `nil` = plano vazio ou ainda não consultado.
    ///
    /// Quem o preenche é o `plan(for:language:selection:)` do **coordenador**, e não um roteador
    /// local: a decisão de qual motor roda o ditado tem uma fonte de verdade só. Uma cópia do
    /// roteador aqui casaria hoje e divergiria em silêncio quando a Onda 6 montar o coordenador com
    /// uma política versionada — a faixa passaria a descrever o motor errado sem nada quebrar.
    private var dictationCandidate: TranscriptionRoutingCandidate?
    /// O aquecimento em voo. Guardado para ser **cancelado** quando outro o supera: arrastar o
    /// seletor de modelo por quatro tamanhos criava quatro `Task`s, e as quatro cargas rodavam em
    /// série na frente do primeiro ditado. O aquecimento superado sai da fila do coordenador sem
    /// tocar em motor nenhum (`warmUp` confere cancelamento na entrada e depois da vaga, e a espera
    /// pela vaga é cancelável).
    ///
    /// O que isto **não** cobre: uma carga que já começou dentro do motor não é interrompível por
    /// quem espera — o single-flight dos motores só desiste de *esperar*. O que some é a fila.
    private var warmUpTask: Task<Void, Never>?
    /// Aviso de fallback pendente. Fica agendado para depois do toast de colagem, senão nasce e
    /// morre engolido por ele — e é cancelado quando um novo ditado começa.
    private var fallbackToastTask: Task<Void, Never>?

    /// O que decide o plano do ditado. Só isto refaz plano e pré-aquecimento.
    private struct DictationRouting: Equatable {
        var selection: TranscriptionUserSelection
        var language: TranscriptionLanguage?
        var requiresVocabulary: Bool
    }

    @Published private(set) var processingEntryID: UUID?
    private var recordingSettings: AppSettings?
    // If disk writing fails, keep the captured samples available for an in-session retry.
    private var unsavedAudio: [UUID: [Float]] = [:]
    private var isProcessing = false
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartID: UUID?
    private var previousActiveApp: NSRunningApplication?
    private var lastExternalActiveApp: NSRunningApplication?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var transcriptionStartTime: Date?

    init(settingsStore: SettingsStore? = nil) {
        let resolvedStore = settingsStore ?? SettingsStore()
        self.settingsStore = resolvedStore
        self._settings = Published(initialValue: resolvedStore.load())
        self.credentialAccessFailed = resolvedStore.credentialError != nil
        print("📱 TranscriptionViewModel init started")
        // Development starts with global shortcuts off; request access only after opting in.
        if !AppEnvironment.current.isDevelopment {
            AccessibilityPermissionService.shared.ensurePrompt()
        }
        setupBindings()
        setupHotKeyHandling()
        observeApplicationActivation()
        retryCredentialAccess()
        print("✅ TranscriptionViewModel init completed")
    }
    
    /// HUD do ditado: com o notch ativo, o status mora nele; senão, vale o painel
    /// flutuante clássico (gated pelo mesmo toggle de sempre).
    private func showDictationHUD(_ state: RecordingHUDState) {
        if settings.notchOverlayEnabled {
            NotchOverlay.shared.isEnabled = true
            NotchOverlay.shared.showDictation(state == .listening ? .listening : .processing)
        } else if settings.showRecordingHUD {
            RecordingHUD.shared.update(state: state)
        }
    }

    private func hideDictationHUD() {
        RecordingHUD.shared.hide()
        NotchOverlay.shared.hideDictation()
    }

    private func setupBindings() {
        NotificationCenter.default.publisher(for: Notification.Name("SettingsChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updated = self.settingsStore.load()
                guard updated != self.settings else { return }
                self.applyingExternalSettings = true
                self.settings = updated
                self.applyingExternalSettings = false
            }.store(in: &cancellables)
        historyStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        historyStore.$entries
            .sink { [weak self] entries in
                guard let self else { return }
                self.unsavedAudio = self.unsavedAudio.filter { self.historyStore.entry(id: $0.key) != nil }
            }
            .store(in: &cancellables)
        audioService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        // Barras de nível do notch durante o ditado (mesma cadência do indicador de reunião).
        audioService.$audioLevel
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] level in
                guard let self, self.settings.notchOverlayEnabled, self.state == .listening else { return }
                NotchOverlay.shared.updateDictationLevel(level)
            }
            .store(in: &cancellables)

        // Espelha o estado de download/carga do modelo para a UI (gauge nas Settings). A fonte
        // agora é o espelho dos motores do coordenador — o ditado não carrega mais nada pelo
        // `TranscriptionService.shared`, então o `loadState` dele não descreveria este ditado.
        runtimeStore.$states
            .sink { [weak self] states in
                self?.refreshModelStatus(states)
            }
            .store(in: &cancellables)

        audioService.onRecordingFinished = { [weak self] samples in
            guard let self else { return }
            Task { @MainActor in
                guard !samples.isEmpty else {
                    self.isProcessing = false
                    if self.state == .processing {
                        self.state = .idle
                    }
                    self.hideDictationHUD()
                    return
                }
                await self.processAudio(samples, resumeListening: false)
            }
        }
        
        $settings
            .removeDuplicates()
            .sink { newSettings in
                NotchOverlay.shared.isEnabled = newSettings.notchOverlayEnabled
            }
            .store(in: &cancellables)
        
        // O motor de atalhos precisa saber se há gravação de fato rolando: ele se reconcilia com isso
        // quando uma sessão termina por fora (HUD, menu, erro) — senão o estado interno dele trava e
        // os atalhos param de responder.
        $state
            .map { $0 == .listening }
            .removeDuplicates()
            .sink { active in
                DictationHotKeyService.shared.updateSessionActive(active)
            }
            .store(in: &cancellables)

        // Reconfigura o motor de ditado (Fn push-to-talk + hands-free) quando os atalhos mudam.
        $settings
            .map { ($0.pushToTalkShortcut, $0.handsFreeShortcut, $0.dictationHotkeysEnabled) }
            .removeDuplicates { $0 == $1 }
            .sink { pushToTalk, handsFree, enabled in
                if enabled && AppEnvironment.current.isDevelopment {
                    AccessibilityPermissionService.shared.ensurePrompt()
                }
                DictationHotKeyService.shared.configure(
                    pushToTalk: pushToTalk,
                    handsFree: handsFree,
                    enabled: enabled
                )
            }
            .store(in: &cancellables)

        // Aplica a escolha de motor/modelo das Configurações (e pré-aquece ao trocar).
        //
        // Substitui os dois sinks legados — `configure(modelName:)` + `ensureInitialized()` no
        // Whisper compartilhado e o pré-carregamento do Parakeet —, que eram o mesmo pré-aquecimento
        // feito duas vezes, um por motor. O primeiro valor de `$settings` chega na assinatura, então
        // o pré-aquecimento de boot continua acontecendo no init, como antes.
        $settings
            .removeDuplicates()
            .sink { [weak self] newSettings in
                self?.applyDictationRouting(for: newSettings)
            }
            .store(in: &cancellables)
    }

    /// Refaz o plano do ditado e pré-aquece o motor do rank 0.
    ///
    /// Só reage ao que de fato muda o plano (seleção do usuário × idioma falado): mexer no HUD, nas
    /// chaves de API ou no atalho não pode disparar carga de modelo.
    ///
    /// Plano e aquecimento vivem na **mesma** `Task`, e ela é cancelada quando outro roteamento a
    /// supera: assim uma sequência rápida de trocas não deixa nem cargas antigas na fila do
    /// coordenador nem uma faixa de status descrevendo um plano que já não vale.
    private func applyDictationRouting(for newSettings: AppSettings) {
        let routing = DictationRouting(
            selection: newSettings.transcriptionSelection(for: .dictation),
            language: newSettings.selectedLanguage.transcriptionLanguage,
            requiresVocabulary: !TranscriptionContext.terms(from: newSettings.dictationVocabulary).isEmpty
        )
        guard routing != dictationRouting else { return }
        dictationRouting = routing

        // O candidato de antes é de outro plano: até o coordenador responder qual é o novo, a faixa
        // não tem o que dizer. Deixá-lo no ar mostraria "Modelo pronto" do modelo anterior.
        dictationCandidate = nil
        modelLoadState = .idle

        warmUpTask?.cancel()
        let coordinator = self.coordinator
        warmUpTask = Task { [weak self] in
            let plan = await coordinator.plan(
                for: .dictation,
                language: routing.language,
                selection: routing.selection,
                requiresVocabulary: routing.requiresVocabulary
            )
            guard !Task.isCancelled else { return }
            self?.adoptDictationCandidate(plan.primary)

            // Pré-aquecimento: sem ele a primeira frase pós-boot pagaria download + carga dentro do
            // `transcribe`, que é a regressão de cadência que o `ensureInitialized()` legado evitava.
            await coordinator.warmUp(
                for: .dictation,
                language: routing.language,
                selection: routing.selection,
                requiresVocabulary: routing.requiresVocabulary
            )
        }
    }

    private func adoptDictationCandidate(_ candidate: TranscriptionRoutingCandidate?) {
        dictationCandidate = candidate
        refreshModelStatus()
    }

    /// Traduz o que o coordenador observou no motor do ditado para a faixa de status das
    /// Configurações.
    ///
    /// Filtra por motor **e** modelo: o coordenador é compartilhado e troca de pesos, então um
    /// `.ready` do motor certo pode ser de um modelo que não é o do ditado.
    private func refreshModelStatus(
        _ states: [TranscriptionEngineID: TranscriptionRuntimeState]? = nil
    ) {
        guard let candidate = dictationCandidate else {
            modelLoadState = .idle
            return
        }
        let stage = (states ?? runtimeStore.states)[candidate.engine]?.stage ?? .idle
        modelLoadState = DictationTranscription.modelStatus(
            for: stage,
            expecting: candidate.model,
            describingFailure: Self.engineFailureMessage(_:)
        )
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

    private func setupHotKeyHandling() {
        let service = DictationHotKeyService.shared
        // Push-to-talk: segura pra falar, solta pra parar e colar.
        service.onPushToTalkStart = { [weak self] in
            DispatchQueue.main.async { self?.startListening() }
        }
        service.onPushToTalkStop = { [weak self] in
            DispatchQueue.main.async { self?.stopListening() }
        }
        // Hands-free: toca pra alternar gravar/parar.
        service.onHandsFreeToggle = { [weak self] in
            DispatchQueue.main.async { self?.toggleRecording() }
        }

        service.configure(
            pushToTalk: settings.pushToTalkShortcut,
            handsFree: settings.handsFreeShortcut,
            enabled: settings.dictationHotkeysEnabled
        )
    }
    
    private func observeApplicationActivation() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app != NSRunningApplication.current,
                !app.isTerminated
            else { return }
            
            Task { @MainActor [weak self] in
                self?.lastExternalActiveApp = app
            }
        }
    }
    
    @MainActor
    func stopListening() {
        cancelRecordingStart()
        guard state == .listening || state == .processing else { return }
        if state == .listening {
            state = .processing
        }
        showDictationHUD(.processing)
        audioService.stopRecording()
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
            recordingSettings = settings
            try audioService.startRecording()
            // Aviso de fallback do ditado anterior não pode aparecer em cima deste.
            fallbackToastTask?.cancel()
            state = .listening
            isProcessing = false
            transcriptionText = ""
            segments.removeAll()
            transcriptionStartTime = Date()
            addDebugLog("🎙️ Gravação iniciada - idioma: \(settings.selectedLanguage.displayName)")
            // Mostra HUD apenas na tab de Transcrição (não na Tradução)
            showDictationHUD(.listening)
        } catch {
            let errorMsg = "Failed to start recording: \(error.localizedDescription)"
            addDebugLog("❌ \(errorMsg)")
            state = .error(errorMsg)
            hideDictationHUD()
        }
    }
    
    @MainActor
    private func handleDeniedPermission() {
        state = .error("Microphone permission denied. Please enable in System Settings > Privacy & Security > Microphone")
        hideDictationHUD()
    }
    
    @MainActor
    private func processAudio(_ samples: [Float], resumeListening: Bool) async {
        guard !isProcessing, !samples.isEmpty else { return }
        let snapshot = recordingSettings ?? settings
        let id = UUID()
        historyStore.addEntry(TranscriptionEntry(
            id: id, text: "", language: snapshot.selectedLanguage,
            timestamp: transcriptionStartTime ?? Date(), duration: Double(samples.count) / 16_000,
            audioID: id,
            processingMessage: String(localized: "Áudio capturado. Aguardando transcrição.")
        ))
        await transcribeRecording(samples, id: id, settings: snapshot, shouldInsert: true)
    }

    func canRetranscribe(_ entry: TranscriptionEntry) -> Bool {
        unsavedAudio[entry.id] != nil || entry.audioID.map { historyStore.audioStore.exists($0) } == true
    }

    func retranscribe(_ entry: TranscriptionEntry) async {
        guard !isProcessing, state != .listening, recordingStartID == nil else { return }
        isProcessing = true
        guard await VoizAccessStore.shared.authorizeNewOperation(kind: .transcription) else {
            isProcessing = false
            if !Task.isCancelled {
                state = .error(VoizAccessStore.shared.lastError ?? VoizAccessMessages.libraryUnavailable)
            }
            return
        }
        guard !Task.isCancelled, historyStore.entries.contains(where: { $0.id == entry.id }) else {
            isProcessing = false
            return
        }
        var snapshot = settings
        snapshot.selectedLanguage = entry.language
        // Loading can suspend; reserve the UI before reading so a new recording cannot race it.
        isProcessing = true
        state = .processing
        processingEntryID = entry.id
        do {
            let samples: [Float]
            if let pending = unsavedAudio[entry.id] {
                samples = pending
            } else if let audioID = entry.audioID {
                let store = historyStore.audioStore
                samples = try await Task.detached { try store.load(audioID) }.value
            } else {
                throw CocoaError(.fileNoSuchFile)
            }
            await transcribeRecording(samples, id: entry.id, settings: snapshot, shouldInsert: false)
        } catch {
            let message = String(localized: "Não foi possível abrir o áudio. O texto anterior foi mantido.")
            historyStore.update(entry.id) { $0.processingMessage = message }
            processingEntryID = nil
            isProcessing = false
            state = .error(message)
        }
    }

    private func transcribeRecording(_ samples: [Float], id: UUID, settings snapshot: AppSettings, shouldInsert: Bool) async {
        isProcessing = true
        state = .processing
        processingEntryID = id
        let storeForCleanup = historyStore.audioStore
        defer {
            if !historyStore.entries.contains(where: { $0.id == id }) {
                // Handles deletion while the archive write or inference was suspended.
                try? storeForCleanup.remove(id)
                unsavedAudio[id] = nil
            }
            isProcessing = false
            processingEntryID = nil
            hideDictationHUD()
        }

        let store = historyStore.audioStore
        var recordingWarning: String?
        if !store.exists(id) {
            do {
                try await Task.detached { try store.save(samples, id: id) }.value
                historyStore.update(id) { $0.audioID = id }
                unsavedAudio[id] = nil
            } catch {
                unsavedAudio[id] = samples
                recordingWarning = String(localized: "Não foi possível salvar o áudio no disco. Tente transcrever novamente antes de fechar o Voiz.")
            }
        }
        // The recording is recoverable even if inference fails or returns no words.
        historyStore.update(id) {
            $0.processingMessage = recordingWarning ?? String(localized: "Áudio salvo. Aguardando transcrição.")
        }
        let vocabulary = TranscriptionContext.terms(from: snapshot.dictationVocabulary)
        do {
            let outcome = try await coordinator.transcribe(
                TranscriptionRequest(
                    useCase: .dictation,
                    language: snapshot.selectedLanguage.transcriptionLanguage,
                    audio: TranscriptionAudio(samples: samples),
                    context: TranscriptionContext(vocabulary: vocabulary, isDictation: true)
                ),
                selection: snapshot.transcriptionSelection(for: .dictation)
            )
            let raw = outcome.text
            let text = DictationTextPolicy.applyingCorrections(
                to: raw, enabled: snapshot.dictationCorrectionsEnabled,
                markers: snapshot.dictationCorrectionMarkers
            )
            var notices = [String]()
            if let preferred = snapshot.transcriptionSelection(for: .dictation).preferred,
               outcome.plan.rejections.contains(where: { $0.engine == preferred.engine && $0.reason == .vocabularyUnsupported }) {
                notices.append(String(localized: "Outro motor foi usado para aplicar seu vocabulário."))
            }
            if let recordingWarning { notices.append(recordingWarning) }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notices.append(String(localized: "Nenhum texto reconhecido. O áudio continua salvo."))
            }
            if !vocabulary.isEmpty {
                if let used = outcome.result.vocabularyTermsUsed {
                    if used < vocabulary.count {
                        notices.append(String(localized: "Alguns termos do vocabulário não foram usados. Reduza a lista."))
                    }
                } else {
                    notices.append(String(localized: "O vocabulário pode não ter sido aplicado."))
                }
            }
            let message = notices.isEmpty ? nil : notices.joined(separator: "\n")
            historyStore.complete(id, raw: outcome.result.unadaptedText ?? raw, text: text, provenance: outcome.provenance, message: message)
            // A user may have deleted this entry while the model was working.
            guard historyStore.entries.contains(where: { $0.id == id }) else {
                unsavedAudio[id] = nil
                state = .idle
                return
            }
            transcriptionText = text
            segments = outcome.result.segments.map {
                TranscriptionSegment(text: $0.text, language: snapshot.selectedLanguage,
                                     confidence: $0.confidence ?? 0, timestamp: Date(), duration: $0.duration)
            }
            addDebugLog("✅ \(DictationTranscription.logSummary(for: outcome.provenance)), \(text.count) caracteres")
            if shouldInsert, !text.isEmpty {
                if snapshot.autoInsertText {
                    insertTextAtCursor(text)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if snapshot.notchOverlayEnabled {
                        NotchOverlay.shared.showToast(message: String(localized: "Copiado. Cole com ⌘V."), symbol: "doc.on.clipboard.fill")
                    }
                }
            }
            announceFallbackIfNeeded(outcome.provenance, afterPasteToast: shouldInsert && !text.isEmpty && snapshot.autoInsertText)
            state = .idle
        } catch {
            let failure = DictationTranscription.failure(for: error)
            let detail = Self.dictationFailureMessage(failure)
            let message = [recordingWarning, String(localized: "Falha na transcrição. Você pode tentar novamente pelo histórico."), detail]
                .compactMap { $0 }.joined(separator: "\n")
            historyStore.update(id) { $0.processingMessage = message }
            state = failure == .cancelled ? .idle : .error(message)
        }
    }

    /// Avisa que o texto veio de um fallback — o motor preferido falhou e outro entrou no lugar.
    ///
    /// A troca nunca é silenciosa (PLANO: "fallback local com proveniência"). Sai pelo mesmo canal
    /// dos outros avisos do ditado, o toast do notch, e portanto só aparece com o notch ligado; a
    /// proveniência fica gravada no histórico de qualquer jeito.
    ///
    /// O atraso existe porque o toast de "Colado" é postado ~0,6 s depois da colagem e substitui o
    /// que estiver na tela: sem esperar, o aviso nasceria e morreria antes de dar para ler.
    private func announceFallbackIfNeeded(
        _ provenance: TranscriptionProvenance,
        afterPasteToast: Bool
    ) {
        fallbackToastTask?.cancel()
        guard let notice = DictationTranscription.fallbackNotice(for: provenance) else { return }
        addDebugLog("↩️ Fallback: \(DictationTranscription.logSummary(for: provenance))")
        guard settings.notchOverlayEnabled else { return }

        let message = String(localized: "Transcrito com outro modelo.")
        guard afterPasteToast else {
            NotchOverlay.shared.showToast(message: message, symbol: "arrow.triangle.branch")
            return
        }
        fallbackToastTask = Task { [weak self] in
            // 0,6 s até a colagem + 1,6 s do toast "Colado".
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard self != nil, !Task.isCancelled else { return }
            NotchOverlay.shared.showToast(message: message, symbol: "arrow.triangle.branch")
        }
    }

    /// A frase que descreve uma falha de motor. Vale para a faixa de status das Configurações e
    /// para o estado de erro do ditado.
    nonisolated private static func engineFailureMessage(_ failure: TranscriptionEngineFailure) -> String {
        switch failure {
        case .modelUnavailable:
            return String(localized: "Modelo de transcrição indisponível. Verifique a conexão ou escolha outro em Configurações.")
        case .languageUnsupported:
            return String(localized: "Este idioma não é compatível com o motor escolhido.")
        case .hardwareUnsupported:
            return String(localized: "Este Mac não atende aos requisitos do motor de transcrição.")
        case .invalidAudio:
            return String(localized: "Não foi possível ler o áudio.")
        case .cancelled:
            return String(localized: "Transcrição cancelada.")
        case .engineInternal(let detail):
            // Descrição técnica do próprio motor, já em linguagem de sistema.
            return detail
        }
    }

    nonisolated private static func dictationFailureMessage(_ failure: DictationTranscription.Failure) -> String {
        switch failure {
        case .noCandidate:
            return String(localized: "Nenhum motor de transcrição disponível para o ditado.")
        case .enginesFailed(let engineFailure):
            return engineFailureMessage(engineFailure)
        case .cancelled:
            return String(localized: "Transcrição cancelada.")
        case .unexpected:
            return String(localized: "Não foi possível transcrever. Tente de novo.")
        }
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
            print("⚠️ Still processing transcription, ignoring toggle request")
        case .error:
            startListening()
        }
    }
    
    private func insertTextAtCursor(_ text: String) {
        addDebugLog("🔐 Verificando permissões de acessibilidade...")
        
        // SEMPRE copia para o clipboard primeiro
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Sem transcript no log (PLANO, regra 7): este `addDebugLog` guardava os primeiros 50
        // caracteres do que o usuário acabou de ditar em `debugLogs` **e** em stdout, a cada ditado
        // com auto-inserção. O que interessa para depurar é que a cópia aconteceu e quanto texto foi.
        addDebugLog(TranscriptionLogRedaction.copiedToPasteboard(text))
        
        guard AccessibilityPermissionService.shared.isTrusted else {
            addDebugLog("❌ Sem permissão de acessibilidade")
            state = .error("Texto copiado! Para colar automaticamente, ative a permissão de Acessibilidade nas Configurações do app.")
            hideDictationHUD()
            return
        }
        
        addDebugLog("✅ Permissão de acessibilidade concedida")
        let targetAppWasRestored = restorePreviousApplicationIfNeeded()
        addDebugLog("🔄 App anterior restaurado: \(targetAppWasRestored)")
        
        let delay: TimeInterval = targetAppWasRestored ? 0.6 : 0.4
        addDebugLog("⏰ Aguardando \(String(format: "%.1f", delay))s antes de colar...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            // Método 1 (preferido): simular Cmd+V no campo focado. É o que o usuário
            // espera, é não-destrutivo e respeita a posição do cursor.
            self.addDebugLog("⌨️ Simulando Cmd+V via CGEvent...")
            var pasted = false
            if self.simulatePasteWithCGEvent() {
                self.addDebugLog("✅ Cmd+V executado via CGEvent!")
                pasted = true
            } else {
                // Fallback: escrita direta via Accessibility API.
                self.addDebugLog("⚠️ CGEvent falhou, tentando Accessibility API...")
                if self.insertTextViaAccessibility(text) {
                    self.addDebugLog("✅ Texto inserido via Accessibility API!")
                    pasted = true
                } else {
                    self.addDebugLog("❌ Não foi possível colar automaticamente - use Cmd+V manualmente")
                }
            }
            if pasted, self.settings.notchOverlayEnabled {
                NotchOverlay.shared.showToast(
                    message: String(localized: "Colado"),
                    duration: 1.6
                )
            }

            // Restaura o conteúdo anterior do clipboard depois que a colagem assentar.
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                    self.addDebugLog("♻️ Clipboard restaurado")
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

        let vKey = CGKeyCode(0x09) // V

        // Em vez de simular a tecla Command física separadamente (que costuma falhar
        // por questões de timing/estado de modificador), aplicamos a flag Command
        // diretamente nos eventos da tecla V. É a forma mais confiável de enviar Cmd+V.
        guard
            let vDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: true),
            let vUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: vKey, keyDown: false)
        else {
            return false
        }

        vDownEvent.flags = .maskCommand
        vUpEvent.flags = .maskCommand

        vDownEvent.post(tap: .cghidEventTap)
        vUpEvent.post(tap: .cghidEventTap)

        return true
    }
    
    private func rememberFrontmostApplication() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            previousActiveApp = lastExternalActiveApp
            return
        }
        
        if frontmost == NSRunningApplication.current {
            previousActiveApp = lastExternalActiveApp
        } else {
            previousActiveApp = frontmost
            lastExternalActiveApp = frontmost
        }
    }
    
    @discardableResult
    private func restorePreviousApplicationIfNeeded() -> Bool {
        let targetApp: NSRunningApplication
        if let app = previousActiveApp,
           app != NSRunningApplication.current,
           !app.isTerminated {
            targetApp = app
        } else if let fallback = lastExternalActiveApp,
                  fallback != NSRunningApplication.current,
                  !fallback.isTerminated {
            targetApp = fallback
        } else {
            previousActiveApp = nil
            return false
        }
        
        let options: NSApplication.ActivationOptions
        if #available(macOS 14, *) {
            options = [.activateAllWindows]
        } else {
            options = [.activateAllWindows, .activateIgnoringOtherApps]
        }
        
        let activated = targetApp.activate(options: options)
        if activated {
            lastExternalActiveApp = targetApp
        }
        previousActiveApp = nil
        return activated
    }
    
    @MainActor
    func clearTranscription() {
        transcriptionText = ""
        segments.removeAll()
    }
    
    private func addDebugLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        debugLogs.append(logMessage)
        print(logMessage)
        
        // Limita a 100 logs
        if debugLogs.count > 100 {
            debugLogs.removeFirst()
        }
    }
    
    deinit {
        if let observer = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
