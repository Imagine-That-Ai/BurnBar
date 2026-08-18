import Foundation

/// The Flame's memory — a routing decision, archived with what became of it
/// (§ The Flame of `plans/2026-08-17-war-room-master-plan.md`).
///
/// A `RoutingDecision` explains itself at the moment it is made and then
/// evaporates. The distill log is what makes the Flame answerable afterwards:
/// the Command Board reads it to show why a run landed where it did, and an
/// operator reads it to find out whether the Flame's judgement is any good.
///
/// The record keeps the full candidate list, not just the winner. "Why did it
/// not pick the Mini?" is the question people actually ask, and it is
/// unanswerable from the winner alone.
public struct DistillRecord: Sendable, Equatable, Codable, Identifiable {

    /// What became of the decision. Distinguishing `abandoned` from `failed`
    /// matters: the first says the Flame chose and nobody acted, the second
    /// says the machine it chose could not do the work.
    public enum Outcome: String, Sendable, Equatable, Codable, CaseIterable {
        /// Chosen, not yet acted on.
        case pending
        /// Handed to the machine.
        case dispatched
        case succeeded
        case failed
        /// The decision was never acted on and no longer will be.
        case abandoned
        /// The Flame found nowhere to route.
        case unrouted
    }

    public var id: String
    public var decidedAt: Date
    public var chosenBodyID: String?
    public var transport: FlameTransport?
    public var rationale: String
    public var candidates: [FlameCandidate]
    public var requiredCapabilities: [String]
    public var outcome: Outcome
    public var runID: String?
    /// Set when the run finished, so dwell time is derivable without a second
    /// source.
    public var settledAt: Date?

    public init(
        id: String,
        decidedAt: Date,
        chosenBodyID: String?,
        transport: FlameTransport?,
        rationale: String,
        candidates: [FlameCandidate],
        requiredCapabilities: [String] = [],
        outcome: Outcome = .pending,
        runID: String? = nil,
        settledAt: Date? = nil
    ) {
        self.id = id
        self.decidedAt = decidedAt
        self.chosenBodyID = chosenBodyID
        self.transport = transport
        self.rationale = rationale
        self.candidates = candidates
        self.requiredCapabilities = requiredCapabilities
        self.outcome = outcome
        self.runID = runID
        self.settledAt = settledAt
    }

    /// Archive a fresh decision. A decision that routed nowhere is recorded as
    /// `unrouted` rather than `pending`, because nothing will ever act on it.
    public init(
        decision: RoutingDecision,
        requiredCapabilities: Set<String> = [],
        decidedAt: Date
    ) {
        self.init(
            id: decision.decisionID,
            decidedAt: decidedAt,
            chosenBodyID: decision.chosenBodyID,
            transport: decision.transport,
            rationale: decision.rationale,
            candidates: decision.candidates,
            requiredCapabilities: requiredCapabilities.sorted(),
            outcome: decision.didRoute ? .pending : .unrouted
        )
    }

    /// The attribution the dispatched run should carry.
    public var originator: BurnBarOriginator {
        BurnBarOriginator(kind: .flame, decisionID: id, confidence: .exact)
    }

    /// How long the decision took to settle, once it has.
    public var dwell: TimeInterval? {
        guard let settledAt else { return nil }
        return settledAt.timeIntervalSince(decidedAt)
    }

    public var isSettled: Bool {
        switch outcome {
        case .succeeded, .failed, .abandoned, .unrouted: return true
        case .pending, .dispatched: return false
        }
    }

    /// Bodies the Flame considered and passed over, with the reason. This is
    /// the "why not the Mini?" answer.
    public var passedOver: [FlameCandidate] {
        candidates.filter { $0.bodyID != chosenBodyID }
    }
}

/// A bounded, newest-first log of the Flame's decisions.
///
/// Bounded on purpose: this runs in a long-lived daemon, and an unbounded
/// decision history is a slow memory leak. Old records fall off the end rather
/// than being kept forever in RAM.
public struct DistillLog: Sendable, Equatable {
    public static let defaultCapacity = 200

    public private(set) var records: [DistillRecord]
    public let capacity: Int

    public init(capacity: Int = DistillLog.defaultCapacity, records: [DistillRecord] = []) {
        self.capacity = max(1, capacity)
        self.records = Array(records.prefix(self.capacity))
    }

    public mutating func record(_ record: DistillRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
    }

    @discardableResult
    public mutating func settle(
        id: String,
        outcome: DistillRecord.Outcome,
        runID: String? = nil,
        at date: Date
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        // Settlement is terminal. A late or duplicate RPC must not flip a
        // settled verdict (success → failure would corrupt the audit history
        // and `successRate`); an identical retry reports success without
        // touching the record, so callers can retry safely.
        if records[index].isSettled {
            return records[index].outcome == outcome
        }
        records[index].outcome = outcome
        records[index].settledAt = date
        if let runID {
            records[index].runID = runID
        }
        return true
    }

    public func record(id: String) -> DistillRecord? {
        records.first { $0.id == id }
    }

    public func recent(_ limit: Int) -> [DistillRecord] {
        Array(records.prefix(max(0, limit)))
    }

    /// Share of settled, routed decisions that succeeded. Nil until there is
    /// something to judge, so the UI shows "no reading yet" instead of a
    /// confident 0%.
    public var successRate: Double? {
        let judged = records.filter { $0.outcome == .succeeded || $0.outcome == .failed }
        guard !judged.isEmpty else { return nil }
        return Double(judged.filter { $0.outcome == .succeeded }.count) / Double(judged.count)
    }
}
