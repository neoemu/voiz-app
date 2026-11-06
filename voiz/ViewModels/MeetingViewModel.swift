import AppKit
import AVFoundation
import Combine
import EventKit
import Foundation

@MainActor
final class MeetingViewModel: ObservableObject {
    private let meetingWorkspace = MeetingWorkspaceStore.shared
    @Published var state: TranscriptionState = .idle
    @Published var selectedTemplateId: String = ""
    @Published var meetingMode: AppSettings.MeetingMode = .quality {
        didSet {
            var settings = settingsStore.load()
            if settings.meetingMode != meetingMode {
                settings.meetingMode = meetingMode
                settingsStore.saveWithSync(settings)
            }
        }
    }
    @Published var activeSession: MeetingSession?
    @Published var selectedSession: MeetingSession?
    @Published var microphoneLevel: Float = 0
    @Published var systemAudioLevel: Float = 0
    /// Mensagens de status são `String` já resolvida (não `LocalizedStringKey`), então cada
    /// atribuição precisa passar por `String(localized:)` — caso contrário o texto sai no
    /// idioma-fonte independentemente do idioma da interface.
    @Published var statusMessage: String = String(localized: "Pronto para gravar")
    @Published private(set) var meetingPaused = false
    /// Progresso (0...1) da transcrição pós-call, proporcional ao áudio já lido dos .caf.
    /// nil fora do pós-processamento (a UI mostra spinner indeterminado nos demais passos).
    @Published private(set) var postProcessingProgress: Double?
    /// Sessões que estão atualmente em pós-processamento ou na fila de pós-processamento de fundo.
    @Published private(set) var processingSessionIDs: Set<UUID> = []
    /// ID da sessão atualmente em pós-processamento ativo (nil se a fila estiver ociosa).
    @Published private(set) var currentProcessingSessionID: UUID?
    /// Fila de IDs de sessões aguardando pós-processamento (executadas de forma serial, fila de 1).
    private var postProcessingQueue: [UUID] = []
    /// Reserva por PROCESSO das sessões em pós-processamento, compartilhada entre todas as
    /// instâncias deste view model. A fila acima é por instância; se a SwiftUI construir um
    /// segundo `MeetingViewModel`, o `init` dele reencontra a mesma sessão incompleta e sem
    /// este registro dispararia um segundo pipeline (e um segundo par de chamadas pagas).
    private static var postProcessingInFlight: Set<UUID> = []
    /// Reprocessar manual: o hangup Granola continua só-resumo; o clique é batch completo.
    private var manualReprocessSessionIDs: Set<UUID> = []
    /// Task de fundo que consome a fila de pós-processamento sequencialmente.
    private var postProcessingTask: Task<Void, Never>?
    @Published private(set) var postProcessingWaitingForCredentials = false
    var hasActivePostProcessing: Bool {
        MeetingCredentialRecoveryGate.hasActiveWork(
            processingIDs: processingSessionIDs, queuedIDs: postProcessingQueue,
            waitingForCredentials: postProcessingWaitingForCredentials
        )
    }
    @Published private(set) var generatingSummarySessionIDs: Set<UUID> = []
    @Published private(set) var generatingChapterSessionIDs: Set<UUID> = []
    var isGeneratingSummary: Bool { !generatingSummarySessionIDs.isEmpty }
    @Published var debugLogs: [String] = []
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var folders: [MeetingFolder] = []
    /// Pasta aberta na aba Reuniões. Vive no view model (não na view) para a sidebar poder
    /// navegar direto pra uma pasta e destacar a que está aberta, estilo Granola.
    @Published var viewingFolderId: UUID?

    // Sugestão de calendário (Onda 3 — detecção de reunião agendada, on-device)
    @Published var detectedMeeting: DetectedMeeting?
    /// Agenda "Em breve" (próximos dias) para a home de Reuniões.
    @Published var upcomingEvents: [CalendarEvent] = []
    @Published private(set) var isStartingMeeting = false

    var canStartMeeting: Bool {
        guard activeSession == nil, !isStartingMeeting else { return false }
        switch state {
        case .idle, .error: return true
        default: return false
        }
    }
    @Published var calendarAuthorized = false
    /// Acesso negado/restrito pelo sistema: a UI deve oferecer "Abrir Ajustes" em vez de re-pedir.
    @Published var calendarAccessBlocked = false
    @Published var calendarSuggestionsEnabled = false

    /// Preview do transcript ao vivo: parágrafos em texto corrido, sem separação de falante.
    /// Ao vivo a atribuição é ruidosa (eco de alto-falante vira "Você" falso e o transcript
    /// fica alternando falante errado) — a versão fiel, com falantes e diarização, é a dos
    /// `turns`, reconstruída no pós-call. Este feed é só display.
    @Published private(set) var liveFeed: [MeetingLiveFeedEntry] = []
    /// Preferência fixada no começo da reunião. Quando false, o Whisper pequeno da
    /// prévia (modo Qualidade) não é executado. O card de transcript usa
    /// `liveTranscriptCardVisible`: no Granola a prévia 1s fica off, mas o card
    /// continua visível enquanto o transcritor ao vivo estiver ativo.
    @Published private(set) var livePreviewEnabled = false
    /// Transcritor Granola desta sessão está emitindo eventos. Fica false no
    /// fallback granola→qualidade (aí vale o modo Qualidade: só a prévia Whisper).
    @Published private(set) var granolaLiveTranscriptionActive = false
    /// Card de transcript ao vivo: prévia Whisper (Qualidade) ou transcritor Granola.
    var liveTranscriptCardVisible: Bool {
        livePreviewEnabled || granolaLiveTranscriptionActive
    }
    /// A assistência exige o transcript oficial crescente do modo Ao vivo.
    var liveMeetingAssistantAvailable: Bool {
        MeetingRecordingLifecycle.liveAssistantIsAvailable(
            mode: activeSession?.meetingMode,
            liveTranscriberActive: granolaLiveTranscriptionActive
        )
    }

    /// Volátil do mic que a UI mostra. Consulta a máquina de hold-off/histerese;
    /// o estado cru continua em `liveVolatiles`.
    var displayedMicrophoneVolatile: String {
        guard micVolatileGate.displaysText else { return "" }
        return liveVolatiles.microphone
    }
    /// Bloco em crescimento da prévia Whisper (modo Qualidade, fluxo único sem canal).
    @Published private(set) var liveCurrentParagraph: String = ""
    /// Hipóteses voláteis do Granola, uma por canal. Sem isso os dois streams
    /// se sobrescrevem no mesmo parágrafo e o StreamingText pisca.
    @Published private(set) var liveVolatiles = MeetingLiveVolatileState()
    /// Finais recentes do canal system, para julgar eco do mic ao vivo.
    private var recentSystemLiveUtterances: [MeetingEchoTextMatch.Utterance] = []
    private var lastSystemVolatile: MeetingEchoTextMatch.Utterance?
    private var lastMicrophoneVolatile: MeetingEchoTextMatch.Utterance?
    private var liveSuppressedMicFinals = 0
    private var micVolatileGate = MeetingLiveMicVolatileGate()
    /// Texto já assentado por janelas internas anteriores do Whisper, mas que ainda
    /// pertence ao mesmo bloco visual. A hipótese da janela corrente é anexada a ele.
    private var livePreviewStablePrefix = ""
    /// Estado da janela corrente usado para tornar a parte antiga monotônica: o Whisper
    /// ainda corrige a ponta, mas não apaga uma fala inteira que já ficou para trás.
    private var livePreviewLockedWindowPrefix = ""
    private var livePreviewPreviousHypothesis = ""

    // Notas rápidas — o editor altera só este rascunho; a sessão é persistida após uma
    // pequena pausa, em vez de reescrever o JSON inteiro a cada tecla.
    @Published private(set) var liveNotesDraft = ""
    private var liveNotesSaveTask: Task<Void, Never>?
    private static let liveNotesSaveDelay: TimeInterval = 0.6

    // Live Assist (sugestões de um toque durante a gravação)
    @Published private(set) var assistRunning = false
    @Published private(set) var assistActionResults: [MeetingAssistAction: MeetingAssistActionResult] = [:]
    @Published private(set) var assistQuestionHistory: [MeetingAssistQuestionResult] = []
    @Published private(set) var assistActiveAction: MeetingAssistAction?
    @Published private(set) var assistActiveQuestionID: UUID?
    @Published var assistQuestion: String = ""

    let store = MeetingSessionStore()
    let templateStore = MeetingTemplateStore()
    /// Prévia ao vivo estilo Granola, com WhisperKit small dedicado.
    let livePreviewService = MeetingLivePreviewService()

    /// Factory de transcritor ao vivo (usado no modo Granola).
    /// Por contrato arquitetural, cada invocação deve retornar uma NOVA instância de `MeetingLiveTranscriber`
    /// dedicada à sessão correspondente, evitando compartilhamento de estado entre gravações consecutivas.
    var liveTranscriberProvider: (@Sendable () -> (any MeetingLiveTranscriber)?)?
    private var activeTranscriber: (any MeetingLiveTranscriber)?
    /// Sobe a cada `start` de transcritor. O `stop` de uma sessão só toca o objeto se a
    /// geração ainda for a dela — contrato A/B quando o provider devolve a mesma instância.
    private var liveTranscriberGeneration = 0
    private var liveTranscriptionTask: Task<Void, Never>?
    private var liveSampleCountsBySource: [MeetingCaptureSource: Int] = [:]

    private let captureService = MeetingCaptureService()
    /// Barreira completa de parada de gravação (cobre hardware de captura, drain e stop do transcritor ao vivo).
    /// Garante que `startMeeting()` aguarde a conclusão integral da sessão anterior antes de iniciar nova captura.
    private var recordingTeardownTask: Task<Void, Never>?
    let calendarService = MeetingCalendarService()
    private let appDetectionService = MeetingAppDetectionService()
    /// O dono único do coordenador no processo (T2.4a/T2.4b/T2.5). A reunião **não** monta motor
    /// nenhum: os dois serviços legados que este view model criava (`TranscriptionService.shared` e
    /// um `ParakeetTranscriptionService` só dele) eram os últimos pesos de transcrição fora dos
    /// livros do coordenador, e é isso que fazia a regra de "um modelo pesado residente" valer só
    /// sobre parte do app.
    private var coordinator: TranscriptionCoordinator { AppTranscriptionCoordinator.shared.coordinator }
    private let settingsStore: SettingsStore
    private let diarizationService = MeetingDiarizationService()
    private var namingService: MeetingSpeakerNamingService
    private var liveAssistService: MeetingLiveAssistService
    /// Idioma da **prévia ao vivo** (fixado ao iniciar a gravação).
    ///
    /// O transcript oficial não lê mais este campo: o idioma dele viaja dentro do
    /// `TranscriptionPlanSnapshot` da sessão, junto do plano, para que um pós-call retomado depois
    /// de o app fechar continue pedindo o idioma da reunião e não o dos Ajustes de hoje.
    private var recordingLanguage: Language = .portuguese
    /// O aquecimento em voo do motor do transcript oficial.
    ///
    /// Hoje há **uma** chamada só, no `init`, espelhando exatamente o `ensureInitialized()` legado:
    /// a reunião nunca reagiu a troca de modelo nas Configurações, e passar a reagir agora seria
    /// mudança de comportamento (regra 6). A alça existe para que uma segunda chamada — a Onda 6,
    /// quando a UI puder re-rotear a reunião — supere a anterior em vez de empilhar cargas na fila
    /// do coordenador, que foi o defeito que o ditado corrigiu na T2.4a.
    private var warmUpTask: Task<Void, Never>?
    /// Segue "Indicador de gravação" dos Ajustes, fixado no início da reunião.
    private var meetingIndicatorEnabled = false
    private var notchOverlayEnabled = false
    /// Início do intervalo pausado corrente; os intervalos concluídos vão para a sessão.
    private var pauseStartedAt: Date?
    private var assistTask: Task<Void, Never>?
    private var assistAuthorizationID: UUID?
    private var sessionOperationRequests: [UUID: UUID] = [:]
    private var meetingStartID: UUID?
    private var cancellables = Set<AnyCancellable>()

    // Transcript oficial pós-call. Durante a reunião só o Whisper small da prévia roda:
    // microfone e áudio do sistema já são gravados separadamente em .caf. Ao finalizar,
    // lemos esses arquivos em chunks de 3s, descartamos silêncio e juntamos fala contínua
    // em lotes de até 28s para o modelo escolhido. Assim small e large-v3-turbo nunca
    // disputam ANE/GPU enquanto Teams/Meet/Zoom processa a câmera.
    private static let recordedChunkSeconds: TimeInterval = 3
    private static let maxFinalBatchSeconds: TimeInterval = 28
    private static let finalBatchGapTolerance: TimeInterval = 0.6
    private static let audibleRMSThreshold: Float = 0.003
    /// Persistência do transcript final é throttled durante o pós-processamento para que,
    /// se houver uma interrupção, os lotes já concluídos continuem salvos junto do áudio.
    private static let liveSaveInterval: TimeInterval = 10
    private var lastLiveSaveAtBySession: [UUID: Date] = [:]

    /// Pares motor+modelo que já falharam no pós-processamento em curso.
    ///
    /// Espelho do que o coordenador registrou (a `batchRetryPolicy` suprime pelo resto da reunião),
    /// e serve só para o log anunciar **uma vez** que os lotes seguintes mudaram de motor. Zerado a
    /// cada pós-processamento: a supressão do coordenador é por instância dele, mas a leitura desta
    /// aqui é sobre "esta passagem pelo áudio".
    private var suppressedBatchCandidates: Set<MeetingTranscription.CandidateKey> = []
    /// O candidato que serviu (ou vai servir) os lotes agora. Usado para detectar o rebaixamento.
    private var currentBatchCandidate: TranscriptionPlanSnapshot.Candidate?
    /// O snapshot do pós-processamento em curso (é dele que sai o "próximo candidato").
    private var batchSnapshot: TranscriptionPlanSnapshot?
    /// A verdade dos turns desta passagem de lotes. O store não monta o transcript.
    private var batchPass = MeetingRecordingLifecycle.BatchTurnPersistence()

    init(settingsStore: SettingsStore? = nil) {
        let resolvedStore = settingsStore ?? SettingsStore()
        self.settingsStore = resolvedStore
        let loadedSettings = resolvedStore.load()
        self.namingService = MeetingSpeakerNamingService(settings: loadedSettings)
        self.liveAssistService = MeetingLiveAssistService(settings: loadedSettings)
        self.sessions = store.sessions
        self.folders = store.folders
        self.selectedSession = store.sessions.first
        self.selectedTemplateId = templateStore.defaultTemplate.id
        self.meetingMode = loadedSettings.meetingMode

        adoptGeneratedTitles()
        setupBindings()
        setupAppDetection(enabled: loadedSettings.meetingDetectionEnabled)
        refreshCalendarSuggestion()

        warmUpBatchEngine(for: loadedSettings)

        // Reconecta ou disponibiliza sessões interrompidas por encerramento do app (incluindo órfãs sem endedAt)
        for session in store.sessions where hasRecordedAudio(session) && session.isProcessingCompleted == false {
            var reconciled = session
            let hadEndedAt = reconciled.endedAt != nil
            if let recovered = MeetingRecordingLifecycle.modeAfterInterruptedRecording(
                stored: reconciled.meetingMode,
                hadEndedAt: hadEndedAt,
                turnCount: reconciled.turns.count
            ) {
                reconciled.meetingMode = recovered
            }
            if reconciled.endedAt == nil {
                reconciled.endedAt = Date()
            }
            store.save(reconciled)
            if self.selectedSession?.id == reconciled.id {
                self.selectedSession = reconciled
            }
            enqueuePostProcessing(
                for: reconciled.id,
                manualReprocess: MeetingRecordingLifecycle.isManualReprocess(reconciled)
            )
        }
    }

