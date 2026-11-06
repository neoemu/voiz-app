import Foundation
import Combine

/// Intenção de navegação vinda da busca global.
///
/// A paleta (⌘K) não conhece o estado interno de cada tela — `MeetingView`, `TranslationView` e a
/// lista de ditados guardam o próprio item aberto em `@State`. Em vez de expor esse estado, a
/// paleta publica aqui o item a abrir; a aba de destino consome e chama `clear()`.
@MainActor
final class VoizNavigation: ObservableObject {
    @Published private(set) var pendingOpen: VoizSearchResult?
    /// Aba que precisa entrar em cena para o item pendente aparecer. A `ContentView` consome e
    /// zera. Existe porque agora quem navega nem sempre é a paleta: as citações do Chat abrem uma
    /// reunião a partir de **outra** aba, e sem trocar a aba o `pendingOpen` ficaria sem plateia.
    @Published var requestedTab: Int?
    @Published var calendarEvent: CalendarEvent?

    /// Opening an agenda item only navigates; recording is a separate action in its workspace.
    func open(_ event: CalendarEvent) {
        pendingOpen = nil
        calendarEvent = event
        requestedTab = VoizSearchKind.meeting.tab
    }

    func open(_ result: VoizSearchResult) {
        calendarEvent = nil
        pendingOpen = result
        requestedTab = result.kind.tab
    }

    /// Item pendente desta aba, se houver. Não limpa — quem consome chama `clear()` depois de
    /// realmente abrir o conteúdo.
    func pending(_ kind: VoizSearchKind) -> UUID? {
        guard let pendingOpen, pendingOpen.kind == kind else { return nil }
        return pendingOpen.id
    }

    func clear() {
        pendingOpen = nil
    }
}
