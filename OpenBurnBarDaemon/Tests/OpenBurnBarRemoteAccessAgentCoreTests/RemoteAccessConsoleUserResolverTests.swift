import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class RemoteAccessConsoleUserResolverTests: XCTestCase {
    /// The regression that broke Remote Unlock: while the screen is locked, `/dev/console` flips to
    /// root (uid 0) but SystemConfiguration still reports the logged-in user. We must trust the
    /// console user and keep serving uid 501.
    func testLockedScreenResolvesLoggedInUserEvenWhenConsoleDeviceIsRoot() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: "albertonunez", uid: 501, gid: 20),
            consoleDeviceOwner: (uid: 0, gid: 0)
        )
        XCTAssertEqual(resolved, RemoteAccessConsoleUser(uid: 501, gid: 20))
    }

    /// At the login window (logged out / fast-user-switch) there is no interactive user. The
    /// resolver must return nil so the daemon stays alive and simply declines work.
    func testLoginWindowReturnsNoConsoleUser() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: "loginwindow", uid: 0, gid: 0),
            consoleDeviceOwner: (uid: 0, gid: 0)
        )
        XCTAssertNil(resolved)
    }

    /// A nil console-user name (some macOS versions return NULL at the login window) is also
    /// treated as "no interactive user" when the uid is root.
    func testNilDynamicStoreNameWithRootUIDReturnsNil() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: nil, uid: 0, gid: 0),
            consoleDeviceOwner: nil
        )
        XCTAssertNil(resolved)
    }

    /// When SystemConfiguration is momentarily unavailable, fall back to the `/dev/console` owner
    /// (valid while unlocked, where it points at the logged-in user).
    func testFallsBackToConsoleDeviceOwnerWhenDynamicStoreUnavailable() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: nil,
            consoleDeviceOwner: (uid: 501, gid: 20)
        )
        XCTAssertEqual(resolved, RemoteAccessConsoleUser(uid: 501, gid: 20))
    }

    /// The console user from SystemConfiguration always wins over the `/dev/console` fallback,
    /// including the multi-user case where they disagree.
    func testDynamicStoreUserTakesPrecedenceOverConsoleDeviceOwner() {
        let resolved = RemoteAccessConsoleUserResolver.resolve(
            dynamicStoreUser: (name: "second", uid: 502, gid: 20),
            consoleDeviceOwner: (uid: 501, gid: 20)
        )
        XCTAssertEqual(resolved, RemoteAccessConsoleUser(uid: 502, gid: 20))
    }

    /// System/service accounts (uid < 500) are never treated as interactive GUI users, even if a
    /// signal somehow reports one.
    func testServiceAccountUIDsAreRejected() {
        XCTAssertNil(
            RemoteAccessConsoleUserResolver.resolve(
                dynamicStoreUser: (name: "_mbsetupuser", uid: 248, gid: 248),
                consoleDeviceOwner: (uid: 248, gid: 248)
            )
        )
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: nil, uid: 0))
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: nil, uid: 499))
        XCTAssertTrue(RemoteAccessConsoleUserResolver.isInteractive(name: "albertonunez", uid: 501))
    }

    /// A real account name with a `root`/`loginwindow` collision in casing/whitespace is still
    /// rejected, but a normal account name passes.
    func testNonInteractiveNamesAreRejectedCaseInsensitively() {
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: " LoginWindow ", uid: 501))
        XCTAssertFalse(RemoteAccessConsoleUserResolver.isInteractive(name: "root", uid: 501))
        XCTAssertTrue(RemoteAccessConsoleUserResolver.isInteractive(name: "alberto", uid: 501))
    }

    func testDisplayWakePolicyWaitsLongerWhenDisplayWasAsleep() {
        XCTAssertEqual(
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: false),
            150_000
        )
        XCTAssertEqual(
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: true),
            900_000
        )
        XCTAssertGreaterThan(
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: true),
            RemoteAccessDisplayWakePolicy.settleDelayMicroseconds(displayWasAsleep: false)
        )
    }

    func testCredentialWorkerLaunchPlanUsesConsoleUserInsideLoginwindowBootstrap() {
        XCTAssertEqual(
            RemoteAccessCredentialWorkerLaunchPlan.launchctlArguments(
                executablePath: "/agent",
                consoleUserUID: 501,
                loginWindowPID: 415,
                credentialFilePath: "/var/run/openburnbar-remote-access-agent.credential.ABC123"
            ),
            [
                "asuser",
                "501",
                "/bin/launchctl",
                "bsexec",
                "415",
                "/agent",
                "--type-credential-worker",
                "--credential-file",
                "/var/run/openburnbar-remote-access-agent.credential.ABC123"
            ]
        )
    }

    func testCredentialWorkerLaunchPlanFallsBackToConsoleUserSession() {
        XCTAssertEqual(
            RemoteAccessCredentialWorkerLaunchPlan.launchctlArguments(
                executablePath: "/agent",
                consoleUserUID: 501,
                loginWindowPID: nil,
                credentialFilePath: "/var/run/openburnbar-remote-access-agent.credential.ABC123"
            ),
            [
                "asuser",
                "501",
                "/agent",
                "--type-credential-worker",
                "--credential-file",
                "/var/run/openburnbar-remote-access-agent.credential.ABC123"
            ]
        )
    }

    func testCredentialWorkerUsesSessionScopedKeyboardEventSource() {
        XCTAssertEqual(
            RemoteAccessCredentialEventSourcePolicy.keyboardEventSource,
            .combinedSessionState
        )
        XCTAssertEqual(
            RemoteAccessCredentialEventSourcePolicy.keyboardEventTap,
            .sessionEventTap
        )
    }

    func testCredentialWorkerDoesNotSubmitEmptyPasswordBeforeTyping() {
        XCTAssertEqual(RemoteAccessCredentialEventSourcePolicy.preCredentialSubmitKeyPresses, 0)
    }

    func testFocusSequenceIsFastDeterministicAndDoesNotClick() {
        let policy = RemoteAccessCredentialEventSourcePolicy.self
        // The pointer nudge is a center *move*, never a click — a mis-aimed click can collapse the
        // password lane.
        XCTAssertEqual(policy.pointerNudgePoint, RemoteAccessNormalizedPoint(x: 0.5, y: 0.5))
        // At least one focus/clear backspace, with cheap settles so the full sequence fits the
        // worker budget (the old reveal loop ran ~5.35s and was killed before typing).
        XCTAssertGreaterThanOrEqual(policy.focusClearKeyPresses, 1)
        XCTAssertLessThanOrEqual(policy.escapeSettleMicroseconds, 300_000)
        XCTAssertLessThanOrEqual(policy.focusKeySettleMicroseconds, 150_000)
        XCTAssertLessThanOrEqual(policy.preTypeSettleMicroseconds, 300_000)
        // No Return is ever sent before the password.
        XCTAssertEqual(policy.preCredentialSubmitKeyPresses, 0)
    }

    func testCredentialWorkerTimeoutBudgetNestsFromWorkerToPhone() {
        let policy = RemoteAccessCredentialTimeoutPolicy.self

        // Worst-case worker work (μs → ns) must fit inside the helper's kill backstop — the core
        // regression was the inverse (worker ~6.3s > 5s backstop), which killed the worker
        // mid-focus before a single password key was posted.
        let worstCaseNanoseconds = policy.worstCaseWorkerMicroseconds() * 1_000
        XCTAssertLessThan(worstCaseNanoseconds, policy.workerExitTimeoutNanoseconds)
        // Demand real margin so future delay tuning that erodes it trips this test instead of
        // silently re-introducing the timeout.
        XCTAssertGreaterThan(
            policy.workerExitTimeoutNanoseconds,
            worstCaseNanoseconds + worstCaseNanoseconds / 4
        )

        // worker backstop < Mac client socket timeout < iPhone ack timeout.
        let macClientNanoseconds = UInt64(policy.macClientSocketTimeoutSeconds) * 1_000_000_000
        XCTAssertLessThan(policy.workerExitTimeoutNanoseconds, macClientNanoseconds)
        XCTAssertLessThan(macClientNanoseconds, policy.iOSCredentialAckTimeoutNanoseconds)
    }

    func testCredentialWorkerSingleAttemptGrowsWithCredentialLength() {
        let policy = RemoteAccessCredentialTimeoutPolicy.self
        XCTAssertGreaterThan(
            policy.singleAttemptMicroseconds(keyCount: 64),
            policy.singleAttemptMicroseconds(keyCount: 8)
        )
        XCTAssertGreaterThanOrEqual(policy.maximumUnlockAttempts, 1)
    }
}
