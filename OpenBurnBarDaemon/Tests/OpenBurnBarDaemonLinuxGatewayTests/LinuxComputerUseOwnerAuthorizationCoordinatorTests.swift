#if os(Linux)
import Glibc
import XCTest
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon

final class LinuxComputerUseOwnerAuthorizationCoordinatorTests: XCTestCase {
    func testRejectsInvalidOperationIdentifiersBeforeReadingPeer() async {
        let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator(
            authenticator: { _, _ in
                XCTFail("Invalid operation must not authenticate")
                throw LinuxComputerUseOwnerAuthorizationError.invalidOperation
            },
            peerIdentityProvider: { _ in
                XCTFail("Invalid operation must not read peer identity")
                throw LinuxComputerUseOwnerAuthorizationError.invalidPeer
            }
        )

        for (operationID, reason) in [
            ("", "Authorize Browser Computer Use"),
            ("contains spaces", "Authorize Browser Computer Use"),
            (String(repeating: "a", count: 129), "Authorize Browser Computer Use"),
            ("run-1", "\n\t")
        ] {
            do {
                _ = try await coordinator.authorize(
                    peerProcessID: 42,
                    operationID: operationID,
                    reason: reason
                )
                XCTFail("Expected invalid operation rejection")
            } catch {
                XCTAssertEqual(error as? LinuxComputerUseOwnerAuthorizationError, .invalidOperation)
            }
        }
    }

    func testReadsCurrentProcessIdentityAndRejectsInvalidProcess() throws {
        let processID = getpid()
        let identity = try LinuxComputerUseOwnerAuthorizationCoordinator.readPeerIdentity(
            processID: processID
        )

        XCTAssertEqual(identity.processID, processID)
        XCTAssertEqual(identity.userID, UInt32(geteuid()))
        XCTAssertGreaterThan(identity.processStartTime, 0)
        XCTAssertFalse(identity.executablePath.isEmpty)
        XCTAssertGreaterThan(identity.executableInode, 0)

        XCTAssertThrowsError(
            try LinuxComputerUseOwnerAuthorizationCoordinator.readPeerIdentity(processID: 1)
        ) { error in
            XCTAssertEqual(error as? LinuxComputerUseOwnerAuthorizationError, .invalidPeer)
        }
    }

    func testAuthorizesExactStableAppPeerWithFreshPolkitProof() async throws {
        let peer = makePeer()
        let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator(
            authenticator: { processID, reason in
                XCTAssertEqual(processID, peer.processID)
                return LinuxDesktopOwnerAuthenticationProof(
                    localAuthenticationSatisfied: true,
                    authority: "polkit",
                    actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                    authenticatedAtMillis: 1_000,
                    reason: reason
                )
            },
            peerIdentityProvider: { _ in peer },
            nowMillis: { 1_000 }
        )

        let proof = try await coordinator.authorize(
            peerProcessID: peer.processID,
            operationID: "run-1:call-2:3",
            reason: "Authorize Browser Computer Use"
        )

        XCTAssertTrue(proof.localAuthenticationSatisfied)
        XCTAssertEqual(proof.authority, "polkit")
    }

    func testRejectsUnsupportedExecutableBeforePrompt() async {
        let peer = makePeer(executablePath: "/tmp/OpenBurnBarCLI")
        let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator(
            authenticator: { _, reason in
                XCTFail("Unsupported peer must not reach polkit")
                return LinuxDesktopOwnerAuthenticationProof(
                    localAuthenticationSatisfied: true,
                    authority: "polkit",
                    actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                    authenticatedAtMillis: 1_000,
                    reason: reason
                )
            },
            peerIdentityProvider: { _ in peer },
            nowMillis: { 1_000 }
        )

        do {
            _ = try await coordinator.authorize(
                peerProcessID: peer.processID,
                operationID: "run-1",
                reason: "Authorize Browser Computer Use"
            )
            XCTFail("Expected unsupported executable rejection")
        } catch {
            XCTAssertEqual(
                error as? LinuxComputerUseOwnerAuthorizationError,
                .unsupportedPeerExecutable
            )
        }
    }

    func testRejectsPeerIdentityChangeAcrossPrompt() async {
        let initial = makePeer(executableInode: 7)
        let changed = makePeer(executableInode: 8)
        let identities = SynchronousIdentitySequence([initial, changed])
        let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator(
            authenticator: { _, reason in
                LinuxDesktopOwnerAuthenticationProof(
                    localAuthenticationSatisfied: true,
                    authority: "polkit",
                    actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                    authenticatedAtMillis: 1_000,
                    reason: reason
                )
            },
            peerIdentityProvider: { _ in identities.next() },
            nowMillis: { 1_000 }
        )

        do {
            _ = try await coordinator.authorize(
                peerProcessID: initial.processID,
                operationID: "run-1",
                reason: "Authorize Browser Computer Use"
            )
            XCTFail("Expected peer replacement rejection")
        } catch {
            XCTAssertEqual(
                error as? LinuxComputerUseOwnerAuthorizationError,
                .peerChangedDuringAuthorization
            )
        }
    }

