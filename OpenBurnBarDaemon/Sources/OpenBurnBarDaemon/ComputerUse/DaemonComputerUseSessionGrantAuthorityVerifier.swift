import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine

/// Verifies a live phone-issued session grant before the broker accepts it.
/// Transport identity is checked by the broker; this verifier owns the
/// independent signing-authority, replay, and local-auth proof boundaries.
public actor DaemonComputerUseSessionGrantAuthorityVerifier {
    public enum VerificationFailure: Error, Equatable, Sendable {
        case malformedAuthority
        case noPinnedKey(peerNodeID: String)
        case wrongKeyKind
        case staleTimestamp
        case expiredGrant
        case localAuthenticationRequired
        case wrongIntentHash
        case signatureInvalid
        case localAuthProofRejected
        case counterReplay(lastSeen: UInt64, attempted: UInt64)
        case replayStoreUnavailable
        case replayCounterPersistenceFailed
    }

    public typealias PinnedKeyResolver = @Sendable (_ peerNodeID: String) -> PhoneControlVerifyingKey?

    public static let freshnessSeconds: TimeInterval = 30

    private let resolvePinnedKey: PinnedKeyResolver
    private let localAuthProofVerifier: DaemonLocalAuthProofVerifier
    private let signer: ComputerUsePhoneControlSigner
    private let replayCounterStore: DaemonComputerUseApprovalReplayCounterStore
    private let logger: BurnBarDaemonLogger
    private var replayStoreHealthy: Bool
    private var lastSeenCounterByPeer: [String: UInt64]

    public init(
        resolvePinnedKey: @escaping PinnedKeyResolver,
        localAuthProofVerifier: DaemonLocalAuthProofVerifier,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        replayCounterStore: DaemonComputerUseApprovalReplayCounterStore = .production(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "computer-use-session-grant-authority")
    ) {
        self.resolvePinnedKey = resolvePinnedKey
        self.localAuthProofVerifier = localAuthProofVerifier
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

    /// Validates the complete grant without consuming its local-auth proof.
    /// The proof is consumed only during the later session-start transaction.
    public func verify(
        _ request: HermesRealtimeRelayAgentGrantRequest,
        expectedAuthorityPeerNodeID: String,
        now: Date = Date()
    ) throws {
        guard replayStoreHealthy else { throw reject(.replayStoreUnavailable, request: request) }
        let authority = request.authority
        guard authority.peerNodeId.isEmpty == false,
              authority.peerNodeId == expectedAuthorityPeerNodeID,
              authority.counter > 0,
              authority.intentHashBlake3.isEmpty == false,
              authority.signatureEd25519.isEmpty == false else {
            throw reject(.malformedAuthority, request: request)
        }
        guard let pinnedKey = resolvePinnedKey(authority.peerNodeId) else {
            throw reject(.noPinnedKey(peerNodeID: authority.peerNodeId), request: request)
        }
        guard authority.keyKind ?? .ed25519 == pinnedKey.kind else {
            throw reject(.wrongKeyKind, request: request)
        }
        guard abs(now.timeIntervalSince(authority.timestamp)) <= Self.freshnessSeconds else {
            throw reject(.staleTimestamp, request: request)
        }
        guard request.expiresAt > now else {
            throw reject(.expiredGrant, request: request)
        }
        guard request.localAuthenticationSatisfied, let proof = request.localAuthProof else {
            throw reject(.localAuthenticationRequired, request: request)
        }

        let expectedIntentHash: String
        do {
            expectedIntentHash = try signer.canonicalAgentGrantRequestHashHex(request: request)
        } catch {
            throw reject(.wrongIntentHash, request: request)
        }
        guard authority.intentHashBlake3.lowercased() == expectedIntentHash.lowercased() else {
            throw reject(.wrongIntentHash, request: request)
        }
        guard signer.isValidAuthoritySignature(
            intentHashHex: authority.intentHashBlake3,
            counter: authority.counter,
            timestamp: authority.timestamp,
            signatureBase64: authority.signatureEd25519,
            key: pinnedKey
        ) else {
            throw reject(.signatureInvalid, request: request)
        }
        do {
            _ = try localAuthProofVerifier.validate(
                proof: proof,
                expectedDeviceId: request.sourceDeviceId,
                expectedIntentHashHex: expectedIntentHash,
                now: now
            )
        } catch {
            throw reject(.localAuthProofRejected, request: request)
        }

        let lastSeen = lastSeenCounterByPeer[authority.peerNodeId] ?? 0
        guard authority.counter > lastSeen else {
            throw reject(
                .counterReplay(lastSeen: lastSeen, attempted: authority.counter),
                request: request
            )
        }
        do {
            switch try replayCounterStore.commit(peerNodeID: authority.peerNodeId, counter: authority.counter) {
            case .committed(let highWater):
                lastSeenCounterByPeer[authority.peerNodeId] = highWater
            case .replay(let persistedLastSeen):
                lastSeenCounterByPeer[authority.peerNodeId] = persistedLastSeen
                throw reject(
                    .counterReplay(lastSeen: persistedLastSeen, attempted: authority.counter),
                    request: request
                )
            }
        } catch let failure as VerificationFailure {
            throw failure
        } catch {
            replayStoreHealthy = false
            throw reject(.replayCounterPersistenceFailed, request: request)
        }
    }

    public func isOperational() -> Bool {
        replayStoreHealthy
    }

    private func reject(
        _ failure: VerificationFailure,
        request: HermesRealtimeRelayAgentGrantRequest
    ) -> VerificationFailure {
        logger.warning(
            "computer_use_session_grant_authority_rejected",
            metadata: [
                "request_id": request.requestId,
                "reason": Self.auditToken(for: failure)
            ]
        )
        return failure
    }

    static func auditToken(for failure: VerificationFailure) -> String {
        switch failure {
        case .malformedAuthority: return "malformed_authority"
        case .noPinnedKey: return "no_pinned_key"
        case .wrongKeyKind: return "wrong_key_kind"
        case .staleTimestamp: return "stale_timestamp"
        case .expiredGrant: return "expired_grant"
        case .localAuthenticationRequired: return "local_authentication_required"
        case .wrongIntentHash: return "wrong_intent_hash"
        case .signatureInvalid: return "signature_invalid"
        case .localAuthProofRejected: return "local_auth_proof_rejected"
        case .counterReplay: return "counter_replay"
        case .replayStoreUnavailable: return "replay_store_unavailable"
        case .replayCounterPersistenceFailed: return "replay_counter_persistence_failed"
        }
    }
}
