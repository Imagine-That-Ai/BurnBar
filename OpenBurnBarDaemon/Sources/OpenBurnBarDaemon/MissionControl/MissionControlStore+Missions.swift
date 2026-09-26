import OpenBurnBarEngine
import Foundation

extension BurnBarMissionControlStore {
    public func mission(id: BurnBarMissionID) throws -> BurnBarMissionSnapshot? {
        try ensureLoaded()
        return projection?.missions[id.rawValue]
    }

    public func missionHealth(_ request: BurnBarMissionHealthRequest) throws -> BurnBarMissionHealthResponse {
        try ensureLoaded()
        guard let mission = projection?.missions[request.missionID.rawValue] else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        let packetHistory = mission.packets.map { packet in
            BurnBarMissionHistoryEntry(
                id: "packet:\(packet.id.rawValue)",
                kind: "packet",
                status: packet.status.rawValue,
                summary: packet.objective,
                occurredAt: packet.completedAt ?? packet.dispatchedAt ?? mission.createdAt,
                metadata: packet.metadata
            )
        }
        let resultHistory = mission.results.map { result in
            BurnBarMissionHistoryEntry(
                id: "result:\(result.id.rawValue)",
                kind: "result",
                status: result.status.rawValue,
                summary: result.summary,
                occurredAt: result.createdAt,
                metadata: result.metadata
            )
        }
        let burnHistory = mission.burnRecords.map { burn in
            BurnBarMissionHistoryEntry(
                id: "burn:\(burn.id)",
                kind: "burn",
                status: "recorded",
                summary: "\(burn.label): \(burn.amount) \(burn.unit)",
                occurredAt: burn.recordedAt
            )
        }
        let takeoverHistory = (mission.takeoverHistory ?? []).map { takeover in
            BurnBarMissionHistoryEntry(
                id: "takeover:\(takeover.id)",
                kind: "takeover",
                status: takeover.status.rawValue,
                summary: takeover.reason,
                occurredAt: takeover.updatedAt,
                metadata: takeover.metadata
            )
        }
        let history = (packetHistory + resultHistory + burnHistory + takeoverHistory)
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt < $1.occurredAt
                }
                return $0.id < $1.id
            }
        let activePacketCount = mission.packets.filter {
            [.queued, .dispatched, .running].contains($0.status)
        }.count
        let failedResultCount = mission.results.filter { $0.status == .failed }.count
        let failedPacket = mission.packets.contains { $0.status == .failed }
        let healthStatus: BurnBarMissionHealthStatus
        let detail: String
        switch (mission.status, failedResultCount > 0 || failedPacket, activePacketCount) {
        case (.failed, _, _), (_, true, _):
            healthStatus = .failed
            detail = "Mission failure is recorded in the daemon projection."
        case (_, _, let active) where active > 0:
            healthStatus = .healthy
            detail = "\(active) mission packet(s) are active."
        case (.draft, _, _), (.awaitingApproval, _, _):
            healthStatus = .degraded
            detail = "Mission is waiting for approval before dispatch."
        case (.completed, _, _), (.cancelled, _, _):
            healthStatus = .healthy
            detail = "Mission reached a terminal state without an active packet."
        default:
            healthStatus = .unknown
            detail = "The daemon projection has no active packet or terminal result."
        }
        let lastActivityAt = history.last?.occurredAt ?? mission.updatedAt
        let health = BurnBarMissionHealthSnapshot(
            status: healthStatus,
            detail: detail,
            checkedAt: Date(),
            lastActivityAt: lastActivityAt,
            activePacketCount: activePacketCount,
            failedResultCount: failedResultCount
        )
        return BurnBarMissionHealthResponse(
            missionID: mission.id,
            health: health,
            history: history
        )
    }

    public func missions(_ request: BurnBarMissionListRequest) throws -> [BurnBarMissionSnapshot] {
        try ensureLoaded()
        return Array(projection?.missions.values
            .filter { item in
                (request.projectSlug == nil || item.projectSlug == request.projectSlug)
                    && request.statuses.contains(item.status)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                // Tie-break: missionID ascending (lexicographic)
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .prefix(request.limit) ?? [])
    }

    public func createMission(_ request: BurnBarMissionCreateRequest) throws -> BurnBarMissionMutationResponse {
        let now = Date()
        let clientMetadata = Self.clientCreatableMissionMetadata(request.metadata)
        let mission = BurnBarMissionSnapshot(
            id: BurnBarMissionID(rawValue: "mission-\(UUID().uuidString)"),
            projectSlug: request.projectSlug,
            title: request.title,
            summary: request.summary,
            status: .awaitingApproval,
            recommendation: request.recommendation,
            createdAt: now,
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(
                approved: false,
                approvedAt: nil,
                approvedBy: nil,
                note: nil
            ),
            takeoverHistory: nil,
            metadata: clientMetadata.merging(["created_by": .string(request.createdBy)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_created",
            projectSlug: mission.projectSlug,
            summary: mission.title,
            detail: mission.summary,
            payload: try BurnBarJSONValue.fromEncodable(mission)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(mission.id),
            emittedEvent: event
        )
    }

    private static func clientCreatableMissionMetadata(_ metadata: BurnBarMetadata) -> BurnBarMetadata {
        metadata.filter { key, _ in
            !BurnBarEnterprisePolicyMetadataKey.missionServerOwnedKeys.contains(key)
        }
    }

    public func approveMission(_ request: BurnBarMissionApproveRequest) throws -> BurnBarMissionMutationResponse {
        guard let existing = try mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        let now = Date()
        var metadata = existing.metadata
        if let pendingPacketID = existing.metadata[BurnBarEnterprisePolicyMetadataKey.pendingPacketID]?.missionStringValue(),
           let pendingPacketFingerprint = existing.metadata[BurnBarEnterprisePolicyMetadataKey.pendingPacketFingerprint]?.missionStringValue() {
            metadata[BurnBarEnterprisePolicyMetadataKey.approvedPacketID] = .string(pendingPacketID)
            metadata[BurnBarEnterprisePolicyMetadataKey.approvedPacketFingerprint] = .string(pendingPacketFingerprint)
            metadata[BurnBarEnterprisePolicyMetadataKey.approvalGranted] = .bool(true)
            metadata[BurnBarEnterprisePolicyMetadataKey.approvalGrantedAt] = .string(now.ISO8601Format())
            metadata[BurnBarEnterprisePolicyMetadataKey.approvalGrantedBy] = .string(request.actor)
        }
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: existing.status == .cancelled ? .cancelled : .approved,
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(
                approved: true,
                approvedAt: now,
                approvedBy: request.actor,
                note: request.note
            ),
            packets: existing.packets,
            results: existing.results,
            burnRecords: existing.burnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: metadata
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_approved",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: request.note,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    /// Terminal mission statuses that block dispatch.
    private static let terminalStatuses: Set<BurnBarMissionStatus> = [
        .completed, .failed, .cancelled
    ]

    public func missionCancel(_ request: BurnBarMissionCancelRequest) throws -> BurnBarMissionMutationResponse {
        guard let existing = try mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        let now = Date()
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: .cancelled,
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: now,
            approval: existing.approval,
            packets: existing.packets,
            results: existing.results,
            burnRecords: existing.burnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: existing.metadata.merging(["cancelled_by": .string(request.actor)]) { _, new in new }
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_cancelled",
            projectSlug: updated.projectSlug,
            summary: updated.title,
            detail: request.note,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    public func dispatchMissionPacket(_ request: BurnBarMissionDispatchPacketRequest) throws -> BurnBarMissionMutationResponse {
        guard let existing = try mission(id: request.missionID) else {
            throw BurnBarMissionControlError.missionNotFound(request.missionID)
        }

        // VAL-DAEMON-009: Dispatch is approval-gated and terminal-safe
        // Block dispatch if mission is not approved
        guard existing.approval.approved else {
            throw BurnBarMissionControlError.missionNotApproved(request.missionID)
        }

        // Block dispatch if mission is in a terminal state
        guard !Self.terminalStatuses.contains(existing.status) else {
            throw BurnBarMissionControlError.missionTerminal(request.missionID, existing.status)
        }

        let packet = BurnBarMissionPacketSnapshot(
            id: request.packet.id,
            missionID: existing.id,
            workerName: request.packet.workerName,
            objective: request.packet.objective,
            status: request.packet.status,
            runID: request.packet.runID,
            dispatchedAt: request.packet.dispatchedAt ?? Date(),
            completedAt: request.packet.completedAt,
            metadata: request.packet.metadata.merging(["actor": .string(request.actor)]) { _, new in new }
        )
        let packets = MissionControlMissionStateMerger.mergePackets(existing.packets, packet)
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: packet.status == .completed ? .inProgress : .dispatching,
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: packet.dispatchedAt ?? Date(),
            approval: existing.approval,
            packets: packets,
            results: existing.results,
            burnRecords: existing.burnRecords,
            takeoverHistory: existing.takeoverHistory,
            metadata: existing.metadata
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_packet_dispatched",
            projectSlug: updated.projectSlug,
            summary: packet.workerName,
            detail: packet.objective,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    public func recordMissionResult(_ request: BurnBarMissionRecordResultRequest, existingMission: BurnBarMissionSnapshot? = nil) throws -> BurnBarMissionMutationResponse {
        let existing: BurnBarMissionSnapshot
        if let provided = existingMission {
            existing = provided
        } else {
            guard let fetched = try mission(id: request.missionID) else {
                throw BurnBarMissionControlError.missionNotFound(request.missionID)
            }
            existing = fetched
        }

        let result = BurnBarMissionResultSnapshot(
            id: request.result.id,
            missionID: existing.id,
            packetID: request.result.packetID,
            runID: request.result.runID,
            status: request.result.status,
            summary: request.result.summary,
            detail: request.result.detail,
            burnDelta: request.result.burnDelta,
            createdAt: request.result.createdAt,
            evidenceRefs: request.result.evidenceRefs,
            prLinkage: request.result.prLinkage ?? BurnBarPRLinkageSnapshot.fromMetadata(request.result.metadata),
            metadata: request.result.metadata
        )
        let burnRecord = BurnBarMissionBurnRecord(
            id: "burn-\(result.id.rawValue)",
            label: result.summary,
            amount: result.burnDelta,
            unit: "points",
            recordedAt: result.createdAt
        )
        let mergedResults = MissionControlMissionStateMerger.mergeResults(existing.results, result)
        let mergedBurnRecords = MissionControlMissionStateMerger.mergeBurnRecords(existing.burnRecords, burnRecord)
        var metadata = existing.metadata
        let totalTokens = mergedResults.reduce(0) { partial, result in
            partial
                + intValue(result.metadata["input_tokens"])
                + intValue(result.metadata["output_tokens"])
                + intValue(result.metadata["cache_read_tokens"])
        }
        metadata["total_tokens"] = .number(Double(totalTokens))
        metadata["result_count"] = .number(Double(mergedResults.count))
        metadata["burn_record_count"] = .number(Double(mergedBurnRecords.count))
        metadata = applyTeamCollaborationMetadata(metadata, incoming: request.result.metadata)
        let reconciledPRLinkage = MissionControlMissionStateMerger.reconcilePRLinkage(
            from: mergedResults,
            fallback: existing.prLinkage
        )
        metadata = applyPRLinkageMetadata(metadata, prLinkage: reconciledPRLinkage)
        let updated = BurnBarMissionSnapshot(
            id: existing.id,
            projectSlug: existing.projectSlug,
            title: existing.title,
            summary: existing.summary,
            status: MissionControlMissionStateMerger.missionStatus(for: result.status),
            recommendation: existing.recommendation,
            createdAt: existing.createdAt,
            updatedAt: result.createdAt,
            approval: existing.approval,
            packets: existing.packets,
            results: mergedResults,
            burnRecords: mergedBurnRecords,
            takeoverHistory: existing.takeoverHistory,
            prLinkage: reconciledPRLinkage,
            metadata: metadata
        )

        let event = try appendEvent(
            family: .mission,
            eventType: "mission_result_recorded",
            projectSlug: updated.projectSlug,
            summary: result.summary,
            detail: result.detail,
            payload: try BurnBarJSONValue.fromEncodable(updated)
        )

        return BurnBarMissionMutationResponse(
            mission: try missionValue(updated.id),
            emittedEvent: event
        )
    }

    public func persistMissionSnapshot(
        _ mission: BurnBarMissionSnapshot,
        eventType: String,
        summary: String,
        detail: String? = nil
    ) throws -> BurnBarMissionMutationResponse {
        let event = try appendEvent(
            family: .mission,
            eventType: eventType,
            projectSlug: mission.projectSlug,
            summary: summary,
            detail: detail,
            payload: try BurnBarJSONValue.fromEncodable(mission)
        )
        return BurnBarMissionMutationResponse(
            mission: try missionValue(mission.id),
            emittedEvent: event
        )
    }
}
