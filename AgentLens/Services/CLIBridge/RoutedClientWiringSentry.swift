import Foundation

// MARK: - Routed Client Wiring Sentry

/// Self-healing watchdog for routed-client wiring. Maintains a `DispatchSource`
/// file-system watcher per enrolled `RoutingClientWiringTarget` and re-applies
/// `RoutingClientWiring.wire(target:gateway:advertisedModels:)` whenever an
/// external rewrite (Claude Code's own atomic settings.json save, a plugin
/// install, a dotfile sync, etc.) strips the env block / sentinel.
///
/// Why this exists: Claude Code rewrites `~/.claude/settings.json` whenever
/// the user signs in/out, edits options, or installs a plugin. Those writes
/// happen via `rename(2)`, which means our env block is silently replaced.
/// Before the sentry, the user had to open BurnBar Settings and press
/// Connect again every time the file got rewritten. Now they don't.
///
/// Architectural contract:
/// - The sentry is the *only* component that schedules unattended re-wires.
/// - It never decides on its own that a target should be wired. It honours
///   the persisted intent in `RoutedClientWiringSettings.enrolledTargets`,
///   which the Connections UI writes on user-driven Connect/Disconnect.
/// - It is gated by `RoutedClientWiringSettings.autoRepairEnabled`, which
///   defaults to `true` per Decision 2026-05-17.
/// - It coalesces bursts of FS events into a single repair via a 400 ms
///   debounce. Atomic rename-replace writes (Claude Code's pattern) emit
///   `.delete` + `.rename` + `.write`; the debounce makes those land as one
///   repair, and the watcher re-arms on the new inode.
/// - It supplements the watcher with a 60 s periodic sweep so any missed
///   FS events (Spotlight, Time Machine, weird filesystems) still self-heal.
@MainActor
final class RoutedClientWiringSentry {

    // MARK: - Configuration

    struct Configuration {
        /// Debounce window for FS event bursts. Atomic rename-replace writes
        /// emit several events back-to-back; we wait this long after the last
        /// one before re-checking the file.
        var debounceNanoseconds: UInt64 = 400_000_000
        /// Cadence for the safety-net sweep that doesn't rely on FS events.
        var periodicSweepSeconds: TimeInterval = 60
        /// Backoff used when the config file disappears (rename-replace in
        /// flight) before the watcher re-arms.
        var reopenBackoffNanoseconds: UInt64 = 250_000_000
        /// FS events we care about. `.write` / `.extend` cover in-place
        /// modifications, `.rename` / `.delete` cover atomic replacements,
        /// `.attrib` covers permission rewrites by some installers, `.link`
        /// covers `ln`/`mv` flows.
        var monitoredEvents: DispatchSource.FileSystemEvent = [
            .write, .extend, .rename, .delete, .attrib, .link
        ]
    }

    // MARK: - State

    private let configuration: Configuration
    private let wiringFactory: () -> RoutingClientWiring
    private let logger: AppLogger
    private let queue: DispatchQueue

    private weak var settingsManager: SettingsManager?

    private var watchers: [RoutingClientWiringTarget: Watcher] = [:]
    private var pendingRepairs: [RoutingClientWiringTarget: Task<Void, Never>] = [:]
    private var sweepTask: Task<Void, Never>?
    private var enrollmentObserver: NSObjectProtocol?
    private var isStarted = false

    private final class Watcher {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject

        init(descriptor: Int32, source: DispatchSourceFileSystemObject) {
            self.descriptor = descriptor
            self.source = source
        }
    }

    // MARK: - Init

    init(
        configuration: Configuration = Configuration(),
        wiringFactory: @escaping () -> RoutingClientWiring = { RoutingClientWiring() },
        logger: AppLogger = AppLogger(category: "RoutedClientWiringSentry"),
        queue: DispatchQueue = DispatchQueue(
            label: "com.openburnbar.routedClientWiringSentry",
            qos: .utility
        )
    ) {
        self.configuration = configuration
        self.wiringFactory = wiringFactory
        self.logger = logger
        self.queue = queue
    }

