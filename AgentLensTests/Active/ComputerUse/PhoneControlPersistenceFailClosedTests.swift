#if canImport(AppKit)
import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// F6 + L9 + F2 persistence hardening:
///  * `PhoneControlReplayCounterStore.loadOutcome()` distinguishes a genuinely
///    absent baseline (safe first run) from an unreadable/corrupt one.
///  * `PhoneControlAuthorityValidator` fails CLOSED — refusing every intent —
///    when the persisted replay baseline exists but cannot be decoded.
///  * `PhoneControlConsumedProofStore` persists consumed single-use proof IDs
///    across restarts (and prunes expired entries) so "single-use" is not
///    merely per-process.
///  * F2 session-boundary hygiene: `deregisterAllPeers` drops admissions but
///    not pins/revocations/counters.
final class PhoneControlPersistenceFailClosedTests: XCTestCase {
    private let phoneSigner = ComputerUsePhoneControlSigner()
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func temporaryFileURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString).json")
        temporaryFiles.append(url)
        return url
    }

    // MARK: - PhoneControlReplayCounterStore.loadOutcome (F6)

    func test_loadOutcome_absentFileIsAbsentAndLoadIsEmpty() {
        let store = PhoneControlReplayCounterStore(fileURL: temporaryFileURL("replay-absent"))
        guard case .absent = store.loadOutcome() else {
            return XCTFail("A missing file is a legitimate first run and must read .absent")
        }
        XCTAssertEqual(store.load(), [:])
    }

    func test_loadOutcome_persistedCountersRoundTrip() throws {
        let url = temporaryFileURL("replay-roundtrip")
        try PhoneControlReplayCounterStore(fileURL: url).persist(["peer-a": 7, "peer-b": 3])

        let reloaded = PhoneControlReplayCounterStore(fileURL: url)
        guard case .loaded(let counters) = reloaded.loadOutcome() else {
            return XCTFail("A decodable snapshot must read .loaded")
        }
        XCTAssertEqual(counters, ["peer-a": 7, "peer-b": 3])
        XCTAssertEqual(reloaded.load(), ["peer-a": 7, "peer-b": 3])
    }

    func test_loadOutcome_corruptFileIsUnreadableAndLoadFailsSafeToEmpty() throws {
        let url = temporaryFileURL("replay-corrupt")
        try Data("{not json".utf8).write(to: url)

        let store = PhoneControlReplayCounterStore(fileURL: url)
        guard case .unreadable = store.loadOutcome() else {
            return XCTFail("An existing-but-undecodable snapshot must read .unreadable, never an empty baseline")
        }
        // The legacy `load()` shape stays empty-map for callers that only need
        // a baseline; the *validator* is responsible for failing closed.
        XCTAssertEqual(store.load(), [:])
    }

    func test_loadOutcome_truncatedSnapshotIsUnreadable() throws {
        let url = temporaryFileURL("replay-truncated")
        try PhoneControlReplayCounterStore(fileURL: url).persist(["peer-a": 9])
        let full = try Data(contentsOf: url)
        try full.prefix(full.count / 2).write(to: url)

        guard case .unreadable = PhoneControlReplayCounterStore(fileURL: url).loadOutcome() else {
            return XCTFail("A truncated snapshot must read .unreadable")
        }
    }

    // MARK: - Validator fails closed on an unreadable replay baseline (F6)

    private func signedTapIntent(
        peerNodeId: String,
        counter: UInt64,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> HermesRealtimeRelayInputIntent {
        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-\(counter)",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64
        return intent
    }

    func test_validatorRefusesEveryIntentWhenReplayBaselineIsUnreadable() throws {
        let url = temporaryFileURL("replay-validator-corrupt")
        try Data("\u{00}corrupt".utf8).write(to: url)

        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: url),
            consumedProofStore: PhoneControlConsumedProofStore(fileURL: temporaryFileURL("proofs-validator-corrupt"))
        )
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)

        // A perfectly signed, fresh, in-window intent must STILL be refused:
        // trusting a zeroed baseline would re-open the restart replay window.
        let intent = try signedTapIntent(peerNodeId: "peer-1", counter: 1, privateKey: privateKey)
        XCTAssertThrowsError(try validator.validate(envelope: intent.authority, intent: intent)) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.replayStoreUnavailable = error else {
                return XCTFail("Expected replayStoreUnavailable, got \(error)")
            }
        }
    }

    func test_validatorAcceptsIntentsOnLegitimateFirstRun() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: temporaryFileURL("replay-first-run")),
            consumedProofStore: PhoneControlConsumedProofStore(fileURL: temporaryFileURL("proofs-first-run"))
        )
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)

        let intent = try signedTapIntent(peerNodeId: "peer-1", counter: 1, privateKey: privateKey)
        XCTAssertNoThrow(try validator.validate(envelope: intent.authority, intent: intent))
    }

    func test_replayStoreUnavailableMapsToFailClosedDenialReasonsOnEveryLane() {
        let error = PhoneControlAuthorityValidator.ValidationError.replayStoreUnavailable
        XCTAssertEqual(error.relayControlDeniedReason, .signatureFailure)
        XCTAssertEqual(error.agentGrantDenialReason, .signatureFailure)
        XCTAssertEqual(error.auditDetailToken, "replay_store_unavailable")
    }

    // MARK: - F2 session-boundary deregistration

    func test_deregisterAllPeersDropsAdmissionsButKeepsReplayCounters() throws {
        let replayURL = temporaryFileURL("replay-deregister")
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: replayURL),
            consumedProofStore: PhoneControlConsumedProofStore(fileURL: temporaryFileURL("proofs-deregister"))
        )
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)

        let first = try signedTapIntent(peerNodeId: "peer-1", counter: 5, privateKey: privateKey)
        XCTAssertNoThrow(try validator.validate(envelope: first.authority, intent: first))

        validator.deregisterAllPeers()

        // The admission is gone — a valid signature no longer validates...
        let afterDrop = try signedTapIntent(peerNodeId: "peer-1", counter: 6, privateKey: privateKey)
        XCTAssertThrowsError(try validator.validate(envelope: afterDrop.authority, intent: afterDrop)) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingPeerPubKey = error else {
                return XCTFail("Expected missingPeerPubKey after deregisterAllPeers, got \(error)")
            }
        }

        // ...and after re-registration the persisted replay floor still holds:
        // an envelope at-or-below the last committed counter is a replay.
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let replayed = try signedTapIntent(peerNodeId: "peer-1", counter: 5, privateKey: privateKey)
        XCTAssertThrowsError(try validator.validate(envelope: replayed.authority, intent: replayed)) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.counterReplay = error else {
                return XCTFail("Expected counterReplay across deregistration, got \(error)")
            }
        }
        let fresh = try signedTapIntent(peerNodeId: "peer-1", counter: 6, privateKey: privateKey)
        XCTAssertNoThrow(try validator.validate(envelope: fresh.authority, intent: fresh))
    }

    // MARK: - PhoneControlConsumedProofStore (L9)

    func test_consumedProofStorePersistsActiveProofsAcrossInstances() {
        let url = temporaryFileURL("proofs-roundtrip")
        let now = Date()
        let store = PhoneControlConsumedProofStore(fileURL: url)
        store.record(proofId: "proof-active", expiresAt: now.addingTimeInterval(60), now: now)
        store.record(proofId: "proof-expired", expiresAt: now.addingTimeInterval(-1), now: now)

        // A fresh instance (simulated restart) sees the still-valid proof only.
        let restarted = PhoneControlConsumedProofStore(fileURL: url)
        XCTAssertEqual(restarted.loadActiveProofIds(now: now), ["proof-active"])
    }

    func test_consumedProofStorePrunesExpiredEntriesOnLoad() {
        let url = temporaryFileURL("proofs-prune")
        let now = Date()
        let store = PhoneControlConsumedProofStore(fileURL: url)
        store.record(proofId: "proof-1", expiresAt: now.addingTimeInterval(30), now: now)

        // After its expiry passes, the proof drops out (and is pruned on disk).
        let later = now.addingTimeInterval(60)
        XCTAssertEqual(store.loadActiveProofIds(now: later), [])
        XCTAssertEqual(PhoneControlConsumedProofStore(fileURL: url).loadActiveProofIds(now: later), [])
    }

    func test_consumedProofStoreDefaultLocationLivesInOpenBurnBarAppSupport() {
        // The default file sits inside the app's own Application Support dir —
        // the exact subtree the F9 restricted-shell sandbox denies reads on.
        let url = PhoneControlConsumedProofStore.defaultFileURL()
        XCTAssertTrue(url.path.contains("com.openburnbar.AgentLens"))
        XCTAssertEqual(url.lastPathComponent, "phone-control-consumed-proofs.json")
        // Constructing the default store performs no I/O — safe at startup.
        _ = PhoneControlConsumedProofStore.defaultStore()
    }

    func test_consumedProofStoreIgnoresEmptyProofIds() {
        let url = temporaryFileURL("proofs-empty-id")
        let now = Date()
        let store = PhoneControlConsumedProofStore(fileURL: url)
        store.record(proofId: "", expiresAt: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(store.loadActiveProofIds(now: now), [])
    }

    func test_consumedProofStoreSurvivesCorruptSnapshotByDegradingToEmpty() throws {
        let url = temporaryFileURL("proofs-corrupt")
        try Data("not json at all".utf8).write(to: url)
        let store = PhoneControlConsumedProofStore(fileURL: url)
        // Best-effort by design (the monotonic counter is the hard guarantee):
        // corruption degrades to the pre-L9 in-memory behavior instead of
        // blocking validation.
        XCTAssertEqual(store.loadActiveProofIds(), [])
        // And the store recovers: recording after corruption works.
        let now = Date()
        store.record(proofId: "proof-after-corruption", expiresAt: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(
            PhoneControlConsumedProofStore(fileURL: url).loadActiveProofIds(now: now),
            ["proof-after-corruption"]
        )
    }

    func test_validatorRestartRefusesReusedLocalAuthProofViaPersistedStore() throws {
        // L9 end-to-end: a single-use local-auth proof consumed by validator #1
        // is refused by validator #2 (fresh process, SAME proof file) even when
        // the replay-counter file is gone — the exact restart window L9 closes.
        let proofStoreURL = temporaryFileURL("proofs-validator-restart")
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()

        var request = HermesRealtimeRelayAgentGrantRequest(
            requestId: UUID().uuidString,
            runtime: "claude",
            threadId: "thread-restart",
            preset: "default",
            capabilities: [AgentDesktopCapability.shell.rawValue],
            trustMode: ComputerUseTrustMode.manual.rawValue,
            deliveryMode: "push",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60),
            grantDurationSeconds: 60,
            sourceDeviceId: "iphone-restart",
            clientIntentId: UUID().uuidString,
            localAuthenticationSatisfied: true,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: now,
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let grantHash = try phoneSigner.canonicalAgentGrantRequestHashHex(request: request)
        let proofPayload = phoneSigner.localAuthProofSignablePayload(
            proofId: "proof-restart-1",
            deviceId: "iphone-restart",
            signedIntentHash: grantHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(45)
        )
        request.localAuthProof = HermesRealtimeRelayAgentGrantLocalAuthProof(
            proofId: "proof-restart-1",
            deviceId: "iphone-restart",
            signedIntentHash: grantHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(45),
            signatureEd25519: try privateKey.signature(for: proofPayload).base64EncodedString()
        )
        let signed = try phoneSigner.sign(
            request: request,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            privateKey: privateKey
        )
        request.authority.intentHashBlake3 = signed.intentHashHex
        request.authority.signatureEd25519 = signed.signatureBase64

        let first = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: temporaryFileURL("replay-proof-restart-1")),
            consumedProofStore: PhoneControlConsumedProofStore(fileURL: proofStoreURL)
        )
        first.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        XCTAssertNoThrow(try first.validate(envelope: request.authority, grantRequest: request, now: now))

        // "Restart": new validator, fresh (empty) replay-counter baseline, same
        // persisted consumed-proof file. The proof must read as already used.
        let second = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: temporaryFileURL("replay-proof-restart-2")),
            consumedProofStore: PhoneControlConsumedProofStore(fileURL: proofStoreURL)
        )
        second.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        XCTAssertThrowsError(
            try second.validate(envelope: request.authority, grantRequest: request, now: now)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.localAuthProofReplay = error else {
                return XCTFail("Expected localAuthProofReplay across restart, got \(error)")
            }
        }
    }
}
#endif
