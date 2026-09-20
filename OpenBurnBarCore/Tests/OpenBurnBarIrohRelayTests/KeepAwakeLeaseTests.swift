import XCTest
@testable import OpenBurnBarIrohRelay

final class KeepAwakeLeaseTests: XCTestCase {
    func testAcquireHoldsAndReleaseDropsWhenLastReasonEnds() {
        var lease = KeepAwakeLease()
        XCTAssertFalse(lease.isHeld)

        XCTAssertTrue(lease.acquire(.irohControl))
        XCTAssertTrue(lease.isHeld)
        XCTAssertEqual(lease.reasons, [.irohControl])

        XCTAssertFalse(lease.acquire(.irohControl), "same reason is idempotent")
        XCTAssertFalse(lease.acquire(.mercuryMirror), "already held")
        XCTAssertEqual(lease.reasons, [.irohControl, .mercuryMirror])

        XCTAssertFalse(lease.release(.irohControl), "still held by mercury")
        XCTAssertTrue(lease.isHeld)
        XCTAssertTrue(lease.release(.mercuryMirror))
        XCTAssertFalse(lease.isHeld)
        XCTAssertTrue(lease.reasons.isEmpty)
    }

    func testSetTogglesAReasonWithoutDroppingSiblings() {
        var lease = KeepAwakeLease()
        XCTAssertTrue(lease.set(.computerUse, held: true))
        XCTAssertTrue(lease.set(.phoneToggle, held: true) == false)
        XCTAssertFalse(lease.set(.computerUse, held: false))
        XCTAssertEqual(lease.reasons, [.phoneToggle])
        XCTAssertTrue(lease.set(.phoneToggle, held: false))
        XCTAssertFalse(lease.isHeld)
    }

    func testReleaseOfUnknownReasonIsANoOp() {
        var lease = KeepAwakeLease()
        XCTAssertFalse(lease.release(.phoneToggle))
        XCTAssertFalse(lease.isHeld)
    }

    func testReachabilityStatusMapsPresenceCapabilities() {
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let awake = HostReachabilityStatus.awake(
            lastSeenAt: now,
            reasons: [.irohControl, .mercuryMirror]
        )
        XCTAssertTrue(awake.isAwake)
        XCTAssertFalse(awake.lidCloseSleepDisabled)
        XCTAssertEqual(awake.presenceCapabilities, [HostReachabilityCapability.held])
        XCTAssertFalse(awake.phoneToggleHeld)

        let sticky = HostReachabilityStatus.awake(
            lastSeenAt: now,
            reasons: [.phoneToggle]
        )
        XCTAssertTrue(sticky.phoneToggleHeld)
        XCTAssertEqual(
            sticky.presenceCapabilities,
            [HostReachabilityCapability.held, HostReachabilityCapability.phoneToggle]
        )
        XCTAssertTrue(HostReachabilityStatus.fromPresence(
            capabilities: sticky.presenceCapabilities,
            lastSeenAt: now
        ).phoneToggleHeld)

        let parsed = HostReachabilityStatus.fromPresence(
            capabilities: awake.presenceCapabilities,
            lastSeenAt: now
        )
        XCTAssertTrue(parsed.isAwake)
        XCTAssertEqual(parsed.lastSeenAt, now)

        let asleep = HostReachabilityStatus.asleep(lastSeenAt: now)
        XCTAssertEqual(asleep.presenceCapabilities, [HostReachabilityCapability.asleep])
        XCTAssertFalse(HostReachabilityStatus.fromPresence(
            capabilities: asleep.presenceCapabilities,
            lastSeenAt: now
        ).isAwake)
        XCTAssertFalse(LidCloseSleepPolicy.disablesSleepByDefault)
    }
}