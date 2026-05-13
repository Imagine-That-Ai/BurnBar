import Foundation

// MARK: - Smart Hub Display Operations
//
// Platform adapter contract used by the cross-platform `SmartHubDisplaySettingsModel`
// to drive Test/Identify/Refresh/Stop/Open uniformly. macOS wires this
// to `SmartHubBridgeServer` + `SmartHubBridgeController`; iOS forwards
// through `SmartHubStore` Firestore actions the Mac picks up.

/// Surfaces a `repairDisplay()` result whose terminal phase is not
/// `.working` (e.g. `.needsUserAction`, `.failed`) as a thrown error so
/// the surrounding `runOperation(...)` wrapper records a `.failed`
/// operation state instead of a misleading `.succeeded`. Without this,
/// the UI shows both "Make display work completed." (green) and the
/// orange user-action banner at once.
public struct SmartHubRepairError: Error, LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

@MainActor
public protocol SmartHubDisplayOperations: AnyObject {
    /// Persist the new display config so the bridge picks it up on its
    /// next pump and the Firestore-backed config is mirrored to the
    /// companion device.
    func updateDisplayConfig(_ config: SmartHubDisplayConfig) async

    /// Verify the bridge is reachable. Returns the resulting status the
    /// model surfaces in the bridge-status row.
    func testBridge() async -> SmartHubBridgeProbeStatus

    /// Trigger a real refetch of provider data + bump the Hub.
    func refreshNow() async

    /// Run the full repair path: start/recover the bridge, cast/recast,
    /// and wait for proof that the Hub is actually rendering OpenBurnBar.
    func repairDisplay() async -> SmartDisplayDeviceRepairStatus

    /// Ping `/voice-refresh` so the Hub speaks/blinks.
    func identify() async

    /// Flip the master enabled toggle off and stop the bridge.
    func stopBridge() async

    /// Open the dashboard in the default browser. The platform adapter
    /// resolves the actual bound port + host so port-fallback works.
    func openInBrowser() async

    /// Copy the voice routine URL to the system clipboard. UI surfaces
    /// the user-facing confirmation toast.
    func copyVoiceRoutineURL() async
}

// MARK: - Bridge Probe Status

public enum SmartHubBridgeProbeStatus: String, Sendable, Equatable {
    case unknown
    case bound
    case unreachable
    case waitingForData
    case error
}

// MARK: - In-Memory Default

@MainActor
public final class InMemorySmartHubDisplayOperations: SmartHubDisplayOperations {
    public var lastConfig: SmartHubDisplayConfig?
    public var probeResult: SmartHubBridgeProbeStatus
    public var refreshCount = 0
    public var identifyCount = 0
    public var stopCount = 0
    public var openCount = 0
    public var copyCount = 0
    public var repairOverride: SmartDisplayDeviceRepairStatus?

    public init(
        probeResult: SmartHubBridgeProbeStatus = .unknown,
        repairOverride: SmartDisplayDeviceRepairStatus? = nil
    ) {
        self.probeResult = probeResult
        self.repairOverride = repairOverride
    }

    public func updateDisplayConfig(_ config: SmartHubDisplayConfig) async {
        lastConfig = config
    }

    public func testBridge() async -> SmartHubBridgeProbeStatus {
        probeResult
    }

    public func refreshNow() async {
        refreshCount += 1
    }

    public func repairDisplay() async -> SmartDisplayDeviceRepairStatus {
        refreshCount += 1
        if let repairOverride { return repairOverride }
        return SmartDisplayDeviceRepairStatus(
            kind: .nestHub,
            phase: probeResult == .bound ? .working : .failed,
            message: probeResult == .bound ? "Nest Hub is showing OpenBurnBar." : "Nest Hub repair failed."
        )
    }

    public func identify() async {
        identifyCount += 1
    }

    public func stopBridge() async {
        stopCount += 1
    }

    public func openInBrowser() async {
        openCount += 1
    }

    public func copyVoiceRoutineURL() async {
        copyCount += 1
    }
}

// MARK: - Operation Kinds

public enum SmartHubDisplayOperationKind: String, Sendable {
    case test
    case identify
    case repair
    case refresh
    case stop
    case open

    public var displayName: String {
        switch self {
        case .test:     return "Test bridge"
        case .identify: return "Identify"
        case .repair:   return "Make display work"
        case .refresh:  return "Refresh Hub"
        case .stop:     return "Stop bridge"
        case .open:     return "Open"
        }
    }

    public var inFlightLabel: String {
        switch self {
        case .test:     return "Pinging…"
        case .identify: return "Identifying…"
        case .repair:   return "Repairing…"
        case .refresh:  return "Refreshing…"
        case .stop:     return "Stopping…"
        case .open:     return "Opening…"
        }
    }

