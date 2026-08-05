import Foundation
import OpenBurnBarEngine

/// Decision for one tick.
enum BurnBarAIInboxGateDecision: Sendable, Hashable {
    /// Nothing moved locally and it is not a remote-phase tick — do nothing.
    case skip(signature: String)
    /// Local evidence changed; run the full pipeline.
    case localChanged(signature: String)
    /// Local evidence is unchanged, but it is time to poll GitHub and
    /// auto-resolve open items. Detectors run; the analyst runs only if the
    /// remote data actually produced something new.
    case remotePhase(signature: String)
    /// Operator pressed "Analyze now".
    case forced(signature: String)

    var signature: String {
        switch self {
        case .skip(let signature), .localChanged(let signature),
             .remotePhase(let signature), .forced(let signature):
            return signature
        }
    }

    var runsPipeline: Bool {
        if case .skip = self { return false }
        return true
    }

    var includesRemote: Bool {
        switch self {
        case .remotePhase, .forced: return true
        case .skip, .localChanged: return false
        }
    }

    var telemetryResult: BurnBarInboxRunTelemetry.GateResult {
        switch self {
        case .skip: return .skippedUnchanged
        case .localChanged: return .localChanged
        case .remotePhase: return .remotePhase
        case .forced: return .forced
        }
    }
}

/// Decides whether a tick has anything to do.
///
/// This is the single most important cost control in the feature. The inbox
/// wakes every 5 minutes — 288 times a day — but a developer's local state only
/// changes during actual working hours, and even then not every 5 minutes. The
/// gate makes the common case *free*: one cheap SQL aggregate plus a handful of
/// `stat` calls, no subprocess, no network, no model.
///
/// The signature deliberately covers four independent sources, because each one
/// can move without the others:
///   1. indexed conversations (`MAX(indexedAt)` + an `(id, messageCount)` hash —
///      message count matters because a live session mutates its row in place)
///   2. agent log files on disk (so a session that has not been indexed yet still
///      wakes the pipeline on the following tick)
///   3. workspace git HEADs and dirty-file counts
///   4. the usage ledger's tail (spend happened)
///
/// GitHub is intentionally NOT in the signature: it changes for reasons that have
/// nothing to do with this machine, and polling it every tick would burn API
/// budget. It is sampled on the remote phase instead.
struct BurnBarAIInboxChangeGate: Sendable {
    private let store: BurnBarAIInboxStore
    private let logger: BurnBarDaemonLogger

    /// Agent log roots watched for "something happened but is not indexed yet".
    /// Relative to the user's home directory.
    static let watchedLogRoots = [
        ".claude/projects",
        ".codex/sessions",
        ".gemini/tmp",
        ".factory/sessions",
        ".hermes/sessions"
    ]

    init(store: BurnBarAIInboxStore, logger: BurnBarDaemonLogger) {
        self.store = store
        self.logger = logger
    }

    func decide(
        config: BurnBarInboxConfig,
        tickIndex: Int,
        forced: Bool,
        usageLedgerSignature: String,
        workspaceSignatures: [String],
        now: Date
    ) -> BurnBarAIInboxGateDecision {
        let signature = computeSignature(
            config: config,
            usageLedgerSignature: usageLedgerSignature,
            workspaceSignatures: workspaceSignatures,
            now: now
        )

        if forced { return .forced(signature: signature) }

        let previous = (try? store.state(BurnBarAIInboxSchema.StateKey.gateSignature, as: String.self)) ?? nil
        if previous != signature {
            return .localChanged(signature: signature)
        }
        // Unchanged locally. Poll GitHub every Nth tick so a PR that merged on
        // another machine can still auto-resolve an open item here.
        if tickIndex % max(1, config.remotePhaseEveryNTicks) == 0 {
            return .remotePhase(signature: signature)
        }
        return .skip(signature: signature)
    }

    func commit(signature: String, now: Date) {
        try? store.setState(BurnBarAIInboxSchema.StateKey.gateSignature, value: signature, now: now)
    }

    // MARK: - Signature

    private func computeSignature(
        config: BurnBarInboxConfig,
        usageLedgerSignature: String,
        workspaceSignatures: [String],
        now: Date
    ) -> String {
        var hasher = BurnBarAIInboxStableHasher()
        // Config participates so flipping egress mode or lookback re-analyzes
        // immediately instead of waiting for unrelated activity.
        hasher.combine(config.egressMode.rawValue)
        hasher.combine(config.lookbackMinutes)

        let since = now.addingTimeInterval(-Double(config.lookbackMinutes) * 60)
        if let watermark = try? store.conversationWatermark(since: since) {
            hasher.combine(watermark.contentHash)
            hasher.combine(watermark.latestIndexedAt.map(BurnBarAIInboxTimestamp.string(from:)) ?? "-")
        } else {
            hasher.combine("watermark-unavailable")
        }

        hasher.combine(usageLedgerSignature)
        for signature in workspaceSignatures.sorted() { hasher.combine(signature) }
        hasher.combine(Self.agentLogSignature(since: since))
        return hasher.finalize()
    }

    /// Cheap freshness probe over agent log directories.
    ///
    /// The app's parser refresh runs on a ~10-minute cadence, so the indexed
    /// tables lag reality. Hashing recent file mtimes lets a tick notice "a
    /// session is active right now" and re-check on the next pass, instead of
    /// going quiet for two ticks after every burst of work.
    ///
    /// Bounded by design: one shallow enumeration per root, newest-first, capped.
    static func agentLogSignature(since: Date) -> String {
        var hasher = BurnBarAIInboxStableHasher()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manager = FileManager.default

        for root in watchedLogRoots {
            let rootURL = home.appendingPathComponent(root, isDirectory: true)
            guard manager.fileExists(atPath: rootURL.path) else { continue }
            guard let enumerator = manager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var inspected = 0
            var recentCount = 0
            var newest: Date?
            for case let url as URL in enumerator {
                inspected += 1
                // Hard cap: a multi-year session archive must not turn the gate
                // into the expensive part of the tick.
                if inspected > 4_000 { break }
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true, let modified = values.contentModificationDate else {
                    continue
                }
                guard modified >= since else { continue }
                recentCount += 1
                newest = max(newest ?? modified, modified)
            }
            hasher.combine(root)
            hasher.combine(recentCount)
            hasher.combine(newest.map(BurnBarAIInboxTimestamp.string(from:)) ?? "-")
        }
        return hasher.finalize()
    }
}
