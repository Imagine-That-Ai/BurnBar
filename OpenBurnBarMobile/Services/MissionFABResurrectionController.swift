import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Mission FAB Resurrection Controller
//
// Owns the dismissed/visible state of `MobileMissionFAB` across:
//   • the running view tree (replaces the old `@State private isDismissed`)
//   • app cold launches (persisted to UserDefaults)
//   • critical mission-console events (auto-resurrect when an approval ask
//     appears or a mission fails — the user shouldn't have to hunt for the
//     restore dot when the agent fleet is begging for attention)
//
// Three resurrect paths exist by design (plan §1: "the user always knows
// what to do next"):
//   1. The 12pt restore dot at the dismissed edge (the original path; now
//      a 16pt visual with a 32pt hit zone + breathing pulse + pending-
//      approval halo)
//   2. Settings → Experimental → "Mission Console orb" toggle (durable,
//      discoverable, survives every dismissal)
//   3. Long-press the Hermes nav tab (covert, gesture-only, fast)
//
// Plus the auto-resurrect rule: critical events flip the orb back on
// regardless of user preference, with a one-shot `wasAutoResurrected`
// flag the orb reads to render a one-time "I'm back because…" pulse.

@MainActor
@Observable
final class MissionFABResurrectionController {

    // MARK: - Shared instance

    static let shared = MissionFABResurrectionController()

    // MARK: - Public state

    /// Whether the FAB is currently hidden. Source of truth — replaces
    /// the per-view `@State private var isDismissed`.
    var isDismissed: Bool {
        didSet {
            guard isDismissed != oldValue else { return }
            persist()
            if !isDismissed { dismissedAt = nil }
        }
    }

    /// ISO-stamped moment the user dismissed the orb. Lets the restore
    /// dot show "Hidden 12m ago" tooltips in a future polish pass.
    private(set) var dismissedAt: Date? {
        didSet { persistDismissedAt() }
    }

    /// One-shot signal the orb reads to render its "auto-back" pulse.
    /// The orb clears this after consuming.
    var wasAutoResurrected: Bool = false

    /// Reason the orb came back, for accessibility narration + the
    /// one-shot tooltip. Cleared alongside `wasAutoResurrected`.
    private(set) var autoResurrectReason: AutoResurrectReason?

    enum AutoResurrectReason: String, Sendable, Hashable {
        case approvalAsk
        case missionFailed
        case settingsToggle
        case longPressTab
        case manualRestoreDot

        var displayMessage: String {
            switch self {
            case .approvalAsk:       return "Approval waiting — orb restored."
            case .missionFailed:     return "Mission failed — orb restored."
            case .settingsToggle:    return "Restored from Settings."
            case .longPressTab:      return "Restored — long-pressed Assistants."
            case .manualRestoreDot:  return "Restored from edge dot."
            }
        }
    }

    // MARK: - Persistence keys

    private static let isDismissedKey = "missionFAB.isDismissed.v1"
    private static let dismissedAtKey = "missionFAB.dismissedAt.v1"

    // MARK: - Init

    init() {
        self.isDismissed = UserDefaults.standard.bool(forKey: Self.isDismissedKey)
        if let ts = UserDefaults.standard.object(forKey: Self.dismissedAtKey) as? TimeInterval {
            self.dismissedAt = Date(timeIntervalSince1970: ts)
        } else {
            self.dismissedAt = nil
        }
    }

    /// Test/preview seed.
    static func offline(initiallyDismissed: Bool = false) -> MissionFABResurrectionController {
        let inst = MissionFABResurrectionController()
        inst.isDismissed = initiallyDismissed
        inst.wasAutoResurrected = false
        inst.autoResurrectReason = nil
        return inst
    }

    // MARK: - User-facing actions

    /// Flick / long-press dismiss path. Stamps the dismissed-at time so
    /// the restore-dot tooltip can read it in a future polish pass.
    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        dismissedAt = Date()
        wasAutoResurrected = false
        autoResurrectReason = nil
    }

    /// Manual restore from the edge dot.
    func restoreFromDot() {
        guard isDismissed else { return }
        restore(reason: .manualRestoreDot, isAuto: false)
    }

    /// Restore from the Settings toggle.
    func restoreFromSettings() {
        restore(reason: .settingsToggle, isAuto: false)
    }

    /// Restore from a long-press on the Hermes nav tab.
    func restoreFromLongPress() {
        restore(reason: .longPressTab, isAuto: false)
    }

    /// Toggle convenience used by the Settings switch.
    func setDismissed(_ dismissed: Bool) {
        if dismissed {
            dismiss()
        } else {
            restoreFromSettings()
        }
    }

    // MARK: - Auto-resurrect from snapshot

    /// Called by the FAB view whenever the mission-console snapshot
    /// changes. If the orb is currently dismissed AND the snapshot is in
    /// a "you need to look at this" state, auto-resurrect and stamp the
    /// one-shot `wasAutoResurrected` flag.
    ///
    /// Rules (intentionally conservative — false-positives would defeat
    /// the user's right to dismiss):
    ///   • An approval is awaiting response → restore
    ///   • A mission terminated in `.failed` AND the failure happened in
    ///     the last 30s → restore
    func reconcile(against snapshot: MissionConsoleSnapshot) {
        guard isDismissed else { return }
        let now = Date()

        if !snapshot.approvalAsks.isEmpty {
            triggerAutoResurrect(reason: .approvalAsk)
            return
        }

        let recentFailure = snapshot.activeTiles.contains { tile in
            guard tile.phase == .failed else { return false }
            guard let started = tile.startedAt else { return false }
            return now.timeIntervalSince(started) < 30
        }
        if recentFailure {
            triggerAutoResurrect(reason: .missionFailed)
        }
    }

    /// Called once the orb's UI has rendered its auto-resurrect pulse so
    /// subsequent renders don't keep pulsing.
    func consumeAutoResurrectSignal() {
        wasAutoResurrected = false
        autoResurrectReason = nil
    }

    // MARK: - Private

    private func restore(reason: AutoResurrectReason, isAuto: Bool) {
        guard isDismissed else { return }
        isDismissed = false
        wasAutoResurrected = isAuto
        autoResurrectReason = reason
    }

    private func triggerAutoResurrect(reason: AutoResurrectReason) {
        isDismissed = false
        wasAutoResurrected = true
        autoResurrectReason = reason
    }

    private func persist() {
        UserDefaults.standard.set(isDismissed, forKey: Self.isDismissedKey)
    }

    private func persistDismissedAt() {
        if let date = dismissedAt {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.dismissedAtKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.dismissedAtKey)
        }
    }
}