    func testRejectsNonPolkitOrMismatchedProof() async {
        let peer = makePeer()
        let expectedReason = "Authorize Browser Computer Use"
        let invalidProofs = [
            LinuxDesktopOwnerAuthenticationProof(
                localAuthenticationSatisfied: true,
                authority: "pam",
                actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                authenticatedAtMillis: 1_000,
                reason: expectedReason
            ),
            LinuxDesktopOwnerAuthenticationProof(
                localAuthenticationSatisfied: true,
                authority: "polkit",
                actionID: "com.openburnbar.wrong-action",
                authenticatedAtMillis: 1_000,
                reason: expectedReason
            ),
            LinuxDesktopOwnerAuthenticationProof(
                localAuthenticationSatisfied: true,
                authority: "polkit",
                actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                authenticatedAtMillis: 1_000,
                reason: "Authorize a different operation"
            ),
            LinuxDesktopOwnerAuthenticationProof(
                localAuthenticationSatisfied: false,
                authority: "polkit",
                actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                authenticatedAtMillis: 1_000,
                reason: expectedReason
            ),
            LinuxDesktopOwnerAuthenticationProof(
                localAuthenticationSatisfied: true,
                authority: "polkit",
                actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                authenticatedAtMillis: 999,
                reason: expectedReason
            ),
            LinuxDesktopOwnerAuthenticationProof(
                localAuthenticationSatisfied: true,
                authority: "polkit",
                actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
                authenticatedAtMillis: 6_001,
                reason: expectedReason
            )
        ]

        for (index, proof) in invalidProofs.enumerated() {
            let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator(
                authenticator: { _, _ in proof },
                peerIdentityProvider: { _ in peer },
                nowMillis: { 1_000 }
            )
            do {
                _ = try await coordinator.authorize(
                    peerProcessID: peer.processID,
                    operationID: "run-1",
                    reason: expectedReason
                )
                XCTFail("Expected invalid proof rejection for case \(index)")
            } catch {
                XCTAssertEqual(
                    error as? LinuxComputerUseOwnerAuthorizationError,
                    .invalidAuthorizationProof,
                    "case \(index)"
                )
            }
        }
    }

    func testSingleFlightRejectsConcurrentPromptForSamePeer() async throws {
        let peer = makePeer()
        let gate = SuspendedOwnerAuthenticator()
        let coordinator = LinuxComputerUseOwnerAuthorizationCoordinator(
            authenticator: { _, reason in try await gate.authenticate(reason: reason) },
            peerIdentityProvider: { _ in peer },
            nowMillis: { 1_000 }
        )
        let first = Task {
            try await coordinator.authorize(
                peerProcessID: peer.processID,
                operationID: "run-1",
                reason: "Authorize Browser Computer Use"
            )
        }
        await gate.waitUntilStarted()

        do {
            _ = try await coordinator.authorize(
                peerProcessID: peer.processID,
                operationID: "run-2",
                reason: "Authorize another session"
            )
            XCTFail("Expected single-flight rejection")
        } catch {
            XCTAssertEqual(
                error as? LinuxComputerUseOwnerAuthorizationError,
                .authorizationAlreadyInProgress
            )
        }

        await gate.resume()
        _ = try await first.value
    }

    func testPromptReasonIsPrintableCollapsedAndBounded() {
        let raw = "  Authorize\nBrowser\tComputer Use \u{1F680} "
            + String(repeating: "x", count: 300)
        let sanitized = LinuxComputerUseOwnerAuthorizationCoordinator.sanitizedReason(raw)

        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertFalse(sanitized.contains("\t"))
        XCTAssertLessThanOrEqual(
            sanitized.count,
            LinuxComputerUseOwnerAuthorizationCoordinator.maximumReasonLength
        )
        XCTAssertTrue(sanitized.hasPrefix("Authorize Browser Computer Use"))
    }

    private func makePeer(
        executablePath: String = "/opt/openburnbar/openburnbar-linux-desktop",
        executableInode: UInt64 = 7
    ) -> LinuxComputerUseOwnerPeerIdentity {
        LinuxComputerUseOwnerPeerIdentity(
            processID: 4242,
            userID: UInt32(geteuid()),
            processStartTime: 99,
            executablePath: executablePath,
            executableDevice: 5,
            executableInode: executableInode
        )
    }
}

private final class SynchronousIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [LinuxComputerUseOwnerPeerIdentity]

    init(_ identities: [LinuxComputerUseOwnerPeerIdentity]) {
        self.identities = identities
    }

    func next() -> LinuxComputerUseOwnerPeerIdentity {
        lock.lock()
        defer { lock.unlock() }
        if identities.count > 1 {
            return identities.removeFirst()
        }
        return identities[0]
    }
}

private actor SuspendedOwnerAuthenticator {
    private var continuation: CheckedContinuation<Void, Never>?

    func authenticate(reason: String) async throws -> LinuxDesktopOwnerAuthenticationProof {
        await withCheckedContinuation { continuation = $0 }
        return LinuxDesktopOwnerAuthenticationProof(
            localAuthenticationSatisfied: true,
            authority: "polkit",
            actionID: LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
            authenticatedAtMillis: 1_000,
            reason: reason
        )
    }

    func waitUntilStarted() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