    isolated deinit {
        postProcessingTask?.cancel()
        // Failed credential access leaves recoveries queued, not running. Closing the
        // window must let its replacement claim them again in the same app process.
        MeetingCredentialRecoveryGate.releaseQueuedClaims(
            postProcessingQueue, current: currentProcessingSessionID,
            inFlight: &Self.postProcessingInFlight
        )
    }

    /// Monta e congela o plano dos lotes com as configurações dadas.
    ///
    /// Quem responde qual é o plano é o **coordenador**, e não um roteador local: a decisão de qual
    /// motor transcreve tem uma fonte de verdade só, e uma cópia do roteador aqui casaria hoje e
    /// divergiria em silêncio quando a Onda 6 montar o coordenador com a política versionada.
    private func batchPlanSnapshot(for settings: AppSettings) async -> TranscriptionPlanSnapshot {
        let language = settings.selectedLanguage.transcriptionLanguage
        let plan = await coordinator.plan(
            for: .meetingFinal,
            language: language,
            selection: settings.transcriptionSelection(for: .meetingFinal)
        )
        return TranscriptionPlanSnapshot(
            plan: plan,
            language: language,
            // Sempre explícito: o idioma vem do seletor, que não tem mais automático.
            // `.autoAdopted` continua existindo para as sessões gravadas antes disso.
            languageOrigin: .explicit
        )
    }

    /// Pré-aquece o motor do transcript oficial, como o `ensureInitialized()` legado fazia no boot.
    ///
    /// Substitui os dois caminhos legados (`configure(modelName:)` + `ensureInitialized()` no
    /// Whisper compartilhado, ou `ensureInitialized()` no Parakeet) por um aquecimento só: o plano
    /// sai do mesmo roteador que vai servir os lotes, então "só a engine escolhida" continua valendo
    /// por construção — o `warmUp` aquece o rank 0 e mais nada.
    ///
    /// A política é a **mesma dos lotes** (`MeetingTranscription.batchRetryPolicy`), e isso é
    /// requisito e não simetria estética: `warmUp` lê a supressão com a política que recebe, e ler
    /// com a do coordenador (300 s) enquanto os lotes escrevem com cooldown infinito faria o
    /// aquecimento furar a supressão — `unload()` + `prepare()`, ou seja, exatamente o download que
    /// a supressão existia para evitar (aditivo (c) do contrato da T2.3, em DECISOES).
    ///
    /// ## Este é o TERCEIRO aquecimento do boot, e por ora isso não custa nada
    ///
    /// O `ContentView` cria este view model junto do de tradução, e o `VoizApp` cria o do ditado —
    /// então o boot dispara três `warmUp`, um por caso de uso (Quilha, T2.5). Hoje os três convergem
    /// para a **mesma** carga: a migração da T1.4 dá o mesmo modelo aos casos de uso que
    /// compartilham motor, e o segundo e o terceiro pedidos caem no caminho rápido do `prepare` (já
    /// residente), sem disco e sem rede.
    ///
    /// Não deduplico aqui de propósito. Dedupe barato — "se outro caso de uso já aqueceu este
    /// motor+modelo, não peça" — é o que o coordenador **já faz**, e melhor, porque ele sabe o que
    /// está residente. O caso que sobra é o caro: modelos **diferentes** no mesmo motor, quando um
    /// aquecimento desfaz o outro. Aí não existe dedupe, existe **escolha** de qual aquecer — que é
    /// política de produto (aquecer só a tela em foco?) e mora na T6.1/T6.2, que é justamente quem
    /// torna esse caso alcançável ao expor seleção por caso de uso. Registrado em DECISOES e no doc
    /// de `wouldEvictForeignWeights`.
    private func warmUpBatchEngine(for settings: AppSettings) {
        let selection = settings.transcriptionSelection(for: .meetingFinal)
        let language = settings.selectedLanguage.transcriptionLanguage
        warmUpTask?.cancel()
        let coordinator = self.coordinator
        warmUpTask = Task {
            await coordinator.warmUp(
                for: .meetingFinal,
                language: language,
                selection: selection,
                retryPolicy: MeetingTranscription.batchRetryPolicy
            )
        }
    }

    /// Gate new user work at its boundary; an admitted recording keeps all of its finishing steps.
    private func authorizeLibraryOperation(kind: VoizOperationKind = .editing, workID: UUID = UUID(), stillCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        guard await VoizAccessStore.shared.authorizeNewOperation(kind: kind, workID: workID) else {
            guard !Task.isCancelled, stillCurrent() else { return false }
            statusMessage = VoizAccessStore.shared.lastError ?? VoizAccessMessages.libraryUnavailable
            return false
        }
        return !Task.isCancelled && stillCurrent()
    }

    /// Each session has one admission in flight; deleting it invalidates the request.
    private func withAvailableSession(_ id: UUID, operation: @escaping @MainActor (MeetingSession) async -> Void) {
        guard sessionOperationRequests[id] == nil else { return }
        let token = UUID()
        sessionOperationRequests[id] = token
        Task { @MainActor in
            defer { if sessionOperationRequests[id] == token { sessionOperationRequests[id] = nil } }
            guard !Task.isCancelled, sessionOperationRequests[id] == token else { return }
            guard await authorizeLibraryOperation(kind: .transcription, workID: token, stillCurrent: { self.sessionOperationRequests[id] == token }),
                  sessionOperationRequests[id] == token,
                  let target = sessionForEditing(id: id) else { return }
            await operation(target)
        }
    }

    func toggleRecording() {
        if isStartingMeeting, activeSession == nil {
            meetingStartID = nil
            isStartingMeeting = false
            return
        }
        switch state {
        case .idle, .error:
            Task { await startMeeting() }
        case .listening:
            Task { await stopMeeting() }
        case .processing:
            Task { await startMeeting() }
        }
    }

    func toggleMeetingPause() {
        guard state == .listening else { return }
        meetingPaused ? resumeMeeting() : pauseMeeting()
    }

    /// Duração útil da reunião: congela durante o pause e desconta todos os intervalos
    /// pausados, ficando alinhada aos arquivos de áudio (que também não recebem o break).
    func meetingDuration(for session: MeetingSession, at now: Date = Date()) -> TimeInterval {
        var paused = session.pausedDuration ?? 0
        if meetingPaused, let pauseStartedAt {
            paused += now.timeIntervalSince(pauseStartedAt)
        }
        return max(0, (session.endedAt ?? now).timeIntervalSince(session.startedAt) - paused)
    }

    private func pauseMeeting() {
        let now = Date()
        _ = captureService.setPaused(true)
        meetingPaused = true
        pauseStartedAt = now
        statusMessage = String(localized: "Gravação pausada — o intervalo não será salvo")
        MeetingRecordingIndicator.shared.setPaused(true)
        NotchOverlay.shared.setPaused(true)

        if livePreviewEnabled {
            settleLivePreviewForPause()
            livePreviewService.stop()
        }
        addDebugLog("Gravação pausada")
    }

    private func resumeMeeting() {
        finishCurrentPause(at: Date(), persist: true)
        _ = captureService.setPaused(false)
        meetingPaused = false
        // The warning itself is shown once, below; the status line stays short.
        statusMessage = activeSession?.systemAudioWarning == nil
            ? String(localized: "Gravando microfone e áudio do sistema") : String(localized: "Gravando só o microfone")
        MeetingRecordingIndicator.shared.setPaused(false)
        NotchOverlay.shared.setPaused(false)

        if livePreviewEnabled {
            Task { @MainActor [weak self] in
                guard let self, !self.meetingPaused, self.state == .listening else { return }
                await self.livePreviewService.start(language: self.recordingLanguage)
            }
        }
        addDebugLog("Gravação retomada")
    }

    private func finishCurrentPause(at end: Date, persist: Bool) {
        guard let started = pauseStartedAt, var session = activeSession else {
            pauseStartedAt = nil
            return
        }
        session.pausedDuration = (session.pausedDuration ?? 0) + max(0, end.timeIntervalSince(started))
        pauseStartedAt = nil
        activeSession = session
        selectedSession = session
        if persist {
            store.save(session)
        }
    }

    private func settleLivePreviewForPause() {
        if !liveCurrentParagraph.isEmpty {
            appendLiveFeed(MeetingLiveFeedEntry(text: liveCurrentParagraph))
        }
        liveCurrentParagraph = ""
        livePreviewStablePrefix = ""
        resetLivePreviewHypothesisState()
    }

    // MARK: - Live Assist

    /// Dispara uma ação de um toque (O que eu digo? / Follow-ups / Recap).
    func runLiveAssist(_ action: MeetingAssistAction) {
        authorizeLiveAssist { settings in
            var result = self.assistActionResults[action] ?? MeetingAssistActionResult(action: action)
            result.contextSessionIDs = self.activeSession?.contextSessionIDs ?? []
            result.error = nil
            result.isRunning = true
            self.assistActionResults[action] = result
            self.assistActiveAction = action
            self.startAssist(action: action, question: nil, target: .action(action), settings: settings)
        }
    }

    /// Dispara a pergunta livre digitada no card de assist.
    func submitLiveAssistQuestion() {
        let question = assistQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        authorizeLiveAssist { settings in
            if self.assistQuestion.trimmingCharacters(in: .whitespacesAndNewlines) == question { self.assistQuestion = "" }
            var item = MeetingAssistQuestionResult(question: question, isRunning: true)
            item.contextSessionIDs = self.activeSession?.contextSessionIDs ?? []
            self.assistQuestionHistory.append(item)
            self.assistActiveQuestionID = item.id
            self.startAssist(action: nil, question: MeetingAIRecipe.expanded(question, recipes: self.meetingWorkspace.recipes), target: .question(item.id), settings: settings)
        }
    }

    private func authorizeLiveAssist(_ operation: @escaping @MainActor (AppSettings) -> Void) {
        guard liveMeetingAssistantAvailable, !assistRunning, let sessionID = activeSession?.id else { return }
        let token = UUID()
        assistAuthorizationID = token
        assistRunning = true
        assistTask = Task { @MainActor in
            defer {
                if assistAuthorizationID == token {
                    assistAuthorizationID = nil
                    assistRunning = false
                    assistTask = nil
                }
            }
            guard !Task.isCancelled, assistAuthorizationID == token else { return }
            guard await authorizeLibraryOperation(kind: .ai, workID: token, stillCurrent: { self.assistAuthorizationID == token && self.activeSession?.id == sessionID }),
                  assistAuthorizationID == token, liveMeetingAssistantAvailable, activeSession?.id == sessionID else { return }
            do {
                let settings = try await settingsForMeetingAI(resource: .assistant)
                guard !Task.isCancelled, assistAuthorizationID == token,
                      liveMeetingAssistantAvailable, activeSession?.id == sessionID else { return }
                assistAuthorizationID = nil
                operation(settings)
            } catch {
                if !Task.isCancelled { statusMessage = SettingsCredentialError.unavailable.localizedDescription }
            }
        }
    }

    /// Limpa toda a memória de trabalho do assistente para a reunião atual.
    func clearAssist() {
        assistAuthorizationID = nil
        assistTask?.cancel()
        assistTask = nil
        assistRunning = false
        assistActionResults = [:]
        assistQuestionHistory = []
        assistActiveAction = nil
        assistActiveQuestionID = nil
    }

    func clearAssistAction(_ action: MeetingAssistAction) {
        guard assistActiveAction != action else { return }
        assistActionResults.removeValue(forKey: action)
    }

    func clearAssistQuestion(_ id: UUID) {
        guard assistActiveQuestionID != id else { return }
        assistQuestionHistory.removeAll { $0.id == id }
    }

    private enum AssistRequestTarget {
        case action(MeetingAssistAction)
        case question(UUID)
    }