    public var symbolName: String {
        switch self {
        case .test:     return "dot.radiowaves.left.and.right"
        case .identify: return "speaker.wave.2"
        case .repair:   return "wand.and.stars"
        case .refresh:  return "arrow.clockwise"
        case .stop:     return "stop.circle"
        case .open:     return "arrow.up.right.square"
        }
    }
}

public enum SmartHubDisplayOperationState: Equatable, Sendable {
    case idle
    case running(SmartHubDisplayOperationKind)
    case succeeded(SmartHubDisplayOperationKind, at: Date)
    case failed(SmartHubDisplayOperationKind, message: String)

    public var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    public var lastSucceededKind: SmartHubDisplayOperationKind? {
        if case .succeeded(let kind, _) = self { return kind }
        return nil
    }
}

// MARK: - Settings Model

@MainActor
@Observable
public final class SmartHubDisplaySettingsModel {

    /// Whether the user has the bridge enabled. Reflects
    /// `SettingsManager.smartHubQuotaDisplayEnabled` on macOS and the
    /// `enabled` field of the published `SmartHubConfig` on iOS.
    public var enabled: Bool

    /// Per-display config. Edits push back via `operations.updateDisplayConfig`.
    public var config: SmartHubDisplayConfig

    /// Last bridge probe outcome.
    public var bridgeStatus: SmartHubBridgeProbeStatus

    /// Inflight + completion state for the quick-action row.
    public var operationState: SmartHubDisplayOperationState

    /// Provider IDs that should appear as filter chips.
    public let availableProviders: [AgentProvider]

    /// Non-`nil` while a Test / Identify / Refresh / Stop / Open is in
    /// flight so the UI can show a spinner.
    public private(set) var inflightOperation: SmartHubDisplayOperationKind?

    /// Toast surfaced after Copy Voice URL completes.
    public var lastClipboardMessage: String?

    /// Last proof-driven repair result. This is intentionally separate
    /// from `bridgeStatus`, which only describes the local HTTP bridge.
    public private(set) var lastRepairStatus: SmartDisplayDeviceRepairStatus?

    private let operations: any SmartHubDisplayOperations
    private var debounceTask: Task<Void, Never>?
    private let onEnabledChange: ((Bool) -> Void)?

    public convenience init(
        enabled: Bool = false,
        initialConfig: SmartHubDisplayConfig = .default,
        availableProviders: [AgentProvider] = AgentProvider.quotaSignalProviders
    ) {
        self.init(
            enabled: enabled,
            initialConfig: initialConfig,
            operations: InMemorySmartHubDisplayOperations(),
            availableProviders: availableProviders,
            onEnabledChange: nil
        )
    }

    public init(
        enabled: Bool,
        initialConfig: SmartHubDisplayConfig,
        operations: any SmartHubDisplayOperations,
        availableProviders: [AgentProvider] = AgentProvider.quotaSignalProviders,
        onEnabledChange: ((Bool) -> Void)? = nil
    ) {
        self.enabled = enabled
        self.config = initialConfig
        self.bridgeStatus = .unknown
        self.operationState = .idle
        self.lastRepairStatus = nil
        self.operations = operations
        self.availableProviders = availableProviders
        self.onEnabledChange = onEnabledChange
    }

    // MARK: - External sync

    public func apply(enabled: Bool, config: SmartHubDisplayConfig) {
        if enabled != self.enabled { self.enabled = enabled }
        if config != self.config { self.config = config }
    }

    // MARK: - Toggle

