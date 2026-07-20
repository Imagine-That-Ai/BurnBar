import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class DaemonComputerUsePanicAuthorityVerifierTests: XCTestCase {
    func testAcceptsFreshSignedPanicAndRejectsReplay() async throws {
        let fixture = try makeFixture(counter: 7)
        let replayURL = temporaryReplayURL()
        defer { try? FileManager.default.removeItem(at: replayURL) }
        let verifier = makeVerifier(fixture: fixture, replayURL: replayURL)

        try await verifier.verify(
            intent: fixture.intent,
            expectedAuthorityPeerNodeID: fixture.peerNodeID,
            now: fixture.now
        )
        do {
            try await verifier.verify(
                intent: fixture.intent,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("Expected replay rejection")
        } catch let failure as DaemonComputerUsePanicAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .counterReplay)
        }
    }

    func testRejectsNonPanicWrongAuthorityAndStaleTimestamp() async throws {
        let fixture = try makeFixture(counter: 1)
        let replayURL = temporaryReplayURL()
        defer { try? FileManager.default.removeItem(at: replayURL) }
        let verifier = makeVerifier(fixture: fixture, replayURL: replayURL)

        var nonPanic = fixture.intent
        nonPanic.kind = .tap
        do {
            try await verifier.verify(
                intent: nonPanic,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("Expected non-panic rejection")
        } catch let failure as DaemonComputerUsePanicAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .malformed)
        }

        do {
            try await verifier.verify(
                intent: fixture.intent,
                expectedAuthorityPeerNodeID: "different-authority",
                now: fixture.now
            )
            XCTFail("Expected authority rejection")
        } catch let failure as DaemonComputerUsePanicAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .wrongAuthority)
        }

        do {
            try await verifier.verify(
                intent: fixture.intent,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now.addingTimeInterval(31)
            )
            XCTFail("Expected stale timestamp rejection")
        } catch let failure as DaemonComputerUsePanicAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .staleTimestamp)
        }
    }

    func testCorruptReplayStoreFailsClosedAndReportsUnhealthy() async throws {
        let fixture = try makeFixture(counter: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-panic-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("counters.json")
        try Data("{".utf8).write(to: fileURL)
        let verifier = DaemonComputerUsePanicAuthorityVerifier(
            resolvePinnedKey: { _ in .ed25519(fixture.key.publicKey) },
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        )

        let operational = await verifier.isOperational()
        XCTAssertFalse(operational)
        do {
            try await verifier.verify(
                intent: fixture.intent,
                expectedAuthorityPeerNodeID: fixture.peerNodeID,
                now: fixture.now
            )
            XCTFail("Expected replay-store rejection")
        } catch let failure as DaemonComputerUsePanicAuthorityVerifier.VerificationFailure {
            XCTAssertEqual(failure, .replayStoreUnavailable)
        }
    }

    private struct Fixture {
        let key: PlatformEd25519SigningMaterial
        let peerNodeID: String
        let now: Date
        let intent: HermesRealtimeRelayInputIntent
    }

    private func makeFixture(counter: UInt64) throws -> Fixture {
        let signer = ComputerUsePhoneControlSigner()
        let key = PlatformCrypto.ed25519PrivateKey()
        let peerNodeID = "ios-authority"
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: now,
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        var intent = HermesRealtimeRelayInputIntent(
            kind: .panic,
            clientIntentId: "panic-1",
            authority: placeholder
        )
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: peerNodeID,
            counter: counter,
            timestamp: now,
            privateKey: key
        )
        intent.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            keyKind: .ed25519
        )
        return Fixture(key: key, peerNodeID: peerNodeID, now: now, intent: intent)
    }

    private func temporaryReplayURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-panic-replay-\(UUID().uuidString).json")
    }

    private func makeVerifier(
        fixture: Fixture,
        replayURL: URL
    ) -> DaemonComputerUsePanicAuthorityVerifier {
        return DaemonComputerUsePanicAuthorityVerifier(
            resolvePinnedKey: { peerNodeID in
                peerNodeID == fixture.peerNodeID ? .ed25519(fixture.key.publicKey) : nil
            },
            replayCounterStore: DaemonComputerUseApprovalReplayCounterStore(fileURL: replayURL)
        )
    }
}
