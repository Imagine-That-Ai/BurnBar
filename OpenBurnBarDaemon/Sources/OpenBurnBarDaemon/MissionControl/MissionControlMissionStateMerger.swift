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

extension BurnBarMissionControlService {
    func missionPacketStatus(for phase: BurnBarRunPhase) -> BurnBarMissionPacketStatus {
        switch phase {
        case .idle, .planning:
            return .dispatched
        case .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return .running
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    func isTerminal(phase: BurnBarRunPhase) -> Bool {
        switch phase {
        case .completed, .failed, .cancelled:
            return true
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return false
        }
    }

    func latestUsageEvent(for runID: BurnBarRunID) -> BurnBarUsageEvent? {
        guard FileManager.default.fileExists(atPath: usageLedgerURL.path) else {
            return nil
        }
        let content: String
        do {
            content = try String(contentsOf: usageLedgerURL, encoding: .utf8)
        } catch {
            logger.silentFailure("read_usage_ledger", error: error)
            return nil
        }

        let decoder = JSONDecoder()
        let lines = content.split(whereSeparator: \.isNewline)
        var matches: [BurnBarUsageEvent] = []
        matches.reserveCapacity(lines.count)

        for line in lines {
            guard line.isEmpty == false else { continue }
            let record: BurnBarUsageRecord
            do {
                record = try decoder.decode(BurnBarUsageRecord.self, from: Data(line.utf8))
            } catch {
                logger.silentFailure("decode_usage_record", error: error)
                continue
            }
            guard record.event.runID == runID else { continue }
            matches.append(record.event)
        }

        return matches.sorted { $0.recordedAt > $1.recordedAt }.first
    }

    func missionResultStatus(for phase: BurnBarRunPhase) -> BurnBarMissionResultStatus {
        switch phase {
        case .completed:
            return .succeeded
        case .failed, .cancelled:
            return .failed
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return .partial
        }
    }

    func missionResultSummary(
        for packet: BurnBarMissionPacketSnapshot,
        snapshot: BurnBarRunStateSnapshot
    ) -> String {
        switch snapshot.phase {
        case .completed:
            return "\(packet.workerName) completed its mission packet."
        case .failed:
            return "\(packet.workerName) failed its mission packet."
        case .cancelled:
            return "\(packet.workerName) was cancelled before finishing."
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return "\(packet.workerName) reported a partial mission result."
        }
    }

    func missionResultDetail(for snapshot: BurnBarRunStateSnapshot) -> String? {
        switch snapshot.phase {
        case .completed:
            return "Run \(snapshot.runID.rawValue) completed on \(snapshot.modelID)."
        case .failed:
            return snapshot.errorMessage?.nonEmpty ?? "Run \(snapshot.runID.rawValue) failed."
        case .cancelled:
            return snapshot.errorMessage?.nonEmpty ?? "Run \(snapshot.runID.rawValue) was cancelled."
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return snapshot.errorMessage?.nonEmpty
        }
    }

    func autoTakeoverStatus(for phase: BurnBarRunPhase) -> BurnBarAutoTakeoverStatus {
        switch phase {
        case .completed:
            return .completed
        case .failed, .cancelled:
            return .failed
        case .idle, .planning, .awaitingApproval, .executingTool, .waitingOnCompanion, .modelStreaming:
            return .launched
        }
    }

    func shouldAutoTakeover(
        snapshot: BurnBarRunStateSnapshot,
        now: Date
    ) -> Bool {
        switch snapshot.phase {
        case .failed, .cancelled:
            return true
        case .awaitingApproval, .completed:
            return false
        case .idle, .planning, .executingTool, .waitingOnCompanion, .modelStreaming:
            return now.timeIntervalSince(snapshot.updatedAt) >= autoTakeoverStallThreshold(for: snapshot.phase)
        }
    }

    func buildAutoTakeoverPrompt(
        mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot,
        snapshot: BurnBarRunStateSnapshot
    ) -> String {
        let recoveryReason = autoTakeoverReason(for: snapshot, now: Date())
        return """
        OpenBurnBar auto-takeover for mission \(mission.title) in project \(mission.projectSlug).

        Original packet:
        - Worker: \(packet.workerName)
        - Objective: \(packet.objective)
        - Source run: \(snapshot.runID.rawValue)
        - Source phase: \(snapshot.phase.rawValue)
        - Last updated: \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
        - Recovery reason: \(snapshot.errorMessage?.nonEmpty ?? recoveryReason)

        Take over the work, recover the objective if possible, and return a concise operator-facing outcome with:
        1. what you completed
        2. what remains blocked
        3. the next recommended operator action
        """
    }

    func autoTakeoverReason(
        for snapshot: BurnBarRunStateSnapshot,
        now: Date
    ) -> String {
        switch snapshot.phase {
        case .failed:
            return snapshot.errorMessage?.nonEmpty ?? "Source run failed."
        case .cancelled:
            return snapshot.errorMessage?.nonEmpty ?? "Source run was cancelled."
        case .idle, .planning, .executingTool, .waitingOnCompanion, .modelStreaming:
            let minutes = max(1, Int(now.timeIntervalSince(snapshot.updatedAt) / 60))
            return "Source run stalled in \(snapshot.phase.rawValue) for \(minutes)m."
        case .awaitingApproval:
            return "Source run is waiting on operator approval."
        case .completed:
            return "Source run already completed."
        }
    }

    func missionExecutionModelID(
        for mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot
    ) -> String {
        stringMetadataValue(forKey: "model_id", in: packet.metadata)
            ?? stringMetadataValue(forKey: "model_id", in: mission.metadata)
            ?? "glm-5"
    }

    private func stringMetadataValue(forKey key: String, in metadata: BurnBarMetadata) -> String? {
        guard case .string(let value)? = metadata[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func buildMissionPacketPrompt(
        mission: BurnBarMissionSnapshot,
        packet: BurnBarMissionPacketSnapshot
    ) -> String {
        let approvalLine = mission.approval.approved
            ? "Approved by \(mission.approval.approvedBy ?? "operator")."
            : "Still awaiting explicit approval."
        let priorResults = mission.results
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(3)
            .map { "- \($0.summary)" }
            .joined(separator: "\n")
        let priorResultsBlock = priorResults.isEmpty ? "- None yet." : priorResults

        return """
        OpenBurnBar mission execution for project \(mission.projectSlug).

        Mission:
        - Title: \(mission.title)
        - Summary: \(mission.summary)
        - Recommendation: \(mission.recommendation.rawValue)
        - Approval: \(approvalLine)

        Packet:
        - Worker: \(packet.workerName)
        - Objective: \(packet.objective)

        Recent mission results:
        \(priorResultsBlock)

        Execute the packet objective directly. Return a concise completion note that states what changed, what evidence you used, and any remaining blockers.
        """
    }

    func missionSnapshot(
        from mission: BurnBarMissionSnapshot,
        status: BurnBarMissionStatus,
        updatedAt: Date,
        packets: [BurnBarMissionPacketSnapshot],
        results: [BurnBarMissionResultSnapshot],
        burnRecords: [BurnBarMissionBurnRecord],
        takeoverHistory: [BurnBarAutoTakeoverRecord]?
    ) -> BurnBarMissionSnapshot {
        var metadata = mission.metadata
        let totalTokens = results.reduce(0) { partial, result in
            partial
                + intValue(result.metadata["input_tokens"])
                + intValue(result.metadata["output_tokens"])
                + intValue(result.metadata["cache_read_tokens"])
        }
        metadata["total_tokens"] = .number(Double(totalTokens))
        metadata["packet_count"] = .number(Double(packets.count))
        metadata["result_count"] = .number(Double(results.count))
        metadata["burn_record_count"] = .number(Double(burnRecords.count))
        if let latestPacket = packets.sorted(by: { ($0.dispatchedAt ?? .distantPast) > ($1.dispatchedAt ?? .distantPast) }).first,
           let runID = latestPacket.runID?.rawValue {
            metadata["latest_run_id"] = .string(runID)
        } else {
            metadata.removeValue(forKey: "latest_run_id")
        }
        if let latestTakeover = takeoverHistory?.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            metadata["latest_takeover_status"] = .string(latestTakeover.status.rawValue)
            if let runID = latestTakeover.takeoverRunID?.rawValue {
                metadata["latest_takeover_run_id"] = .string(runID)
            }
        } else {
            metadata.removeValue(forKey: "latest_takeover_status")
            metadata.removeValue(forKey: "latest_takeover_run_id")
        }

        return BurnBarMissionSnapshot(
            id: mission.id,
            projectSlug: mission.projectSlug,
            title: mission.title,
            summary: mission.summary,
            status: resolvedMissionStatus(
                preferredStatus: status,
                approval: mission.approval,
                packets: packets,
                results: results
            ),
            recommendation: mission.recommendation,
            createdAt: mission.createdAt,
            updatedAt: updatedAt,
            approval: mission.approval,
            packets: packets,
            results: results,
            burnRecords: burnRecords,
            takeoverHistory: takeoverHistory,
            metadata: metadata
        )
    }

    func resolvedMissionStatus(
        preferredStatus: BurnBarMissionStatus,
        approval: BurnBarMissionApprovalSnapshot,
        packets: [BurnBarMissionPacketSnapshot],
        results: [BurnBarMissionResultSnapshot]
    ) -> BurnBarMissionStatus {
        if preferredStatus == .cancelled {
            return .cancelled
        }
        if approval.approved == false {
            return packets.isEmpty && results.isEmpty ? preferredStatus : .awaitingApproval
        }
        if packets.isEmpty {
            return results.isEmpty ? preferredStatus : statusFromTerminalResults(results)
        }

        if packets.contains(where: { $0.status == .running }) {
            return .inProgress
        }
        if packets.contains(where: { $0.status == .queued || $0.status == .dispatched }) {
            return .dispatching
        }

        let allPacketsTerminal = packets.allSatisfy { packet in
            [.completed, .failed, .cancelled].contains(packet.status)
        }
        guard allPacketsTerminal else {
            return preferredStatus
        }
        guard results.isEmpty == false else {
            return preferredStatus
        }

        return statusFromTerminalResults(results)
    }

    func statusFromTerminalResults(
        _ results: [BurnBarMissionResultSnapshot]
    ) -> BurnBarMissionStatus {
        let statuses = Set(results.map(\.status))
        if statuses.isSubset(of: [.succeeded, .replayed]) {
            return .completed
        }
        if statuses == [.failed] {
            return .failed
        }
        return .partiallyCompleted
    }

    func mergePackets(
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

    func replacePacket(
        _ packet: BurnBarMissionPacketSnapshot,
        in packets: [BurnBarMissionPacketSnapshot]
    ) -> [BurnBarMissionPacketSnapshot] {
        var replaced = false
        let updated = packets.map { existing -> BurnBarMissionPacketSnapshot in
            guard existing.id == packet.id else { return existing }
            replaced = true
            return packet
        }
        return mergePackets(replaced ? updated : packets, packet)
    }

    func replaceTakeoverRecord(
        _ record: BurnBarAutoTakeoverRecord,
        in history: [BurnBarAutoTakeoverRecord]?
    ) -> [BurnBarAutoTakeoverRecord] {
        let existing = history ?? []
        var replaced = false
        let updated = existing.map { current -> BurnBarAutoTakeoverRecord in
            guard current.id == record.id else { return current }
            replaced = true
            return record
        }
        let merged = replaced ? updated : (existing + [record])
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    func autoTakeoverStallThreshold(for phase: BurnBarRunPhase) -> TimeInterval {
        switch phase {
        case .idle, .planning:
            return 5 * 60
        case .executingTool, .waitingOnCompanion, .modelStreaming:
            return 15 * 60
        case .awaitingApproval, .completed, .failed, .cancelled:
            return .infinity
        }
    }
}
