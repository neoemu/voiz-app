import Combine
import Foundation

/// De onde vêm as notas: a API oficial ou um arquivo exportado.
nonisolated protocol GranolaNoteSource: Sendable {
    func listNotes() async throws -> [GranolaNoteListing]
    func note(id: String) async throws -> GranolaNote
}

extension GranolaAPIClient: GranolaNoteSource {}

/// Onde as reuniões importadas ficam no Voiz.
enum GranolaFolderPlacement: Hashable {
    case keepGranolaFolders
    case singleFolder

    /// Nome de produto, igual em todos os idiomas.
    static let singleFolderName = "Granola"
}

struct GranolaImportPlan: Equatable {
    let pending: [GranolaNoteListing]
    let alreadyInLibrary: Int
    /// Linhas do arquivo que não deu para aproveitar. Contam como falha no resultado.
    var unreadable = 0
    /// O CSV pode vir sem transcrições, e isso precisa aparecer antes de importar.
    var lacksTranscripts = false

    var oldest: Date? { pending.map(\.createdAt).min() }
    var newest: Date? { pending.map(\.createdAt).max() }
}

struct GranolaImportOutcome: Equatable {
    var imported = 0
    var failed = 0
    /// Por que a importação parou antes do fim. nil = chegou ao fim.
    var stopReason: String?
    var cancelled = false

    var isComplete: Bool { stopReason == nil && !cancelled }
}

/// Fluxo da importação. A chave vive só em memória, enquanto a folha está aberta.
///
/// Importar é sempre aditivo: nota que já tem reunião na biblioteca, mesmo na lixeira do Sync, fica
/// como está. Parar no meio não perde nada; a próxima rodada continua do que faltou.
final class GranolaImporter: ObservableObject {
    enum Phase: Equatable {
        case choosingSource
        case enteringKey(error: String?)
        case choosingFile(error: String?)
        case checking
        case ready(GranolaImportPlan)
        case importing(done: Int, total: Int)
        case finished(GranolaImportOutcome)
    }

    @Published var apiKey = ""
    @Published var folderPlacement = GranolaFolderPlacement.keepGranolaFolders
    @Published private(set) var phase = Phase.choosingSource

    private let store: MeetingSessionStore
    private let makeClient: (String) -> GranolaAPIClient
    private let gate: VoizEditingGate
    private var source: (any GranolaNoteSource)?
    private var task: Task<Void, Never>?

    init(
        store: MeetingSessionStore,
        makeClient: @escaping (String) -> GranolaAPIClient = { GranolaAPIClient(apiKey: $0) },
        gate: VoizEditingGate = .shared
    ) {
        self.store = store
        self.makeClient = makeClient
        self.gate = gate
    }

    var canConnect: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func chooseAPIKey() { phase = .enteringKey(error: nil) }
    func chooseFile() { phase = .choosingFile(error: nil) }
    func backToSources() { phase = .choosingSource }

    func connect() {
        guard canConnect else { return }
        let client = makeClient(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        source = client
        phase = .checking
        task = Task {
            do {
                try await preparePlan(from: client)
            } catch is CancellationError {
                phase = .enteringKey(error: nil)
            } catch {
                phase = .enteringKey(error: (error as? GranolaImportError ?? .unreadableResponse).message)
            }
        }
    }

    func open(fileAt url: URL) {
        phase = .checking
        task = Task {
            do {
                let archive = try await Task.detached { try GranolaCSVArchive.load(from: url) }.value
                guard !archive.notes.isEmpty else { throw GranolaCSVError.notAGranolaExport }
                source = archive
                try await preparePlan(from: archive, unreadable: archive.unreadableRows,
                                      lacksTranscripts: !archive.hasTranscripts)
            } catch is CancellationError {
                phase = .choosingFile(error: nil)
            } catch {
                phase = .choosingFile(error: (error as? GranolaCSVError ?? .unreadableFile).message)
            }
        }
    }

    func startImport() {
        guard case .ready(let plan) = phase, let source else { return }
        phase = .importing(done: 0, total: plan.pending.count)
        task = Task { await run(plan, from: source) }
    }

    func cancel() {
        task?.cancel()
    }

    /// Esperável em teste; a folha só dispara os passos.
    func waitForCurrentStep() async {
        await task?.value
    }

    private func preparePlan(from source: any GranolaNoteSource, unreadable: Int = 0,
                             lacksTranscripts: Bool = false) async throws {
        let live = try await source.listNotes().filter { $0.deletedAt == nil }
        let pending = live.filter { !isInLibrary($0) }
        phase = .ready(GranolaImportPlan(pending: pending, alreadyInLibrary: live.count - pending.count,
                                         unreadable: unreadable, lacksTranscripts: lacksTranscripts))
    }

    /// API e CSV identificam a nota de jeitos diferentes. Sem o título e o horário, usar as duas
    /// rotas duplicaria tudo. A folga cobre a nota criada antes da primeira fala.
    private func isInLibrary(_ listing: GranolaNoteListing) -> Bool {
        if store.hasRecord(forSession: GranolaNoteMapper.sessionID(forNoteID: listing.id)) { return true }
        guard let title = listing.title else { return false }
        return store.sessions.contains {
            $0.summaryModel == GranolaNoteMapper.summaryOrigin && $0.title == title
                && abs($0.startedAt.timeIntervalSince(listing.createdAt)) < 3_600
        }
    }

    /// Uma admissão cobre a rodada inteira, e a atividade segura a troca de biblioteca até o fim.
    private func run(_ plan: GranolaImportPlan, from source: any GranolaNoteSource) async {
        var outcome = GranolaImportOutcome(failed: plan.unreadable)
        defer {
            apiKey = ""
            self.source = nil
            phase = .finished(outcome)
        }
        guard let activity = await gate.begin() else {
            if Task.isCancelled {
                outcome.cancelled = true
            } else {
                outcome.stopReason = VoizAccessStore.shared.lastError
                    ?? String(localized: "Não foi possível iniciar a operação nesta biblioteca. Confira a biblioteca no Perfil.")
            }
            return
        }
        defer { activity.finish() }
        loop: for (index, listing) in plan.pending.enumerated() {
            do {
                let note = try await source.note(id: listing.id)
                try Task.checkCancellation()
                let session = GranolaNoteMapper.session(from: note, folderID: folderID(for: note))
                if !store.hasRecord(forSession: session.id) {
                    if store.save(session) { outcome.imported += 1 } else { outcome.failed += 1 }
                }
            } catch is CancellationError {
                outcome.cancelled = true
                break loop
            } catch let error as GranolaImportError where error.endsImport {
                outcome.stopReason = error.message
                break loop
            } catch {
                outcome.failed += 1
            }
            phase = .importing(done: index + 1, total: plan.pending.count)
        }
    }

    /// O Voiz guarda uma pasta por reunião e não aninha: vale a primeira, reaproveitada pelo nome.
    private func folderID(for note: GranolaNote) -> UUID? {
        let requested = folderPlacement == .singleFolder
            ? GranolaFolderPlacement.singleFolderName
            : note.folderMembership.first?.name
        guard let name = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let existing = store.folders.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        return (existing ?? store.createFolder(name: name)).id
    }
}
