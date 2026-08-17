import OpenBurnBarKernel
import Foundation
import Observation
import SwiftUI

// MARK: - Confidence Presentation

/// Documented confidence level → label/color mapping for the fleet dashboard
/// (VAL-DASH-024). Every level is textually labeled — never color-only — and
/// the mapping is deterministic and fixed-DTO testable.
///
/// The color mapping is pinned here and documented in
/// docs/fleet/BURNBAR_FLEET_SIGNALS.md ("Fleet dashboard rendering contract").
/// Every level color meets the WCAG AA 3:1 UI-component boundary against the
/// card surface in both appearances (verified by
/// `FleetConfidencePresentationTests`); the textual label is the primary
/// carrier of meaning (VAL-DASH-021).
enum FleetConfidencePresentation {
    /// Canonical textual label for a confidence level.
    static func label(for confidence: BurnBarFleetConfidence) -> String {
        switch confidence {
        case .exactProcess:
            return "Exact process"
        case .activeSessionFile:
            return "Session file"
        case .logHeartbeat:
            return "Log heartbeat"
        case .estimated:
            return "Estimated"
        case .unsupported:
            return "No live signal"
        }
    }

    /// Short badge label (fits chips and cards).
    static func shortLabel(for confidence: BurnBarFleetConfidence) -> String {
        switch confidence {
        case .exactProcess:
            return "Exact"
        case .activeSessionFile:
            return "Session"
        case .logHeartbeat:
            return "Heartbeat"
        case .estimated:
            return "Estimated"
        case .unsupported:
            return "Unsupported"
        }
    }

    /// The level color for a confidence value. All five values are pairwise
    /// distinct in both appearances (colorblind-safe rendering pairs the
    /// color with the textual label — never color-only, VAL-DASH-004/024).
    /// Every level color meets the WCAG AA 3:1 UI-component boundary against
    /// the card surface in both appearances (verified by
    /// `FleetConfidencePresentationTests`).
    static func color(for confidence: BurnBarFleetConfidence) -> Color {
        switch confidence {
        case .exactProcess:
            return DesignSystem.Colors.success
        case .activeSessionFile:
            return DesignSystem.Colors.whimsy
        case .logHeartbeat:
            return DesignSystem.Colors.warning
        case .estimated:
            return DesignSystem.Colors.blaze
        case .unsupported:
            return DesignSystem.Colors.textMuted
        }
    }

    /// Provenance copy for a card's accessibility label: the confidence label
    /// plus the first non-secret signal kind when one exists (VAL-DASH-027).
    /// Only the signal KIND is used — never the path or detail, which could
    /// bear secret material.
    static func provenance(for agent: BurnBarFleetAgent) -> String {
        let confidenceLabel = label(for: agent.confidence)
        guard let signalKind = agent.signals.first?.kind, !signalKind.isEmpty else {
            return confidenceLabel
        }
        return "\(confidenceLabel) · \(signalKind)"
    }

    /// Visible per-card provenance text (VAL-DASH-027): the confidence label
    /// plus the first non-secret signal kind when one exists. Unsupported rows
    /// state that no live signal is available. Never color-only, never
    /// secret-bearing (kind only, never path/detail).
    static func provenanceLabel(for agent: BurnBarFleetAgent) -> String {
        switch agent.confidence {
        case .unsupported:
            return "No live signal"
        default:
            return provenance(for: agent)
        }
    }
}

// MARK: - Status Presentation

/// Documented status → label/color mapping for the fleet dashboard
/// (VAL-DASH-005/025). `unknown` has its own treatment, distinct from `idle`
/// and from the empty-fleet state. Every status color meets the WCAG AA 3:1
/// UI-component boundary against the card surface in both appearances.
enum FleetStatusPresentation {
    static func label(for status: BurnBarFleetAgentStatus) -> String {
        switch status {
        case .running:
            return "Running"
        case .idle:
            return "Idle"
        case .stale:
            return "Stale"
        case .unknown:
            return "Unknown"
        }
    }