    deinit {
        if let enrollmentObserver {
            NotificationCenter.default.removeObserver(enrollmentObserver)
        }
        for (_, watcher) in watchers {
            watcher.source.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Start the sentry against the given settings manager. Re-runs are safe;
    /// the second call is a no-op other than the initial sweep.
    func start(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        guard !isStarted else {
            triggerInitialSweep()
            return
        }
        isStarted = true
        logger.info("sentry_started", metadata: [
            "enrolled": settingsManager.routedClientWiring.enrolledTargets.sorted().joined(separator: ",")
        ])
        installEnrollmentObserver()
        rebuildWatchers()
        triggerInitialSweep()
        startPeriodicSweep()
    }

    /// Tear down all watchers and pending work. Intended for explicit
    /// shutdown paths (tests, app termination). Idempotent.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        sweepTask?.cancel()
        sweepTask = nil
        if let enrollmentObserver {
            NotificationCenter.default.removeObserver(enrollmentObserver)
            self.enrollmentObserver = nil
        }
        for (_, task) in pendingRepairs {
            task.cancel()
        }
        pendingRepairs.removeAll()
        for (target, watcher) in watchers {
            watcher.source.cancel()
            logger.debug("watcher_stopped", metadata: ["target": target.rawValue])
        }
        watchers.removeAll()
        logger.info("sentry_stopped")
    }

    /// Public hook for callers that mutate `enrolledTargets` without going
    /// through `RoutedClientWiringSettings.enroll`/`.unenroll` (tests, code
    /// paths that bypass the notification). The notification-driven observer
    /// covers the production path automatically.
    func enrollmentDidChange() {
        guard isStarted else { return }
        rebuildWatchers()
        triggerInitialSweep()
    }

    private func installEnrollmentObserver() {
        if let enrollmentObserver {
            NotificationCenter.default.removeObserver(enrollmentObserver)
        }
        enrollmentObserver = NotificationCenter.default.addObserver(
            forName: .routedClientWiringEnrollmentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enrollmentDidChange()
            }
        }
    }

