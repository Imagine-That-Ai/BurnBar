import Foundation

// MARK: - RPC contract

/// War Room Flame RPC request/response DTOs (§ The Flame of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// Requests encode through the shared `BurnBarRPCRequestEnvelopeWithParams`
/// envelope; responses use `BurnBarRPCResponseEnvelope<Result>`. The wire
/// strings on `BurnBarRPCMethod` are authoritative: `daemon.war.flame.route`,
/// `daemon.war.flame.distill.list`, `daemon.war.flame.distill.settle`.

/// Ask the Flame where a unit of work should run.
public struct BurnBarWarFlameRouteParams: Codable, Hashable, Sendable {
    public let requiredCapabilities: [String]
    /// Recorded with the decision so the distill log reads as a history of real
    /// work rather than anonymous routing events.
    public let instruction: String?

    public init(requiredCapabilities: [String] = [], instruction: String? = nil) {
        self.requiredCapabilities = requiredCapabilities
        self.instruction = instruction
    }
}

public struct BurnBarWarFlameRouteResponse: Codable, Equatable, Sendable {
    public let decision: RoutingDecision
    /// The archived form, returned alongside so a caller that wants to settle
    /// the decision later does not need a second round trip to learn its id.
    public let record: DistillRecord

    public init(decision: RoutingDecision, record: DistillRecord) {
        self.decision = decision
        self.record = record
    }
}

public struct BurnBarWarFlameDistillListParams: Codable, Hashable, Sendable {
    public let limit: Int?

    public init(limit: Int? = nil) {
        self.limit = limit
    }
}

public struct BurnBarWarFlameDistillListResponse: Codable, Equatable, Sendable {
    public let records: [DistillRecord]
    /// Nil when nothing has been judged yet, so a client shows "no reading yet"
    /// rather than a confident zero.
    public let successRate: Double?

    public init(records: [DistillRecord], successRate: Double?) {
        self.records = records
        self.successRate = successRate
    }
}

/// Report what became of a decision the Flame made.
public struct BurnBarWarFlameDistillSettleParams: Codable, Hashable, Sendable {
    public let decisionID: String
    public let outcome: DistillRecord.Outcome
    public let runID: String?

    public init(decisionID: String, outcome: DistillRecord.Outcome, runID: String? = nil) {
        self.decisionID = decisionID
        self.outcome = outcome
        self.runID = runID
    }
}

public struct BurnBarWarFlameDistillSettleResponse: Codable, Equatable, Sendable {
    /// False when no such decision is in the log — settling an unknown decision
    /// reports the miss rather than inventing a record for it.
    public let settled: Bool
    public let record: DistillRecord?

    public init(settled: Bool, record: DistillRecord?) {
        self.settled = settled
        self.record = record
    }
}
