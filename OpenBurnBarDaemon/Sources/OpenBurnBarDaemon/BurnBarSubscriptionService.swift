import Foundation
import OpenBurnBarCore

public enum BurnBarSubscriptionServiceError: Error, LocalizedError, Equatable {
    case invalidTopic(String)
    case invalidSubscriptionID
    case invalidSequence
    case subscriptionAlreadyExists
    case subscriptionMismatch
    case subscriptionStopped

    public var errorDescription: String? {
        switch self {
        case .invalidTopic(let topic):
            return "Subscription topic '\(topic)' is not supported."
        case .invalidSubscriptionID:
            return "The subscription identifier is invalid."
        case .invalidSequence:
            return "The subscription cursor must be a non-negative integer."
        case .subscriptionAlreadyExists:
            return "The requested subscription identifier is already active."
        case .subscriptionMismatch:
            return "The subscription topic, run, or client does not match its original scope."
        case .subscriptionStopped:
            return "The subscription was stopped and cannot be resumed."
        }
    }
}

public actor BurnBarSubscriptionService {
    private struct Record: Sendable {
        let id: String
        let topic: String
        let runID: String?
        let clientID: String?
        var seq: Int
        var lastAccess: Date
    }

    private static let supportedTopics: Set<String> = ["data", "health", "run"]
    private static let maximumIdentifierLength = 128
    private static let identifierCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"
    )

    private let daemonVersion: String
    private let daemonSessionID: String
    private let now: @Sendable () -> Date
    private let subscriptionTTL: TimeInterval
    private let maximumSubscriptions: Int
    private var records: [String: Record] = [:]
    private var stoppedAt: [String: Date] = [:]

    public init(
        daemonVersion: String = BurnBarDaemonVersion.current,
        daemonSessionID: String = UUID().uuidString,
        subscriptionTTL: TimeInterval = 15 * 60,
        maximumSubscriptions: Int = 128,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.daemonVersion = daemonVersion
        self.daemonSessionID = daemonSessionID
        self.subscriptionTTL = max(30, subscriptionTTL)
        self.maximumSubscriptions = max(1, maximumSubscriptions)
        self.now = now
    }

    public func start(_ request: BurnBarSubscriptionStartRequest) throws -> BurnBarSubscriptionResponse {
        let timestamp = now()
        cleanup(at: timestamp)
        let topic = try normalizedTopic(request.topic)
        let subscriptionID = try normalizedSubscriptionID(
            request.requestedSubscriptionID ?? "sub-\(topic)-\(UUID().uuidString)"
        )
        let clientID = try normalizedOptionalIdentifier(request.clientID)
        let runID = try normalizedOptionalIdentifier(request.runID)
        try validateRunScope(topic: topic, runID: runID)
        guard records[subscriptionID] == nil else {
            throw BurnBarSubscriptionServiceError.subscriptionAlreadyExists
        }
        stoppedAt.removeValue(forKey: subscriptionID)
        evictOldestIfNeeded(excluding: subscriptionID)

        let record = Record(
            id: subscriptionID,
            topic: topic,
            runID: runID,
            clientID: clientID,
            seq: 1,
            lastAccess: timestamp
        )
        records[subscriptionID] = record
        return response(
            record: record,
            firstSnapshot: true,
            disconnectDetected: false,
            recoveredAfterRestart: false,
            reason: "first_snapshot",
            timestamp: timestamp
        )
    }

    public func resume(_ request: BurnBarSubscriptionResumeRequest) throws -> BurnBarSubscriptionResponse {
        guard request.afterSeq >= 0, request.afterSeq < Int.max else {
            throw BurnBarSubscriptionServiceError.invalidSequence
        }
        let timestamp = now()
        cleanup(at: timestamp)
        let subscriptionID = try normalizedSubscriptionID(request.subscriptionID)
        if stoppedAt[subscriptionID] != nil {
            throw BurnBarSubscriptionServiceError.subscriptionStopped
        }
        let topic = try normalizedTopic(request.topic)
        let clientID = try normalizedOptionalIdentifier(request.clientID)
        let runID = try normalizedOptionalIdentifier(request.runID)
        try validateRunScope(topic: topic, runID: runID)

        if var existing = records[subscriptionID] {
            guard existing.topic == topic,
                  existing.runID == runID,
                  existing.clientID == clientID else {
                throw BurnBarSubscriptionServiceError.subscriptionMismatch
            }
            guard existing.seq < Int.max else {
                throw BurnBarSubscriptionServiceError.invalidSequence
            }
            let cursorDiverged = request.afterSeq != existing.seq
            existing.seq = max(existing.seq + 1, request.afterSeq + 1)
            existing.lastAccess = timestamp
            records[subscriptionID] = existing
            return response(
                record: existing,
                firstSnapshot: false,
                disconnectDetected: cursorDiverged,
                recoveredAfterRestart: false,
                reason: cursorDiverged ? "cursor_reconciled" : "cadence_tick",
                timestamp: timestamp
            )
        }

        evictOldestIfNeeded(excluding: subscriptionID)
        let recovered = Record(
            id: subscriptionID,
            topic: topic,
            runID: runID,
            clientID: clientID,
            seq: max(request.afterSeq + 1, 1),
            lastAccess: timestamp
        )
        records[subscriptionID] = recovered
        return response(
            record: recovered,
            firstSnapshot: true,
            disconnectDetected: request.afterSeq > 0,
            recoveredAfterRestart: request.afterSeq > 0,
            reason: request.afterSeq > 0 ? "daemon_restart_recovery" : "first_snapshot",
            timestamp: timestamp
        )
    }

    public func stop(_ request: BurnBarSubscriptionStopRequest) throws -> BurnBarSubscriptionStopResponse {
        let timestamp = now()
        cleanup(at: timestamp)
        let subscriptionID = try normalizedSubscriptionID(request.subscriptionID)
        let clientID = try normalizedOptionalIdentifier(request.clientID)
        if let record = records[subscriptionID] {
            guard record.clientID == clientID else {
                throw BurnBarSubscriptionServiceError.subscriptionMismatch
            }
            records.removeValue(forKey: subscriptionID)
            stoppedAt[subscriptionID] = timestamp
            return BurnBarSubscriptionStopResponse(
                subscriptionID: subscriptionID,
                stopped: true,
                lastSeq: record.seq
            )
        }
        stoppedAt[subscriptionID] = timestamp
        return BurnBarSubscriptionStopResponse(
            subscriptionID: subscriptionID,
            stopped: false,
            lastSeq: 0
        )
    }

    private func response(
        record: Record,
        firstSnapshot: Bool,
        disconnectDetected: Bool,
        recoveredAfterRestart: Bool,
        reason: String,
        timestamp: Date
    ) -> BurnBarSubscriptionResponse {
        let event = BurnBarSubscriptionEvent(
            seq: record.seq,
            kind: "\(record.topic).\(firstSnapshot ? "snapshot" : "tick")",
            snapshot: [
                "topic": record.topic,
                "run_id": record.runID ?? "",
                "client_id": record.clientID ?? "unknown",
                "daemon_version": daemonVersion,
                "daemon_session_id": daemonSessionID,
                "generated_at": ISO8601DateFormatter().string(from: timestamp),
                "transport": "af_unix_burnbarrpc_pull",
                "cursor_semantics": "monotonic_seq",
                "backpressure": "coalesce_latest_per_topic",
                "event_reason": reason
            ],
            terminal: false
        )
        return BurnBarSubscriptionResponse(
            subscriptionID: record.id,
            topic: record.topic,
            seq: record.seq,
            cursor: String(record.seq),
            firstSnapshot: firstSnapshot,
            events: [event],
            degradedFallback: true,
            degradationReason: "bounded_pull_over_burnbarrpc_envelope",
            backpressure: "coalesce_latest_per_topic",
            disconnectDetected: disconnectDetected,
            recoveredAfterRestart: recoveredAfterRestart,
            terminalStateDelivered: false
        )
    }

    private func normalizedTopic(_ rawValue: String) throws -> String {
        let topic = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.supportedTopics.contains(topic) else {
            throw BurnBarSubscriptionServiceError.invalidTopic(topic)
        }
        return topic
    }

    private func normalizedSubscriptionID(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= Self.maximumIdentifierLength,
              value.unicodeScalars.allSatisfy({
                  Self.identifierCharacters.contains($0)
              }) else {
            throw BurnBarSubscriptionServiceError.invalidSubscriptionID
        }
        return value
    }

    private func normalizedOptionalIdentifier(_ rawValue: String?) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return try normalizedSubscriptionID(value)
    }

    private func validateRunScope(topic: String, runID: String?) throws {
        guard topic != "run" || runID != nil else {
            throw BurnBarSubscriptionServiceError.invalidTopic("run_without_run_id")
        }
    }

    private func cleanup(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-subscriptionTTL)
        records = records.filter { $0.value.lastAccess >= cutoff }
        stoppedAt = stoppedAt.filter { $0.value >= cutoff }
    }

    private func evictOldestIfNeeded(excluding subscriptionID: String) {
        guard records[subscriptionID] == nil, records.count >= maximumSubscriptions,
              let oldest = records.values.min(by: { $0.lastAccess < $1.lastAccess }) else {
            return
        }
        records.removeValue(forKey: oldest.id)
    }
}
