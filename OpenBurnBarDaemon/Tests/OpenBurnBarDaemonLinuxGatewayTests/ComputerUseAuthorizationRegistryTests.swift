import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseAuthorizationRegistryTests: XCTestCase {
    func testBindingRequiresReservationAndUnknownDevelopmentSessionIsDenied() async {
        let registry = ComputerUseAuthorizationRegistry(enforcementEnabled: false)
        let runID = BurnBarRunID(rawValue: "run-reservation")
        let sessionID = ComputerUseSessionID("session-reservation")
        let owner = BurnBarClientID(rawValue: "owner")

        let boundWithoutReservation = await registry.bind(
            sessionID: sessionID,
            runID: runID,
            clientID: owner
        )
        let unknownSessionAllowed = await registry.contains(sessionID: sessionID)
        XCTAssertFalse(boundWithoutReservation)
        XCTAssertFalse(unknownSessionAllowed)
    }

    func testReservationAndBindingAreUniqueAndCompareAndRemove() async {
        let registry = ComputerUseAuthorizationRegistry(enforcementEnabled: false)
        let runID = BurnBarRunID(rawValue: "run-1")
        let sessionID = ComputerUseSessionID("session-1")
        let owner = BurnBarClientID(rawValue: "owner")

        let firstReservation = await registry.reserve(runID: runID)
        let duplicateReservation = await registry.reserve(runID: runID)
        let didBind = await registry.bind(
            sessionID: sessionID,
            runID: runID,
            clientID: owner,
            generation: 7
        )
        let boundSessionID = await registry.sessionID(for: runID)
        let binding = await registry.binding(runID: runID)
        XCTAssertTrue(firstReservation)
        XCTAssertFalse(duplicateReservation)
        XCTAssertTrue(didBind)
        XCTAssertEqual(boundSessionID, sessionID)
        XCTAssertEqual(binding?.generation, 7)

        await registry.revoke(sessionID: ComputerUseSessionID("other-session"))
        let bindingAfterUnrelatedRevoke = await registry.sessionID(for: runID)
        XCTAssertEqual(bindingAfterUnrelatedRevoke, sessionID)
        await registry.revoke(sessionID: sessionID)
        let bindingAfterRevoke = await registry.sessionID(for: runID)
        XCTAssertNil(bindingAfterRevoke)
    }

    func testEnforcedLeaseRejectsExpiryRunAndClientMismatch() async {
        let registry = ComputerUseAuthorizationRegistry(enforcementEnabled: true)
        let runID = BurnBarRunID(rawValue: "run-lease")
        let sessionID = ComputerUseSessionID("session-lease")
        let owner = BurnBarClientID(rawValue: "owner")
        let now = Date(timeIntervalSinceReferenceDate: 100)
        _ = await registry.reserve(runID: runID)
        let didBind = await registry.bind(sessionID: sessionID, runID: runID, clientID: owner)
        XCTAssertTrue(didBind)
        await registry.authorize(
            sessionID: sessionID,
            runID: runID,
            clientID: owner,
            requestedTimeoutSeconds: 10,
            maximumLifetime: 30,
            now: now
        )

        let permittedBeforeExpiry = await registry.permits(
            sessionID: sessionID,
            invocation: invocation(runID: runID, clientID: owner),
            now: now.addingTimeInterval(9)
        )
        let wrongRunPermitted = await registry.permits(
            sessionID: sessionID,
            invocation: invocation(runID: BurnBarRunID(rawValue: "other"), clientID: owner),
            now: now.addingTimeInterval(9)
        )
        let wrongClientPermitted = await registry.permits(
            sessionID: sessionID,
            invocation: invocation(runID: runID, clientID: BurnBarClientID(rawValue: "other")),
            now: now.addingTimeInterval(9)
        )
        let permittedAtExpiry = await registry.permits(
            sessionID: sessionID,
            invocation: invocation(runID: runID, clientID: owner),
            now: now.addingTimeInterval(10)
        )
        let bindingAfterExpiry = await registry.sessionID(for: runID)
        XCTAssertTrue(permittedBeforeExpiry)
        XCTAssertFalse(wrongRunPermitted)
        XCTAssertFalse(wrongClientPermitted)
        XCTAssertFalse(permittedAtExpiry)
        XCTAssertNil(bindingAfterExpiry)
    }

    func testDisabledEnforcementStillRequiresExactBindingIdentity() async {
        let registry = ComputerUseAuthorizationRegistry(enforcementEnabled: false)
        let runID = BurnBarRunID(rawValue: "run-dev")
        let sessionID = ComputerUseSessionID("session-dev")
        let owner = BurnBarClientID(rawValue: "owner")
        _ = await registry.reserve(runID: runID)
        _ = await registry.bind(sessionID: sessionID, runID: runID, clientID: owner)

        let correctIdentityPermitted = await registry.permits(
            sessionID: sessionID,
            invocation: invocation(runID: runID, clientID: owner)
        )
        let wrongIdentityPermitted = await registry.permits(
            sessionID: sessionID,
            invocation: invocation(runID: runID, clientID: BurnBarClientID(rawValue: "other"))
        )
        XCTAssertTrue(correctIdentityPermitted)
        XCTAssertFalse(wrongIdentityPermitted)
    }

    func testVerifiedSessionLeaseSupportsNonRunComputerUseSession() async {
        let registry = ComputerUseAuthorizationRegistry(enforcementEnabled: true)
        let sessionID = ComputerUseSessionID("system-session")
        let now = Date(timeIntervalSinceReferenceDate: 500)

        await registry.authorizeVerifiedSession(
            sessionID: sessionID,
            requestedTimeoutSeconds: 10,
            maximumLifetime: 30,
            now: now
        )

        let active = await registry.contains(sessionID: sessionID, now: now.addingTimeInterval(9))
        let expired = await registry.contains(sessionID: sessionID, now: now.addingTimeInterval(10))
        XCTAssertTrue(active)
        XCTAssertFalse(expired)
    }

    func testConsumedProofLedgerRejectsReplayAcrossReconstruction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-proof-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("consumed.json")
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let first = DaemonConsumedLocalAuthProofLedger(fileURL: fileURL, now: now)
        XCTAssertTrue(first.consume(
            proofId: "proof-restart",
            expiresAt: now.addingTimeInterval(120),
            now: now
        ))

        let reconstructed = DaemonConsumedLocalAuthProofLedger(fileURL: fileURL, now: now)
        XCTAssertFalse(reconstructed.consume(
            proofId: "proof-restart",
            expiresAt: now.addingTimeInterval(120),
            now: now
        ))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testComputerUseSessionIntentCanonicalHashMatchesRustGolden() throws {
        let request = ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            scopeRuleIds: ["https://example.com/*"],
            phoneViewerNodeId: "android-device-1",
            actionCap: 50,
            sessionTimeoutSeconds: 1_800,
            clientID: BurnBarClientID(rawValue: "linux-shell"),
            runID: BurnBarRunID(rawValue: "run-1"),
            runCallID: "call-1",
            runGeneration: 7
        )
        let hash = try ComputerUsePhoneControlSigner()
            .canonicalComputerUseSessionIntentID(request: request)
        XCTAssertEqual(hash, "76a01cfd3b2795d2dc664612b76758b5c5c46943f9e2927a5449190764dd0c1e")
    }

    private func invocation(runID: BurnBarRunID, clientID: BurnBarClientID) -> BurnBarToolInvocation {
        BurnBarToolInvocation(
            callID: "call",
            runID: runID,
            tool: .browserScreenshot,
            arguments: .object([:]),
            requestedBy: clientID,
            requestedAt: Date()
        )
    }
}