    /// Visible for tests — run the same logic as the periodic sweep once.
    /// Caller owns awaiting the returned task if needed.
    @discardableResult
    func sweepNow() -> Task<Void, Never> {
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performSweep()
        }
        return task
    }

    // MARK: - Watcher fleet

    private func rebuildWatchers() {
        guard let settingsManager else { return }
        let desired = settingsManager.routedClientWiring.enrolledTargets
            .compactMap(RoutingClientWiringTarget.init(rawValue:))
        let desiredSet = Set(desired)

        for target in Array(watchers.keys) where !desiredSet.contains(target) {
            if let watcher = watchers.removeValue(forKey: target) {
                watcher.source.cancel()
                logger.debug("watcher_dropped", metadata: ["target": target.rawValue])
            }
            pendingRepairs.removeValue(forKey: target)?.cancel()
        }

        for target in desired where watchers[target] == nil {
            armWatcher(for: target)
        }
    }

    private func armWatcher(for target: RoutingClientWiringTarget) {
        let wiring = wiringFactory()
        let url = wiring.configURL(for: target)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logger.silentFailure(
                "sentry_ensure_directory_failed",
                error: error,
                context: ["target": target.rawValue, "path": url.deletingLastPathComponent().path]
            )
        }

        guard let watcher = makeWatcher(at: url, target: target) else {
            scheduleReopen(for: target)
            return
        }
        watchers[target] = watcher
        watcher.source.resume()
        logger.debug("watcher_armed", metadata: [
            "target": target.rawValue,
            "path": url.path
        ])
    }

    private func makeWatcher(at url: URL, target: RoutingClientWiringTarget) -> Watcher? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_EVTONLY)
        }
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: configuration.monitoredEvents,
            queue: queue
        )
        let watcher = Watcher(descriptor: descriptor, source: source)
        source.setEventHandler { [weak self, weak watcher] in
            let data = watcher?.source.data ?? []
            Task { @MainActor [weak self] in
                self?.handleFileSystemEvent(target: target, events: data)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        return watcher
    }

    private func scheduleReopen(for target: RoutingClientWiringTarget) {
        guard isStarted else { return }
        let backoff = configuration.reopenBackoffNanoseconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: backoff)
            guard let self else { return }
            guard self.isStarted else { return }
            guard self.watchers[target] == nil else { return }
            guard let settingsManager = self.settingsManager,
                  settingsManager.routedClientWiring.enrolledTargets
                  .contains(target.rawValue) else {
                return
            }
            self.armWatcher(for: target)
            self.scheduleRepair(for: target, reason: "watcher_reopen")
        }
    }

    // MARK: - Event handling

    private func handleFileSystemEvent(
        target: RoutingClientWiringTarget,
        events: DispatchSource.FileSystemEvent
    ) {
        if events.contains(.delete) || events.contains(.rename) || events.contains(.link) {
            if let watcher = watchers.removeValue(forKey: target) {
                watcher.source.cancel()
            }
            logger.debug("watcher_rearm_requested", metadata: [
                "target": target.rawValue,
                "events": Self.describe(events: events)
            ])
            scheduleReopen(for: target)
            return
        }
        scheduleRepair(for: target, reason: "fs_event")
    }

    private func scheduleRepair(for target: RoutingClientWiringTarget, reason: String) {
        pendingRepairs[target]?.cancel()
        let debounce = configuration.debounceNanoseconds
        pendingRepairs[target] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounce)
            if Task.isCancelled { return }
            guard let self else { return }
            self.pendingRepairs.removeValue(forKey: target)
            await self.repairIfNeeded(target: target, reason: reason)
        }
    }

    // MARK: - Repair

    private func repairIfNeeded(
        target: RoutingClientWiringTarget,
        reason: String
    ) async {
        guard let settingsManager else { return }
        let intent = settingsManager.routedClientWiring
        guard intent.autoRepairEnabled else {
            logger.debug("repair_skipped_auto_repair_disabled", metadata: ["target": target.rawValue])
            return
        }
        guard intent.enrolledTargets.contains(target.rawValue) else {
            logger.debug("repair_skipped_not_enrolled", metadata: ["target": target.rawValue])
            return
        }
        guard settingsManager.gateway.gatewayEnabled else {
            logger.debug("repair_skipped_gateway_disabled", metadata: ["target": target.rawValue])
            return
        }
        let wiring = wiringFactory()
        guard !wiring.isWired(target: target) else { return }

        let gateway = Self.makeGateway(from: settingsManager.gateway)
        let advertisedModels: [RoutingClientAdvertisedModel]
        if Self.targetRequiresAdvertisedModels(target) {
            advertisedModels = await wiring.advertisedModels(gateway: gateway)
        } else {
            advertisedModels = []
        }

        do {
            _ = try wiring.wire(
                target: target,
                gateway: gateway,
                advertisedModels: advertisedModels
            )
            let now = Date()
            intent.recordRepair(targetRawValue: target.rawValue, at: now)
            logger.notice("routed_wiring_repaired", metadata: [
                "target": target.rawValue,
                "reason": reason,
                "advertised_models": String(advertisedModels.count)
            ])
        } catch {
            logger.silentFailure(
                "routed_wiring_repair_failed",
                error: error,
                context: ["target": target.rawValue, "reason": reason]
            )
        }
    }

    private static func targetRequiresAdvertisedModels(_ target: RoutingClientWiringTarget) -> Bool {
        switch target {
        case .claudeCode, .forge:
            return false
        case .codex, .opencode, .droid:
            return true
        }
    }

    // MARK: - Sweep

    private func triggerInitialSweep() {
        guard isStarted else { return }
        Task { @MainActor [weak self] in
            await self?.performSweep()
        }
    }

    private func startPeriodicSweep() {
        sweepTask?.cancel()
        let seconds = configuration.periodicSweepSeconds
        guard seconds > 0 else { return }
        sweepTask = Task { @MainActor [weak self] in
            let nanos = UInt64(seconds * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                await self?.performSweep()
            }
        }
    }

    private func performSweep() async {
        guard let settingsManager else { return }
        let targets = settingsManager.routedClientWiring.enrolledTargets
            .compactMap(RoutingClientWiringTarget.init(rawValue:))
        for target in targets {
            await repairIfNeeded(target: target, reason: "sweep")
        }
    }

    // MARK: - Helpers

    private static func makeGateway(from settings: GatewaySettings) -> RoutingClientGateway {
        let host = settings.gatewayHost.isEmpty ? "127.0.0.1" : settings.gatewayHost
        let port = settings.gatewayPort > 0 ? settings.gatewayPort : 8317
        return RoutingClientGateway(
            host: host,
            port: port,
            authToken: settings.gatewayAuthToken
        )
    }

    private static func describe(events: DispatchSource.FileSystemEvent) -> String {
        var parts: [String] = []
        if events.contains(.delete) { parts.append("delete") }
        if events.contains(.write) { parts.append("write") }
        if events.contains(.extend) { parts.append("extend") }
        if events.contains(.attrib) { parts.append("attrib") }
        if events.contains(.link) { parts.append("link") }
        if events.contains(.rename) { parts.append("rename") }
        if events.contains(.revoke) { parts.append("revoke") }
        if events.contains(.funlock) { parts.append("funlock") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }
}
