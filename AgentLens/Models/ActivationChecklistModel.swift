import Foundation
import Observation
import OpenBurnBarKernel

// MARK: - Activation Checklist Model

/// Derives the five-switch activation path (plan §4.4 / Tier 1 item 6) as
/// live state, not stored progress.
///
/// WHY derived: a fresh install ships with indexing, memory, the gateway and
/// the inbox all off. The checklist's job is to walk the user through those
/// switches — so each step's done-state must be the switch itself, read live
/// from `SettingsManager` / `DataStoreCoordinator`. Storing per-step progress
/// would let the card drift from reality the first time a switch is flipped
/// anywhere else. The only stored facts are the user's dismissal and the
/// completion timestamp (see `ActivationSettings`).
@Observable
@MainActor
final class ActivationChecklistModel {

    // MARK: Step identity

    enum StepID: String, CaseIterable, Identifiable {
        case seeNumber
        case indexSessions
        case turnOnMemory
        case routeDrains
        case armInbox

        var id: String { rawValue }
    }

    /// What the card should do when a step's single action button is clicked.
    /// The model names the intent; the view owns execution, because the
    /// targets (the usage aggregator, the Settings sheet, the consent sheet)
    /// are view-layer dependencies.
    enum StepAction: Equatable {
        /// Kick a usage scan now instead of waiting for the next refresh tick.
        case scanNow
        /// Open Settings routed to a specific `SettingsManifest` item.
        case openSettingsItem(String)
        /// Present the memory consent sheet (gate G0). Consent is granted on a
        /// dashboard sheet, not in Settings — deep-linking to the Settings
        /// memory toggle while consent is still false would hand the user a
        /// switch that does nothing.
        case presentMemoryConsent
    }

    struct Step: Identifiable, Equatable {
        let id: StepID
        let title: String
        let detail: String
        let actionTitle: String
        let action: StepAction
        let isDone: Bool
        let isCurrent: Bool
    }

    // MARK: Dependencies

    private let settingsManager: SettingsManager
    private let dataStore: DataStoreCoordinator
    private let inboxEnabledProbe: @Sendable () async -> Bool?

    // MARK: Daemon-owned state
    //
    // The AI Inbox `enabled` lever is daemon-side config (`BurnBarInboxConfig`)
    // with no app-side persisted mirror — the daemon owns the loop, the
    // credentials, and the egress policy, and re-clamps every write. The only
    // observable app-side state is a socket read of the stored config, so the
    // model keeps the last answer here: nil until the daemon responds, and an
    // unreachable daemon honestly counts as "not armed".

    private(set) var inboxEnabled: Bool?
    @ObservationIgnored private var inboxProbeInFlight = false

    // MARK: Completion beat

    /// One quiet acknowledgment the moment the last switch lands, then gone
    /// for good. No confetti, no modal — the timestamp is stamped before the
    /// beat starts, so even a crash mid-beat retires the card. The view owns
    /// the timeout (see `ActivationChecklistCard`) so the retirement animates.
    private(set) var isShowingCompletionBeat = false
    static let completionBeatNanoseconds: UInt64 = 5_000_000_000

    // MARK: - Init

    init(
        settingsManager: SettingsManager,
        dataStore: DataStoreCoordinator,
        inboxEnabledProbe: (@Sendable () async -> Bool?)? = nil
    ) {
        self.settingsManager = settingsManager
        self.dataStore = dataStore
        self.inboxEnabledProbe = inboxEnabledProbe ?? Self.liveInboxEnabledProbe()
    }

    // MARK: - Derived state

    /// Step 1 is earned by evidence, not a toggle: the scan already ran at
    /// startup, so any tracked session or non-zero spend today means the user
    /// has a real number on screen.
    private var numberSeen: Bool {
        dataStore.totalUsageSessionCount > 0 || dataStore.totalCostToday > 0
    }

    var steps: [Step] {
        let done: [StepID: Bool] = [
            .seeNumber: numberSeen,
            .indexSessions: settingsManager.conversationIndexingEnabled,
            .turnOnMemory: settingsManager.memoryExtractionEnabled,
            .routeDrains: settingsManager.gatewayEnabled,
            .armInbox: inboxEnabled == true
        ]
        let currentID = StepID.allCases.first { done[$0] != true }
        return StepID.allCases.map { id in
            makeStep(id, isDone: done[id] == true, isCurrent: id == currentID)
        }
    }

    var doneCount: Int { steps.filter(\.isDone).count }

    var allStepsDone: Bool { steps.allSatisfy(\.isDone) }

    /// The card renders until the user dismisses it or completion is stamped;
    /// after the stamp it lingers only for the single completion beat.
    var shouldShowCard: Bool {
        if settingsManager.activationChecklistDismissed { return false }
        if settingsManager.activationChecklistCompletedAt != nil { return isShowingCompletionBeat }
        return true
    }

    // MARK: - Step copy
    //
    // Copy rules from the plan: imperative, concrete, honest, grounded in a
    // number where one exists. Details render only on the current step, so
    // each line has to carry the whole pitch for its switch.

