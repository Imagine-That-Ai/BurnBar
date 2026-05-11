import Foundation

// MARK: - Pixel Clock Operations
//
// Platform adapters implement this so the cross-platform settings model
// can drive Probe / Test / Push / Remove uniformly. macOS wires it to
// `PixelClockController`; iOS wires it to `SmartHubStore` which publishes
// `smart_display_actions` documents the Mac listens for.

@MainActor
public protocol PixelClockOperations: AnyObject {
    /// Detect whether AWTRIX is reachable on the configured host. Returns
    /// the resulting probe status so the model can update its in-memory
    /// firmware state without round-tripping through `PixelClockConfig`.
    func probePixelClock(config: PixelClockConfig) async -> PixelClockProbeStatus

    /// Run the shortest safe setup path for the detected firmware. On
    /// AWTRIX Light this verifies direct HTTP control; on stock Ulanzi it
    /// configures Awtrix Simulator with the Mac as host and returns the
    /// flash URL needed for full OpenBurnBar direct control.
    func preparePixelClock(config: PixelClockConfig) async throws -> PixelClockSetupResult

    func flashPixelClockFirmware(config: PixelClockConfig, wifiCredentials: PixelClockWiFiCredentials?) async throws -> PixelClockSetupResult

    /// Send a single notify frame so the user can confirm the right
    /// device responded.
    func testPixelClock(config: PixelClockConfig) async throws

    /// Push the rendered carousel immediately.
    func pushPixelClockNow(config: PixelClockConfig) async throws

    /// Remove the OpenBurnBar custom app from the device.
    func removePixelClockApp(config: PixelClockConfig) async throws

    /// Persist a config change. UI calls this after every meaningful
    /// edit so the underlying store can debounce + ship a single update.
    func updatePixelClockConfig(_ config: PixelClockConfig) async
}

// MARK: - In-Memory Default

/// Preview/test-only adapter. Has no side effects beyond echoing the
/// caller's config back. The real adapters live in the AgentLens (macOS)
/// and OpenBurnBarMobile (iOS) targets.
@MainActor
public final class InMemoryPixelClockOperations: PixelClockOperations {
    public var lastConfig: PixelClockConfig?
    public var probeResult: PixelClockProbeStatus
    public var prepareResult: PixelClockSetupResult?
    public var prepareResults: [PixelClockSetupResult] = []
    public var flashResult: PixelClockSetupResult?
    public var failureToThrow: Error?
    public private(set) var prepareCallCount = 0
    public private(set) var flashCallCount = 0
    public private(set) var pushCallCount = 0

    public init(probeResult: PixelClockProbeStatus = .unknown) {
        self.probeResult = probeResult
    }

    public func probePixelClock(config: PixelClockConfig) async -> PixelClockProbeStatus {
        lastConfig = config
        return probeResult
    }

    public func preparePixelClock(config: PixelClockConfig) async throws -> PixelClockSetupResult {
        lastConfig = config
        prepareCallCount += 1
        if let failureToThrow { throw failureToThrow }
        if !prepareResults.isEmpty {
            return prepareResults.removeFirst()
        }
        if let prepareResult { return prepareResult }
        return PixelClockSetupResult(
            mode: probeResult == .awtrixReady ? .awtrixLightReady : .needsAwtrixLightFlash,
            probeStatus: probeResult,
            message: probeResult == .awtrixReady ? "AWTRIX Light is ready." : "Pixel Clock needs setup.",
            clockHost: config.host
        )
    }

    public func flashPixelClockFirmware(config: PixelClockConfig, wifiCredentials: PixelClockWiFiCredentials?) async throws -> PixelClockSetupResult {
        lastConfig = config
        flashCallCount += 1
        if let failureToThrow { throw failureToThrow }
        if let flashResult { return flashResult }
        return try await preparePixelClock(config: config)
    }

    public func testPixelClock(config: PixelClockConfig) async throws {
        lastConfig = config
        if let failureToThrow { throw failureToThrow }
    }

    public func pushPixelClockNow(config: PixelClockConfig) async throws {
        lastConfig = config
        pushCallCount += 1
        if let failureToThrow { throw failureToThrow }
    }

    public func removePixelClockApp(config: PixelClockConfig) async throws {
        lastConfig = config
        if let failureToThrow { throw failureToThrow }
    }

    public func updatePixelClockConfig(_ config: PixelClockConfig) async {
        lastConfig = config
    }
}

// MARK: - Settings Model

/// Drives the Pixel Clock settings card. Owned by the SwiftUI surface,
/// not by any persistence store — the store remains the source of truth
/// for the persisted config and is reflected back via `apply(config:)`.
@MainActor
@Observable
public final class PixelClockSettingsModel {

