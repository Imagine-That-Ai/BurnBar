import Foundation
import Observation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

// MARK: - Live fleet model
//
// Merges every source that can honestly speak to "what are my agents doing"
// into one ranked list of `FleetAgentRow`.
//
// Sources, in descending fidelity:
//
//   1. `AgentPresenceModel` — instantaneous, but only sees chat panes inside
//      this app. The only source that can claim an agent is running *now*.
//   2. Session-log watchers (`ProviderSessionActivityWatcher`) — sub-second,
//      and covers external CLI agents. Reports "wrote at T", never "running".
//   3. Parsed `TokenUsage` rows — covers external agents too, but only as
//      fresh as the scan cadence (60s floor, 600s with the Pixel Clock).
//
// Anything not covered by those degrades to `.unobservable`, never to a
// confident "idle".

@MainActor
@Observable
final class LiveFleetModel {

    // MARK: Published state

    private(set) var rows: [FleetAgentRow] = []
    /// True when at least one real-time source is armed, so the panel footer
    /// can distinguish "watched live" from "as of last scan".
    private(set) var hasRealTimeCoverage = false
    /// Set while the display has slept and the watchers were torn down, so
    /// pre-sleep timestamps are never rendered as if current.
    private(set) var sleepGapReason: String?
    /// When the parsed-usage snapshot was last rebuilt, for the footer.
    private(set) var lastScanAt: Date?

    var activeCount: Int { rows.filter(\.liveness.isActive).count }

    // MARK: Inputs

    /// Memoized last-write per provider, derived from parsed usage rows.
    ///
    /// Keyed on `usagesVersion` because `dataStore.usages` can be six figures
    /// and this is a launch-surface panel — the O(n) pass must run once per
    /// version tick, never per render and never per row.
    private var usageActivity: [AgentProvider: (date: Date, project: String?)] = [:]
    private var usageActivityVersion: Int = -1

    /// Live write timestamps from the filesystem watchers, keyed by provider.
    private var watchedActivity: [AgentProvider: (date: Date, path: String)] = [:]

    /// Providers the watchers could not be armed for, with the reason —
    /// sandboxed build, missing directory, watcher disabled.
    private var unwatchable: [AgentProvider: String] = [:]

    /// The last inputs `rebuild` ran with. Retained so a watcher event can
    /// recompute rows on its own: FSEvents is the whole point of the live panel,
    /// and without this the observed write only lands in the evidence dictionary
    /// and waits for the unrelated shared refresh cadence — turning an
    /// advertised sub-second watcher into a minute-or-more lag.
    private struct RebuildInputs {
        let providers: [AgentProvider]
        let presence: [ChatBackendID: AgentPresence]
        let busyLocation: [ChatBackendID: String]
        let usages: [TokenUsage]
        let usagesVersion: Int
    }

    private var lastRebuildInputs: RebuildInputs?

    // MARK: - Rebuild

    /// Rebuilds every row.
    ///
    /// Cheap by construction: the only O(n) work is the usage scan, and that is
    /// skipped entirely unless `usagesVersion` changed since the last pass.
    func rebuild(
        providers: [AgentProvider],
        presence: [ChatBackendID: AgentPresence],
        busyLocation: [ChatBackendID: String],
        usages: [TokenUsage],
        usagesVersion: Int,
        now: Date = Date()
    ) {
        refreshUsageActivityIfNeeded(usages: usages, version: usagesVersion, now: now)

        let backendsByProvider = Self.backendsByProvider()

        rows = providers.map { provider in
            let backend = backendsByProvider[provider]
            var evidence = FleetLivenessResolver.Evidence()

            if let backend {
                evidence.presence = presence[backend]
                evidence.location = busyLocation[backend]
            }

            // Prefer the watcher's timestamp over the parsed row: same event,
            // but the watcher saw it seconds ago and the parser saw it at the
            // last scan. Taking the newer of the two would be wrong when the
            // parser is *behind*, which is its normal state.
            //
            // Parsed usage is only attached for providers that own a local
            // session tree. API-backed / piggyback agents (MiMo, OpenAI,
            // DeepSeek, OpenBurnBar, MiniMax, Z.ai) inherit gateway ledger
            // timestamps that are not those agents writing.
            var project: String?
            if let watched = watchedActivity[provider] {
                evidence.lastWrite = (watched.date, .sessionLogWrite(watched.path))
                project = usageActivity[provider]?.project
            } else if AgentProviderLogDiscovery.isLiveWatchCandidate(provider),
                      let parsed = usageActivity[provider] {
                evidence.lastWrite = (parsed.date, .parsedUsageRow)
                project = parsed.project
            }

            // A sleep gap invalidates every non-live source at once: those
            // timestamps are from before the machine stopped watching, and
            // rendering them as current is the exact failure this model exists
            // to prevent. An in-app turn is unaffected — it is observed
            // directly and `resolve` ranks it above this.
            if let sleepGapReason {
                evidence.unobservableReason = sleepGapReason
            } else if let reason = unwatchable[provider], evidence.lastWrite == nil {
                evidence.unobservableReason = reason
            }

            return FleetAgentRow(
                provider: provider,
                backend: backend,
                liveness: FleetLivenessResolver.resolve(evidence, now: now),
                context: project
            )
        }
        .sorted(by: Self.rank)

        hasRealTimeCoverage = watchedActivity.isEmpty == false || unwatchable.count < providers.count
        lastRebuildInputs = RebuildInputs(
            providers: providers,
            presence: presence,
            busyLocation: busyLocation,
            usages: usages,
            usagesVersion: usagesVersion
        )
    }

