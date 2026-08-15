import Foundation

// MARK: - Memory Extraction Policy
//
// Hard ceilings + per-pump safety rails for the memory-extraction scheduler,
// mirroring `AutoSummaryPolicy` (the established summary-feature pattern). These are
// the bounds the `MemoryExtractionEngine` clamps to so a misconfigured setting, a
// runaway model, or a large backlog can never push the feature past a safe envelope.
//
// All values are deliberately conservative: memory extraction is a background,
// best-effort enrichment, not a foreground task the user waits on. Durable writes require
// BOTH `settingsManager.memoryExtractionEnabled` (consent + user toggle + fleet gate) AND
// `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault` through the worker's
// authority closure (PR-D FIX #1).
enum MemoryExtractionPolicy {
    /// Upper bound on transcript characters fed to the model per job (input-side
    /// bound). Smaller than summaries: a single thread's recent turns, not a backlog.
    static let maxPromptChars = 16_000

    /// Upper bound on model output tokens — extracted "facts" are short.
    static let maxOutputTokens = 512

    /// Defensive ceiling on candidates persisted per job, against a model dumping
    /// hundreds of low-value "facts" from one transcript.
    static let maxCandidatesPerJob = 12

    /// Per-pump ceiling on the number of jobs a single foreground drain processes
    /// (PR-D2 must-fix #6). A large backlog must NOT fire an unbounded serial chain of
    /// (possibly paid) cloud calls in one tick; the remainder is picked up on the next
    /// scheduled drain. Mirrors `AutoSummaryPolicy.maxBatchSize`.
    static let maxJobsPerPump = 8

    /// Delay before a bounded pump schedules its own follow-up after hitting the job
    /// ceiling or deadline. Keeps each pump bounded while allowing persisted startup
    /// backlog to drain without waiting for an unrelated future chat commit.
    static let continuationDelay: TimeInterval = 1

    /// Per-pump wall-clock deadline (PR-D2 must-fix #6). The pump stops claiming new
    /// jobs once this elapses, even if `maxJobsPerPump` is not reached, so a slow
    /// provider chain cannot monopolize the loop. The per-JOB wall clock is bounded
    /// separately and far more tightly by `ChatTranscriptExtractor.maxWallClock`.
    static let maxPumpDuration: TimeInterval = 4 * 60

    /// Daily USD cap for cloud egress. Chat-memory extraction remains local-only
    /// and never consults it; the usage-memory cloud lane (U5) realizes it
    /// client-side as the default cap of `UsageMemoryBudgetLedger.cloudBudgetOK`,
    /// the belt-and-braces second gate under the server's token metering.
    static let defaultDailyCapUSD: Double = 0.50

    /// Default per-request timeout (seconds) for the extraction LLM round-trip when no
    /// summary timeout is configured. Bounded so a hung provider cannot pin a job.
    static let defaultRequestTimeoutSeconds: Double = 60

    /// Clamp a configured prompt-char budget into `[4_000, maxPromptChars]`.
    static func clampedPromptChars(_ configured: Int) -> Int {
        min(max(configured, 4_000), maxPromptChars)
    }

    /// Clamp a configured output-token budget into `[120, maxOutputTokens]`.
    static func clampedOutputTokens(_ configured: Int) -> Int {
        min(max(configured, 120), maxOutputTokens)
    }
}

// MARK: - Memory Extraction Kill Switch (Sendable atomic)

/// A `Sendable`, lock-guarded boolean the `MemoryExtractionEngine` (a `@MainActor`
/// type) updates synchronously on every toggle / Remote Config refresh, and the
/// off-main `MemoryExtractionWorker` reads through its `@Sendable () -> Bool` closure.
///
/// WHY THIS EXISTS (PR-D2 must-fix #2): the combined gate
/// `settingsManager.memoryExtractionEnabled` is a `@MainActor` computed property.
/// Reading it synchronously from inside the worker actor (off-main) does NOT compile
/// under strict concurrency. This box is the single live source the worker reads: the
/// MainActor pushes the latest value in, the worker pulls it out, and the gate is
/// therefore NEVER cached — every drain tick sees the current value.
///
/// Implemented with `NSLock` (not `OSAllocatedUnfairLock`, which requires macOS 15;
/// the app targets macOS 14). This mirrors the repo's existing `NSLock`-guarded
/// Sendable boxes (e.g. `DatabaseEncryptionService`, `DirectDownloadUpdateService`).
final class MemoryExtractionKillSwitch: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var allowed: Bool

    /// Starts CLOSED (disabled) by default — fail-safe. The engine opens it only after
    /// reading the live gate on the MainActor.
    init(initiallyAllowed: Bool = false) {
        self.allowed = initiallyAllowed
    }

    /// Push the latest combined-gate value in (called on the MainActor).
    func set(_ newValue: Bool) {
        lock.lock()
        allowed = newValue
        lock.unlock()
    }

    /// Pull the current value out (called off-main by the worker closure).
    func isAllowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }
}

@MainActor
private final class WeakMemoryExtractionKillSwitch {
    weak var value: MemoryExtractionKillSwitch?

    init(_ value: MemoryExtractionKillSwitch) {
        self.value = value
    }
}