    /// User-edited config. Starts mirroring the persisted config and is
    /// pushed back via `operations.updatePixelClockConfig(_:)` after each
    /// meaningful edit.
    public var config: PixelClockConfig

    /// Last-known probe status. UI updates with the latest detection.
    public var firmware: PixelClockProbeStatus

    /// Last operation's progress + failure. UI uses this to disable the
    /// row and surface error copy.
    public var operationState: PixelClockOperationState

    /// Last setup-assistant result, suitable for showing a next step
    /// without parsing error strings.
    public private(set) var setupResult: PixelClockSetupResult?

    /// Provider IDs that should appear as filter chips. Defaults to
    /// `AgentProvider.quotaSignalProviders` since those have signals to
    /// render. Callers can override in tests.
    public let availableProviders: [AgentProvider]

    /// Non-`nil` for the duration of a probe / test / push so the UI can
    /// show a spinner without blocking other state updates.
    public private(set) var inflightOperation: PixelClockOperationKind?

    /// True while one-click setup is waiting for a clock to appear on LAN
    /// or as a real USB serial setup target.
    public private(set) var isWaitingForConnection = false

    private let operations: any PixelClockOperations
    private let setupRetryAttempts: Int
    private let setupRetryIntervalNanoseconds: UInt64
    private var debounceTask: Task<Void, Never>?

    public convenience init(
        initialConfig: PixelClockConfig = .disabled,
        availableProviders: [AgentProvider] = AgentProvider.quotaSignalProviders
    ) {
        self.init(
            initialConfig: initialConfig,
            operations: InMemoryPixelClockOperations(),
            availableProviders: availableProviders
        )
    }

    public init(
        initialConfig: PixelClockConfig = .disabled,
        operations: any PixelClockOperations,
        availableProviders: [AgentProvider] = AgentProvider.quotaSignalProviders,
        setupRetryAttempts: Int = 0,
        setupRetryIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.config = initialConfig
        self.firmware = initialConfig.lastProbeStatus
        self.operationState = .idle
        self.setupResult = nil
        self.operations = operations
        self.availableProviders = availableProviders
        self.setupRetryAttempts = max(0, setupRetryAttempts)
        self.setupRetryIntervalNanoseconds = setupRetryIntervalNanoseconds
    }

    /// Apply a config provided by the persistence layer — keeps the UI
    /// in sync when settings load from disk / Firestore.
    public func apply(config: PixelClockConfig) {
        self.config = config
        self.firmware = config.lastProbeStatus
    }

    // MARK: - Bindings

    public var enabledBinding: Bool {
        get { config.enabled }
        set { mutate { $0.enabled = newValue } }
    }

    public func toggleEnabled(_ enabled: Bool) {
        mutate { $0.enabled = enabled }
    }

    public func updateHost(_ host: String) {
        mutate { $0.host = host }
    }

    public func updatePort(_ port: Int) {
        mutate { $0.port = port }
    }

    public func updateLayout(_ layout: PixelClockLayout) {
        mutate { $0.layout = layout }
    }

    public func updatePalette(_ palette: PixelClockPalette) {
        mutate { $0.palette = palette }
    }

    public func updateTimePeriod(_ period: SmartHubTimePeriod) {
        mutate { $0.timePeriod = period }
    }

    public func updateWorkingSpinnerStyle(_ style: PixelClockSpinnerStyle) {
        mutate { $0.workingSpinnerStyle = style }
    }

    public func updateWorkingSpinnerPrimaryHex(_ hex: String) {
        mutate { $0.workingSpinnerPrimaryHex = hex }
    }

    public func updateWorkingSpinnerSecondaryHex(_ hex: String) {
        mutate { $0.workingSpinnerSecondaryHex = hex }
    }

    public func updateCompletionClockSoundEnabled(_ enabled: Bool) {
        mutate { $0.completionClockSoundEnabled = enabled }
    }

    public func updateCompletionLocalNotificationsEnabled(_ enabled: Bool) {
        mutate { $0.completionLocalNotificationsEnabled = enabled }
    }

    public func updateBrightness(_ brightness: Int?) {
        mutate { $0.brightness = brightness }
    }

    public func updateScrollSpeed(_ percent: Int) {
        mutate { $0.scrollSpeedPercent = percent }
    }

    public func updateUpdateInterval(_ seconds: Int) {
        mutate { $0.updateIntervalSeconds = seconds }
    }

