import Foundation
import OpenBurnBarKernel

/// The daemon's Flame (§ The Flame of `plans/2026-08-17-war-room-master-plan.md`).
///
/// An actor, because it is the one place that both makes routing decisions and
/// remembers them; interleaving those would let two callers settle the same
/// decision differently.
///
/// The routing itself is `FlameRouter`'s, unchanged — this type supplies the
/// fleet, mints a decision id, and archives the result. That split is why the
/// daemon and the app cannot disagree about where work should go: they run the
/// same pure function over the same snapshot.
public actor BurnBarFlameService {

    /// How the service learns what the fleet looks like. Injected so tests
    /// drive real fleets without a network, and so the source can later become
    /// the Wire's fleet snapshots without touching this type.
    public typealias FleetProvider = @Sendable () async -> FleetSnapshot

    private let fleetProvider: FleetProvider
    private let now: @Sendable () -> Date
    private let makeDecisionID: @Sendable () -> String
    private var log: DistillLog

    public init(
        fleetProvider: @escaping FleetProvider,
        capacity: Int = DistillLog.defaultCapacity,
        now: @escaping @Sendable () -> Date = { Date() },
        makeDecisionID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.fleetProvider = fleetProvider
        self.log = DistillLog(capacity: capacity)
        self.now = now
        self.makeDecisionID = makeDecisionID
    }

    /// Route a unit of work and archive the decision in one step.
    ///
    /// Archiving is not optional: a decision the Flame made but did not record
    /// is one the Command Board can never explain, so there is no path that
    /// routes without writing to the log.
    @discardableResult
    public func route(
        requiredCapabilities: Set<String> = [],
        instruction: String? = nil
    ) async -> (decision: RoutingDecision, record: DistillRecord) {
        let snapshot = await fleetProvider()
        let decision = FlameRouter.route(
            snapshot: snapshot,
            requiredCapabilities: requiredCapabilities,
            decisionID: makeDecisionID()
        )
        var record = DistillRecord(
            decision: decision,
            requiredCapabilities: requiredCapabilities,
            decidedAt: now()
        )
        if let instruction, !instruction.isEmpty {
            record.rationale = "\(decision.rationale) — \(instruction)"
        }
        log.record(record)
        return (decision, record)
    }

    public func recentRecords(limit: Int = 50) -> [DistillRecord] {
        log.recent(limit)
    }

    public func successRate() -> Double? {
        log.successRate
    }

    public func record(id: String) -> DistillRecord? {
        log.record(id: id)
    }

    /// Report what became of a decision. Returns nil when the decision is not
    /// in the log, so the caller can tell "unknown" from "recorded".
    public func settle(
        decisionID: String,
        outcome: DistillRecord.Outcome,
        runID: String? = nil
    ) -> DistillRecord? {
        guard log.settle(id: decisionID, outcome: outcome, runID: runID, at: now()) else {
            return nil
        }
        return log.record(id: decisionID)
    }
}