    static func color(for status: BurnBarFleetAgentStatus) -> Color {
        switch status {
        case .running:
            return DesignSystem.Colors.success
        case .idle:
            return DesignSystem.Colors.textMuted
        case .stale:
            return DesignSystem.Colors.warning
        case .unknown:
            return DesignSystem.Colors.textSecondary
        }
    }
}

// MARK: - Repo Group Row Model

/// One per-repo group row (VAL-DASH-010/019): project name, member agent ids,
/// and collapse state. The "No repo" bucket holds agents with nil/empty
/// projectName — they are never dropped. Collapse state lives in the view
/// model so it survives snapshot polls; the count always reflects the latest
/// snapshot.
struct FleetRepoGroupRowModel: Equatable, Identifiable {
    let projectName: String
    let agentIDs: [BurnBarFleetAgentID]
    var isCollapsed: Bool

    var id: String { projectName }
    var count: Int { agentIDs.count }
}

// MARK: - Machine Row Model

/// One machine-panel row (VAL-DASH-011/022/030): label, rendered value, and
/// typed unavailability. Absent optional metrics carry `value == nil` and
/// `isUnavailable == true` — the view renders "—" and the accessibility
/// label states unavailability. Absence is never formatted as 0, NaN, or a
/// current-looking value.
struct FleetMachineRow: Equatable, Identifiable {
    let label: String
    let value: String?
    let isUnavailable: Bool
    let accessibilityLabel: String

    var id: String { label }

    /// Deterministic rows for a machine status block. Numeric metrics render
    /// through `FleetFormatting` (units, thresholds); thermal/power render
    /// their typed sensor state (available value or "Unavailable (reason)").
    static func rows(for machine: BurnBarMachineStatus) -> [FleetMachineRow] {
        func metric(_ label: String, _ value: String?) -> FleetMachineRow {
            FleetMachineRow(
                label: label,
                value: value,
                isUnavailable: value == nil,
                accessibilityLabel: value.map { "\(label): \($0)" } ?? "\(label): unavailable"
            )
        }
        var rows: [FleetMachineRow] = [
            metric("CPU", machine.cpuPercent.map { FleetFormatting.formatCPU($0) }),
            metric(
                "Memory",
                machine.memoryUsedBytes.map {
                    FleetFormatting.formatMemory(used: $0, total: machine.memoryTotalBytes)
                }
            ),
            metric("Load", machine.loadAverage.map { FleetFormatting.formatLoadAverage($0) }),
            metric("Disk free", machine.diskFreeBytes.map { FleetFormatting.formatDiskFree($0) })
        ]
        rows.append(sensorRow("Thermal", machine.thermal))
        rows.append(sensorRow("Power", machine.power))
        return rows
    }

    private static func sensorRow(_ label: String, _ state: BurnBarSensorState) -> FleetMachineRow {
        switch state {
        case .available(let value):
            let text = String(format: "%.1f", value)
            return FleetMachineRow(
                label: label,
                value: text,
                isUnavailable: false,
                accessibilityLabel: "\(label): \(text)"
            )
        case .unavailable(let reason):
            let text = "Unavailable (\(reason))"
            return FleetMachineRow(
                label: label,
                value: text,
                isUnavailable: true,
                accessibilityLabel: "\(label): unavailable (\(reason))"
            )
        }
    }
}

// MARK: - Resource Consumer Model

/// One resource-consumers row (VAL-DASH-012/023). Exact rows carry per-pid
/// CPU/memory from the snapshot's `process` block; proxy rows carry a
/// token-burn estimate derived from usage history and are ALWAYS labeled
/// "Proxy" — never formatted identically to exact numbers without the label.
struct FleetResourceConsumer: Equatable, Identifiable {
    let agentID: BurnBarFleetAgentID
    let pid: Int?
    let cpuPercent: Double?
    let memoryBytes: Int?
    let tokensPerMinute: Double?
    let isProxy: Bool