    public func updatePageDuration(_ seconds: Int) {
        mutate { $0.pageDurationSeconds = seconds }
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

    public func isProviderSelected(_ provider: AgentProvider) -> Bool {
        let normalized = Set(config.providerIDs.map { $0.lowercased() })
        if normalized.isEmpty { return true } // Empty filter == "all providers"
        return normalized.contains(provider.persistedToken.lowercased())
    }

    /// `true` when the user has explicitly narrowed the filter (i.e. the
    /// active set isn't "all providers").
    public var hasExplicitProviderFilter: Bool {
        !config.providerIDs.isEmpty
    }

    // MARK: - Operations

    public func probe() async {
        await runOperation(.probe) {
            let result = await self.operations.probePixelClock(config: self.config)
            self.firmware = result
            self.mutate(persist: false) { $0.lastProbeStatus = result }
        }
    }

    public func prepare() async {
        await runOperation(.probe) {
            let result = try await self.operations.preparePixelClock(config: self.config)
            self.setupResult = result
            self.firmware = result.probeStatus
            self.mutate(persist: false) {
                $0.host = result.clockHost
                $0.lastProbeStatus = result.probeStatus
            }
        }
    }

    public func setupAutomatically() async {
        if !config.enabled {
            toggleEnabled(true)
        }
        await prepare()
        if setupResult?.mode == .unreachable {
            await waitForSetupTransport()
        }
        if setupResult?.mode == .needsAwtrixLightFlash || setupResult?.mode == .needsWiFiProvisioning {
            await flashAndFinishSetup()
        }
        if firmware == .awtrixReady || setupResult?.mode == .stockSimulatorConfigured {
            await push()
        }
    }

    public func flashAndFinishSetup(wifiCredentials: PixelClockWiFiCredentials? = nil) async {
        if !config.enabled {
            toggleEnabled(true)
        }
        await runOperation(.flash) {
            let result = try await self.operations.flashPixelClockFirmware(config: self.config, wifiCredentials: wifiCredentials)
            self.setupResult = result
            self.firmware = result.probeStatus
            self.mutate(persist: false) {
                $0.host = result.clockHost
                $0.lastProbeStatus = result.probeStatus
            }
        }
    }

    public func test() async {
        await runOperation(.test) {
            try await self.operations.testPixelClock(config: self.config)
        }
    }

    public func push() async {
        await runOperation(.push) {
            try await self.operations.pushPixelClockNow(config: self.config)
        }
    }

    public func remove() async {
        await runOperation(.remove) {
            try await self.operations.removePixelClockApp(config: self.config)
        }
    }

    // MARK: - Derived UI State

    public var isBusy: Bool {
        inflightOperation != nil || isWaitingForConnection
    }

    public var setupPrimaryTitle: String {
        if isWaitingForConnection {
            return "Waiting for Clock..."
        }
        if inflightOperation == .flash {
            return "Flashing..."
        }
        if inflightOperation == .probe {
            return "Detecting..."
        }
        if inflightOperation == .push {
            return "Pushing..."
        }
        if setupResult?.mode == .needsWiFiProvisioning {
            return "Send Wi-Fi and Finish"
        }
        if setupResult?.mode == .needsAwtrixLightFlash {
            return "Flash and Finish Setup"
        }
        if setupResult?.mode == .unreachable {
            return "Detect Pixel Clock"
        }
        switch firmware {
        case .awtrixReady:
            return "Push to Pixel Clock"
        case .stockUlanziFirmware, .unreachable, .unsupported, .error, .unknown:
            return "Set up automatically"
        }
    }

    public var setupStatusTitle: String {
        if isWaitingForConnection {
            return "Waiting for Pixel Clock on Wi-Fi or data USB. OpenBurnBar will keep checking for several minutes."
        }
        if let failure = operationState.failureMessage {
            return failure
        }
        if let setupResult {
            return setupResult.message
        }
        switch firmware {
        case .awtrixReady:
            return "Pixel Clock is ready for OpenBurnBar."
        case .stockUlanziFirmware:
            return "Stock Ulanzi found. OpenBurnBar can configure simulator settings and serve quota frames from your Mac."
        case .unreachable:
            return "No Pixel Clock found on Wi-Fi or data USB. A lit TC001 can still be battery-powered or charge-only; use stable wall power plus Wi-Fi, or a direct data USB cable for setup."
        case .unsupported:
            return "OpenBurnBar found a device, but it needs AWTRIX Light for direct quota frames."
        case .error:
            return "Setup hit an error. Run automatic setup again."
        case .unknown:
            return "OpenBurnBar will find the clock, configure what it can, and push the display when it is ready."
        }
    }

    public var setupStatusSymbolName: String {
        if isWaitingForConnection {
            return "dot.radiowaves.left.and.right"
        }
        if operationState.failureMessage != nil {
            return "exclamationmark.triangle.fill"
        }
        switch setupResult?.mode {
        case .awtrixLightReady:
            return "checkmark.circle.fill"
        case .stockSimulatorConfigured:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .needsAwtrixLightFlash:
            return "bolt.badge.automatic.fill"
        case .needsWiFiProvisioning:
            return "wifi.router.fill"
        case .unreachable:
            return "wifi.exclamationmark"
        case nil:
            break
        }
        switch firmware {
        case .awtrixReady: return "checkmark.circle.fill"
        case .stockUlanziFirmware: return "arrow.triangle.2.circlepath.circle.fill"
        case .unreachable: return "wifi.exclamationmark"
        case .unsupported, .error: return "exclamationmark.triangle.fill"
        case .unknown: return "wand.and.stars"
        }
    }

    public var setupNeedsAttention: Bool {
        if operationState.failureMessage != nil {
            return true
        }
        switch setupResult?.mode {
        case .awtrixLightReady:
            return false
        case .stockSimulatorConfigured:
            return false
        case .needsAwtrixLightFlash, .needsWiFiProvisioning, .unreachable:
            return true
        case nil:
            return firmware != .awtrixReady && firmware != .unknown
        }
    }

    public var firmwareWarningMessage: String? {
        switch firmware {
        case .stockUlanziFirmware:
            if setupResult?.mode == .stockSimulatorConfigured { return nil }
            return "Stock Ulanzi needs Awtrix Simulator pointed at this Mac's IP."
        case .unreachable:
            return "Pixel Clock is unreachable. Verify the host and that it's on the same Wi-Fi."
        case .unsupported:
            return "Device responded but didn't look like AWTRIX. Re-flash with AWTRIX or pick a different display."
        case .error:
            return "Last probe ended in an error. Try again or check Logs for details."
        case .awtrixReady, .unknown:
            return nil
        }
    }

    // MARK: - Internals

    private func mutate(persist: Bool = true, _ change: (inout PixelClockConfig) -> Void) {
        var next = config
        change(&next)
        apply(local: next, persist: persist)
    }

    private func apply(local next: PixelClockConfig, persist: Bool = true) {
        guard next != config else { return }
        config = next
        if persist {
            scheduleDebouncedPersist()
        }
    }

    private func scheduleDebouncedPersist() {
        debounceTask?.cancel()
        let snapshot = config
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms — keeps slider drags cheap.
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.operations.updatePixelClockConfig(snapshot)
        }
    }