    public func toggleEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        enabled = newValue
        onEnabledChange?(newValue)
    }

    /// User-facing master switch behavior. Turning the Nest Hub on should
    /// actually start/recover the Cast display, and turning it off should stop
    /// the local bridge instead of only changing persisted preference state.
    public func setEnabledFromToggle(_ newValue: Bool) async {
        if newValue {
            if !enabled {
                enabled = true
                onEnabledChange?(true)
            }
            await repair()
        } else {
            await stop()
        }
    }

    // MARK: - Display config bindings

    public func updateLayout(_ layout: SmartHubDisplayLayout) {
        mutate { $0.layout = layout }
    }

    public func updatePalette(_ palette: SmartHubDisplayPalette) {
        mutate { $0.palette = palette }
    }

    public func updateTheme(_ theme: SmartHubDisplayTheme) {
        mutate { $0.theme = theme }
    }

    public func updateBackground(_ background: SmartHubDisplayBackground) {
        mutate { $0.background = background }
    }

    public func updateBrightness(_ value: Double) {
        mutate { $0.brightness = value }
    }

    public func updateScrollSpeed(_ seconds: Int) {
        mutate { $0.scrollSpeedSeconds = seconds }
    }

    public func updateRefreshCadence(_ seconds: Int) {
        mutate { $0.refreshCadenceSeconds = seconds }
    }

    public func updateAudibleCue(_ value: Bool) {
        mutate { $0.audibleCue = value }
    }

    public func updateIdentifyOnRefresh(_ value: Bool) {
        mutate { $0.identifyOnRefresh = value }
    }

    public func toggleProvider(_ provider: AgentProvider) {
        let token = provider.persistedToken
        var next = config
        var ids = next.providerIDs
        if let index = ids.firstIndex(where: { $0.lowercased() == token.lowercased() }) {
            ids.remove(at: index)
        } else {
            ids.append(token)
        }
        next.providerIDs = ids
        apply(local: next)
    }

    public func resetProviderFilter() {
        guard !config.providerIDs.isEmpty else { return }
        var next = config
        next.providerIDs = []
        apply(local: next)
    }

    public func isProviderSelected(_ provider: AgentProvider) -> Bool {
        let normalized = Set(config.providerIDs.map { $0.lowercased() })
        if normalized.isEmpty { return true }
        return normalized.contains(provider.persistedToken.lowercased())
    }

    public var hasExplicitProviderFilter: Bool {
        !config.providerIDs.isEmpty
    }

    // MARK: - Operations

    public func test() async {
        await runOperation(.test) {
            self.bridgeStatus = await self.operations.testBridge()
        }
    }

    public func identify() async {
        await runOperation(.identify) {
            await self.operations.identify()
        }
    }

    public func refresh() async {
        await runOperation(.refresh) {
            await self.operations.refreshNow()
        }
    }

    public func repair() async {
        await runOperation(.repair) {
            let result = await self.operations.repairDisplay()
            self.lastRepairStatus = result
            switch result.phase {
            case .working:
                self.bridgeStatus = .bound
            case .needsUserAction, .failed:
                self.bridgeStatus = .unreachable
                throw SmartHubRepairError(message: result.message)
            case .waitingForProof, .repairing, .detecting:
                self.bridgeStatus = .waitingForData
            case .idle, .skipped:
                break
            }
        }
    }

    public func stop() async {
        await runOperation(.stop) {
            await self.operations.stopBridge()
            self.enabled = false
            self.onEnabledChange?(false)
        }
    }

    public func open() async {
        await runOperation(.open) {
            await self.operations.openInBrowser()
        }
    }

    public func copyVoiceURL() async {
        await operations.copyVoiceRoutineURL()
        lastClipboardMessage = "Voice routine URL copied."
    }

    // MARK: - Derived UI

    public var isBusy: Bool { inflightOperation != nil }

    public var bridgeStatusMessage: String {
        if let lastRepairStatus {
            return lastRepairStatus.message
        }
        switch bridgeStatus {
        case .bound:          return "Bridge listening on the configured port."
        case .unreachable:    return "Bridge unreachable. Toggle off and on to restart."
        case .waitingForData: return "Bridge ready, waiting on the first provider sync."
        case .error:          return "Last bridge probe ended in an error."
        case .unknown:        return "Hit Test bridge to verify the Hub can reach OpenBurnBar."
        }
    }

    public var bridgeStatusIsWarning: Bool {
        switch bridgeStatus {
        case .unreachable, .error: return true
        case .bound, .waitingForData, .unknown: return false
        }
    }

    public var bridgeStatusSymbol: String {
        switch bridgeStatus {
        case .unknown:        return "questionmark.circle"
        case .bound:          return "checkmark.seal.fill"
        case .waitingForData: return "hourglass"
        case .unreachable:    return "wifi.exclamationmark"
        case .error:          return "xmark.octagon"
        }
    }

    // MARK: - Internals

    private func mutate(_ change: (inout SmartHubDisplayConfig) -> Void) {
        var next = config
        change(&next)
        apply(local: next)
    }

    private func apply(local next: SmartHubDisplayConfig) {
        var stamped = next
        stamped.updatedAt = Date()
        guard stamped != config else { return }
        config = stamped
        scheduleDebouncedPersist()
    }

    private func scheduleDebouncedPersist() {
        debounceTask?.cancel()
        let snapshot = config
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.operations.updateDisplayConfig(snapshot)
        }
    }

    private func runOperation(
        _ kind: SmartHubDisplayOperationKind,
        block: @escaping () async throws -> Void
    ) async {
        guard inflightOperation == nil else { return }
        inflightOperation = kind
        operationState = .running(kind)
        defer { inflightOperation = nil }
        do {
            try await block()
            operationState = .succeeded(kind, at: Date())
        } catch {
            operationState = .failed(kind, message: error.localizedDescription)
        }
    }
}