    var id: String { agentID.wireValue }
}

// MARK: - Token Burn Estimator

/// Token-burn proxy estimator (VAL-DASH-012): derives a tokens/minute rate
/// from the app's usage history for agents WITHOUT a process block. The
/// estimate is explicitly a proxy — it is never presented as an exact
/// per-process measurement. Returns nil when no usage history supports an
/// estimate (the agent then gets no proxy row).
enum FleetTokenBurnEstimator {
    /// Usage rows within this window count toward the burn estimate.
    static let windowSeconds: TimeInterval = 600

    /// Minimum elapsed time considered for a rate (avoids division blow-up
    /// from a single row just written).
    static let minimumElapsedSeconds: TimeInterval = 60

    /// Tokens/minute for a fleet agent, derived from usage rows in the
    /// window. The rate is total tokens in the window divided by the
    /// elapsed time from the earliest row to `now` (clamped to the
    /// minimum), so a burst of recent rows yields a higher rate.
    static func estimateTokensPerMinute(
        usages: [TokenUsage],
        agentID: BurnBarFleetAgentID,
        now: Date = Date()
    ) -> Double? {
        guard let provider = AgentProvider(fleetAgentID: agentID) else { return nil }
        let windowStart = now.addingTimeInterval(-windowSeconds)
        let rows = usages.filter { $0.provider == provider && $0.startTime >= windowStart }
        guard !rows.isEmpty else { return nil }
        let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
        let earliest = rows.map(\.startTime).min() ?? windowStart
        let elapsed = max(minimumElapsedSeconds, now.timeIntervalSince(earliest))
        return Double(totalTokens) / (elapsed / 60)
    }
}

// MARK: - Fleet View Model

/// View model for the fleet dashboard (M3). Owns the `FleetService` lifecycle
/// for the view (start on appear, stop on disappear, restart on reopen) and
/// exposes typed, deterministic presentation state derived from the snapshot.
///
/// The view model never fabricates data: every row, count, and label derives
/// from the daemon snapshot (or the typed degraded state).
@MainActor
@Observable
final class FleetViewModel {
    /// The service backing this view model. Exactly one poller exists while
    /// the view is visible (VAL-DASH-015/018).
    let service: FleetService

    /// Whether the view is currently visible (drives the poller lifecycle).
    private(set) var isVisible = false

    /// The display name of the explicit ungrouped bucket (VAL-DASH-010):
    /// agents with nil/empty projectName appear here, never dropped.
    static let noRepoBucketName = "No repo"

    /// Collapse state per repo group, keyed by project name (VAL-DASH-019).
    /// Lives here — not in the view — so it survives snapshot polls. The
    /// count badge always reflects the latest snapshot, collapsed or not.
    private var collapsedRepos: Set<String> = []

    /// Token-burn provider (injectable for tests): returns the estimated
    /// tokens/minute for an agent, or nil when no usage history supports an
    /// estimate. Defaults to no proxy rows; the app wires the
    /// usage-history-backed estimator (DashboardView).
    private let tokenBurnProvider: (BurnBarFleetAgentID) -> Double?

    init(
        service: FleetService,
        tokenBurnProvider: @escaping (BurnBarFleetAgentID) -> Double? = { _ in nil }
    ) {
        self.service = service
        self.tokenBurnProvider = tokenBurnProvider
    }

    /// The typed load state (loading/ready/empty/daemonDown).
    var loadState: FleetLoadState { service.loadState }

    /// The latest snapshot, if any.
    var snapshot: BurnBarFleetSnapshot? { service.loadState.snapshot }

    /// The daemon-owned orchestrator state (designation + pending count),
    /// fetched on demand (M4). A previously acknowledged value is retained
    /// across refresh failures; nil means no authoritative state has ever
    /// been received.
    var orchestratorState: BurnBarOrchestratorState? { service.orchestratorState }