@MainActor
private final class WeakMemoryExtractionDrainLauncher {
    weak var value: MemoryExtractionEngine?

    init(_ value: MemoryExtractionEngine) {
        self.value = value
    }
}

@MainActor
enum MemoryExtractionKillSwitchRegistry {
    private static var switches: [WeakMemoryExtractionKillSwitch] = []
    private static var drainLaunchers: [WeakMemoryExtractionDrainLauncher] = []

    static func register(_ killSwitch: MemoryExtractionKillSwitch, initiallyAllowed: Bool) {
        switches.removeAll { $0.value == nil }
        switches.append(WeakMemoryExtractionKillSwitch(killSwitch))
        killSwitch.set(initiallyAllowed)
    }

    static func registerDrainLauncher(_ engine: MemoryExtractionEngine) {
        drainLaunchers.removeAll { $0.value == nil }
        drainLaunchers.append(WeakMemoryExtractionDrainLauncher(engine))
    }

    static func setAll(_ allowed: Bool) {
        switches.removeAll { $0.value == nil }
        for entry in switches {
            entry.value?.set(allowed)
        }
        guard allowed else { return }
        drainLaunchers.removeAll { $0.value == nil }
        for entry in drainLaunchers {
            entry.value?.launchDrain()
        }
    }
}

// MARK: - Usage Memory Kill Switch Registry (two lanes)

/// Registry for the usage-memory pipeline's kill switches, sibling of
/// `MemoryExtractionKillSwitchRegistry` and built from the same
/// `MemoryExtractionKillSwitch` box. Two independent lanes:
///
/// - **extraction** — the combined `UsageMemoryExtractionGate` value (usage
///   consent AND the `memory_usage_extraction_enabled` fleet switch). Future
///   usage-memory workers read this before touching any Safari ask or agent
///   session log.
/// - **authorityWrites** — the `memory_usage_authority_writes_enabled` fleet
///   switch. Gates durable authority writes from the usage pipeline
///   independently of extraction, so a fleet flip can quarantine writes while
///   leaving read-side behavior untouched.
///
/// `MemorySettings.propagateUsageGates()` pushes recomputed values into both
/// lanes on every relevant didSet, mirroring the chat registry's push/pull
/// discipline (switches start CLOSED and are never cached by readers).
@MainActor
enum UsageMemoryKillSwitchRegistry {
    private static var extractionSwitches: [WeakMemoryExtractionKillSwitch] = []
    private static var authorityWriteSwitches: [WeakMemoryExtractionKillSwitch] = []

    static func registerExtraction(_ killSwitch: MemoryExtractionKillSwitch, initiallyAllowed: Bool) {
        extractionSwitches.removeAll { $0.value == nil }
        extractionSwitches.append(WeakMemoryExtractionKillSwitch(killSwitch))
        killSwitch.set(initiallyAllowed)
    }

    static func registerAuthorityWrites(_ killSwitch: MemoryExtractionKillSwitch, initiallyAllowed: Bool) {
        authorityWriteSwitches.removeAll { $0.value == nil }
        authorityWriteSwitches.append(WeakMemoryExtractionKillSwitch(killSwitch))
        killSwitch.set(initiallyAllowed)
    }

    static func setExtraction(_ allowed: Bool) {
        extractionSwitches.removeAll { $0.value == nil }
        for entry in extractionSwitches {
            entry.value?.set(allowed)
        }
    }

    static func setAuthorityWrites(_ allowed: Bool) {
        authorityWriteSwitches.removeAll { $0.value == nil }
        for entry in authorityWriteSwitches {
            entry.value?.set(allowed)
        }
    }
}

// MARK: - Memory Extraction Settings Box (Sendable snapshot holder)

/// A `Sendable`, lock-guarded holder for the latest `MemoryExtractionSettingsSnapshot`.
///
/// WHY THIS EXISTS: `ChatTranscriptExtractor`'s `settingsProvider` is a
/// `@Sendable () -> MemoryExtractionSettingsSnapshot` invoked OFF the main actor (inside
/// the worker's deadline task group). It therefore CANNOT read a `@MainActor`
/// `SettingsManager` directly — and `MainActor.assumeIsolated` from off-main would crash.
/// Instead the `MemoryExtractionEngine` builds the snapshot ON the MainActor (where
/// reading `SettingsManager` is legal) and pushes it into this box before each drain; the
/// off-main provider reads the box. Same push/pull discipline as the kill switch, so the
/// snapshot is fresh per pump and never read across an isolation boundary.
///
/// `NSLock`-guarded for macOS 14 compatibility (no `OSAllocatedUnfairLock`).
final class MemoryExtractionSettingsBox: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var snapshot: MemoryExtractionSettingsSnapshot

    init(_ snapshot: MemoryExtractionSettingsSnapshot) {
        self.snapshot = snapshot
    }

    /// Push the latest snapshot in (called on the MainActor).
    func set(_ newValue: MemoryExtractionSettingsSnapshot) {
        lock.lock()
        snapshot = newValue
        lock.unlock()
    }

    /// Pull the current snapshot out (called off-main by the extractor provider).
    func current() -> MemoryExtractionSettingsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