    private func runOperation(
        _ kind: PixelClockOperationKind,
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

    private func waitForSetupTransport() async {
        guard setupRetryAttempts > 0 else { return }
        guard setupResult?.mode == .unreachable else { return }

        isWaitingForConnection = true
        defer { isWaitingForConnection = false }

        for _ in 0..<setupRetryAttempts {
            guard setupResult?.mode == .unreachable else { return }
            try? await Task.sleep(nanoseconds: setupRetryIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            await prepare()
        }
    }
}

// MARK: - Operation Types

public enum PixelClockOperationKind: String, Sendable {
    case flash
    case probe
    case test
    case push
    case remove

    public var displayName: String {
        switch self {
        case .flash:  return "Flash and Finish Setup"
        case .probe:  return "Detect"
        case .test:   return "Test"
        case .push:   return "Push Now"
        case .remove: return "Remove"
        }
    }

    public var inFlightLabel: String {
        switch self {
        case .flash:  return "Flashing…"
        case .probe:  return "Detecting…"
        case .test:   return "Testing…"
        case .push:   return "Pushing…"
        case .remove: return "Removing…"
        }
    }

    public var symbolName: String {
        switch self {
        case .flash:  return "bolt.badge.automatic.fill"
        case .probe:  return "dot.radiowaves.left.and.right"
        case .test:   return "bolt.horizontal.circle"
        case .push:   return "paperplane.fill"
        case .remove: return "trash"
        }
    }
}

public enum PixelClockOperationState: Equatable, Sendable {
    case idle
    case running(PixelClockOperationKind)
    case succeeded(PixelClockOperationKind, at: Date)
    case failed(PixelClockOperationKind, message: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    public var lastSucceededKind: PixelClockOperationKind? {
        if case .succeeded(let kind, _) = self { return kind }
        return nil
    }
}

public extension PixelClockSpinnerStyle {
    var displayName: String {
        switch self {
        case .orbit: return "Orbit"
        case .chase: return "Chase"
        case .pulse: return "Pulse"
        case .scan: return "Scan"
        }
    }

    var iconName: String {
        switch self {
        case .orbit: return "circle.dotted"
        case .chase: return "arrow.triangle.2.circlepath"
        case .pulse: return "dot.radiowaves.left.and.right"
        case .scan: return "line.3.horizontal"
        }
    }
}