    /// Typed reason when the orchestrator state could not be fetched.
    var orchestratorStateError: String? { service.orchestratorStateError }

    /// True while a designation set request is in flight (the control
    /// changes only after daemon acknowledgement — VAL-ORCH-034).
    var isSettingDesignation: Bool { service.isSettingDesignation }

    /// The current designation kind for the control (VAL-ORCH-034). An
    /// unavailable daemon is represented by nil, never fabricated as the
    /// authoritative `.none` designation.
    var designationKind: BurnBarOrchestratorDesignation? {
        orchestratorState?.designation
    }

    /// True when the designation control has no authoritative state or its
    /// last refresh failed. The Fleet view suppresses the picker and badge
    /// in this state rather than presenting "No orchestrator designated".
    var isDesignationUnavailable: Bool {
        orchestratorState == nil || orchestratorStateError != nil
    }

    /// True when the given agent is the designated orchestrator (the badge
    /// on the agent's card, VAL-ORCH-005). Derives from daemon state.
    func isDesignatedAgent(_ agentID: BurnBarFleetAgentID) -> Bool {
        if case .agent(let id, _) = designationKind, orchestratorStateError == nil {
            return id == agentID
        }
        return false
    }

    /// Fetches the daemon-owned orchestrator state (called when the fleet
    /// view appears and after each acknowledged set).
    func refreshOrchestratorState() {
        service.refreshOrchestratorState()
    }

    /// Sets the daemon-owned designation. The control/badge changes only
    /// after daemon acknowledgement; a rejected or unavailable set preserves
    /// the prior acknowledged state and surfaces a typed error
    /// (VAL-ORCH-034).
    func setDesignation(_ designation: BurnBarOrchestratorDesignation) async {
        await service.setDesignation(designation)
    }

    /// Whether the current snapshot is stale per the documented
    /// `2 * cadenceSeconds` threshold (VAL-DASH-006/009).
    var isStale: Bool { service.isStale }

    /// Snapshot age in seconds (for the stale-age display).
    var snapshotAgeSeconds: TimeInterval? { service.snapshotAgeSeconds }

    /// The snapshot cadence (seconds).
    var cadenceSeconds: Int { service.cadenceSeconds }

    /// Total running count from the snapshot.
    var runningCount: Int { snapshot?.runningCount ?? 0 }

    /// Pinned-header running readout. A missing snapshot is never shown as
    /// "0 running" (VAL-DASH-028).
    enum HeaderRunningReadout: Equatable {
        case checking
        case unavailable
        case running(Int)
    }

    var headerRunningReadout: HeaderRunningReadout {
        switch loadState {
        case .loading:
            return .checking
        case .daemonDown:
            return .unavailable
        case .ready, .empty:
            return .running(runningCount)
        }
    }

    /// Per-provider running counts, ordered by the declared roster order.
    /// Agents with count 0 are included so the view can render explicit
    /// zero-count chips (documented rule: zero-count chips render "0").
    var countsByProvider: [(agentID: BurnBarFleetAgentID, count: Int)] {
        guard let snapshot else { return [] }
        return BurnBarFleetAgentID.declaredRoster.map { id in
            (id, snapshot.countsByAgent[id.wireValue] ?? 0)
        }
    }

    /// Agent rows in the snapshot, in payload order.
    var agents: [BurnBarFleetAgent] {
        snapshot?.agents ?? []
    }

    /// Repo group rows (VAL-DASH-010/019): snapshot repos in payload order,
    /// plus the explicit "No repo" bucket holding agents with nil/empty
    /// projectName. Collapse state is per-project and survives polls; counts
    /// always reflect the latest snapshot.
    var repoGroupRows: [FleetRepoGroupRowModel] {
        guard let snapshot else { return [] }
        var rows = snapshot.repos.map { group in
            FleetRepoGroupRowModel(
                projectName: group.projectName,
                agentIDs: group.agents,
                isCollapsed: collapsedRepos.contains(group.projectName)
            )
        }
        let ungrouped = snapshot.agents
            .filter { $0.projectName == nil || $0.projectName?.isEmpty == true }
            .map(\.id)
        if !ungrouped.isEmpty {
            rows.append(
                FleetRepoGroupRowModel(
                    projectName: Self.noRepoBucketName,
                    agentIDs: ungrouped,
                    isCollapsed: collapsedRepos.contains(Self.noRepoBucketName)
                )
            )
        }
        return rows
    }

