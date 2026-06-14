import XCTest
@testable import OpenBurnBarMobile

// MARK: - App Lock Policy (T-IOS-02)
//
// Locks the LocalAuthentication re-lock contract: chat + vault data must be
// gated at cold launch and after a real backgrounding, while a quick
// task-switch inside the grace window stays unlocked. Pure value type, so these
// run without a device or a real LAContext.

final class AppLockPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testColdLaunchRequiresAuthentication() {
        let policy = AppLockPolicy()
        XCTAssertTrue(
            policy.requiresAuthentication(lastUnlock: nil, lastBackgrounded: nil, now: t0),
            "Never authenticated this process ⇒ must require auth (cold launch)"
        )
    }

    func testStaysUnlockedWhenNotBackgroundedSinceUnlock() {
        let policy = AppLockPolicy()
        XCTAssertFalse(
            policy.requiresAuthentication(
                lastUnlock: t0,
                lastBackgrounded: nil,
                now: t0.addingTimeInterval(3600)
            ),
            "No backgrounding since unlock ⇒ no re-auth even much later"
        )
    }

    func testStaysUnlockedWithinGraceWindow() {
        let policy = AppLockPolicy(graceInterval: 60)
        let backgrounded = t0.addingTimeInterval(10)
        XCTAssertFalse(
            policy.requiresAuthentication(
                lastUnlock: t0,
                lastBackgrounded: backgrounded,
                now: backgrounded.addingTimeInterval(30)
            ),
            "Returning within the grace window must not force a prompt"
        )
    }

    func testRelocksAfterGraceWindow() {
        let policy = AppLockPolicy(graceInterval: 60)
        let backgrounded = t0.addingTimeInterval(10)
        XCTAssertTrue(
            policy.requiresAuthentication(
                lastUnlock: t0,
                lastBackgrounded: backgrounded,
                now: backgrounded.addingTimeInterval(60)
            ),
            "Past the grace window ⇒ relock"
        )
    }

    func testBackgroundedBeforeUnlockDoesNotRelock() {
        // A stale backgrounding timestamp from before the last unlock must not
        // trigger a relock.
        let policy = AppLockPolicy(graceInterval: 60)
        XCTAssertFalse(
            policy.requiresAuthentication(
                lastUnlock: t0.addingTimeInterval(100),
                lastBackgrounded: t0,
                now: t0.addingTimeInterval(10_000)
            )
        )
    }

    func testDisabledPolicyNeverRequiresAuthentication() {
        let policy = AppLockPolicy(isEnabled: false)
        XCTAssertFalse(
            policy.requiresAuthentication(lastUnlock: nil, lastBackgrounded: nil, now: t0),
            "Opted-out users are never gated"
        )
    }
}
