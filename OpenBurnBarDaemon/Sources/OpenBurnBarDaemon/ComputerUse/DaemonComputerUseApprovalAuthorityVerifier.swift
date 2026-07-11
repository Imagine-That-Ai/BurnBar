import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

/// Fail-closed verifier for phone-authorized Computer Use action decisions.
/// The response is bound to the exact pending request and a pinned controller
/// key, while a durable per-peer counter prevents replay across daemon restarts.
public actor DaemonComputerUseApprovalAuthorityVerifier {
    public enum VerificationFailure: Error, Equatable, Sendable {
        case missingSessionID
        case wrongSession(expected: String, observed: String)
        case wrongApprovalID(expected: String, observed: String)
        case missingRequestHash
        case wrongRequestHash
        case missingAuthority
        case wrongResponder(expected: String, observed: String)
        case noPinnedKey(peerNodeID: String)
        case wrongKeyKind
        case staleTimestamp
        case responseTimestampMismatch
        case counterReplay(lastSeen: UInt64, attempted: UInt64)
        case replayStoreUnavailable
        case replayCounterPersistenceFailed
        case wrongIntentHash
        case signatureInvalid
    }

    public typealias PinnedKeyResolver = @Sendable (_ peerNodeID: String) -> PhoneControlVerifyingKey?

    public static let freshnessSeconds: TimeInterval = 30

    private let resolvePinnedKey: PinnedKeyResolver
    private let signer: ComputerUsePhoneControlSigner
    private let logger: BurnBarDaemonLogger
    private let replayCounterStore: DaemonComputerUseApprovalReplayCounterStore
    private var replayStoreHealthy: Bool
    private var lastSeenCounterByPeer: [String: UInt64]

    public init(
        resolvePinnedKey: @escaping PinnedKeyResolver,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        replayCounterStore: DaemonComputerUseApprovalReplayCounterStore = DaemonComputerUseApprovalReplayCounterStore(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-approval-authority")
    ) {
        self.resolvePinnedKey = resolvePinnedKey
        self.signer = signer
        self.replayCounterStore = replayCounterStore
        self.logger = logger
        switch replayCounterStore.loadOutcome() {
        case .absent:
            self.lastSeenCounterByPeer = [:]
            self.replayStoreHealthy = true
        case .loaded(let counters):
            self.lastSeenCounterByPeer = counters
            self.replayStoreHealthy = true
        case .unreadable:
            self.lastSeenCounterByPeer = [:]
            self.replayStoreHealthy = false
        }
    }

    public func verify(
        response: HermesRealtimeRelayApprovalResponse,
        pendingRequest: HermesRealtimeRelayApprovalRequest,
        sessionID: String?,
        now: Date = Date()
    ) throws {
        guard replayStoreHealthy else {
            throw reject(.replayStoreUnavailable, response: response)
        }
        guard let sessionID, sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw reject(.missingSessionID, response: response)
        }
        guard pendingRequest.sessionId == sessionID else {
            throw reject(
                .wrongSession(expected: pendingRequest.sessionId, observed: sessionID),
                response: response
            )
        }
        guard response.approvalId == pendingRequest.approvalId else {
            throw reject(
                .wrongApprovalID(expected: pendingRequest.approvalId, observed: response.approvalId),
                response: response
            )
        }

        guard let requestHash = response.requestHashBlake3 else {
            throw reject(.missingRequestHash, response: response)
        }
        let expectedRequestHash = try signer.canonicalApprovalRequestHashHex(request: pendingRequest)
        guard requestHash.lowercased() == expectedRequestHash.lowercased() else {
            throw reject(.wrongRequestHash, response: response)
        }
        guard let authority = response.authority else {
            throw reject(.missingAuthority, response: response)
        }
        guard authority.peerNodeId == response.respondedBy,
              response.respondedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw reject(
                .wrongResponder(expected: authority.peerNodeId, observed: response.respondedBy),
                response: response
            )
        }
        guard let pinnedKey = resolvePinnedKey(authority.peerNodeId) else {
            throw reject(.noPinnedKey(peerNodeID: authority.peerNodeId), response: response)
        }
        guard authority.keyKind ?? .ed25519 == pinnedKey.kind else {
            throw reject(.wrongKeyKind, response: response)
        }
        guard abs(now.timeIntervalSince(authority.timestamp)) <= Self.freshnessSeconds else {
            throw reject(.staleTimestamp, response: response)
        }
        guard abs(now.timeIntervalSince(response.respondedAt)) <= Self.freshnessSeconds,
              abs(response.respondedAt.timeIntervalSince(authority.timestamp)) <= Self.freshnessSeconds else {
            throw reject(.responseTimestampMismatch, response: response)
        }
        let lastSeenCounter = lastSeenCounterByPeer[authority.peerNodeId] ?? 0
        guard authority.counter > lastSeenCounter else {
            throw reject(
                .counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter),
                response: response
            )
        }
        let expectedIntentHash = try signer.canonicalApprovalResponseHashHex(response: response)
        guard authority.intentHashBlake3.lowercased() == expectedIntentHash.lowercased() else {
            throw reject(.wrongIntentHash, response: response)
        }
        guard signer.isValidAuthoritySignature(
            intentHashHex: authority.intentHashBlake3,
            counter: authority.counter,
            timestamp: authority.timestamp,
            signatureBase64: authority.signatureEd25519,
            key: pinnedKey
        ) else {
            throw reject(.signatureInvalid, response: response)
        }

        do {
            switch try replayCounterStore.commit(
                peerNodeID: authority.peerNodeId,
                counter: authority.counter
            ) {
            case .committed(let highWater):
                lastSeenCounterByPeer[authority.peerNodeId] = highWater
            case .replay(let persistedLastSeen):
                lastSeenCounterByPeer[authority.peerNodeId] = persistedLastSeen
                throw reject(
                    .counterReplay(lastSeen: persistedLastSeen, attempted: authority.counter),
                    response: response
                )
            }
        } catch let failure as VerificationFailure {
            throw failure
        } catch {
            replayStoreHealthy = false
            throw reject(.replayCounterPersistenceFailed, response: response)
        }
    }

    private func reject(
        _ failure: VerificationFailure,
        response: HermesRealtimeRelayApprovalResponse
    ) -> VerificationFailure {
        logger.warning(
            "computer_use_approval_authority_rejected",
            metadata: [
                "approval_id": response.approvalId,
                "reason": Self.auditToken(for: failure)
            ]
        )
        return failure
    }

    static func auditToken(for failure: VerificationFailure) -> String {
        switch failure {
        case .missingSessionID: return "missing_session_id"
        case .wrongSession: return "wrong_session"
        case .wrongApprovalID: return "wrong_approval_id"
        case .missingRequestHash: return "missing_request_hash"
        case .wrongRequestHash: return "wrong_request_hash"
        case .missingAuthority: return "missing_authority"
        case .wrongResponder: return "wrong_responder"
        case .noPinnedKey: return "no_pinned_key"
        case .wrongKeyKind: return "wrong_key_kind"
        case .staleTimestamp: return "stale_timestamp"
        case .responseTimestampMismatch: return "response_timestamp_mismatch"
        case .counterReplay: return "counter_replay"
        case .replayStoreUnavailable: return "replay_store_unavailable"
        case .replayCounterPersistenceFailed: return "replay_counter_persistence_failed"
        case .wrongIntentHash: return "wrong_intent_hash"
        case .signatureInvalid: return "signature_invalid"
        }
    }
}
