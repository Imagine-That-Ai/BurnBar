import Foundation

/// Face C, the Command Board (§ The three faces of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// Every run across every machine, in one grid, with the column the plan asks
/// for by name: STARTED BY. The rollups live here rather than in the view so
/// "what did the Flame spend on the Mini today" has exactly one answer.
public struct CommandBoardRun: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable, CaseIterable {
        case running
        /// No longer producing work, outcome unknown. Usage rows carry no
        /// end-of-run marker, so a source that infers "finished" from silence
        /// reports this rather than claiming a success it never observed.
        case ended
        case succeeded
        case failed
        case cancelled
    }

    public var id: String
    /// Nil for a run that predates machine identity, which reads as "this Mac".
    public var bodyID: String?
    public var bodyDisplayName: String
    public var title: String
    public var originator: BurnBarOriginator
    public var status: Status
    public var startedAt: Date
    public var endedAt: Date?
    public var costUSD: Double
    public var tokens: Int

    public init(
        id: String,
        bodyID: String?,
        bodyDisplayName: String,
        title: String,
        originator: BurnBarOriginator,
        status: Status,
        startedAt: Date,
        endedAt: Date? = nil,
        costUSD: Double = 0,
        tokens: Int = 0
    ) {
        self.id = id
        self.bodyID = bodyID
        self.bodyDisplayName = bodyDisplayName
        self.title = title
        self.originator = originator
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.costUSD = costUSD
        self.tokens = tokens
    }

    public var isFinished: Bool { status != .running }

    public func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// A cost rollup for one grouping key.
public struct CommandBoardRollup: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var runCount: Int
    public var runningCount: Int
    public var costUSD: Double
    public var tokens: Int

    public init(
        id: String,
        label: String,
        runCount: Int,
        runningCount: Int,
        costUSD: Double,
        tokens: Int
    ) {
        self.id = id
        self.label = label
        self.runCount = runCount
        self.runningCount = runningCount
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

public struct CommandBoardSummary: Sendable, Equatable {
    public var runs: [CommandBoardRun]
    public var byMachine: [CommandBoardRollup]
    public var byOriginator: [CommandBoardRollup]
    public var totalCostUSD: Double
    public var totalTokens: Int
    public var runningCount: Int

    public init(
        runs: [CommandBoardRun],
        byMachine: [CommandBoardRollup],
        byOriginator: [CommandBoardRollup],
        totalCostUSD: Double,
        totalTokens: Int,
        runningCount: Int
    ) {
        self.runs = runs
        self.byMachine = byMachine
        self.byOriginator = byOriginator
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.runningCount = runningCount
    }

    public var isEmpty: Bool { runs.isEmpty }

    /// True once work is running on more than one machine — the moment the
    /// board stops being a list and starts being a fleet view.
    public var isFleetActive: Bool {
        byMachine.filter { $0.runningCount > 0 }.count > 1
    }
}

public enum CommandBoard {

    /// Build the board. Running work sorts first and newest-first within each
    /// half, because the board is read to answer "what is happening right now"
    /// before "what happened earlier".
    public static func summarize(runs: [CommandBoardRun]) -> CommandBoardSummary {
        let ordered = runs.sorted { lhs, rhs in
            if lhs.isFinished != rhs.isFinished { return !lhs.isFinished }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id < rhs.id
        }

        return CommandBoardSummary(
            runs: ordered,
            byMachine: rollups(
                ordered,
                // Falling back to the display name keeps an unidentified remote
                // machine out of the local machine's bucket, which would
                // otherwise sum two machines' spend under one name.
                key: { $0.bodyID ?? "name:\($0.bodyDisplayName)" },
                label: { $0.bodyDisplayName }
            ),
            byOriginator: rollups(
                ordered,
                key: { $0.originator.kind.rawValue },
                // The kind's own generic label, not the run's specific one:
                // rolling up "Flame · d-a3f2c9" and "Flame · d-77b1" under the
                // first decision's id would read as a lie.
                label: { BurnBarOriginator.defaultLabel(kind: $0.originator.kind) }
            ),
            totalCostUSD: ordered.reduce(0) { $0 + $1.costUSD },
            totalTokens: ordered.reduce(0) { $0 + $1.tokens },
            runningCount: ordered.filter { !$0.isFinished }.count
        )
    }

    /// Rollups sort by spend, because the question that brings someone to a
    /// cost column is "where is the money going".
    private static func rollups(
        _ runs: [CommandBoardRun],
        key: (CommandBoardRun) -> String,
        label: (CommandBoardRun) -> String
    ) -> [CommandBoardRollup] {
        var order: [String] = []
        var grouped: [String: [CommandBoardRun]] = [:]
        for run in runs {
            let id = key(run)
            if grouped[id] == nil {
                grouped[id] = []
                order.append(id)
            }
            grouped[id]?.append(run)
        }

        return order
            .compactMap { id -> CommandBoardRollup? in
                guard let group = grouped[id], let first = group.first else { return nil }
                return CommandBoardRollup(
                    id: id,
                    label: label(first),
                    runCount: group.count,
                    runningCount: group.filter { !$0.isFinished }.count,
                    costUSD: group.reduce(0) { $0 + $1.costUSD },
                    tokens: group.reduce(0) { $0 + $1.tokens }
                )
            }
            .sorted { lhs, rhs in
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                if lhs.runCount != rhs.runCount { return lhs.runCount > rhs.runCount }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }
}