    /// Toggles the collapse state of a repo group (VAL-DASH-010/019). The
    /// state is stored in the view model so it survives snapshot polls.
    func toggleRepoCollapse(_ projectName: String) {
        if collapsedRepos.contains(projectName) {
            collapsedRepos.remove(projectName)
        } else {
            collapsedRepos.insert(projectName)
        }
    }

    /// Machine panel rows (VAL-DASH-011/022/030): deterministic formatting
    /// with units, typed per-field unavailability for absent optional
    /// metrics, and typed sensor states for thermal/power.
    var machineRows: [FleetMachineRow] {
        guard let machine = snapshot?.machine else { return [] }
        return FleetMachineRow.rows(for: machine)
    }

    /// Header cost-strip labels. Thermal/power stay on the full machine panel.
    static let headerMachineMetricLabels = ["CPU", "Memory", "Load", "Disk free"]

    var headerMachineMetrics: [FleetMachineRow] {
        machineRows.filter { Self.headerMachineMetricLabels.contains($0.label) }
    }

    /// Derived resource-consumer rows, cached per snapshot (the token-burn
    /// provider may scan usage history, so it must not run per render).
    private var cachedConsumers: (snapshot: BurnBarFleetSnapshot, rows: [FleetResourceConsumer])?

    /// Resource consumers (VAL-DASH-012/023): exact per-pid rows for agents
    /// whose snapshot rows carry `process` info, plus token-burn proxy rows
    /// for agents with a usage-history-backed estimate. Ordering is
    /// deterministic and documented: exact rows first (CPU desc, ties by
    /// pid asc), then proxy rows (tokens/min desc, ties by agent id asc).
    /// An agent with a process block never also gets a proxy row. The
    /// result is cached per snapshot so the provider runs once per poll,
    /// not once per render.
    var resourceConsumers: [FleetResourceConsumer] {
        guard let snapshot else { return [] }
        if let cached = cachedConsumers, cached.snapshot == snapshot {
            return cached.rows
        }
        var exact: [FleetResourceConsumer] = []
        var proxy: [FleetResourceConsumer] = []
        for agent in snapshot.agents {
            if let process = agent.process {
                exact.append(
                    FleetResourceConsumer(
                        agentID: agent.id,
                        pid: process.pid,
                        cpuPercent: process.cpuPercent,
                        memoryBytes: process.memoryBytes,
                        tokensPerMinute: nil,
                        isProxy: false
                    )
                )
            } else if let burn = tokenBurnProvider(agent.id) {
                proxy.append(
                    FleetResourceConsumer(
                        agentID: agent.id,
                        pid: nil,
                        cpuPercent: nil,
                        memoryBytes: nil,
                        tokensPerMinute: burn,
                        isProxy: true
                    )
                )
            }
        }
        exact.sort { lhs, rhs in
            let lhsCPU = lhs.cpuPercent ?? 0
            let rhsCPU = rhs.cpuPercent ?? 0
            if lhsCPU != rhsCPU { return lhsCPU > rhsCPU }
            return (lhs.pid ?? 0) < (rhs.pid ?? 0)
        }
        proxy.sort { lhs, rhs in
            let lhsBurn = lhs.tokensPerMinute ?? 0
            let rhsBurn = rhs.tokensPerMinute ?? 0
            if lhsBurn != rhsBurn { return lhsBurn > rhsBurn }
            return lhs.agentID.wireValue < rhs.agentID.wireValue
        }
        let rows = exact + proxy
        cachedConsumers = (snapshot, rows)
        return rows
    }

