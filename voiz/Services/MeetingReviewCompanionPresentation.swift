import Combine
import Foundation
import SwiftUI

/// Window and embedded source previews own separate presentations. A visible review registers
/// its controls without opening a panel. Closing the panel keeps those controls available;
/// leaving the review removes both. Late updates cannot register a departed review again.
@MainActor
final class MeetingReviewCompanionPresentation: ObservableObject {
    static let defaultWidth: CGFloat = 340
    static let minimumWidth: CGFloat = 280
    static let maximumWidth: CGFloat = 640
    static let minimumReviewWidth: CGFloat = 480
    static let dockedMinimumWidth: CGFloat = 900
    private static let widthKey = "voiz.meeting.companion.width"

    @Published private(set) var tab = 0
    @Published private(set) var session: MeetingSession?
    @Published private(set) var player: MeetingAudioPlayer?
    @Published private(set) var viewportWidth: CGFloat = dockedMinimumWidth
    @Published private(set) var preferredWidth: CGFloat
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let saved = defaults?.object(forKey: Self.widthKey) as? Double
        preferredWidth = Self.clampedPreference(CGFloat(saved ?? Double(Self.defaultWidth)))
    }

    var hasReview: Bool { session != nil && player != nil }
    var showsWindowPanel: Bool { tab != 0 && hasReview }
    var isOverlay: Bool { showsWindowPanel && viewportWidth < Self.dockedMinimumWidth }
    var overlayWidth: CGFloat { Self.panelWidth(for: viewportWidth, preferred: preferredWidth) }

    static func panelWidth(for viewportWidth: CGFloat) -> CGFloat {
        panelWidth(for: viewportWidth, preferred: defaultWidth)
    }

    static func panelWidth(for viewportWidth: CGFloat, preferred: CGFloat) -> CGFloat {
        let viewport = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        // Keep room for the summary when docked, and a dismissible backdrop when overlaid.
        let reserved = viewport >= dockedMinimumWidth ? minimumReviewWidth : 48
        let upper = min(maximumWidth, max(0, viewport - reserved))
        return min(clampedPreference(preferred), upper)
    }

    private static func clampedPreference(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(maximumWidth, max(minimumWidth, width))
    }

    func resize(to proposedWidth: CGFloat) {
        guard hasReview, proposedWidth.isFinite else { return }
        let width = Self.panelWidth(for: viewportWidth, preferred: proposedWidth)
        if width != preferredWidth { preferredWidth = width }
    }

    /// Save only an explicit resize, never an automatic clamp caused by a smaller window.
    func saveWidth() {
        defaults?.set(Double(Self.clampedPreference(preferredWidth)), forKey: Self.widthKey)
    }

    var tabBinding: Binding<Int> {
        Binding(get: { self.tab }, set: { newTab in
            if newTab == 0 { self.closePanel() }
            else if self.showsWindowPanel, (1...2).contains(newTab) { self.tab = newTab }
        })
    }

    func registerHost(session: MeetingSession, player: MeetingAudioPlayer, viewportWidth: CGFloat) {
        if self.session?.id != session.id || self.player !== player { closePanel() }
        if self.session != session { self.session = session }
        if self.player !== player { self.player = player }
        if self.viewportWidth != viewportWidth { self.viewportWidth = viewportWidth }
    }

    func toggle(tab: Int) {
        guard hasReview, (1...2).contains(tab) else { return }
        self.tab = self.tab == tab ? 0 : tab
    }

    func updateHost(session: MeetingSession, player: MeetingAudioPlayer, viewportWidth: CGFloat) {
        guard self.session?.id == session.id, self.player === player else { return }
        if self.session != session { self.session = session }
        if self.viewportWidth != viewportWidth { self.viewportWidth = viewportWidth }
    }

    func dismissIfMatching(_ sessionID: UUID, player: MeetingAudioPlayer) {
        guard session?.id == sessionID, self.player === player else { return }
        dismiss()
    }

    func closePanel() { tab = 0 }

    func dismiss() {
        closePanel()
        session = nil
        player = nil
    }
}
