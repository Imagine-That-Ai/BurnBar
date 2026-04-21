import Foundation

public enum BurnBarControllerNextActionPlanner {
    public static func orderedActions(
        from missions: [BurnBarMissionSnapshot]
    ) -> [BurnBarControllerNextActionSnapshot] {
        missions
            .map(nextAction(for:))
            .sorted(by: nextActionSort)
    }

    public static func bucket(
        for status: BurnBarMissionStatus
    ) -> BurnBarControllerNextActionBucket {
        switch status {
        case .failed:
            return .blockage
        case .completed, .cancelled:
            return .completion
        case .draft, .awaitingApproval, .approved, .dispatching, .inProgress, .partiallyCompleted:
            return .interruption
        }
    }

    private static func nextAction(
        for mission: BurnBarMissionSnapshot
    ) -> BurnBarControllerNextActionSnapshot {
        BurnBarControllerNextActionSnapshot(
            id: "next-action-\(mission.id.rawValue)",
            missionID: mission.id,
            projectSlug: mission.projectSlug,
            title: actionTitle(for: mission.status),
            summary: actionSummary(for: mission),
            bucket: bucket(for: mission.status),
            status: mission.status,
            recommendation: mission.recommendation,
            updatedAt: mission.updatedAt
        )
    }

    private static func nextActionSort(
        lhs: BurnBarControllerNextActionSnapshot,
        rhs: BurnBarControllerNextActionSnapshot
    ) -> Bool {
        let lhsBucketRank = bucketRank(lhs.bucket)
        let rhsBucketRank = bucketRank(rhs.bucket)
        if lhsBucketRank != rhsBucketRank {
            return lhsBucketRank < rhsBucketRank
        }

        let lhsStatusRank = statusRank(lhs.status)
        let rhsStatusRank = statusRank(rhs.status)
        if lhsStatusRank != rhsStatusRank {
            return lhsStatusRank < rhsStatusRank
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.missionID.rawValue < rhs.missionID.rawValue
    }

    private static func bucketRank(
        _ bucket: BurnBarControllerNextActionBucket
    ) -> Int {
        switch bucket {
        case .blockage: return 0
        case .interruption: return 1
        case .completion: return 2
        }
    }

    private static func statusRank(
        _ status: BurnBarMissionStatus
    ) -> Int {
        switch status {
        case .failed: return 0
        case .awaitingApproval: return 1
        case .partiallyCompleted: return 2
        case .inProgress: return 3
        case .dispatching: return 4
        case .approved: return 5
        case .draft: return 6
        case .completed: return 7
        case .cancelled: return 8
        }
    }

    private static func actionTitle(
        for status: BurnBarMissionStatus
    ) -> String {
        switch status {
        case .failed:
            return "Resolve blocker"
        case .awaitingApproval:
            return "Approve mission"
        case .partiallyCompleted:
            return "Resume interrupted mission"
        case .inProgress, .dispatching:
            return "Monitor active mission"
        case .approved, .draft:
            return "Start mission execution"
        case .completed:
            return "Review completion"
        case .cancelled:
            return "Review cancellation"
        }
    }

    private static func actionSummary(
        for mission: BurnBarMissionSnapshot
    ) -> String {
        let trimmed = mission.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed
        }

        switch mission.status {
        case .failed:
            return "Clear the blocker and resume execution."
        case .awaitingApproval:
            return "Operator approval is required before dispatch can continue."
        case .partiallyCompleted:
            return "Mission work was interrupted and still needs closure."
        case .inProgress, .dispatching:
            return "Mission is active; watch for the next checkpoint."
        case .approved, .draft:
            return "Mission is ready to begin execution."
        case .completed:
            return "Mission closed successfully; review closure evidence."
        case .cancelled:
            return "Mission was cancelled; confirm whether it should be reopened."
        }
    }
}