    private func startAssist(
        action: MeetingAssistAction?,
        question: String?,
        target: AssistRequestTarget,
        settings: AppSettings
    ) {
        guard liveMeetingAssistantAvailable, let session = activeSession else { return }
        assistTask?.cancel()
        liveAssistService.updateSettings(settings)

        assistRunning = true

        // No modo Ao vivo, os finais já persistidos formam o contexto estável.
        // A prévia visual do modo Qualidade não habilita o assistente.
        let officialTranscript = session.transcriptText
        var previewPieces = liveFeed.map(\.text)
        previewPieces.append(contentsOf: MeetingRecordingLifecycle.liveOpenPreviewPieces(
            currentParagraph: liveCurrentParagraph,
            displayedMicrophoneVolatile: displayedMicrophoneVolatile,
            systemVolatile: liveVolatiles.systemAudio
        ))
        let transcript = officialTranscript.isEmpty
            ? previewPieces.joined(separator: "\n")
            : officialTranscript
        let scope = "meeting/" + session.id.uuidString + "/assist/" + (action?.rawValue ?? "question")
        assistTask = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let stream = liveAssistService.respondStream(
                    action: action,
                    question: question,
                    transcript: transcript,
                    context: MeetingProductivity.context(sessions: sessions,
                        selectedIDs: Set(session.contextSessionIDs ?? []))
                )
                var accumulated = ""
                for try await delta in stream {
                    if Task.isCancelled { return }
                    accumulated += delta
                    updateAssist(target: target, text: accumulated)
                }
                guard meetingWorkspace.saveAssistantAnswer(scope: scope, question: question ?? action?.title ?? "", text: accumulated, operationID: nil) else { throw CocoaError(.fileWriteUnknown) }

            } catch {
                if Task.isCancelled { return }
                updateAssist(target: target, error: error.localizedDescription)
            }
            finishAssist(target: target)
        }
    }

    private func updateAssist(target: AssistRequestTarget, text: String? = nil, error: String? = nil) {
        switch target {
        case .action(let action):
            var result = assistActionResults[action] ?? MeetingAssistActionResult(action: action)
            if let text { result.text = text }
            if let error { result.error = error }
            assistActionResults[action] = result
        case .question(let id):
            guard let index = assistQuestionHistory.firstIndex(where: { $0.id == id }) else { return }
            if let text { assistQuestionHistory[index].answer = text }
            if let error { assistQuestionHistory[index].error = error }
        }
    }

    private func finishAssist(target: AssistRequestTarget) {
        switch target {
        case .action(let action):
            if var result = assistActionResults[action] {
                result.isRunning = false
                assistActionResults[action] = result
            }
            assistActiveAction = nil
        case .question(let id):
            if let index = assistQuestionHistory.firstIndex(where: { $0.id == id }) {
                assistQuestionHistory[index].isRunning = false
            }
            assistActiveQuestionID = nil
        }
        assistRunning = false
        assistTask = nil
    }

    // MARK: - Sugestão de calendário

    /// Reavalia a sugestão de calendário. Lê o toggle de Ajustes a cada chamada (a tela de Ajustes
    /// edita outra cópia de settings) e só busca eventos se ligado + autorizado.
    func refreshCalendarSuggestion() {
        let settings = settingsStore.load()
        calendarSuggestionsEnabled = settings.calendarSuggestionsEnabled
        calendarService.configure(enabled: calendarSuggestionsEnabled, selection: settings.calendarSelection)
    }

    /// Pede acesso ao calendário (a partir do card na tela de Reuniões) e já reavalia.
    func requestCalendarAccess() async {
        let granted = await calendarService.requestAccess()
        addDebugLog("Calendário: acesso \(granted ? "concedido" : "negado/indisponível")")
        refreshCalendarSuggestion()
    }

    /// Abre Ajustes do Sistema no painel de Calendário (quando o acesso foi negado/restrito).
    func openCalendarSettings() {
        calendarService.openSystemSettings()
    }

    /// Inicia a gravação a partir da reunião sugerida, herdando o título do evento.
    func recordDetectedMeeting() {
        let title = detectedMeeting?.title
        calendarService.dismiss()
        Task { await startMeeting(suggestedTitle: title) }
    }

    /// Called only by the explicit start button, with preparation captured before any audio starts.
    func recordCalendarEvent(_ event: CalendarEvent) async -> Bool {
        guard canStartMeeting else { return false }
        let workspace = meetingWorkspace
        await startMeeting(suggestedTitle: event.title,
                           initialNotes: workspace.scheduledDrafts[event.id]?.notes ?? "",
                           contextSessionIDs: workspace.scheduledDrafts[event.id]?.contextSessionIDs
                            ?? workspace.preparations[event.id]?.selectedSessionIDs)
        guard state == .listening, activeSession != nil else { return false }
        calendarService.dismiss(event)
        return true
    }

    /// Espelha a reunião iminente no countdown do notch ("6m" nas asas). Some quando
    /// não há sugestão, quando o notch está desligado ou quando já estamos gravando.
    private func updateNotchCalendarCountdown(_ meeting: DetectedMeeting?) {
        guard notchOverlayEnabled,
              calendarSuggestionsEnabled,
              let meeting,
              activeSession == nil
        else {
            NotchOverlay.shared.hideCalendarCountdown()
            return
        }
        NotchOverlay.shared.showCalendarCountdown(
            id: meeting.id,
            title: meeting.title,
            startDate: meeting.startDate,
            isInProgress: meeting.isInProgress,
            onRecord: { [weak self] in self?.recordDetectedMeeting() },
            onDismiss: { [weak self] in self?.dismissCalendarSuggestion() }
        )
    }

    /// Esconde a sugestão sem gravar (botão "x").
    func dismissCalendarSuggestion() {
        calendarService.dismiss()
    }

    // MARK: - Detecção de reunião em curso (Teams/Meet/Zoom — card flutuante estilo Granola)

    /// Liga o monitor de apps de reunião e conecta o resultado ao card flutuante.
    private func setupAppDetection(enabled: Bool) {
        appDetectionService.isSelfCapturing = { [weak self] in
            guard let self else { return true }
            switch self.state {
            case .listening, .processing: return true
            default: return AudioCaptureService.activeInstances > 0
            }
        }

        appDetectionService.$detectedApp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                guard let self else { return }
                if let app {
                    self.addDebugLog("Reunião detectada em curso: \(app.appName)")
                    if self.notchOverlayEnabled {
                        // Com o notch ativo, o prompt mora nele — sem card flutuante duplicado.
                        NotchOverlay.shared.showMeetingPrompt(
                            appName: app.appName,
                            onRecord: { [weak self] in self?.recordDetectedApp(app) },
                            onDismiss: { [weak self] in self?.appDetectionService.dismissCurrent() }
                        )
                    } else {
                        MeetingDetectionPanel.shared.show(
                            appName: app.appName,
                            onRecord: { [weak self] in self?.recordDetectedApp(app) },
                            onDismiss: { [weak self] in self?.appDetectionService.dismissCurrent() }
                        )
                    }
                } else {
                    MeetingDetectionPanel.shared.hide()
                    NotchOverlay.shared.hideMeetingPrompt()
                }
            }
            .store(in: &cancellables)

        // Segue o toggle de Ajustes (a tela de Ajustes posta "SettingsChanged" ao editar).
        NotificationCenter.default.publisher(for: NSNotification.Name("SettingsChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let settings = self.settingsStore.load()
                self.appDetectionService.configure(enabled: settings.meetingDetectionEnabled)
                self.notchOverlayEnabled = settings.notchOverlayEnabled
                NotchOverlay.shared.isEnabled = settings.notchOverlayEnabled
                self.refreshCalendarSuggestion()
            }
            .store(in: &cancellables)

        appDetectionService.configure(enabled: enabled)

        // Carga inicial: sem isso o countdown de calendário no notch só funcionaria
        // depois da primeira gravação (que é quando o flag era relido).
        notchOverlayEnabled = settingsStore.load().notchOverlayEnabled
        NotchOverlay.shared.isEnabled = notchOverlayEnabled
    }

    /// Botão "Gravar" do card flutuante: traz o Voiz pra frente, abre Reuniões e grava.
    /// Título: prefere o evento do calendário em curso; senão, nomeia pelo app da chamada.
    private func recordDetectedApp(_ app: DetectedMeetingApp) {
        appDetectionService.markHandled()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Notification.Name("VoizOpenMeetingsTab"), object: nil)
        let title = detectedMeeting?.title ?? "Reunião no \(app.appName)"
        Task { await startMeeting(suggestedTitle: title) }
    }

    func startMeeting(suggestedTitle: String? = nil, initialNotes: String = "", contextSessionIDs: [UUID]? = nil) async {
        guard canStartMeeting else { return }
        let token = UUID()
        meetingStartID = token
        isStartingMeeting = true
        defer {
            if meetingStartID == token { meetingStartID = nil; isStartingMeeting = false }
        }
        guard await VoizAccessStore.shared.prepareNewOperation(kind: .recording, workID: token) else {
            if !Task.isCancelled, meetingStartID == token { statusMessage = VoizAccessStore.shared.lastError ?? String(localized: "Não foi possível autorizar esta operação.") }
            return
        }
        guard !Task.isCancelled, meetingStartID == token, activeSession == nil else { return }

        let microphoneAllowed = await requestMicrophonePermissionIfNeeded()
        guard !Task.isCancelled, meetingStartID == token, activeSession == nil else { return }
        guard microphoneAllowed else {
            state = .error("Permissão de microfone negada.")
            statusMessage = String(localized: "Ative o microfone em Ajustes do Sistema.")
            return
        }

        // Fixa a partir de Ajustes o que não pode mudar no meio da gravação (o auto-detect caindo
        // em inglês, a prévia trocando de idioma, o indicador aparecendo/sumindo).
        let currentSettings = settingsStore.load()
        recordingLanguage = currentSettings.selectedLanguage
        // No modo Granola, a prévia 1s do WhisperKit é desativada porque a transcrição ao vivo
        // já acontece via MeetingLiveTranscriber. No modo Qualidade, ela segue o opt-in.
        livePreviewEnabled = (currentSettings.meetingMode == .granola) ? false : currentSettings.meetingLivePreviewEnabled
        granolaLiveTranscriptionActive = false
        meetingIndicatorEnabled = currentSettings.showRecordingHUD
        notchOverlayEnabled = currentSettings.notchOverlayEnabled
        NotchOverlay.shared.isEnabled = notchOverlayEnabled

        if let teardown = recordingTeardownTask {
            await teardown.value
            recordingTeardownTask = nil
        }

        // O plano do transcript oficial é congelado AGORA, no start, e vai persistido na sessão.
        // É a versão com a decisão inteira do roteador dentro dos três campos que o código legado
        // fixava à mão aqui (engine, modelo Whisper, idioma) — e, por ser persistida, sobrevive ao
        // app fechar no meio do pós-call.
        let planSnapshot = await batchPlanSnapshot(for: currentSettings)
        guard !Task.isCancelled, meetingStartID == token, activeSession == nil else { return }

        guard await authorizeLibraryOperation(kind: .recording, workID: token,
            stillCurrent: { self.meetingStartID == token && self.activeSession == nil }) else { return }

        let template = templateStore.template(withId: selectedTemplateId) ?? templateStore.defaultTemplate
        var session = store.createSession(type: template.sessionType)
        session.notes = initialNotes
        session.contextSessionIDs = contextSessionIDs
        session.templateId = template.id
        session.meetingMode = currentSettings.meetingMode
        session.transcriptionPlan = planSnapshot
        session.isProcessingCompleted = false
        if currentSettings.meetingMode == .granola {
            session.speakers = [
                MeetingSpeaker(source: .microphone, name: String(localized: "Você")),
                MeetingSpeaker(source: .systemAudio, name: String(localized: "Outros na chamada"))
            ]
        }
        if let suggestedTitle = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestedTitle.isEmpty {
            session.title = suggestedTitle
        }
        activeSession = session
        selectedSession = session
        store.save(session)

        lastLiveSaveAtBySession[session.id] = .distantPast
        liveFeed = []
        liveCurrentParagraph = ""
        liveVolatiles = MeetingLiveVolatileState()
        recentSystemLiveUtterances = []
        lastSystemVolatile = nil
        lastMicrophoneVolatile = nil
        liveSuppressedMicFinals = 0
        micVolatileGate.reset()
        livePreviewStablePrefix = ""
        resetLivePreviewHypothesisState()
        liveNotesSaveTask?.cancel()
        liveNotesSaveTask = nil
        liveNotesDraft = session.notes
        meetingPaused = false
        pauseStartedAt = nil
        clearAssist()
        assistQuestion = ""

        // O transcript oficial de qualidade é produzido dos arquivos gravados no pós-call.
        // Não emitir chunks aqui também evita cópias/arrays que seriam descartados.
        captureService.onAudioChunk = nil

        liveSampleCountsBySource = [:]
        let currentSessionId = session.id

        if currentSettings.meetingMode == .granola {
            let locale = MeetingRecordingLifecycle.liveLocale(
                forPlanLanguage: session.transcriptionPlan?.language
            )
            let attempt = await MeetingRecordingLifecycle.attemptLiveStart(
                requested: .granola,
                provider: liveTranscriberProvider,
                locale: locale
            )
            session = MeetingRecordingLifecycle.persistLiveStart(
                to: session,
                attempt: attempt,
                save: { store.save($0) }
            )
            if activeSession?.id == session.id { activeSession = session }
            if selectedSession?.id == session.id { selectedSession = session }

            if let transcriber = attempt.transcriber, let stream = attempt.stream {
                liveTranscriberGeneration += 1
                let generation = liveTranscriberGeneration
                activeTranscriber = transcriber
                granolaLiveTranscriptionActive = true
                liveTranscriptionTask = Task { @MainActor [weak self] in
                    for await event in stream {
                        guard let self else { break }
                        guard self.liveTranscriberGeneration == generation else { break }
                        self.handleLiveTranscriptionEvent(event, forSessionId: currentSessionId)
                    }
                }
            } else {
                activeTranscriber = nil
                granolaLiveTranscriptionActive = false
                addDebugLog("Transcritor indisponível no modo Ao vivo — fallback para modo Qualidade")
            }

            captureService.onPreviewAudio = { [weak self, transcriber = activeTranscriber] source, samples in
                guard let self, let transcriber, self.activeSession?.id == currentSessionId else { return }
                let channel: MeetingLiveAudioChannel = source == .microphone ? .microphone : .systemAudio
                let currentCount = self.liveSampleCountsBySource[source, default: 0]
                let startTime = Double(currentCount) / 16000.0
                self.liveSampleCountsBySource[source] = currentCount + samples.count
                let chunk = MeetingLiveAudioChunk(
                    samples: samples,
                    sampleRate: 16000,
                    startTime: startTime,
                    channel: channel
                )
                Task {
                    await transcriber.feed(chunk)
                }
            }
        } else {
            // Modo Qualidade: prévia ao vivo opt-in com Whisper leve
            captureService.onPreviewAudio = livePreviewEnabled
                ? { [weak livePreviewService] source, samples in
                    livePreviewService?.append(source: source, samples: samples)
                }
                : nil
            livePreviewService.onWindowText = { [weak self] text in
                guard let self else { return }
                // Bloco inteiro NÃO passa por nenhum mecanismo de janela deslizante: nem pelo
                // estabilizador (que tranca a hipótese anterior quando a nova "perde" conteúdo),
                // nem pela costura por sobreposição. Os dois foram escritos para hipóteses que
                // repetem o fim da anterior; um bloco novo legitimamente não compartilha nada com
                // o anterior, e cada um desses mecanismos, sozinho, o duplicava na tela.
                self.liveCurrentParagraph = self.livePreviewService.emitsWholeBlockText
                    ? MeetingPreviewComposer.join(
                        prefix: self.livePreviewStablePrefix,
                        block: text
                    )
                    : Self.mergePreviewWindow(
                        stablePrefix: self.livePreviewStablePrefix,
                        hypothesis: self.stabilizedLivePreviewWindow(text)
                    )
            }
            livePreviewService.onWindowCommitted = { [weak self] text, reason in
                guard let self else { return }
                let combined = self.livePreviewService.emitsWholeBlockText
                    ? MeetingPreviewComposer.join(
                        prefix: self.livePreviewStablePrefix,
                        block: text
                    )
                    : Self.mergePreviewWindow(
                        stablePrefix: self.livePreviewStablePrefix,
                        hypothesis: self.stabilizedLivePreviewWindow(text)
                    )
                self.resetLivePreviewHypothesisState()

                switch reason {
                case .silence:
                    if !combined.isEmpty {
                        self.appendLiveFeed(MeetingLiveFeedEntry(text: combined))
                    }
                    self.livePreviewStablePrefix = ""
                    self.liveCurrentParagraph = ""
                case .windowLimit, .sourceSwitch:
                    self.livePreviewStablePrefix = combined
                    self.liveCurrentParagraph = combined
                }
            }
            livePreviewService.onDeactivated = { [weak self] reason in
                guard let self else { return }
                self.addDebugLog("Prévia ao vivo desligada (\(reason)); o transcript final continua preservado no áudio")
            }
        }

        do {
            let result = try await captureService.startRecording(
                sessionDirectory: store.sessionDirectoryURL(for: session.id),
                store: store
            )
            session.audioFiles = result.audioFiles
            session.systemAudioWarning = result.systemAudioWarning
            activeSession = session
            selectedSession = session
            store.save(session)

            state = .listening
            statusMessage = result.systemAudioWarning == nil
                ? String(localized: "Gravando microfone e áudio do sistema") : String(localized: "Gravando só o microfone")

            if meetingIndicatorEnabled {
                MeetingRecordingIndicator.shared.show(
                    isPaused: false,
                    viewModel: self,
                    onTogglePause: { [weak self] in self?.toggleMeetingPause() },
                    onStop: { [weak self] in self?.toggleRecording() }
                )
            } else {
                MeetingRecordingIndicator.shared.hide()
            }
            NotchOverlay.shared.hideCalendarCountdown()
            if notchOverlayEnabled {
                NotchOverlay.shared.showRecording(
                    onTogglePause: { [weak self] in self?.toggleMeetingPause() },
                    onStop: { [weak self] in self?.toggleRecording() }
                )
                if result.systemAudioWarning != nil {
                    NotchOverlay.shared.showToast(
                        message: String(localized: "Sem áudio do sistema — gravando só o microfone"),
                        symbol: "exclamationmark.triangle.fill",
                        duration: 6
                    )
                }
            } else {
                NotchOverlay.shared.hideRecording()
            }
            addDebugLog("Reunião iniciada: \(session.title)")
            addDebugLog("Transcript final seguirá o plano: \(planSnapshot.logSummary)")
            if let warning = result.systemAudioWarning {
                addDebugLog(warning)
            }

            if livePreviewEnabled {
                await livePreviewService.start(language: recordingLanguage)
                addDebugLog(livePreviewService.isActive
                    ? "Prévia visual do modo Qualidade ativa"
                    : "Prévia ao vivo indisponível — áudio preservado para o transcript final")
            } else {
                livePreviewService.stop()
            }
            lastLiveSaveAtBySession[session.id] = Date()
        } catch {
            MeetingRecordingIndicator.shared.hide()
            NotchOverlay.shared.hideRecording()
            if MeetingRecordingLifecycle.mustTeardownLiveCycleAfterCaptureFailure(
                liveTranscriberStarted: activeTranscriber != nil
            ) {
                let failedId = session.id
                let transcriber = activeTranscriber
                let consumer = liveTranscriptionTask
                let generation = liveTranscriberGeneration
                captureService.onPreviewAudio = nil
                let teardown = Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.captureService.stopRecording()
                    await self.finishLiveConsumer(
                        transcriber: transcriber,
                        consumer: consumer,
                        generation: generation,
                        persistRemainingTo: failedId
                    )
                }
                recordingTeardownTask = teardown
                await teardown.value
            }
            activeTranscriber = nil
            granolaLiveTranscriptionActive = false
            liveTranscriptionTask = nil
            activeSession = nil
            state = .error(error.localizedDescription)
            statusMessage = String(localized: "Falha ao iniciar reunião")
            addDebugLog("Erro ao iniciar reunião: \(error.localizedDescription)")
        }
    }

    private func handleLiveTranscriptionEvent(_ event: MeetingLiveTranscriptionEvent, forSessionId expectedSessionId: UUID) {
        switch event {
        case .volatile(let text, let channel, let window):
            if activeSession?.id == expectedSessionId {
                var next = liveVolatiles
                next.apply(text: text, channel: channel)
                liveVolatiles = next
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if channel == .systemAudio {
                        lastSystemVolatile = nil
                    } else {
                        lastMicrophoneVolatile = nil
                    }
                } else {
                    let utterance = MeetingEchoTextMatch.Utterance(
                        text: trimmed,
                        startTime: window.startTime,
                        endTime: window.endTime
                    )
                    if channel == .systemAudio {
                        lastSystemVolatile = utterance
                    } else {
                        lastMicrophoneVolatile = utterance
                    }
                }
                refreshMicVolatileGate(clock: window.endTime)
            }
        case .final(let text, let channel, let window):
            persistLiveFinal(
                text: text,
                channel: channel,
                window: window,
                sessionId: expectedSessionId,
                updateLiveFeed: activeSession?.id == expectedSessionId
            )
        case .channelFailed(let channel, let failure):
            addDebugLog("Canal \(channel.rawValue) falhou: \(failure)")
        }
    }

    /// Persiste um `.final` na sessão pedida por ID. Vale com `activeSession` ainda viva
    /// e no intervalo em que ela já foi desocupada (teardown) — o consumo do stream
    /// continua até o `stop()` drenar.
    @discardableResult
    private func persistLiveFinal(
        text: String,
        channel: MeetingLiveAudioChannel,
        window: MeetingLiveCaptureWindow,
        sessionId: UUID,
        updateLiveFeed: Bool
    ) -> Bool {
        guard var session = sessionForEditing(id: sessionId) else { return false }
        let speakerName = session.speakerName(
            for: channel == .microphone ? .microphone : .systemAudio
        )
        guard let draft = MeetingRecordingLifecycle.draftFromLiveFinal(
            text: text,
            channel: channel,
            window: window,
            speakerName: speakerName
        ) else { return false }

        // WYSIWYG Granola: supressão errada aqui é perda definitiva do turn.
        // Por isso o julgamento textual é o mais estrito que existe — igualdade
        // BIDIRECIONAL das sequências de tokens, com acento preservado (ver
        // `MeetingEchoTextMatch.textIsEcho`). Só eco literal é suprimido; toda
        // divergência de ASR duplica, que é o lado seguro do erro.
        // Vale nos dois caminhos (updateLiveFeed true/false) — o hangup também
        // passa por aqui.
        if channel == .microphone,
           MeetingEchoTextMatch.shouldSuppressMicDisplay(
               micText: draft.text,
               micStart: window.startTime,
               micEnd: window.endTime,
               systemUtterances: liveSystemEchoCandidates(at: window.endTime)
           ) {
            liveSuppressedMicFinals += 1
            addDebugLog(TranscriptionLogRedaction.meetingLiveEchoSuppressed(liveSuppressedMicFinals))
            if updateLiveFeed {
                var next = liveVolatiles
                next.clear(.microphone)
                liveVolatiles = next
            }
            micVolatileGate.reset()
            return false
        }

        let turn = MeetingTurn(
            source: draft.source,
            speakerName: draft.speakerName,
            text: draft.text,
            startTime: draft.startTime,
            endTime: draft.endTime,
            confidence: 1.0,
            provenance: nil
        )
        merge(turn: turn, into: &session)
        updateSession(session)
        if channel == .systemAudio {
            rememberSystemLiveUtterance(
                MeetingEchoTextMatch.Utterance(
                    text: turn.text,
                    startTime: window.startTime,
                    endTime: window.endTime
                )
            )
            refreshMicVolatileGate(clock: window.endTime)
        } else {
            micVolatileGate.reset()
        }
        if updateLiveFeed {
            appendLiveFeed(
                MeetingLiveFeedEntry(
                    text: turn.text,
                    channel: channel,
                    startTime: window.startTime
                )
            )
            var next = liveVolatiles
            next.clear(channel)
            liveVolatiles = next
        }
        return true
    }

    private func rememberSystemLiveUtterance(_ utterance: MeetingEchoTextMatch.Utterance) {
        recentSystemLiveUtterances.append(utterance)
        let cutoff = utterance.startTime - 15
        recentSystemLiveUtterances.removeAll { $0.endTime < cutoff }
        if recentSystemLiveUtterances.count > 24 {
            recentSystemLiveUtterances.removeFirst(recentSystemLiveUtterances.count - 24)
        }
    }

    private func liveSystemEchoCandidates(at clock: TimeInterval) -> [MeetingEchoTextMatch.Utterance] {
        MeetingEchoTextMatch.echoCandidates(
            finals: recentSystemLiveUtterances,
            currentVolatileText: liveVolatiles.systemAudio,
            currentVolatileWindow: lastSystemVolatile,
            captureClock: clock
        )
    }

    private func appendLiveFeed(_ entry: MeetingLiveFeedEntry) {
        liveFeed = MeetingLiveFeedEntry.inserting(entry, into: liveFeed)
    }

    private func refreshMicVolatileGate(clock: TimeInterval) {
        let window = lastMicrophoneVolatile
        micVolatileGate.apply(
            micText: liveVolatiles.microphone,
            micStart: window?.startTime ?? clock,
            micEnd: window?.endTime ?? clock,
            clock: clock,
            systemUtterances: liveSystemEchoCandidates(at: clock)
        )
    }

    func stopMeeting() async {
        guard var session = activeSession, state == .listening else { return }

        var pausedDurationFloor: TimeInterval? = nil
        if meetingPaused {
            if let started = pauseStartedAt {
                let delta = max(0, Date().timeIntervalSince(started))
                session.pausedDuration = (session.pausedDuration ?? 0) + delta
                pausedDurationFloor = session.pausedDuration
            }
            pauseStartedAt = nil
            meetingPaused = false
        }
        liveNotesSaveTask?.cancel()
        liveNotesSaveTask = nil
        let pendingNotes = session.notes != liveNotesDraft ? liveNotesDraft : nil
        if let pendingNotes {
            session.notes = pendingNotes
        }
        store.save(session)

        let stoppedSessionId = session.id
        let stoppingTranscriber = activeTranscriber
        let stoppingTask = liveTranscriptionTask
        let stoppingGeneration = liveTranscriberGeneration

        // Síncrono, antes de qualquer await: a UI libera. O consumo do stream
        // (stoppingTask) continua até o drain do stop() — finais no intervalo
        // entram por ID em persistLiveFinal.
        activeSession = nil
        activeTranscriber = nil
        granolaLiveTranscriptionActive = false
        captureService.onPreviewAudio = nil
        state = .idle
        statusMessage = String(localized: "Reunião salva")

        MeetingRecordingIndicator.shared.hide()
        NotchOverlay.shared.hideRecording()

        livePreviewService.stop()
        if !liveCurrentParagraph.isEmpty {
            appendLiveFeed(MeetingLiveFeedEntry(text: liveCurrentParagraph))
            liveCurrentParagraph = ""
        }
        if !liveVolatiles.microphone.isEmpty {
            appendLiveFeed(
                MeetingLiveFeedEntry(
                    text: liveVolatiles.microphone,
                    channel: .microphone,
                    startTime: lastMicrophoneVolatile?.startTime
                )
            )
        }
        if !liveVolatiles.systemAudio.isEmpty {
            appendLiveFeed(
                MeetingLiveFeedEntry(
                    text: liveVolatiles.systemAudio,
                    channel: .systemAudio,
                    startTime: lastSystemVolatile?.startTime
                )
            )
        }
        liveVolatiles = MeetingLiveVolatileState()
        livePreviewStablePrefix = ""
        resetLivePreviewHypothesisState()

        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.captureService.stopRecording()
            await self.finishLiveConsumer(
                transcriber: stoppingTranscriber,
                consumer: stoppingTask,
                generation: stoppingGeneration,
                persistRemainingTo: stoppedSessionId
            )
        }
        recordingTeardownTask = teardownTask
        await teardownTask.value
        liveTranscriptionTask = nil

        guard var stoppingSession = sessionForEditing(id: stoppedSessionId) else { return }
        stoppingSession = MeetingRecordingLifecycle.mergeStopDeltas(
            onto: stoppingSession,
            notes: pendingNotes,
            pausedDurationFloor: pausedDurationFloor
        )
        stoppingSession.endedAt = Date()
        stoppingSession.isProcessingCompleted = false
        updateSession(stoppingSession)

        enqueuePostProcessing(for: stoppedSessionId)
    }

    /// `stop()` do protocolo não reemite finais já publicados no stream. Sem
    /// `await consumer.value` esses itens bufferizados somem antes do pós.
    /// Se a geração mudou, só cancela+aguarda — não chama stop no objeto da sessão B.
    private func finishLiveConsumer(
        transcriber: (any MeetingLiveTranscriber)?,
        consumer: Task<Void, Never>?,
        generation: Int,
        persistRemainingTo sessionId: UUID
    ) async {
        if let transcriber,
           MeetingRecordingLifecycle.shouldStopLiveTranscriber(
               stoppingGeneration: generation,
               currentGeneration: liveTranscriberGeneration
           ) {
            let remainingEvents = await transcriber.stop()
            // System primeiro: o julgamento do mic no hangup precisa dos finais
            // do outro canal já no buffer, senão o preview e o persist divergem.
            for event in remainingEvents {
                if case .final(let text, .systemAudio, let window) = event {
                    persistLiveFinal(
                        text: text,
                        channel: .systemAudio,
                        window: window,
                        sessionId: sessionId,
                        updateLiveFeed: false
                    )
                }
            }
            for event in remainingEvents {
                if case .final(let text, .microphone, let window) = event {
                    persistLiveFinal(
                        text: text,
                        channel: .microphone,
                        window: window,
                        sessionId: sessionId,
                        updateLiveFeed: false
                    )
                }
            }
        } else {
            consumer?.cancel()
        }
        if let consumer {
            _ = await consumer.value
        }
    }

    /// Executa a diarização e identificação de participantes sob demanda para uma sessão gravada.
    func diarizeSession(_ session: MeetingSession) {
        guard !isProcessing(session), hasRecordedAudio(session) else { return }
        withAvailableSession(session.id) { target in
            guard !self.isProcessing(target), self.hasRecordedAudio(target) else { return }
            self.processingSessionIDs.insert(target.id)
            defer { self.processingSessionIDs.remove(target.id) }
            var copy = target
            await self.diarizeAndName(&copy)
            self.applyDiarizationDelta(copy, before: target.speakers, sessionId: target.id)
        }
    }

    /// Executa a reconciliação de eco sob demanda para uma sessão gravada.
    func reconcileEchoForSession(_ session: MeetingSession) {
        guard !isProcessing(session), hasRecordedAudio(session) else { return }
        withAvailableSession(session.id) { target in
            guard MeetingRecordingLifecycle.showsRemoveEchoAction(mode: target.meetingMode, turnCount: target.turns.count),
                  !self.isProcessing(target), self.hasRecordedAudio(target) else { return }
            self.processingSessionIDs.insert(target.id)
            defer { self.processingSessionIDs.remove(target.id) }
            let updated = await self.reconcileEcho(target)
            self.applyEchoReconciliationDelta(updated, sessionId: target.id)
        }
    }

    func selectSession(_ session: MeetingSession) {
        guard activeSession == nil else { return }
        selectedSession = session
    }

    func setNotesIncluded(_ included: Bool, sessionID: UUID) {
        VoizEditingGate.shared.submit { [self] in
            guard var session = sessionForEditing(id: sessionID) else { return }
            session.includeNotesInSummary = included
            updateSession(session)
        }
    }

    func setContextSessions(_ ids: Set<UUID>) {
        guard var session = activeSession else { return }
        session.contextSessionIDs = Array(ids.prefix(8))
        updateSession(session)
    }

    func updateTask(_ item: MeetingActionItem, sessionID: UUID, sectionID: String) {
        VoizEditingGate.shared.submit { [self] in
            guard var session = sessionForEditing(id: sessionID), var summary = session.summary,
                  let sectionIndex = summary.sections.firstIndex(where: { $0.id == sectionID }),
                  let itemIndex = summary.sections[sectionIndex].actionItems.firstIndex(where: { $0.id == item.id }) else { return }
            var edited = item
            let existing = summary.sections[sectionIndex].actionItems[itemIndex]
            edited.done = existing.done
            edited.followed = existing.followed
            if existing.text != item.text || existing.assignee != item.assignee || existing.dueDate != item.dueDate {
                summary.sections[sectionIndex].evidence?.removeAll { $0.itemIndex == itemIndex }
            }
            summary.sections[sectionIndex].actionItems[itemIndex] = edited
            session.summary = summary
            updateSession(session)
        }
    }

    func updateNotes(_ notes: String, sessionID: UUID? = nil) {
        guard var session = sessionID.flatMap({ sessionForEditing(id: $0) }) ?? activeSession ?? selectedSession else { return }
        session.notes = notes
        updateSession(session)
    }

    func updateLiveNotesDraft(_ notes: String) {
        guard state == .listening else { return }
        liveNotesDraft = notes
        liveNotesSaveTask?.cancel()
        liveNotesSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.liveNotesSaveDelay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, self.liveNotesDraft == notes else { return }
            self.persistLiveNotesDraft()
        }
    }

    private func persistLiveNotesDraft() {
        liveNotesSaveTask?.cancel()
        liveNotesSaveTask = nil
        guard var session = activeSession, session.notes != liveNotesDraft else { return }
        session.notes = liveNotesDraft
        updateSession(session)
    }

    func updateSpeakerName(source: MeetingCaptureSource, name: String) {
        VoizEditingGate.shared.submit { [self] in
            guard var session = activeSession ?? selectedSession else { return }
            if let index = session.speakers.firstIndex(where: { $0.source == source }) {
                session.speakers[index].name = name
            } else {
                session.speakers.append(MeetingSpeaker(source: source, name: name))
            }

            for index in session.turns.indices where session.turns[index].source == source {
                session.turns[index].speakerName = name
            }

            updateSession(session)
        }
    }

    func retrySummary(for session: MeetingSession) {
        withAvailableSession(session.id) { target in
            await self.generateSummary(for: target)
        }
    }

    /// Troca o template da sessão e regenera o resumo (usado na revisão).
    func regenerateSummary(for session: MeetingSession, templateId: String) {
        guard !generatingSummarySessionIDs.contains(session.id) else { return }
        withAvailableSession(session.id) { target in
            guard !self.generatingSummarySessionIDs.contains(target.id) else { return }
            var updated = target
            updated.templateId = templateId
            if let template = self.templateStore.template(withId: templateId) {
                updated.sessionType = template.sessionType
            }
            self.updateSession(updated)
            await self.generateSummary(for: updated)
        }
    }

    /// true se a sessão está sendo processada ou aguarda na fila de pós-processamento.
    func isProcessing(_ session: MeetingSession) -> Bool {
        processingSessionIDs.contains(session.id)
    }

    /// true enquanto ESTA sessão está sendo retranscrita fora de uma gravação ativa.
    func isReprocessingTranscript(_ session: MeetingSession) -> Bool {
        isProcessing(session)
    }

    /// Sessão encerrada sem conclusão do pós-processamento mas com áudio em disco (interrompida
    /// por app fechado/crash no meio). A UI oferece "Reprocessar transcript".
    func needsTranscriptRecovery(_ session: MeetingSession) -> Bool {
        guard !isProcessing(session) else { return false }
        guard hasRecordedAudio(session) else { return false }
        if session.isProcessingCompleted == false { return true }
        if session.endedAt == nil { return true }
        return session.turns.isEmpty && !(session.summary?.hasContent ?? false)
    }

    /// Progresso mensurável da transcrição pós-call (0...1) para uma sessão específica.
    /// Devolve nil se a sessão não estiver sendo processada ativamente pelo worker no momento.
    func postProcessingProgress(for session: MeetingSession) -> Double? {
        currentProcessingSessionID == session.id ? postProcessingProgress : nil
    }

    /// Mensagem de status escopada por sessão para a interface de revisão.
    func processingStatusMessage(for session: MeetingSession) -> String {
        if currentProcessingSessionID == session.id {
            if isGeneratingSummary {
                return String(localized: "Gerando resumo…")
            }
            return String(localized: "Processando…")
        } else if postProcessingQueue.contains(session.id) {
            return String(localized: "Na fila de processamento…")
        } else {
            return String(localized: "Reunião salva")
        }
    }

    func hasRecordedAudio(_ session: MeetingSession) -> Bool {
        let directory = store.sessionDirectoryURL(for: session.id)
        return session.audioFiles.contains { _, fileName in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    /// Reconstrói o transcript oficial a partir dos .caf da sessão, rodando o mesmo
    /// pipeline do fim de gravação (transcrição → diarização → eco → resumo). Cobre o
    /// pós-call interrompido; como usa os Ajustes atuais, também serve para retranscrever
    /// com outro modelo. O áudio original nunca é alterado.
    func reprocessTranscript(for session: MeetingSession) {
        guard activeSession == nil, !isProcessing(session), hasRecordedAudio(session) else { return }
        withAvailableSession(session.id) { target in
            guard self.activeSession == nil, !self.isProcessing(target), self.hasRecordedAudio(target) else { return }
            let currentSettings = self.settingsStore.load()
            let snapshot = await self.batchPlanSnapshot(for: currentSettings)
            guard !Task.isCancelled, self.activeSession == nil,
                  var current = self.sessionForEditing(id: target.id), !self.isProcessing(current) else { return }
            self.recordingLanguage = currentSettings.selectedLanguage
            self.selectedSession = current
            self.lastLiveSaveAtBySession[current.id] = .distantPast
            current = MeetingRecordingLifecycle.markingReprocessStarted(current)
            current.transcriptionPlan = snapshot
            self.updateSession(current)
            self.addDebugLog("Reprocessando com o plano atual: \(snapshot.logSummary)")
            self.enqueuePostProcessing(for: current.id, manualReprocess: true)
        }
    }

    /// Parte do fluxo de resumo; aplica só o resultado sobre a versão mais recente da sessão.
    private func generateChapters(for session: MeetingSession, settings: AppSettings) async -> Bool {
        guard !session.turns.isEmpty else { return true }
        guard generatingChapterSessionIDs.insert(session.id).inserted else { return true }
        defer { generatingChapterSessionIDs.remove(session.id) }
        do {
            let verified = try await settingsForMeetingAI(resource: .chapters, preferences: settings)
            let service = MeetingChaptersService(settings: verified)
            let chapters = try await service.chapters(for: session)
            guard !Task.isCancelled else { return false }
            guard var fresh = sessionForEditing(id: session.id), fresh.turns == session.turns else { return true }
            fresh.chapters = chapters
            fresh.chaptersError = chapters.isEmpty ? String(localized: "Não foi possível gerar capítulos.") : nil
            guard updateSession(fresh) else { throw CocoaError(.fileWriteUnknown) }

            addDebugLog("Capítulos: \(chapters.count)")
        } catch {
            if Task.isCancelled || error is CancellationError { return false }
            if error is SettingsCredentialError {
                statusMessage = SettingsCredentialError.unavailable.localizedDescription
                return false
            }
            if var fresh = sessionForEditing(id: session.id), fresh.turns == session.turns {
                fresh.chaptersError = String(localized: "Não foi possível gerar capítulos.")
                updateSession(fresh)
            }
            addDebugLog(
                TranscriptionLogRedaction.meetingAssistantFailed(
                    kind: "Capítulos",
                    detail: error.localizedDescription
                )
            )
        }
        return true
    }

    func setActionItemFollowed(_ followed: Bool, sessionId: UUID, sectionId: String, itemId: UUID) {
        VoizEditingGate.shared.submit { [self] in
            guard var session = sessionForEditing(id: sessionId), var summary = session.summary,
                  let sectionIndex = summary.sections.firstIndex(where: { $0.id == sectionId }),
                  let itemIndex = summary.sections[sectionIndex].actionItems.firstIndex(where: { $0.id == itemId }) else { return }
            summary.sections[sectionIndex].actionItems[itemIndex].followed = followed
            session.summary = summary
            updateSession(session)
        }
    }

    /// Marca/desmarca um action item de uma seção do resumo e persiste.
    func setActionItemDone(_ done: Bool, sessionId: UUID, sectionId: String, itemId: UUID) {
        VoizEditingGate.shared.submit { [self] in
            guard var session = sessionForEditing(id: sessionId), var summary = session.summary else { return }
            guard let sectionIndex = summary.sections.firstIndex(where: { $0.id == sectionId }),
                  let itemIndex = summary.sections[sectionIndex].actionItems.firstIndex(where: { $0.id == itemId }) else { return }
            summary.sections[sectionIndex].actionItems[itemIndex].done = done
            session.summary = summary
            updateSession(session)
        }
    }

    private func sessionForEditing(id: UUID) -> MeetingSession? {
        if let active = activeSession, active.id == id { return active }
        return store.sessions.first(where: { $0.id == id }) ?? (selectedSession?.id == id ? selectedSession : nil)
    }

    func deleteSelectedSession() {
        guard let session = selectedSession, activeSession == nil else { return }
        deleteSession(session)
    }

    /// Apaga uma sessão específica da lista (não permite apagar a gravação ativa).
    func deleteSession(_ session: MeetingSession) {
        VoizEditingGate.shared.submit { [self] in
            guard activeSession?.id != session.id else { return }
            sessionOperationRequests[session.id] = nil
            postProcessingQueue.removeAll { $0 == session.id }
            processingSessionIDs.remove(session.id)
            manualReprocessSessionIDs.remove(session.id)
            MeetingRecordingLifecycle.releasingPostProcessing(session.id, inFlight: &Self.postProcessingInFlight)
            lastLiveSaveAtBySession.removeValue(forKey: session.id)
            store.delete(session)
            if selectedSession?.id == session.id {
                selectedSession = store.sessions.first
            }
        }
    }

    // MARK: - Pastas

    /// Cria uma pasta (nome vazio é ignorado).
    func createFolder(name: String, details: String) {
        VoizEditingGate.shared.submit { [self] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            store.createFolder(name: trimmed, details: details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Atualiza nome/descrição de uma pasta (nome vazio é ignorado).
    func updateFolder(_ folder: MeetingFolder, name: String, details: String) {
        VoizEditingGate.shared.submit { [self] in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var updated = folder
            updated.name = trimmed
            updated.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateFolder(updated, basedOn: folder)
        }
    }

    /// Apaga a pasta; as reuniões dela ficam sem pasta (nada é perdido).
    func deleteFolder(_ folder: MeetingFolder) {
        VoizEditingGate.shared.submit { [self] in
            if viewingFolderId == folder.id {
                viewingFolderId = nil
            }
            store.deleteFolder(folder)
        }
    }

    /// Move a sessão para uma pasta (nil = remover da pasta).
    func moveSession(_ session: MeetingSession, toFolderId folderId: UUID?) {
        VoizEditingGate.shared.submit { [self] in
            guard session.folderId != folderId else { return }
            var updated = sessionForEditing(id: session.id) ?? session
            updated.folderId = folderId
            updateSession(updated)
        }
    }

    /// Nome da pasta da sessão, para exibir como grupo na lista de recentes.
    func folderName(for session: MeetingSession) -> String? {
        store.folder(withId: session.folderId)?.name
    }

    /// Sessões de uma pasta, já na ordem do store (mais recente primeiro).
    func sessions(inFolder folderId: UUID) -> [MeetingSession] {
        sessions.filter { $0.folderId == folderId }
    }

    /// Renomeia uma sessão (nome vazio é ignorado).
    func renameSession(_ session: MeetingSession, to title: String) {
        VoizEditingGate.shared.submit { [self] in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var updated = sessionForEditing(id: session.id) ?? session
            updated.title = trimmed
            updateSession(updated)
        }
    }

    /// Renomeia um falante (participante diarizado ou "Você") e propaga o nome pros turns.
    func renameSpeaker(_ speaker: MeetingSpeaker, to name: String) {
        VoizEditingGate.shared.submit { [self] in
            guard var session = activeSession ?? selectedSession else { return }
            session.renameSpeaker(id: speaker.id, to: name)
            updateSession(session)
        }
    }

    private func setupBindings() {
        NotificationCenter.default.publisher(for: NSNotification.Name("SettingsChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settingsStore.credentialsAreReady else { return }
                self.startPostProcessingQueueWorkerIfNeeded()
            }
            .store(in: &cancellables)

        captureService.$microphoneLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$microphoneLevel)

        captureService.$systemAudioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$systemAudioLevel)

        Publishers.CombineLatest(
            captureService.$microphoneLevel,
            captureService.$systemAudioLevel
        )
        .receive(on: DispatchQueue.main)
        .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] microphone, system in
            guard let self,
                  self.state == .listening,
                  !self.meetingPaused
            else { return }
            if self.meetingIndicatorEnabled {
                MeetingRecordingIndicator.shared.update(
                    microphoneLevel: microphone,
                    systemAudioLevel: system
                )
            }
            if self.notchOverlayEnabled {
                NotchOverlay.shared.updateLevels(
                    microphoneLevel: microphone,
                    systemAudioLevel: system
                )
            }
        }
        .store(in: &cancellables)

        // Alimenta o painel expandido do notch com a cauda da prévia ao vivo. Só os
        // últimos ~320 caracteres importam: a view trunca o início, então o texto
        // "rola" acompanhando a fala.
        Publishers.CombineLatest3($liveFeed, $liveCurrentParagraph, $liveVolatiles)
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] feed, current, volatiles in
                guard let self, self.notchOverlayEnabled, self.state == .listening else { return }
                var pieces = feed.suffix(2).map(\.text)
                pieces.append(contentsOf: MeetingRecordingLifecycle.liveOpenPreviewPieces(
                    currentParagraph: current,
                    displayedMicrophoneVolatile: self.displayedMicrophoneVolatile,
                    systemVolatile: volatiles.systemAudio
                ))
                let joined = pieces.joined(separator: " ")
                NotchOverlay.shared.updateLivePreview(tail: String(joined.suffix(320)))
            }
            .store(in: &cancellables)

        calendarService.$detectedMeeting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meeting in
                guard let self else { return }
                self.detectedMeeting = meeting
                self.updateNotchCalendarCountdown(meeting)
            }
            .store(in: &cancellables)

        calendarService.$upcomingEvents
            .receive(on: DispatchQueue.main)
            .assign(to: &$upcomingEvents)

        calendarService.$authorizationStatus
            .map { $0 == .fullAccess }
            .receive(on: DispatchQueue.main)
            .assign(to: &$calendarAuthorized)

        calendarService.$authorizationStatus
            .map { $0 == .denied || $0 == .restricted }
            .receive(on: DispatchQueue.main)
            .assign(to: &$calendarAccessBlocked)

        store.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.sessions = sessions
            }
            .store(in: &cancellables)

        store.$folders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] folders in
                self?.folders = folders
            }
            .store(in: &cancellables)
    }

    // MARK: - Pós-processamento em segundo plano (Fila de 1)

    /// Enfileira uma sessão para pós-processamento de fundo (transcrição → diarização → eco → resumo).
    ///
    /// ## Fila de 1 (serial) e Proteção de Concorrência
    ///
    /// O pós-processamento roda em segundo plano sem travar a interface nem impedir novas gravações.
    /// Para não sobrecarregar ANE/GPU com múltiplos pós-processamentos concorrentes (regra de
    /// performance: inferências pesadas não competem), a fila é estritamente sequencial (1 de cada vez).
    /// O pós-processamento usa a vaga não-interativa do coordenador (`useCase: .meetingFinal`), onde
    /// a cota de justiça 3:1 já protege os fluxos interativos (ditado e tradução ao vivo).
    private func enqueuePostProcessing(for sessionId: UUID, manualReprocess: Bool = false) {
        // Entrada nova nesta instância exige a reserva do processo. Se outra instância já
        // segura a sessão, esta desiste — nada de estado local, nada de worker.
        let knownLocally = postProcessingQueue.contains(sessionId) || currentProcessingSessionID == sessionId
        if !knownLocally,
           !MeetingRecordingLifecycle.claimingPostProcessing(sessionId, inFlight: &Self.postProcessingInFlight) {
            return
        }
        if manualReprocess {
            manualReprocessSessionIDs.insert(sessionId)
        }
        processingSessionIDs.insert(sessionId)
        _ = MeetingRecordingLifecycle.admittingToPostProcessing(
            sessionId,
            queue: &postProcessingQueue,
            current: currentProcessingSessionID
        )
        startPostProcessingQueueWorkerIfNeeded()
    }

    private func startPostProcessingQueueWorkerIfNeeded() {
        guard postProcessingTask == nil, !postProcessingQueue.isEmpty else { return }
        postProcessingTask = Task { @MainActor [weak self] in
            while let self = self {
                guard !self.postProcessingQueue.isEmpty else { break }
                let processed = await MeetingCredentialRecoveryGate.runNext(
                    loadCredentials: {
                        self.postProcessingWaitingForCredentials = false
                        let ready = await self.settingsStore.loadCredentialsForWork()
                        self.postProcessingWaitingForCredentials = !ready
                        return ready
                    },
                    takeNext: {
                        self.postProcessingWaitingForCredentials = false
                        return self.postProcessingQueue.isEmpty ? nil : self.postProcessingQueue.removeFirst()
                    },
                    process: { sessionId in
                        self.currentProcessingSessionID = sessionId
                        let completed = await self.runPostProcessing(for: sessionId)
                        if !completed {
                            self.currentProcessingSessionID = nil
                            self.postProcessingQueue.insert(sessionId, at: 0)
                            self.postProcessingWaitingForCredentials = true
                            return
                        }
                        self.processingSessionIDs.remove(sessionId)
                        self.currentProcessingSessionID = nil
                        MeetingRecordingLifecycle.releasingPostProcessing(
                            sessionId, inFlight: &Self.postProcessingInFlight
                        )
                    }
                )
                if !processed || self.postProcessingWaitingForCredentials { break }
            }
            self?.postProcessingTask = nil
            // A successful settings retry may have notified while this worker was still
            // awaiting its failed read. Do not lose that wakeup or retry a failed vault in a loop.
            if !Task.isCancelled, let self, self.settingsStore.credentialsAreReady {
                self.startPostProcessingQueueWorkerIfNeeded()
            }
        }
    }

    /// Executa o pipeline de pós-processamento completo de uma sessão encerrada.
    ///
    /// Opera exclusivamente por ID através de `sessionForEditing(id:)` e `updateSession(_:)`, de modo
    /// que uma nova reunião ativa (`activeSession`) ou edições de notas pelo usuário nunca sejam
    /// sobrescritas.
    private func runPostProcessing(for sessionId: UUID) async -> Bool {
        guard let session = sessionForEditing(id: sessionId) else { return true }

        let isManualReprocess = MeetingRecordingLifecycle.consumeManualReprocessIntent(
            session: session,
            inMemoryIDs: &manualReprocessSessionIDs
        )
        switch MeetingRecordingLifecycle.granolaPostCallWork(
            mode: session.meetingMode,
            turnCount: session.turns.count,
            isManualReprocess: isManualReprocess
        ) {
        case .liveTranscriptThenSummary:
            // WYSIWYG: o preview ao vivo já é o transcript final. Sem eco pós-call.
            if let current = sessionForEditing(id: sessionId) {
                guard await generateSummary(for: current) else { return false }
            }
            if var fresh = sessionForEditing(id: sessionId) {
                fresh = MeetingRecordingLifecycle.finishing(fresh, after: .succeeded)
                updateSession(fresh)
            }
            if activeSession == nil {
                statusMessage = String(localized: "Reunião salva")
            }
            return true
        case .fullBatchPipeline:
            break
        }

        // Modo Qualidade (ou Fallback do Granola com 0 turnos): pipeline completo
        //
        // A ORDEM é a feature (O2). A diarização vem PRIMEIRO — custa 13 s para
        // 79 min e roda UMA vez — e o mesmo resultado alimenta duas coisas: os
        // cortes de lote da transcrição e a atribuição de falante depois. Com a
        // ordem antiga (transcrever → diarizar) a fronteira do lote nunca caía
        // na troca de falante, e pergunta e resposta viravam um bloco só do
        // dominante.
        // 1. Diarização (Camada 1) — as trocas de falante viram cortes
        let diarizedSegments = await diarizeSystemAudio(for: sessionId)
        let speakerBoundaries = DiarizationBatchCuts.batchBoundaries(
            from: diarizedSegments
        )
        if !speakerBoundaries.isEmpty {
            addDebugLog("Cortes de lote pela diarização: \(speakerBoundaries.count)")
        }

        // 2. Transcrição dos lotes de áudio (.caf), cortados na troca de falante
        let outcome = await transcribeRecordedAudio(
            sessionId: sessionId,
            speakerBoundaries: speakerBoundaries
        )

        // 3. Atribuição de falante (com os lotes já de um falante só) e nomes
        if !diarizedSegments.isEmpty, let session = sessionForEditing(id: sessionId) {
            var copy = session
            applyDiarization(to: &copy, segments: diarizedSegments)
            guard await nameParticipants(&copy) else { return false }
            applyDiarizationDelta(copy, before: session.speakers, sessionId: sessionId)
        }

        // 4. Reconciliação de eco acústico
        if let session = sessionForEditing(id: sessionId) {
            let reconciled = await reconcileEcho(session)
            applyEchoReconciliationDelta(reconciled, sessionId: sessionId)
        }

        // 5. Geração do resumo com IA
        if let session = sessionForEditing(id: sessionId) {
            guard await generateSummary(for: session) else { return false }
        }

        // 6. Marca o pós-processamento como concluído. Sucesso, plano vazio e
        // falha de lote são todos TÉRMINOS: a flag manual sai pelos três ramos,
        // e é `finishing` que decide isso — não uma linha solta por ramo.
        if var fresh = sessionForEditing(id: sessionId) {
            fresh = MeetingRecordingLifecycle.finishing(fresh, after: outcome)
            updateSession(fresh)
        }

        if activeSession == nil {
            statusMessage = String(localized: "Reunião salva")
        }
        return true
    }

    /// Constrói o transcript oficial somente depois que a captura terminou. Cada leitor
    /// mantém no máximo um lote de ~28s em memória; os dois canais são intercalados por
    /// timestamp para preservar a mesma ordem temporal usada pelos turns e pela diarização.
    ///
    /// Opera por id (via `sessionForEditing`) em vez de exigir `activeSession`: o mesmo
    /// caminho serve o fim de gravação e o reprocessamento de uma sessão já encerrada.
    private func transcribeRecordedAudio(
        sessionId: UUID,
        speakerBoundaries: [TimeInterval] = []
    ) async -> MeetingRecordingLifecycle.PostCallOutcome {
        guard let initial = sessionForEditing(id: sessionId) else { return .batchFailed }

        // O plano dos lotes: o snapshot da sessão manda. Uma mudança nos Ajustes durante a call (ou
        // depois dela, com o pós-call retomado noutro dia) não troca o motor no meio do transcript
        // — é a mesma garantia do `configure(modelName:)` legado, agora sobre a decisão inteira do
        // roteador e persistida.
        let settings = settingsStore.load()
        let snapshot: TranscriptionPlanSnapshot
        var storedPlanIsUsable = false
        if let stored = initial.transcriptionPlan, MeetingTranscription.batchPlan(from: stored) != nil {
            let use = MeetingTranscription.preparingStoredPlan(
                stored,
                selectedLanguage: settings.selectedLanguage
            )
            switch use {
            case .usable(let prepared, _):
                snapshot = prepared
                storedPlanIsUsable = true
                // One-shot: origem resolvida no disco antes de qualquer await
                // desta passagem. persistPlanIfCorrected só grava isCorrected.
                if let originFresh = sessionForEditing(id: sessionId),
                   let fresh = MeetingTranscription.persistingResolvedOrigin(use, on: originFresh) {
                    updateSession(fresh)
                }
            case .unusable:
                snapshot = await batchPlanSnapshot(for: settings)
                storedPlanIsUsable = false
                addDebugLog(
                    "Plano gravado ilegível — refeito com os Ajustes atuais: \(snapshot.logSummary)"
                )
            }
        } else {
            let hadUnusablePlan = initial.transcriptionPlan != nil
            snapshot = await batchPlanSnapshot(for: settings)
            addDebugLog(
                hadUnusablePlan
                    ? "Plano gravado ilegível — refeito com os Ajustes atuais: \(snapshot.logSummary)"
                    : "Sessão sem plano gravado — usando os Ajustes atuais: \(snapshot.logSummary)"
            )
        }

        // A fronteira da passagem. O cooldown de `.meetingBatch` é infinito de propósito ("não
        // retente dentro desta reunião"), mas o coordenador vive enquanto o app vive: sem reabrir
        // aqui, uma falha na reunião de hoje condenaria a próxima e o botão "Reprocessar
        // transcript" a pularem o rank 0 sem nunca tentá-lo (MAIOR do Farol). Reabre UMA VEZ, no
        // começo da passagem — nunca entre lotes, que é justamente o que a supressão protege — e só
        // o que a REUNIÃO aprendeu: o que o ditado sabe é dele.
        // A guarda de idioma exige esta reabertura ANTES do probe: `recordsGlobalFailure: false`
        // impede o probe de ESCREVER supressão, não de LER a que sobrou de uma passagem anterior.
        await coordinator.clearFailures(useCase: .meetingFinal)

        batchSnapshot = snapshot
        suppressedBatchCandidates = []
        currentBatchCandidate = snapshot.primary

        if activeSession == nil {
            statusMessage = String(localized: "Transcrevendo…")
        }

        // Releitura fresca por ID após os awaits. Plano utilizável do start NÃO
        // é substituído aqui. Turns da passagem vivem no acumulador — o store
        // só recebe um overlay (throttle no disco, flush incondicional no fim).
        batchPass = MeetingRecordingLifecycle.BatchTurnPersistence(
            existing: initial.turns,
            writeInterval: Self.liveSaveInterval,
            speakerBoundaries: speakerBoundaries
        )
        guard var fresh = sessionForEditing(id: sessionId) else { return .batchFailed }
        if !storedPlanIsUsable {
            fresh.transcriptionPlan = snapshot
        }
        updateSession(fresh)

        // Plano vazio: nenhum motor atende esta reunião (seleção estrita inviável, hardware, idioma).
        // O áudio continua intacto e o botão "Reprocessar transcript" continua oferecido, que é o
        // mesmo desfecho de quando o modelo não carregava no caminho legado.
        guard MeetingTranscription.batchPlan(from: snapshot) != nil else {
            addDebugLog("Nenhum motor disponível para o transcript final — o áudio da reunião está preservado")
            return MeetingRecordingLifecycle.postCallOutcome(hasUsablePlan: false, cancelled: false)
        }

        let directory = store.sessionDirectoryURL(for: fresh.id)
        var readers: [MeetingCaptureSource: MeetingRecordedAudioBatchReader] = [:]
        for source in MeetingCaptureSource.allCases {
            guard let fileName = fresh.audioFiles[source] else { continue }
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                readers[source] = try MeetingRecordedAudioBatchReader(
                    source: source,
                    url: url,
                    chunkSeconds: Self.recordedChunkSeconds,
                    maxBatchSeconds: Self.maxFinalBatchSeconds,
                    gapTolerance: Self.finalBatchGapTolerance,
                    audibleThreshold: Self.audibleRMSThreshold,
                    // A MESMA lista corta os dois canais. No mic isso é o bônus
                    // registrado: o turno para de misturar eco e resposta,
                    // porque a fronteira de fala do system agora fecha o lote.
                    speakerBoundaries: speakerBoundaries
                )
            } catch {
                addDebugLog("Não foi possível abrir \(source.displayName): \(error.localizedDescription)")
            }
        }

        var nextBatch: [MeetingCaptureSource: MeetingAudioChunk] = [:]
        for (source, reader) in readers {
            do {
                nextBatch[source] = try await reader.nextBatch()
            } catch {
                addDebugLog("Falha ao ler \(source.displayName): \(error.localizedDescription)")
            }
        }

        // Progresso proporcional ao áudio LIDO (não aos lotes): trechos de silêncio são
        // pulados pelo leitor quase de graça, então a barra avança rápido neles — que é
        // exatamente o custo real do processamento.
        let totalSeconds = readers.values.reduce(0) { $0 + $1.totalSeconds }
        postProcessingProgress = totalSeconds > 0 ? 0 : nil
        defer { postProcessingProgress = nil }

        addDebugLog("Transcript final pós-call iniciado (\(snapshot.logSummary))")

        var pass = TranscriptionLanguagePass(snapshot: snapshot)
        var accumulator = TranscriptionLanguageProbeAccumulator()
        var buffered: [MeetingAudioChunk] = []
        var cancelled = false
        let collectProbe = MeetingTranscription.shouldCollectProbeAudio(from: snapshot)
        while collectProbe, !accumulator.isReady, !accumulator.isExhausted {
            if Task.isCancelled {
                cancelled = true
                break
            }
            guard let candidate = nextBatch.min(by: { $0.value.startTime < $1.value.startTime }) else {
                break
            }
            let chunk = candidate.value
            buffered.append(chunk)
            accumulator.append(chunk.samples, timeline: chunk.startTime..<chunk.endTime)
            await refillNextBatch(&nextBatch, source: candidate.key, readers: readers)
        }

        if Task.isCancelled { cancelled = true }

        let plannedBeforeProbe = pass.language
        if !cancelled, let probePlan = pass.probePlan,
           let audio = accumulator.probeAudio ?? accumulator.finalProbeAudio {
            let probe = try? await coordinator.transcribe(
                TranscriptionRequest(useCase: .meetingFinal, language: nil, audio: audio),
                using: probePlan,
                retryPolicy: TranscriptionLanguageProbe.retryPolicy
            )
            let decision = pass.applyProbe(
                detected: probe?.result.detectedLanguage,
                reportedBy: probe?.provenance.engine ?? .whisperKit
            )
            addDebugLog(
                TranscriptionLanguageProbe.logSummary(
                    decision,
                    planned: plannedBeforeProbe,
                    speechSeconds: accumulator.speechSeconds
                )
            )
        } else {
            pass.skipProbe()
        }
        if !cancelled {
            persistPlanIfCorrected(&pass, sessionId: sessionId)
        }

        // Um lote de cada vez, sequencialmente — é a regra de performance da reunião e não um
        // detalhe de estilo: inferências concorrentes a cada poucos segundos foram a regressão real
        // que travava a câmera do Teams. O coordenador já serializa por conta própria (vaga única),
        // e este `await` dentro do laço mantém a garantia mesmo se a vaga um dia mudar.
        for (index, chunk) in buffered.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let outcome = await transcribeGuardedChunk(chunk, sessionId: sessionId, pass: &pass)
            if outcome == .cancelled {
                cancelled = true
                break
            }
            let pending = Array(buffered.dropFirst(index + 1)) + Array(nextBatch.values)
            reportPostCallProgress(
                readers: readers,
                totalSeconds: totalSeconds,
                pending: pending
            )
        }

        // `!cancelled` na condição é a **continuidade** entre as duas fases: se o replay do buffer
        // parou por cancelamento, esta fase não pode retomar a passagem. O `Task.isCancelled` de
        // dentro não cobre isso, porque o cancelamento pode ter chegado pelo coordenador (um lote
        // devolvendo `.cancelled`) sem que a `Task` deste pós-processamento esteja cancelada — e o
        // contrato diz que cancelamento vale para a passagem inteira, não para um lote. São dois
        // sinais independentes de propósito, e por isso os dois ficam visíveis aqui.
        while !cancelled, let candidate = nextBatch.min(by: { $0.value.startTime < $1.value.startTime }) {
            // O laço OBSERVA cancelamento, nos dois lugares em que ele pode chegar: o Task que roda
            // este pós-processamento pode ser cancelado entre lotes, e o coordenador pode devolver
            // `.cancelled` de dentro de um. Hoje nada cancela — não existe botão de parar o
            // pós-call —, mas engolir o sinal faria os lotes restantes falharem um a um, com uma
            // linha de log cada, até o áudio acabar (MENOR da Quilha). Os turns já salvos ficam.
            if Task.isCancelled {
                cancelled = true
                break
            }

            let source = candidate.key
            let outcome = await transcribeGuardedChunk(
                candidate.value,
                sessionId: sessionId,
                pass: &pass
            )
            if outcome == .cancelled {
                cancelled = true
                break
            }

            await refillNextBatch(&nextBatch, source: source, readers: readers)
            reportPostCallProgress(
                readers: readers,
                totalSeconds: totalSeconds,
                pending: Array(nextBatch.values)
            )
        }

        if var fresh = sessionForEditing(id: sessionId) {
            fresh.turns = batchPass.flush(speakers: fresh.speakers)
            updateSession(fresh)
            addDebugLog(
                cancelled
                    ? "Transcript final interrompido: \(fresh.turns.count) turn(s) salvos"
                    : "Transcript final concluído: \(fresh.turns.count) turn(s)"
            )
        }
        return MeetingRecordingLifecycle.postCallOutcome(hasUsablePlan: true, cancelled: cancelled)
    }

    /// Um lote pelo coordenador, seguindo o plano congelado da reunião.
    ///
    /// - Parameter plan: o plano do snapshot. Vai como plano **pronto** (`transcribe(_:using:)`) em
    ///   vez de uma seleção: rotear de novo a cada lote leria os Ajustes vivos, que é exatamente o
    ///   que o snapshot existe para impedir.
    /// - Parameter language: o idioma do snapshot, pelo mesmo motivo.
    private func processChunk(
        _ chunk: MeetingAudioChunk,
        sessionId: UUID,
        plan: TranscriptionRoutingPlan,
        language: TranscriptionLanguage?
    ) async -> BatchOutcome {
        guard !chunk.samples.isEmpty else { return .skipped }
        guard sessionForEditing(id: sessionId) != nil else { return .skipped }

        do {
            let outcome = try await coordinator.transcribe(
                TranscriptionRequest(
                    useCase: .meetingFinal,
                    language: language,
                    audio: TranscriptionAudio(samples: chunk.samples)
                ),
                using: plan,
                retryPolicy: MeetingTranscription.batchRetryPolicy
            )
            // O candidato que **venceu** sai da conta: `failedAttempts` guarda a primeira tentativa
            // mesmo quando a segunda do mesmo candidato deu certo, e o coordenador apaga o registro
            // dele no sucesso. Sem excluí-lo, o espelho anunciaria um rebaixamento que não houve —
            // e, pior, ficaria marcado, calando o aviso na hora em que a falha fosse definitiva
            // (MENOR do Farol).
            noteBatchAttempts(outcome.failedAttempts, succeeded: outcome.provenance)
            return persistRecognizedTurn(
                text: outcome.text,
                chunk: chunk,
                sessionId: sessionId,
                provenance: outcome.provenance,
                segments: outcome.result.segments
            )
        } catch {
            // Cancelamento não é falha de lote: quem cancelou não quer os lotes seguintes, e tratá-lo
            // como erro faria o laço percorrer o áudio inteiro falhando de linha em linha.
            guard !MeetingTranscription.isCancellation(error) else {
                addDebugLog("Transcrição do lote cancelada (\(chunk.source.displayName))")
                return .cancelled
            }
            if let coordinatorError = error as? TranscriptionCoordinatorError,
               case .allCandidatesFailed(let attempts) = coordinatorError {
                noteBatchAttempts(attempts, succeeded: nil)
            }
            // `TranscriptionCoordinatorError` é `LocalizedError` (T2.4b) e descreve motor, modelo,
            // estágio e falha — vocabulário técnico, sem texto reconhecido.
            addDebugLog("Erro na transcrição de \(chunk.source.displayName): \(error.localizedDescription)")
            return .skipped
        }
    }

    /// O laço do pós-call deve seguir para o próximo lote?
    private enum BatchOutcome {
        case produced
        case empty
        case cancelled
        case skipped
    }

    /// Lote com o plano vigente da passagem; texto vazio consulta a evidência antes de seguir.
    private func transcribeGuardedChunk(
        _ chunk: MeetingAudioChunk,
        sessionId: UUID,
        pass: inout TranscriptionLanguagePass
    ) async -> BatchOutcome {
        guard let plan = pass.batchPlan else {
            addDebugLog("Nenhum motor disponível para o lote após a correção de idioma")
            return .skipped
        }
        let outcome = await processChunk(
            chunk,
            sessionId: sessionId,
            plan: plan,
            language: pass.language
        )
        guard outcome == .empty else { return outcome }
        return await applyEmptyBatchGuard(to: chunk, sessionId: sessionId, pass: &pass)
    }

    private func applyEmptyBatchGuard(
        to chunk: MeetingAudioChunk,
        sessionId: UUID,
        pass: inout TranscriptionLanguagePass
    ) async -> BatchOutcome {
        let verdict = pass.verdictForEmptyBatch(samples: chunk.samples)
        addDebugLog(TranscriptionLanguageEvidenceGuard.logSummary(verdict, planned: pass.language))
        guard case .tryAlternate(let other) = verdict,
              let trial = pass.trialPlan(for: other) else {
            return .skipped
        }
        let result: TranscriptionLanguageEvidenceGuard.TrialResult
        var produced: BatchOutcome = .skipped
        do {
            let retry = try await coordinator.transcribe(
                TranscriptionRequest(
                    useCase: .meetingFinal,
                    language: other,
                    audio: TranscriptionAudio(samples: chunk.samples)
                ),
                using: trial,
                retryPolicy: TranscriptionLanguageGuard.trialRetryPolicy
            )
            noteBatchAttempts(retry.failedAttempts, succeeded: retry.provenance)
            produced = persistRecognizedTurn(
                text: retry.text,
                chunk: chunk,
                sessionId: sessionId,
                provenance: retry.provenance,
                segments: retry.result.segments
            )
            result = produced == .produced ? .producedText : .empty
        } catch {
            guard !MeetingTranscription.isCancellation(error) else {
                addDebugLog("Transcrição do lote cancelada (\(chunk.source.displayName))")
                return .cancelled
            }
            if let coordinatorError = error as? TranscriptionCoordinatorError,
               case .allCandidatesFailed(let attempts) = coordinatorError {
                noteBatchAttempts(attempts, succeeded: nil)
            }
            addDebugLog("Erro na transcrição de \(chunk.source.displayName): \(error.localizedDescription)")
            result = .failed
        }
        if case .adopts = pass.note(alternate: other, result: result) {
            persistPlanIfCorrected(&pass, sessionId: sessionId)
        }
        return produced
    }

    private func persistPlanIfCorrected(
        _ pass: inout TranscriptionLanguagePass,
        sessionId: UUID
    ) {
        guard pass.isCorrected, var fresh = sessionForEditing(id: sessionId) else { return }
        let previous = batchSnapshot
        fresh.transcriptionPlan = pass.snapshot
        updateSession(fresh)
        batchSnapshot = pass.snapshot
        currentBatchCandidate = pass.snapshot.primary
        if let previous, previous.language != pass.snapshot.language {
            addDebugLog(
                TranscriptionLanguageGuard.retargetLogSummary(from: previous, to: pass.snapshot)
            )
        }
    }

    @discardableResult
    private func persistRecognizedTurn(
        text rawText: String,
        chunk: MeetingAudioChunk,
        sessionId: UUID,
        provenance: TranscriptionProvenance,
        segments: [TranscriptionTextSegment]
    ) -> BatchOutcome {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "..." else { return .empty }
        guard sessionForEditing(id: sessionId) != nil else { return .skipped }

        let speakerName = sessionForEditing(id: sessionId)?.speakerName(for: chunk.source)
            ?? chunk.source.defaultSpeakerName
        let turn = MeetingTurn(
            source: chunk.source,
            speakerName: speakerName,
            text: text,
            startTime: chunk.startTime,
            endTime: chunk.endTime,
            confidence: averageConfidence(segments),
            provenance: provenance
        )

        batchPass.accept(turn)
        persistAccumulatedTurns(sessionId: sessionId)
        addDebugLog(
            TranscriptionLogRedaction.meetingTurn(
                text,
                source: chunk.source.displayName,
                provenance: provenance
            )
        )
        return .produced
    }

    /// Progresso = áudio já transcrito, não o que o leitor adiantou no buffer/nextBatch.
    private func reportPostCallProgress(
        readers: [MeetingCaptureSource: MeetingRecordedAudioBatchReader],
        totalSeconds: TimeInterval,
        pending: [MeetingAudioChunk]
    ) {
        guard totalSeconds > 0 else { return }
        let pendingSeconds = pending.reduce(0.0) { $0 + max(0, $1.endTime - $1.startTime) }
        let consumed = readers.values.reduce(0.0) { $0 + $1.consumedSeconds }
        postProcessingProgress = min(1, max(0, consumed - pendingSeconds) / totalSeconds)
    }

    private func refillNextBatch(
        _ nextBatch: inout [MeetingCaptureSource: MeetingAudioChunk],
        source: MeetingCaptureSource,
        readers: [MeetingCaptureSource: MeetingRecordedAudioBatchReader]
    ) async {
        do {
            nextBatch[source] = try await readers[source]?.nextBatch()
        } catch {
            nextBatch[source] = nil
            addDebugLog("Falha ao continuar lendo \(source.displayName): \(error.localizedDescription)")
        }
    }

    /// Acompanha o rebaixamento do plano ao longo dos lotes, para anunciá-lo **uma vez**.
    ///
    /// O que decide de fato o próximo candidato é o coordenador (a `batchRetryPolicy` suprime um par
    /// motor+modelo que falhou pela reunião inteira); isto é só o espelho que faz o log dizer "os
    /// lotes que faltam vão sair do Parakeet" em vez de repetir a mesma falha dezenas de vezes.
    /// Nenhum lote já salvo é reprocessado: o transcript cresce para a frente.
    private func noteBatchAttempts(
        _ attempts: [TranscriptionAttempt],
        succeeded: TranscriptionProvenance?
    ) {
        guard !attempts.isEmpty, let snapshot = batchSnapshot else { return }
        let before = suppressedBatchCandidates
        suppressedBatchCandidates.formUnion(
            MeetingTranscription.suppressedCandidates(from: attempts, succeeded: succeeded)
        )
        guard suppressedBatchCandidates != before else { return }

        let next = MeetingTranscription.nextPrimaryCandidate(
            in: snapshot,
            suppressing: suppressedBatchCandidates
        )
        guard next != currentBatchCandidate else { return }
        addDebugLog(
            MeetingTranscription.downgradeLogSummary(from: currentBatchCandidate, to: next)
        )
        currentBatchCandidate = next
    }

    /// Overlay do acumulador numa releitura fresca: notas/título do humano
    /// sobrevivem; nomes da sessão fresca reaplicam-se aos turns; o throttle
    /// só decide se o disco vê o snapshot agora.
    private func persistAccumulatedTurns(sessionId: UUID) {
        guard var fresh = sessionForEditing(id: sessionId) else { return }
        fresh.turns = batchPass.flush(speakers: fresh.speakers)
        if activeSession?.id == sessionId { activeSession = fresh }
        if selectedSession?.id == sessionId { selectedSession = fresh }
        saveLiveThrottled(fresh)
    }

    private func merge(turn: MeetingTurn, into session: inout MeetingSession) {
        MeetingRecordingLifecycle.merge(turn: turn, into: &session.turns)
    }

    /// Pós-call: remove o eco da caixa de som do transcript (turns de "Você" que são eco) e gera uma
    /// faixa de mic limpa pro player não reproduzir o eco. Roda após a diarização e antes do resumo.
    /// O trabalho pesado (DSP de correlação) roda fora da main thread. Auto-adapta: com fone não há
    /// eco e nada é gerado. Ver `MeetingEchoReconciler`.
    /// Escreve o delta da diarização numa releitura fresca da sessão. `before` é a
    /// lista de falantes de quando o passo começou: se a UI renomeou alguém durante
    /// o await, o nome fresco manda e é reaplicado aos turns do passo. Sem isso, a
    /// volta do await sobrescreve `speakers`/`turns` com a cópia velha e o rename some.
    private func applyDiarizationDelta(
        _ stepOutput: MeetingSession,
        before: [MeetingSpeaker],
        sessionId: UUID
    ) {
        guard var fresh = sessionForEditing(id: sessionId) else { return }
        let speakers = MeetingRecordingLifecycle.mergingPipelineSpeakers(
            stepSpeakers: stepOutput.speakers,
            before: before,
            fresh: fresh.speakers
        )
        fresh.speakers = speakers
        fresh.turns = MeetingRecordingLifecycle.applyingFreshSpeakerNames(
            to: stepOutput.turns,
            speakers: speakers
        )
        _ = updateSession(fresh)
    }

    /// Idem para a reconciliação de eco: o passo só mexe em turns e na faixa limpa,
    /// então a lista fresca de falantes é a autoridade dos nomes.
    private func applyEchoReconciliationDelta(
        _ stepOutput: MeetingSession,
        sessionId: UUID
    ) {
        guard var fresh = sessionForEditing(id: sessionId) else { return }
        fresh.turns = MeetingRecordingLifecycle.applyingFreshSpeakerNames(
            to: stepOutput.turns,
            speakers: fresh.speakers
        )
        fresh.cleanMicFile = stepOutput.cleanMicFile
        updateSession(fresh)
    }

    private func reconcileEcho(_ session: MeetingSession) async -> MeetingSession {
        guard let micName = session.audioFiles[.microphone],
              let sysName = session.audioFiles[.systemAudio] else { return session }
        let dir = store.sessionDirectoryURL(for: session.id)
        let micURL = dir.appendingPathComponent(micName)
        let sysURL = dir.appendingPathComponent(sysName)
        guard FileManager.default.fileExists(atPath: micURL.path),
              FileManager.default.fileExists(atPath: sysURL.path) else { return session }

        if activeSession == nil {
            statusMessage = String(localized: "Removendo eco…")
        }
        let turns = session.turns
        let result = await Task.detached(priority: .userInitiated) {
            MeetingEchoReconciler().reconcile(
                turns: turns, micURL: micURL, systemURL: sysURL,
                outputDirectory: dir, cleanMicFileName: "microphone-clean.caf"
            )
        }.value

        var updated = session
        if result.droppedCount > 0 || result.trimmedCount > 0 { updated.turns = result.turns }
        if let clean = result.cleanMicFileName { updated.cleanMicFile = clean }
        addDebugLog("Reconciliação de eco: \(result.note)")
        // As linhas de `trimLog` trazem `prefix(60)` do texto removido (ver `MeetingEchoReconciler`),
        // e iam para o log uma a uma. Fica a contagem (turns removidos pelo áudio ou recortados pelo
        // texto), que é a informação operacional; o que foi recortado é transcript (PLANO, regra 7).
        addDebugLog(TranscriptionLogRedaction.meetingEchoTrims(result.droppedCount + result.trimmedCount))
        return updated
    }

    /// Pós-call: separa as vozes do áudio do sistema (Camada 1) e sugere nomes reais
    /// a partir da conversa (Camada 2). Roda antes do resumo para que ele já receba nomes.
    private func diarizeAndName(_ session: inout MeetingSession) async {
        let segments = await diarizeSystemAudio(for: session.id)
        guard !segments.isEmpty else { return }
        applyDiarization(to: &session, segments: segments)
        await nameParticipants(&session)
    }

    /// Camada 1 isolada: separa as vozes e devolve os segmentos, sem aplicar
    /// nada. É o que permite a diarização vir ANTES da transcrição — o mesmo
    /// resultado alimenta os CORTES de lote e a atribuição, numa passagem só.
    /// `[]` quando não há áudio do sistema ou a diarização falha.
    private func diarizeSystemAudio(for sessionId: UUID) async -> [DiarizedSegment] {
        guard let session = sessionForEditing(id: sessionId),
              let systemFileName = session.audioFiles[.systemAudio]
        else { return [] }
        let url = store.sessionDirectoryURL(for: sessionId).appendingPathComponent(systemFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        if activeSession == nil {
            statusMessage = String(localized: "Identificando participantes…")
        }
        do {
            return try await diarizationService.diarize(audioFileURL: url)
        } catch {
            addDebugLog("Diarização indisponível: \(error.localizedDescription)")
            return []
        }
    }

    /// Camada 2 — nomes ditos na conversa (LLM)
    @discardableResult
    private func nameParticipants(_ session: inout MeetingSession) async -> Bool {
        if activeSession == nil {
            statusMessage = String(localized: "Identificando nomes…")
        }
        do {
            let verified = try await settingsForMeetingAI(resource: .speakerNames)
            namingService.updateSettings(verified)
            let names = try await namingService.suggestNames(for: session)
            guard !Task.isCancelled else { return false }
            applyNames(to: &session, names: names)
            if !names.isEmpty {
                // O mapa rótulo→nome ia inteiro para o log. Os nomes saem da conversa (é o que esta
                // camada faz: ler o transcript e achar como as pessoas se chamam), então são
                // conteúdo derivado — e conteúdo que identifica gente.
                addDebugLog(TranscriptionLogRedaction.meetingNamesApplied(names.count))
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return false }
            if error is SettingsCredentialError {
                statusMessage = SettingsCredentialError.unavailable.localizedDescription
                return false
            }
            addDebugLog(
                TranscriptionLogRedaction.meetingAssistantFailed(
                    kind: "Atribuição de nomes",
                    detail: error.localizedDescription
                )
            )
        }
        return true
    }

    /// Mapeia cada turn do áudio do sistema ao cluster de maior sobreposição e reconstrói
    /// a lista de falantes (mic "Você" + "Participante N").
    private func applyDiarization(to session: inout MeetingSession, segments: [DiarizedSegment]) {
        session.applyDiarization(segments: segments)
        let count = session.speakers.filter { $0.source == .systemAudio }.count
        addDebugLog("Diarização: \(count) participante(s)")
    }

    private func applyNames(to session: inout MeetingSession, names: [String: String]) {
        session.applySpeakerNames(names)
    }

    private func settingsForMeetingAI(resource: AIResource, preferences: AppSettings? = nil) async throws -> AppSettings {
        try await MeetingCredentialRecoveryGate.settingsForAI(preferences: preferences) {
            try await self.settingsStore.settingsForAIUse(resource: resource)
        }
    }

    @discardableResult
    private func generateSummary(for session: MeetingSession) async -> Bool {
        guard generatingSummarySessionIDs.insert(session.id).inserted else { return true }
        let template = templateStore.template(withId: session.templateId) ?? templateStore.defaultTemplate
        defer { generatingSummarySessionIDs.remove(session.id) }
        if activeSession == nil {
            statusMessage = String(localized: "Gerando resumo…")
        }

        do {
            let settings = try await settingsForMeetingAI(resource: .summary)
            let summaryService = MeetingSummaryService(settings: settings)
            let summary = try await summaryService.summarize(session: session, template: template)
            guard !Task.isCancelled else { return false }
            if var fresh = sessionForEditing(id: session.id) {
                guard fresh.includeNotesInSummary == session.includeNotesInSummary,
                      fresh.notes == session.notes, fresh.turns == session.turns else { return true }
                fresh.summary = MeetingProductivity.preservingTaskState(summary, from: fresh.summary)
                fresh.summaryError = nil
                fresh.summaryModel = settings.currentModelDisplayName
                fresh.summaryEffort = settings.effectiveReasoningEffort.apiValue
                if MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                    current: fresh.title,
                    generated: summary.title,
                    defaultTitles: Self.defaultSessionTitles
                ) {
                    fresh.title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard updateSession(fresh) else { throw CocoaError(.fileWriteUnknown) }

            }
            addDebugLog("Resumo gerado (\(template.name))")
            if let fresh = sessionForEditing(id: session.id) {
                guard await generateChapters(for: fresh, settings: settings) else { return false }
            }
            NotchOverlay.shared.showToast(message: String(localized: "Resumo pronto"))
        } catch {
            if Task.isCancelled || error is CancellationError { return false }
            if error is SettingsCredentialError {
                statusMessage = SettingsCredentialError.unavailable.localizedDescription
                return false
            }
            if var fresh = sessionForEditing(id: session.id) {
                fresh.summaryError = error.localizedDescription
                updateSession(fresh)
            }
            addDebugLog(
                TranscriptionLogRedaction.meetingAssistantFailed(
                    kind: "Resumo",
                    detail: error.localizedDescription
                )
            )
            NotchOverlay.shared.showToast(
                message: String(localized: "Resumo indisponível"),
                symbol: "exclamationmark.triangle.fill"
            )
        }
        return true
    }

    /// Reuniões que ficaram com o título padrão ("Reunião 17/09/2026, 17:01") mesmo com um
    /// resumo que já trazia um título: a regra antiga só trocava quando o título era exatamente
    /// "Reunião". Roda uma vez por launch e só toca o que ainda parece padrão.
    private func adoptGeneratedTitles() {
        var changed = false
        for session in store.sessions {
            guard let generated = session.summary?.title,
                  MeetingRecordingLifecycle.shouldAdoptGeneratedTitle(
                      current: session.title,
                      generated: generated,
                      defaultTitles: Self.defaultSessionTitles
                  ) else { continue }
            var updated = sessionForEditing(id: session.id) ?? session
            updated.title = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            store.save(updated)
            changed = true
        }
        if changed {
            sessions = store.sessions
            if let selected = selectedSession { selectedSession = store.sessions.first { $0.id == selected.id } ?? selected }
        }
    }

    private static var defaultSessionTitles: Set<String> {
        Set(MeetingSessionType.allCases.map(\.displayName) + ["Nova reunião"])
    }

    @discardableResult
    private func updateSession(_ session: MeetingSession) -> Bool {
        var session = session
        session.reconcileSpeakers()
        if activeSession?.id == session.id {
            activeSession = session
        }
        if selectedSession?.id == session.id {
            selectedSession = session
        }
        return store.save(session)
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// Costura o pre-roll (~2s) de uma nova janela ao texto já assentado. A janela do
    /// Whisper precisa sobrepor áudio para não cortar palavras; sem esta deduplicação,
    /// essa mesma sobreposição apareceria duas vezes no bloco visual.
    private static func mergePreviewWindow(stablePrefix: String, hypothesis: String) -> String {
        let prefix = stablePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return current }
        guard !current.isEmpty else { return prefix }

        let prefixWords = prefix.split(whereSeparator: \.isWhitespace)
        let currentWords = current.split(whereSeparator: \.isWhitespace)
        let maximumOverlap = min(24, prefixWords.count, currentWords.count)
        var additionStart = 0

        if maximumOverlap >= 2 {
            for candidate in stride(from: maximumOverlap, through: 2, by: -1) {
                let oldTail = prefixWords.suffix(candidate).map(normalizedPreviewWord)
                let newHead = currentWords.prefix(candidate).map(normalizedPreviewWord)
                if oldTail == newHead, oldTail.contains(where: { !$0.isEmpty }) {
                    additionStart = candidate
                    break
                }
            }
        }

        // Se o Whisper corrigiu uma ou duas palavras no começo, procura uma âncora um
        // pouco adiante. Preserva o prefixo assentado e acrescenta só o que vem depois
        // da âncora, em vez de duplicar a hipótese inteira.
        if additionStart == 0 {
            let maximumAnchor = min(12, prefixWords.count, currentWords.count)
            if maximumAnchor >= 3 {
                anchorSearch: for candidate in stride(from: maximumAnchor, through: 3, by: -1) {
                    let oldTail = prefixWords.suffix(candidate).map(normalizedPreviewWord)
                    let maximumStart = min(12, currentWords.count - candidate)
                    for start in 0...maximumStart {
                        let end = start + candidate
                        let newAnchor = currentWords[start..<end].map(normalizedPreviewWord)
                        if oldTail == newAnchor, oldTail.contains(where: { !$0.isEmpty }) {
                            additionStart = end
                            break anchorSearch
                        }
                    }
                }
            }
        }

        let addition = currentWords.dropFirst(additionStart).joined(separator: " ")
        return addition.isEmpty ? prefix : prefix + " " + addition
    }

    private static func normalizedPreviewWord(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Mantém monotônica a parte antiga da hipótese. O Whisper pode reescrever livremente
    /// as quatro palavras mais recentes; o que já ficou para trás é promovido para um
    /// prefixo preservado. Se uma hipótese nova perde uma parte relevante da anterior,
    /// tratamos como continuação truncada em vez de apagar uma fala que o usuário já viu.
    private func stabilizedLivePreviewWindow(_ hypothesis: String) -> String {
        let current = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            return livePreviewLockedWindowPrefix
        }

        let previous = livePreviewPreviousHypothesis
        if !previous.isEmpty {
            let previousWords = previous.split(whereSeparator: \.isWhitespace)
            let currentWords = current.split(whereSeparator: \.isWhitespace)
            let previousNormalized = previousWords.map(Self.normalizedPreviewWord)
            let currentNormalized = currentWords.map(Self.normalizedPreviewWord)
            let shared = Self.longestCommonSubsequenceLength(
                previousNormalized,
                currentNormalized
            )
            let retainedPreviousRatio = Double(shared) / Double(previousWords.count)
            let lostPreviousHypothesis = previousWords.count >= 6
                && currentWords.count >= 3
                && retainedPreviousRatio < 0.7

            if lostPreviousHypothesis {
                livePreviewLockedWindowPrefix = Self.mergePreviewWindow(
                    stablePrefix: livePreviewLockedWindowPrefix,
                    hypothesis: previous
                )
            } else {
                let horizonCount = max(0, previousWords.count - 4)
                let agreementCount = max(
                    0,
                    Self.commonPreviewPrefixLength(previousNormalized, currentNormalized) - 2
                )
                let candidateCount = max(horizonCount, agreementCount)
                if candidateCount > 0 {
                    promoteLockedWindowPrefix(
                        previousWords.prefix(candidateCount).joined(separator: " ")
                    )
                }
            }
        }

        livePreviewPreviousHypothesis = current
        return Self.mergePreviewWindow(
            stablePrefix: livePreviewLockedWindowPrefix,
            hypothesis: current
        )
    }

    private func promoteLockedWindowPrefix(_ candidate: String) {
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace)
        let lockedWords = livePreviewLockedWindowPrefix.split(whereSeparator: \.isWhitespace)
        guard !candidateWords.isEmpty else { return }
        guard !lockedWords.isEmpty else {
            livePreviewLockedWindowPrefix = candidate
            return
        }
        guard candidateWords.count > lockedWords.count else { return }
        let candidateHead = candidateWords.prefix(lockedWords.count).map(Self.normalizedPreviewWord)
        let locked = lockedWords.map(Self.normalizedPreviewWord)
        if candidateHead == locked {
            livePreviewLockedWindowPrefix = candidate
        }
    }

    private func resetLivePreviewHypothesisState() {
        livePreviewLockedWindowPrefix = ""
        livePreviewPreviousHypothesis = ""
    }

    private static func commonPreviewPrefixLength(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func longestCommonSubsequenceLength(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for rightIndex in rhs.indices {
                if left == rhs[rightIndex] {
                    current[rightIndex + 1] = previous[rightIndex] + 1
                } else {
                    current[rightIndex + 1] = max(current[rightIndex], previous[rightIndex + 1])
                }
            }
            previous = current
        }
        return previous[rhs.count]
    }

    /// Persistência incremental do transcript oficial enquanto o áudio pós-call é processado.
    private func saveLiveThrottled(_ session: MeetingSession) {
        let now = Date().timeIntervalSince1970
        guard batchPass.shouldWriteToDisk(at: now) else { return }
        lastLiveSaveAtBySession[session.id] = Date()
        store.save(session)
    }

    /// A confiança média dos segmentos do lote, no vocabulário dos contratos (T1.2).
    ///
    /// `confidence` é opcional lá (nem todo motor reporta), então a média é sobre os que reportam —
    /// e não sobre todos com zero no lugar dos ausentes, que puxaria o número para baixo e mudaria o
    /// significado do campo gravado no turno. Sem nenhum, `0`, que é o que o caminho legado
    /// devolvia para lote sem segmento. Nos dois motores que a reunião usa hoje o número é o mesmo
    /// de antes: `avgLogprob` no WhisperKit, a confiança da utterance no Parakeet.
    private func averageConfidence(_ segments: [TranscriptionTextSegment]) -> Float {
        let reported = segments.compactMap(\.confidence)
        guard !reported.isEmpty else { return 0 }
        return reported.reduce(0, +) / Float(reported.count)
    }

    private func addDebugLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLogs.append("[\(timestamp)] \(message)")
        if debugLogs.count > 100 {
            debugLogs.removeFirst()
        }
        print(message)
    }
}
