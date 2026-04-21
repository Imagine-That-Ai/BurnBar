import OpenBurnBarCore
import Foundation

enum MissionControlMissionStateMerger {
    static func missionStatus(for resultStatus: BurnBarMissionResultStatus) -> BurnBarMissionStatus {
        switch resultStatus {
        case .succeeded, .replayed:
            return .completed
        case .partial:
            return .partiallyCompleted
        case .failed:
            return .failed
        }
    }

    static func mergePackets(
        _ existing: [BurnBarMissionPacketSnapshot],
        _ appended: BurnBarMissionPacketSnapshot
    ) -> [BurnBarMissionPacketSnapshot] {
        var merged: [String: BurnBarMissionPacketSnapshot] = [:]
        for packet in existing {
            merged[packet.id.rawValue] = packet
        }
        merged[appended.id.rawValue] = appended
        return merged.values.sorted {
            let lhsDispatchedAt = $0.dispatchedAt ?? .distantPast
            let rhsDispatchedAt = $1.dispatchedAt ?? .distantPast
            if lhsDispatchedAt != rhsDispatchedAt {
                return lhsDispatchedAt < rhsDispatchedAt
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    static func mergeResults(
        _ existing: [BurnBarMissionResultSnapshot],
        _ appended: BurnBarMissionResultSnapshot
    ) -> [BurnBarMissionResultSnapshot] {
        var merged: [String: BurnBarMissionResultSnapshot] = [:]
        for result in existing {
            merged[result.id.rawValue] = result
        }
        merged[appended.id.rawValue] = appended
        return merged.values.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    static func mergeBurnRecords(
        _ existing: [BurnBarMissionBurnRecord],
        _ appended: BurnBarMissionBurnRecord
    ) -> [BurnBarMissionBurnRecord] {
        var merged: [String: BurnBarMissionBurnRecord] = [:]
        for record in existing {
            merged[record.id] = record
        }
        merged[appended.id] = appended
        return merged.values.sorted {
            if $0.recordedAt != $1.recordedAt {
                return $0.recordedAt < $1.recordedAt
            }
            return $0.id < $1.id
        }
    }

    static func reconcilePRLinkage(
        from results: [BurnBarMissionResultSnapshot],
        fallback: BurnBarPRLinkageSnapshot? = nil
    ) -> BurnBarPRLinkageSnapshot? {
        let sorted = results.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.rawValue < $1.id.rawValue
        }

        var reconciled = fallback
        for result in sorted {
            guard let incoming = result.prLinkage ?? BurnBarPRLinkageSnapshot.fromMetadata(result.metadata) else {
                continue
            }
            reconciled = mergePRLinkage(current: reconciled, incoming: incoming)
        }
        return reconciled
    }

    private static func mergePRLinkage(
        current: BurnBarPRLinkageSnapshot?,
        incoming: BurnBarPRLinkageSnapshot
    ) -> BurnBarPRLinkageSnapshot {
        guard let current else {
            return incoming
        }
        guard samePullRequest(lhs: current, rhs: incoming) else {
            return incoming
        }

        let merged = current.isMerged || incoming.isMerged
        let resolvedState: BurnBarPRLinkageState = merged ? .merged : incoming.state
        let mergedAt = incoming.mergedAt ?? current.mergedAt
        let closedAt = incoming.closedAt
            ?? current.closedAt
            ?? ((resolvedState == .closed || resolvedState == .merged) ? mergedAt : nil)

        return BurnBarPRLinkageSnapshot(
            schemaVersion: max(current.schemaVersion, incoming.schemaVersion),
            repository: incoming.repository,
            prNumberOrID: incoming.prNumberOrID,
            url: incoming.url,
            state: resolvedState,
            mergeCommitSHA: incoming.mergeCommitSHA ?? current.mergeCommitSHA,
            mergedAt: mergedAt,
            closedAt: closedAt
        )
    }

    private static func samePullRequest(
        lhs: BurnBarPRLinkageSnapshot,
        rhs: BurnBarPRLinkageSnapshot
    ) -> Bool {
        lhs.repository.caseInsensitiveCompare(rhs.repository) == .orderedSame
            && lhs.prNumberOrID.caseInsensitiveCompare(rhs.prNumberOrID) == .orderedSame
    }

    static func eventSort(lhs: BurnBarControllerEvent, rhs: BurnBarControllerEvent) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        if lhs.recordedAt != rhs.recordedAt {
            return lhs.recordedAt < rhs.recordedAt
        }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
