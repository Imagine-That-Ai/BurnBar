import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

// MARK: - Provider session activity watcher
//
// Watches every enabled provider's session-log directory and reports observed
// writes, so external CLI agents — a Claude Code running in Terminal, a Codex
// in another window — become visible on the Home fleet panel.
//
// The inference this class implements, stated once so it can be checked:
//
//     A write at time T is evidence the agent was active at T.
//     The absence of writes is NOT evidence of idleness.
//
// An agent may be thinking for four minutes, blocked on a tool, or sitting on a
// permission prompt — all of which write nothing. That is why this type only
// ever reports *writes*, and why `FleetLiveness` has no `.idle` case for it to
// report into.
//
// Paths come from the generated ingestion catalog rather than a hardcoded list,
// so this cannot drift from `contracts/provider-ingestion-catalog.json`.
//
// A write counts only when the provider *owns* the file. API-backed rows
// (`*-no-local-logs`, e.g. MiMo) and model-filter piggybacks (MiniMax / Z.ai
// on Factory's session tree) never get a stream — their activity arrives
// through parsed usage, not through someone else's mtime. The catalog glob
// is applied to every event, so `~/.codex/auth.json` is not a session write.

@MainActor
final class ProviderSessionActivityWatcher {

    struct Configuration {
        /// FSEvents coalescing window. Injectable so tests can run hot.
        var latency: TimeInterval = 1.0
        /// Additional app-side debounce after a batch, so a burst of writes in
        /// one turn produces one model update rather than dozens.
        var debounce: Duration = .milliseconds(400)
        /// Re-probe interval for directories that did not exist at arm time.
        var rearmProbe: Duration = .seconds(60)

        static let live = Configuration()
    }

    private let configuration: Configuration
    private let environment: [String: String]
    private weak var model: LiveFleetModel?

    private var streams: [AgentProvider: FileTreeEventStream] = [:]
    private var pending: [AgentProvider: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "ai.burnbar.fleet.watch", qos: .utility)

    private(set) var isArmed = false

    init(
        model: LiveFleetModel,
        configuration: Configuration = .live,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.model = model
        self.configuration = configuration
        self.environment = environment
    }

    // MARK: - Arming

    /// Arms a watcher per provider.
    ///
    /// Only providers whose resolved directory actually exists get a stream —
    /// existence is one `stat` at arm time, re-probed on the shared cadence and
    /// never by a watcher. In practice this is 3–6 streams, not 37.
    func arm(providers: [AgentProvider]) {
#if DISTRIBUTION_MAS
        // The App Store build is sandboxed with `files.user-selected.read-only`,
        // so `~/.claude/projects` and friends are structurally unreadable. Say
        // so per row rather than rendering every external agent as quiet.
        for provider in providers {
            model?.recordUnwatchable(
                provider: provider,
                reason: "App Store build can't read agent logs"
            )
        }
        isArmed = false
#else
        for provider in providers where streams[provider] == nil {
            // Piggybacks and API-backed providers keep parsed-usage / in-app
            // presence as their evidence. Marking them unwatchable would
            // hide those rows behind "Not watched".
            guard AgentProviderLogDiscovery.shouldArmLiveWatch(
                for: provider,
                environment: environment
            ) else { continue }

            let source = AgentProviderLogDiscovery.resolveLogSource(
                for: provider,
                environment: environment
            )
            let root = URL(fileURLWithPath: source.resolvedPath, isDirectory: true)

            let stream = FileTreeEventStream(
                root: root,
                queue: queue,
                latency: configuration.latency
            ) { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.handle(provider: provider, paths: paths, root: root)
                }
            }

            if stream.start() {
                streams[provider] = stream
                model?.clearUnwatchable(provider: provider)
            } else {
                model?.recordUnwatchable(provider: provider, reason: "No session logs found yet")
            }
        }
        isArmed = streams.isEmpty == false
#endif
    }

    /// Tears every stream down.
    ///
    /// Called on display sleep as well as teardown. A stream that survives
    /// sleep wakes the process on every write from a lid-closed CLI, which is
    /// strictly worse than the 60s poll it replaced.
    func disarm() {
        for stream in streams.values { stream.stop() }
        streams.removeAll()
        for task in pending.values { task.cancel() }
        pending.removeAll()
        isArmed = false
    }

    // MARK: - Sleep / wake

    func handleWillSleep() {
        disarm()
        model?.beginSleepGap()
    }

    /// Re-arms after wake.
    ///
    /// Rows stay `unobservable` until the first post-wake event arrives —
    /// `LiveFleetModel.recordWrite` clears the gap. Showing pre-sleep
    /// timestamps as if current is the exact failure this whole design exists
    /// to prevent.
    func handleDidWake(providers: [AgentProvider]) {
        arm(providers: providers)
    }

    // MARK: - Events

    private func handle(provider: AgentProvider, paths: [String], root: URL) {
        pending[provider]?.cancel()
        pending[provider] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.configuration.debounce) // try?-ok(cancellation only; debounce sleep)
            guard Task.isCancelled == false else { return }
            self.commit(provider: provider, paths: paths, root: root)
        }
    }

    private func commit(provider: AgentProvider, paths: [String], root: URL) {
        // Path + mtime is the entire honesty budget. We never open or read a
        // session file here: the panel's claim is "a file belonging to this
        // provider was written at T", and reading contents would be both
        // slower and a privacy claim we have not earned on this surface.
        var newest: (date: Date, path: String)?
        for path in paths {
            let url = URL(fileURLWithPath: path)
            // try?-ok(session file may vanish between event and stat; skip it)
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ),
                  let modified = values.contentModificationDate else { continue }
            let isDirectory = values.isDirectory ?? false
            guard AgentProviderLogDiscovery.admitsLiveWrite(
                provider: provider,
                path: path,
                isDirectory: isDirectory,
                environment: environment
            ) else { continue }
            if let current = newest, current.date >= modified { continue }
            newest = (modified, Self.displayPath(for: url, root: root))
        }

        guard let newest else { return }
        model?.recordWrite(provider: provider, at: newest.date, path: newest.path)
    }

    /// The path shown in a tooltip: relative to the watched root, so it reads
    /// as "projects/BurnBar/session.jsonl" rather than a home-directory-leaking
    /// absolute path.
    static func displayPath(for url: URL, root: URL) -> String {
        let full = url.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard full.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(full.dropFirst(prefix.count))
    }
}
