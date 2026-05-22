#if canImport(UIKit)
import Combine
import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Drives the Agent Live Stage through its three layout phases. Lives in
/// `RootTabView` so the same instance survives tab swaps and is shared
/// between the dock tile, the maximize layer, and the Chat Puck.
///
/// Auto-open contract (decided in spec): on `AgentWatchState.sessionId`
/// becoming non-nil the stage springs into `.dock`. When the session
/// ends, the stage stays in dock for a 6-second grace window so the final
/// audit-head update and action animation finish playing, then collapses
/// with `stripExpand`.
///
/// The presenter is intentionally pure-data: it never touches the relay,
/// the signer, or the video pipeline. It only flips its `mode` and a few
/// layout knobs. This makes it cheap to unit-test (see
/// `AgentLiveStagePresenterTests`) and lets the consumer animate
/// transitions with whatever spring is appropriate for the surface.
@MainActor
final class AgentLiveStagePresenter: ObservableObject {
    enum Mode: Equatable, Sendable {
        /// No overlay rendered.
        case hidden
        /// 320×180 (compact) / 360×203 (regular) floating tile, mirror
        /// non-interactive — preview only.
        case dock
        /// 50/50 vertical (iPhone) or 60/40 horizontal (iPad regular)
        /// split with chat and the live mirror sharing the screen.
        /// Mirror is interactive; "You are driving" badge surfaces.
        case split
        /// Mirror fills the safe area; chat collapses to a draggable
        /// `ChatPuck` that expands into a floating panel on tap.
        case maximize
    }

    /// Stage corners snap targets. Used by both the dock tile and the
    /// chat puck so layout state is symmetric.
    enum Corner: String, Equatable, Sendable, CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    /// How long the stage stays in dock after the Mac session ends
    /// before collapsing to `.hidden`. Lets the final action animation
    /// and the audit-head update finish playing. Test-overridable.
    static var sessionEndGrace: TimeInterval = 6

    @Published private(set) var mode: Mode = .hidden
    @Published var dockCorner: Corner = .bottomTrailing
    @Published var puckCorner: Corner = .bottomLeading
    /// `true` while the user has expanded the Chat Puck into the
    /// floating chat panel. Reset on every maximize-exit.
    @Published var chatPuckExpanded: Bool = false
    /// Mirrors system PiP lifecycle so views and tests can distinguish
    /// background PiP from an in-app dock/split/maximize stage.
    @Published private(set) var pipActive: Bool = false
    /// User-facing reason the stage collapsed (panic, session-end,
    /// dismissed). Cleared on the next dock entry.
    @Published private(set) var collapseReason: CollapseReason?

    enum CollapseReason: Equatable, Sendable {
        case sessionEnded
        case panic
        case dismissed
    }

    private var graceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var observedState: AgentWatchState?
    private var manualDockAfterSessionEnd = false

    init() {}

    // MARK: - Observation

    /// Subscribe to the singleton's state. Calling more than once swaps
    /// the subscription onto the new state instance (e.g., between unit
    /// test fixtures).
    func observe(_ state: AgentWatchState) {
        guard observedState !== state else { return }
        observedState = state
        cancellables.removeAll(keepingCapacity: true)
        state.$sessionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionId in
                self?.handleSessionIDChange(sessionId)
            }
            .store(in: &cancellables)
    }

    private func handleSessionIDChange(_ sessionId: ComputerUseSessionID?) {
        if sessionId != nil {
            cancelGrace()
            manualDockAfterSessionEnd = false
            collapseReason = nil
            if mode == .hidden {
                mode = .dock
            }
        } else if manualDockAfterSessionEnd {
            cancelGrace()
        } else if mode != .hidden {
            pipActive = false
            scheduleGraceCollapse(reason: .sessionEnded)
        }
    }

    // MARK: - User intents

    func enterDock() {
        cancelGrace()
        manualDockAfterSessionEnd = observedState?.sessionId == nil
        pipActive = false
        mode = .dock
        chatPuckExpanded = false
    }

    /// Move dock → split, or split ↔ maximize, depending on starting
    /// state. Symmetric with `requestCollapse()` (the "smaller" gesture).
    func requestExpand() {
        switch mode {
        case .hidden, .dock:
            mode = .split
        case .split:
            mode = .maximize
        case .maximize:
            break
        }
    }

    /// Inverse of `requestExpand()`. From maximize → split → dock →
    /// hidden (only when the user explicitly dismisses, otherwise dock
    /// is the floor while a session is live).
    func requestCollapse(sessionActive: Bool) {
        switch mode {
        case .maximize:
            mode = .split
            chatPuckExpanded = false
        case .split:
            mode = .dock
        case .dock:
            if sessionActive {
                // Sticky at dock while a session is live — user must use
                // `dismiss()` to force hide.
                break
            } else {
                cancelGrace()
                mode = .hidden
            }
        case .hidden:
            break
        }
    }

    /// User explicitly dismisses the stage (long-press dismiss). Suppresses
    /// further auto-open until a new session arrives.
    func dismiss() {
        cancelGrace()
        manualDockAfterSessionEnd = false
        pipActive = false
        mode = .hidden
        chatPuckExpanded = false
        collapseReason = .dismissed
    }

    /// Panic halt was triggered: collapse instantly + remember reason
    /// so the dock-tile entry animation can paint a one-shot ember
    /// pulse the next time the stage opens.
    func panicCollapse() {
        cancelGrace()
        manualDockAfterSessionEnd = false
        pipActive = false
        mode = .hidden
        chatPuckExpanded = false
        collapseReason = .panic
    }

    /// System PiP started or stopped outside SwiftUI's own stage chrome.
    func setPiPActive(_ active: Bool) {
        pipActive = active
    }

    /// User tapped the system PiP tile. Flip back into the full mirror with
    /// the chat puck available, matching the spec's SysPiP → Maximize edge.
    func enterMaximizeFromPiP() {
        cancelGrace()
        manualDockAfterSessionEnd = false
        pipActive = false
        collapseReason = nil
        mode = .maximize
        chatPuckExpanded = false
    }

    /// Toggle Chat Puck between collapsed (56pt) and expanded
    /// (320×420 panel). Only meaningful while `mode == .maximize`.
    func toggleChatPuck() {
        guard mode == .maximize else { return }
        chatPuckExpanded.toggle()
    }

    // MARK: - Snap helpers

    func snapDock(to corner: Corner) { dockCorner = corner }
    func snapPuck(to corner: Corner) { puckCorner = corner }

    /// Returns the nearest snap corner for a CGPoint inside a given
    /// container. Used by drag gestures on the dock tile and the puck.
    static func nearestCorner(for point: CGPoint, in size: CGSize) -> Corner {
        let isLeading = point.x < size.width / 2
        let isTop = point.y < size.height / 2
        switch (isTop, isLeading) {
        case (true, true):   return .topLeading
        case (true, false):  return .topTrailing
        case (false, true):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    // MARK: - Grace handling

    private func scheduleGraceCollapse(reason: CollapseReason) {
        cancelGrace()
        let grace = Self.sessionEndGrace
        graceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.manualDockAfterSessionEnd = false
            self.collapseReason = reason
            self.mode = .hidden
            self.chatPuckExpanded = false
            self.pipActive = false
            self.graceTask = nil
        }
    }

    private func cancelGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    // MARK: - Diagnostics

    var isOverlayVisible: Bool { mode != .hidden }
    var isInteractive: Bool { mode == .split || mode == .maximize }
}
#endif
