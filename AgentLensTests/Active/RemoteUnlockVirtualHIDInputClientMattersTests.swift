#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

/// Locks down the trust-classification behavior of `RemoteUnlockVirtualHIDInputClient.dispatch`.
///
/// The privileged-input dispatcher prefers the XPC/socket lane (which authenticates the
/// helper's UID + code signature *before* the envelope — possibly carrying the macOS login
/// credential — is sent) and only falls back to the legacy Unix socket when the preferred
/// lane is genuinely *unavailable*.
///
/// The site that previously read `if (try? Self.xpcClient.perform(envelope)) != nil`
/// swallowed EVERY error and fell through to the legacy lane. That converted two
/// security outcomes into fail-open behavior:
///
///   * `ClientError.rejected` — the authenticated helper deliberately refused the action.
///   * `ClientError.serverUntrusted` — the socket peer failed UID / code-signature
///     validation (something is impersonating the helper).
///
/// Retrying the *same* action on a weaker lane after either outcome is a fail-open. These
/// tests prove those outcomes now fail CLOSED (rethrow, never reach the socket), while
/// genuine transport faults still degrade gracefully to the legacy lane.
final class RemoteUnlockVirtualHIDInputClientMattersTests: XCTestCase {

    private func sampleAction() -> MacInputAction {
        MacInputAction(kind: .type, text: "secret-login-password")
    }

    // MARK: - Fail closed: helper rejected the action

    func testRejectedOutcomeFailsClosedAndNeverFallsBackToSocket() async {
        let performed = LockedFlag()
        let client = RemoteUnlockVirtualHIDInputClient(performEnvelope: { _ in
            performed.set()
            throw PrivilegedInputXPCClient.ClientError.rejected("capability_token_invalid")
        })

        do {
            _ = try await client.dispatch(sampleAction())
            XCTFail("Expected dispatch to rethrow the helper rejection (fail closed)")
        } catch let error as PrivilegedInputXPCClient.ClientError {
            guard case .rejected(let detail) = error else {
                XCTFail("Expected .rejected, got \(error)"); return
            }
            XCTAssertEqual(detail, "capability_token_invalid")
        } catch {
            XCTFail("Expected ClientError.rejected, got \(error)")
        }
        XCTAssertTrue(performed.value, "The preferred lane should have been attempted")
    }

    // MARK: - Fail closed: socket peer failed trust validation (impersonation)

    func testServerUntrustedOutcomeFailsClosedAndNeverFallsBackToSocket() async {
        let performed = LockedFlag()
        let client = RemoteUnlockVirtualHIDInputClient(performEnvelope: { _ in
            performed.set()
            throw PrivilegedInputXPCClient.ClientError.serverUntrusted("uid_mismatch")
        })

        do {
            _ = try await client.dispatch(sampleAction())
            XCTFail("Expected dispatch to rethrow the server-untrusted failure (fail closed)")
        } catch let error as PrivilegedInputXPCClient.ClientError {
            guard case .serverUntrusted(let detail) = error else {
                XCTFail("Expected .serverUntrusted, got \(error)"); return
            }
            XCTAssertEqual(detail, "uid_mismatch")
        } catch {
            XCTFail("Expected ClientError.serverUntrusted, got \(error)")
        }
        XCTAssertTrue(performed.value, "The preferred lane should have been attempted")
    }

    // MARK: - Happy path: preferred lane succeeds, no socket fallback

    func testSuccessfulPreferredLaneReturnsPayloadWithoutSocketFallback() async throws {
        let client = RemoteUnlockVirtualHIDInputClient(performEnvelope: { _ in
            // Succeeds: no throw.
        })

        let payload = try await client.dispatch(sampleAction())
        guard case .object(let fields) = payload else {
            XCTFail("Expected an object payload, got \(payload)"); return
        }
        XCTAssertEqual(fields["ok"], .bool(true))
        XCTAssertEqual(fields["kind"], .string(MacInputAction.Kind.type.rawValue))
        XCTAssertEqual(fields["backend"], .string("openburnbar_virtual_hid"))
    }

    // MARK: - Recoverable transport fault degrades to the legacy lane

    func testTransportUnavailableDoesNotRethrowTrustErrorAndAttemptsSocketLane() async {
        let performed = LockedFlag()
        let client = RemoteUnlockVirtualHIDInputClient(performEnvelope: { _ in
            performed.set()
            throw PrivilegedInputXPCClient.ClientError.connectionUnavailable
        })

        do {
            _ = try await client.dispatch(sampleAction())
            // In CI there is no live virtual-HID bridge socket, so the legacy lane
            // is expected to throw. If it somehow succeeded that is also acceptable —
            // what matters is that we did NOT rethrow the recoverable ClientError.
        } catch let error as PrivilegedInputXPCClient.ClientError {
            XCTFail("Recoverable transport fault must not be rethrown; got \(error)")
        } catch {
            // The fall-through reached the legacy socket lane and failed there
            // (e.g. RemoteUnlockVirtualHIDInputClient.Error.socketUnavailable /
            // .daemonUnavailable). That proves we did NOT short-circuit on the
            // ClientError — exactly the recoverable-degradation contract.
            XCTAssertFalse(
                error is PrivilegedInputXPCClient.ClientError,
                "Fallback path should surface a socket-lane error, not the preferred-lane ClientError"
            )
        }
        XCTAssertTrue(performed.value, "The preferred lane should have been attempted first")
    }

    // MARK: - Non-ClientError transport faults also degrade (never short-circuit)

    func testRawTransportErrorDegradesToSocketLane() async {
        let performed = LockedFlag()
        struct RawXPCError: Error {}
        let client = RemoteUnlockVirtualHIDInputClient(performEnvelope: { _ in
            performed.set()
            throw RawXPCError()
        })

        do {
            _ = try await client.dispatch(sampleAction())
        } catch is RawXPCError {
            XCTFail("Raw transport error must not be rethrown; it should degrade to the socket lane")
        } catch {
            // Reached and failed on the legacy socket lane — acceptable.
        }
        XCTAssertTrue(performed.value, "The preferred lane should have been attempted first")
    }
}

/// Minimal thread-safe boolean flag for asserting a `@Sendable` closure ran across the
/// detached task boundary inside `dispatch`.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
#endif
