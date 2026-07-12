import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

public actor DaemonComputerUsePanicAuthorityVerifier {
    public enum VerificationFailure: Error, Equatable, Sendable {
        case malformed
        case wrongAuthority
        case noPinnedKey
        case wrongKeyKind
        case staleTimestamp
        case wrongIntentHash
        case signatureInvalid
        case counterReplay
        case replayStoreUnavailable
        case replayCounterPersistenceFailed
    }

    public typealias PinnedKeyResolver = @Sendable (String) -> PhoneControlVerifyingKey?
    public static let freshnessSeconds: TimeInterval = 30

    private let resolvePinnedKey: PinnedKeyResolver
    private let signer: ComputerUsePhoneControlSigner
    private let replayCounterStore: DaemonComputerUseApprovalReplayCounterStore
    private var replayStoreHealthy: Bool
    private var lastSeenCounterByPeer: [String: UInt64]

    public init(
        resolvePinnedKey: @escaping PinnedKeyResolver,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        replayCounterStore: DaemonComputerUseApprovalReplayCounterStore = .production()
    ) {
        self.resolvePinnedKey = resolvePinnedKey
        self.signer = signer
        self.replayCounterStore = replayCounterStore
        switch replayCounterStore.loadOutcome() {
        case .absent:
            replayStoreHealthy = true
            lastSeenCounterByPeer = [:]
        case .loaded(let counters):
            replayStoreHealthy = true
            lastSeenCounterByPeer = counters
        case .unreadable:
            replayStoreHealthy = false
            lastSeenCounterByPeer = [:]
        }
    }

    public func verify(
        intent: HermesRealtimeRelayInputIntent,
        expectedAuthorityPeerNodeID: String,
        now: Date = Date()
    ) throws {
        guard replayStoreHealthy else { throw VerificationFailure.replayStoreUnavailable }
        guard intent.kind == .panic else { throw VerificationFailure.malformed }
        let authority = intent.authority
        guard authority.peerNodeId == expectedAuthorityPeerNodeID,
              authority.counter > 0,
              authority.intentHashBlake3.isEmpty == false,
              authority.signatureEd25519.isEmpty == false else {
            throw VerificationFailure.wrongAuthority
        }
        guard let key = resolvePinnedKey(authority.peerNodeId) else {
            throw VerificationFailure.noPinnedKey
        }
        guard authority.keyKind ?? .ed25519 == key.kind else {
            throw VerificationFailure.wrongKeyKind
        }
        guard abs(now.timeIntervalSince(authority.timestamp)) <= Self.freshnessSeconds else {
            throw VerificationFailure.staleTimestamp
        }
        let expectedHash = try signer.canonicalInputIntentHashHex(intent: intent)
        guard expectedHash.lowercased() == authority.intentHashBlake3.lowercased() else {
            throw VerificationFailure.wrongIntentHash
        }
        guard signer.isValidAuthoritySignature(
            intentHashHex: authority.intentHashBlake3,
            counter: authority.counter,
            timestamp: authority.timestamp,
            signatureBase64: authority.signatureEd25519,
            key: key
        ) else {
            throw VerificationFailure.signatureInvalid
        }
        let lastSeen = lastSeenCounterByPeer[authority.peerNodeId] ?? 0
        guard authority.counter > lastSeen else { throw VerificationFailure.counterReplay }
        do {
            switch try replayCounterStore.commit(peerNodeID: authority.peerNodeId, counter: authority.counter) {
            case .committed(let highWater):
                lastSeenCounterByPeer[authority.peerNodeId] = highWater
            case .replay(let highWater):
                lastSeenCounterByPeer[authority.peerNodeId] = highWater
                throw VerificationFailure.counterReplay
            }
        } catch let failure as VerificationFailure {
            throw failure
        } catch {
            replayStoreHealthy = false
            throw VerificationFailure.replayCounterPersistenceFailed
        }
    }

    public func isOperational() -> Bool {
        replayStoreHealthy
    }
}