    /// Probe health entries (payload order).
    var probeHealth: [BurnBarFleetProbeHealth] {
        snapshot?.probeHealth ?? []
    }

    /// The provider theme color for a fleet agent id (via the app's
    /// `AgentProvider` mapping — VAL-CROSS-003).
    func providerColor(for agentID: BurnBarFleetAgentID) -> SwiftUI.Color {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return DesignSystem.Colors.textMuted
        }
        return DesignSystem.Colors.primary(for: provider)
    }

    /// The provider display name for a fleet agent id.
    func providerName(for agentID: BurnBarFleetAgentID) -> String {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return agentID.wireValue
        }
        return provider.displayName
    }

    /// The provider SF Symbol for a fleet agent id — the same icon the usage
    /// surface renders for the same provider (VAL-CROSS-003).
    func providerIconName(for agentID: BurnBarFleetAgentID) -> String {
        guard let provider = AgentProvider(fleetAgentID: agentID) else {
            return "questionmark.circle"
        }
        return provider.iconName
    }

    /// True for the typed unsupported roster rows (kimi, gemini-cli): present,
    /// labeled unsupported, and excluded from running/resource totals
    /// (VAL-DASH-031).
    func isUnsupportedRosterRow(_ agent: BurnBarFleetAgent) -> Bool {
        agent.confidence == .unsupported
    }

    // MARK: - Command Well

    var selectedAgentID: BurnBarFleetAgentID = .claudeCode
    var selectedThreadID: String?
    var composeKind: BurnBarFleetDirectiveKind = .askStatus
    var composePayload: String = ""
    var threadFilter: String = ""
    var lastHandoffNote: String?

    var selectedAgent: BurnBarFleetAgent? {
        agents.first { $0.id == selectedAgentID }
    }

    var threadsForSelectedCLI: [BurnBarFleetThread] {
        guard let snapshot else { return [] }
        let query = threadFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let threads = snapshot.threads(for: selectedAgentID)
        let filtered = query.isEmpty ? threads : threads.filter { thread in
            thread.id.lowercased().contains(query)
                || (thread.projectName?.lowercased().contains(query) ?? false)
                || (thread.currentTask?.lowercased().contains(query) ?? false)
                || FleetStatusPresentation.label(for: thread.status).lowercased().contains(query)
        }
        return filtered.sorted { lhs, rhs in
            if lhs.status.rollupRank != rhs.status.rollupRank {
                return lhs.status.rollupRank > rhs.status.rollupRank
            }
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
    }

    var selectedThread: BurnBarFleetThread? {
        if let selectedThreadID {
            return threadsForSelectedCLI.first { $0.id == selectedThreadID }
                ?? snapshot?.threads.first { $0.agentID == selectedAgentID && $0.id == selectedThreadID }
        }
        return threadsForSelectedCLI.first
    }

    var queue: [BurnBarFleetDirective] {
        snapshot?.recentDirectives ?? []
    }

    struct NeedsYouItem: Identifiable, Equatable {
        let id: String
        let text: String
    }

    var needsYouItems: [NeedsYouItem] {
        var items: [NeedsYouItem] = []
        switch loadState {
        case .daemonDown(let reason):
            items.append(NeedsYouItem(id: "daemon", text: "Daemon unreachable: \(reason)"))
        case .loading:
            break
        case .ready, .empty:
            break
        }
        if isStale {
            items.append(NeedsYouItem(id: "stale", text: "Snapshot is stale — the daemon has not refreshed on cadence."))
        }
        if let error = orchestratorStateError {
            items.append(NeedsYouItem(id: "designation", text: "Designation unavailable: \(error)"))
        }
        if let error = service.directiveActionError {
            items.append(NeedsYouItem(id: "directive", text: error))
        }
        if let snapshot {
            let pending = snapshot.recentDirectives.filter {
                if case .proposed = $0.state { return true }
                if case .approved = $0.state { return true }
                return false
            }
            if !pending.isEmpty {
                items.append(NeedsYouItem(
                    id: "pending",
                    text: "\(pending.count) directive\(pending.count == 1 ? "" : "s") waiting for approve or dismiss."
                ))
            }
            let failed = snapshot.recentDirectives.filter {
                if case .failed = $0.state { return true }
                return false
            }
            if !failed.isEmpty {
                items.append(NeedsYouItem(
                    id: "failed",
                    text: "\(failed.count) directive\(failed.count == 1 ? "" : "s") failed."
                ))
            }
            let degraded = snapshot.probeHealth.filter {
                if case .ok = $0.state { return false }
                return true
            }
            if !degraded.isEmpty {
                items.append(NeedsYouItem(
                    id: "probes",
                    text: "\(degraded.count) probe\(degraded.count == 1 ? "" : "s") degraded or failed."
                ))
            }
        }
        return items
    }

    func consumePendingJump() {
        guard let jump = service.consumePendingJump() else { return }
        selectedAgentID = jump.0
        selectedThreadID = jump.1
    }

    func selectCLI(_ agentID: BurnBarFleetAgentID) {
        selectedAgentID = agentID
        if selectedThread?.agentID != agentID {
            selectedThreadID = threadsForSelectedCLI.first?.id
        }
    }

    func selectThread(_ thread: BurnBarFleetThread) {
        selectedAgentID = thread.agentID
        selectedThreadID = thread.id
    }

    func moveThreadSelection(by delta: Int) {
        let threads = threadsForSelectedCLI
        guard !threads.isEmpty else { return }
        let current = selectedThread.flatMap { selected in threads.firstIndex(where: { $0.id == selected.id }) } ?? 0
        let next = min(max(current + delta, 0), threads.count - 1)
        selectedThreadID = threads[next].id
    }

    func runningThreadCount(for agentID: BurnBarFleetAgentID) -> Int? {
        guard snapshot != nil else { return nil }
        return snapshot?.countsByAgent[agentID.wireValue] ?? 0
    }

    func emptyCLIReason(for agentID: BurnBarFleetAgentID) -> String {
        if snapshot == nil { return "Waiting for snapshot." }
        if let agent = agents.first(where: { $0.id == agentID }) {
            if agent.confidence == .unsupported {
                return agent.note ?? "No live signal. Inbox still accepts a command."
            }
            if let note = agent.note, !note.isEmpty { return note }
        }
        return "No live or fresh threads for this CLI."
    }

    @discardableResult
    func queueDirective(state: BurnBarFleetDirectiveState = .proposed) async -> BurnBarFleetDirective? {
        let payload: String
        switch composeKind {
        case .askStatus:
            payload = composePayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Ask this thread for a concise status update."
                : composePayload
        case .summarize:
            payload = composePayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Summarize the current work in this thread."
                : composePayload
        case .focusRepo:
            payload = composePayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Focus on \(selectedThread?.projectName ?? selectedAgent?.projectName ?? "the current repo")."
                : composePayload
        case .suggestAssignee, .custom:
            let trimmed = composePayload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                lastHandoffNote = "Custom payload cannot be empty."
                return nil
            }
            payload = trimmed
        }
        let sessionRef = selectedThread?.id ?? "inbox"
        let directive = BurnBarFleetDirective(
            id: UUID().uuidString,
            kind: composeKind,
            targetAgent: selectedAgentID,
            sessionRef: sessionRef,
            payload: payload,
            state: state,
            createdAt: Date()
        )
        return await service.recordDirective(directive)
    }

    func designateSelectedThread() async {
        let sessionRef = selectedThread?.id
        let designation: BurnBarOrchestratorDesignation
        if let sessionRef {
            designation = .agent(id: selectedAgentID, sessionRef: .present(sessionRef))
        } else {
            designation = .agent(id: selectedAgentID, sessionRef: .absent)
        }
        await setDesignation(designation)
    }

    func approveAndHandOff(_ directive: BurnBarFleetDirective? = nil) async {
        let source: BurnBarFleetDirective?
        if let directive {
            source = directive
        } else {
            source = await queueDirective(state: .proposed)
        }
        guard let source else { return }
        let approved = BurnBarFleetDirective(
            id: source.id,
            kind: source.kind,
            targetAgent: source.targetAgent,
            sessionRef: source.sessionRef,
            payload: source.payload,
            state: .approved,
            createdAt: source.createdAt,
            decidedAt: Date()
        )
        guard let recorded = await service.recordDirective(approved) else { return }
        guard let channel = FleetDirectiveChannelRegistry.channel(for: recorded.targetAgent) else {
            lastHandoffNote = "No documented channel for this CLI."
            return
        }
        let result = await BurnBarFleetDeliveryRunner.run(
            directive: recorded,
            channel: channel,
            record: { candidate in
                try OpenBurnBarDaemonSocketClient.fleetDirectiveRecord(candidate, at: service.socketURL)
            }
        )
        switch result.outcome {
        case .delivered:
            lastHandoffNote = "Delivered to \(recorded.targetAgent?.wireValue ?? "agent") \(recorded.sessionRef ?? "")."
        case .submitted:
            lastHandoffNote = "Submitted via inbox for \(recorded.targetAgent?.wireValue ?? "agent") / \(recorded.sessionRef ?? "inbox"). Not a live-TUI inject."
        case .failed(let reason):
            lastHandoffNote = "Handoff failed: \(reason)"
        case .unsupported(let reason):
            lastHandoffNote = "Unsupported: \(reason)"
        }
        refreshNow()
    }

    func dismissDirective(_ directive: BurnBarFleetDirective) async {
        let dismissed = BurnBarFleetDirective(
            id: directive.id,
            kind: directive.kind,
            targetAgent: directive.targetAgent,
            sessionRef: directive.sessionRef,
            payload: directive.payload,
            state: .dismissed,
            createdAt: directive.createdAt,
            decidedAt: Date(),
            deliveryChannel: directive.deliveryChannel,
            deliveryAttemptID: directive.deliveryAttemptID
        )
        _ = await service.recordDirective(dismissed)
        refreshNow()
    }

    func startNewTurn(_ directive: BurnBarFleetDirective) async {
        guard let agent = directive.targetAgent,
              let channel = FleetDirectiveChannelRegistry.oneShot(for: agent)
        else {
            lastHandoffNote = "No documented one-shot binary for this CLI. Inbox already holds the command."
            return
        }
        let outcome = await channel.deliver(directive)
        switch outcome {
        case .submitted:
            lastHandoffNote = "Started a new turn with \(channel.binaryName). Not injected into a live TUI."
        case .unsupported(let reason), .failed(let reason):
            lastHandoffNote = reason
        case .delivered:
            lastHandoffNote = "One-shot cannot be delivered; unexpected ack."
        }
    }

    // MARK: - Lifecycle

    /// Called when the fleet view appears: starts the single poller and
    /// fetches the daemon-owned orchestrator state for the designation
    /// control/badge (VAL-ORCH-005/034).
    func viewAppeared() {
        isVisible = true
        service.start()
        service.refreshOrchestratorState()
    }

    /// Called when the fleet view disappears (navigate away, window close):
    /// stops the only poller. Documented hidden-window behavior is "paused":
    /// the reopened view restarts the poller and receives its first refresh
    /// within one cadence interval plus the documented scheduling tolerance
    /// (VAL-DASH-018).
    func viewDisappeared() {
        isVisible = false
        // The dashboard owns the shared FleetService poller so ⌘K, the
        // chat queue accessory, and the Control Deck tile stay current.
    }

    /// Immediate snapshot pull. Used by the daemon-down Retry control so the
    /// user does not wait a full cadence after a reconnect.
    func refreshNow() {
        service.fetchOnce()
        service.refreshOrchestratorState()
    }
}