    private func makeStep(_ id: StepID, isDone: Bool, isCurrent: Bool) -> Step {
        switch id {
        case .seeNumber:
            return Step(
                id: id,
                title: "See your number",
                detail: "The logs are already on this Mac. A scan turns them into today's spend, up in the menu bar.",
                actionTitle: "Scan now",
                action: .scanNow,
                isDone: isDone,
                isCurrent: isCurrent
            )
        case .indexSessions:
            let count = dataStore.totalUsageSessionCount
            return Step(
                id: id,
                title: "Index your sessions",
                detail: count > 0
                    ? "Make \(count.formatted()) tracked sessions searchable. Indexed text stays on this Mac."
                    : "Make your sessions searchable. Indexed text stays on this Mac.",
                actionTitle: "Turn it on",
                action: .openSettingsItem(SettingsAnchor.indexingToggle),
                isDone: isDone,
                isCurrent: isCurrent
            )
        case .turnOnMemory:
            // Consent (G0) is the outermost lever: until it is granted, the
            // Settings memory toggle is inert, so the action must be the
            // consent sheet itself. Once granted, the remaining levers (the
            // user toggle, the fleet kill switch) live on the same Settings
            // surface as indexing.
            let consentGranted = settingsManager.memoryConsentGranted
            return Step(
                id: id,
                title: "Turn on memory",
                detail: "Memory extracts durable facts from your sessions, locally. You approve every fact before it's kept.",
                actionTitle: consentGranted ? "Turn it on" : "Review and allow",
                action: consentGranted
                    ? .openSettingsItem(SettingsAnchor.indexingToggle)
                    : .presentMemoryConsent,
                isDone: isDone,
                isCurrent: isCurrent
            )
        case .routeDrains:
            return Step(
                id: id,
                title: "Route around drains",
                detail: "A local gateway skips accounts that are out of quota and prefers the window that resets soonest.",
                actionTitle: "Set it up",
                action: .openSettingsItem(SettingsAnchor.modelProxyOverview),
                isDone: isDone,
                isCurrent: isCurrent
            )
        case .armInbox:
            return Step(
                id: id,
                title: "Arm the inbox",
                detail: "It catches work an agent claimed but never landed. About $0.016 per active check, capped at $1.50 a day.",
                actionTitle: "Arm it",
                action: .openSettingsItem(SettingsDeepLinkRouting.aiInboxItemID),
                isDone: isDone,
                isCurrent: isCurrent
            )
        }
    }

    // MARK: - Actions

    /// Records the memory consent decision. Mirrors
    /// `DashboardConsentCoordinator.confirmMemoryConsent`: granting flips the
    /// consent lever (whose setter also marks the prompt shown); declining
    /// only marks it shown so the loop stays dormant.
    func recordMemoryConsent(granted: Bool) {
        settingsManager.memoryConsentGranted = granted
        if !granted {
            settingsManager.memoryConsentShown = true
        }
        markCompletedIfNeeded()
    }

    /// Re-reads the daemon-stored inbox config. Cheap (one loopback socket
    /// round trip off the main actor) and guarded, so callers can invoke it
    /// on every plausible change signal without piling up probes.
    func refreshInboxEnabled() async {
        guard shouldShowCard, !inboxProbeInFlight else { return }
        inboxProbeInFlight = true
        defer { inboxProbeInFlight = false }
        inboxEnabled = await inboxEnabledProbe()
        markCompletedIfNeeded()
    }

    /// Stamps the completion timestamp the first time every step reads done,
    /// and starts the one quiet completion beat. Idempotent — the stamp is
    /// the retire, so a second call can never replay the beat.
    func markCompletedIfNeeded() {
        guard settingsManager.activationChecklistCompletedAt == nil, allStepsDone else { return }
        settingsManager.activationChecklistCompletedAt = Date()
        guard !settingsManager.activationChecklistDismissed else { return }
        isShowingCompletionBeat = true
    }

    func finishCompletionBeat() {
        isShowingCompletionBeat = false
    }

    /// The user closed the card. Forever — see `ActivationSettings`.
    func dismiss() {
        settingsManager.activationChecklistDismissed = true
    }

    // MARK: - Live inbox probe

    /// Production probe: read the daemon-stored inbox config over the local
    /// socket. Blocking POSIX I/O never runs on the main actor (the same rule
    /// `ControlDeckModel` follows); any failure — daemon down, auth rotated —
    /// answers nil, which the checklist treats as "not armed".
    private static func liveInboxEnabledProbe() -> @Sendable () async -> Bool? {
        {
            let socketURL = OpenBurnBarDaemonRuntimePaths.live().socketURL
            let probe = Task.detached(priority: .utility) {
                try OpenBurnBarDaemonSocketClient.inboxConfiguration(at: socketURL).enabled
            }
            return try? await probe.value // try?-ok(unreachable daemon = not armed)
        }
    }
}
