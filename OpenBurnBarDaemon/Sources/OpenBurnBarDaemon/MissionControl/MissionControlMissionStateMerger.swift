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
            ($0.dispatchedAt ?? .distantPast) < ($1.dispatchedAt ?? .distantPast)
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
        return merged.values.sorted { $0.createdAt < $1.createdAt }
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
        return merged.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    static func eventSort(lhs: BurnBarControllerEvent, rhs: BurnBarControllerEvent) -> Bool {
        if lhs.sequence == rhs.sequence {
            return lhs.recordedAt < rhs.recordedAt
        }
        return lhs.sequence < rhs.sequence
    }
}