    /// Recompute rows from the retained inputs after a watcher event. Cheap: the
    /// usage scan is version-gated, so an unchanged `usagesVersion` skips it.
    private func rebuildFromRetainedInputs(now: Date) {
        guard let inputs = lastRebuildInputs else { return }
        rebuild(
            providers: inputs.providers,
            presence: inputs.presence,
            busyLocation: inputs.busyLocation,
            usages: inputs.usages,
            usagesVersion: inputs.usagesVersion,
            now: now
        )
    }

    // MARK: - Watcher input

    /// Records an observed write. Called by `ProviderSessionActivityWatcher`.
    func recordWrite(provider: AgentProvider, at date: Date, path: String) {
        watchedActivity[provider] = (date, path)
        // The first real event after a wake proves we are watching again.
        sleepGapReason = nil
        // Publish it now rather than waiting for the shared refresh cadence.
        rebuildFromRetainedInputs(now: date)
    }

    /// Records that a provider cannot be watched, with a user-facing reason.
    func recordUnwatchable(provider: AgentProvider, reason: String) {
        unwatchable[provider] = reason
    }

    func clearUnwatchable(provider: AgentProvider) {
        unwatchable.removeValue(forKey: provider)
    }

    /// Marks every non-live row unobservable because the watchers were torn
    /// down for display sleep. Cleared by the first post-wake event.
    func beginSleepGap(reason: String = "Not watched while asleep") {
        sleepGapReason = reason
        watchedActivity.removeAll()
    }

    func endSleepGap() {
        sleepGapReason = nil
    }

    // MARK: - Usage scan

    private func refreshUsageActivityIfNeeded(usages: [TokenUsage], version: Int, now: Date) {
        guard version != usageActivityVersion else { return }
        usageActivityVersion = version
        lastScanAt = now

        var latest: [AgentProvider: (date: Date, project: String?)] = [:]
        for usage in usages {
            let provider = usage.provider
            if let existing = latest[provider], existing.date >= usage.endTime { continue }
            latest[provider] = (usage.endTime, usage.projectName)
        }
        usageActivity = latest
    }

    // MARK: - Ordering

    /// Rows sort by how much they want the user's attention: live turns, then
    /// recent writes, then blocked agents (which need an action), then quiet,
    /// then everything we cannot see.
    static func rank(_ lhs: FleetAgentRow, _ rhs: FleetAgentRow) -> Bool {
        let l = weight(lhs.liveness), r = weight(rhs.liveness)
        if l != r { return l < r }
        return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
    }

    private static func weight(_ liveness: FleetLiveness) -> Int {
        switch liveness {
        case .workingHere: return 0
        case .wroteRecently: return 1
        case .blocked: return 2
        case .quietSince: return 3
        case .standingBy: return 4
        case .unobservable: return 5
        }
    }

    /// Provider → chat backend, inverted from `ChatBackendID.agentProvider`
    /// so the mapping has exactly one definition.
    static func backendsByProvider() -> [AgentProvider: ChatBackendID] {
        var map: [AgentProvider: ChatBackendID] = [:]
        for backend in ChatBackendID.allCases {
            guard let provider = backend.agentProvider else { continue }
            // First wins: `allCases` order is the declaration order, and the
            // earlier backend is the canonical one for that provider.
            if map[provider] == nil { map[provider] = backend }
        }
        return map
    }
}
