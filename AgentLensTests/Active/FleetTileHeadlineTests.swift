import OpenBurnBarKernel
import XCTest

@testable import OpenBurnBar

final class FleetTileHeadlineTests: XCTestCase {
    func test_snapshotZeroRunningIsHonestZeroNotWatching() {
        let headline = FleetTileHeadline.resolved(fromSnapshot: FleetTestFixtures.makeEmptySnapshot())
        XCTAssertEqual(headline, .running(0))
        XCTAssertEqual(headline.label, "0 agents running")
        XCTAssertEqual(headline.chipLabel, "Live watch")
        XCTAssertEqual(headline.tileState, .on)
    }

    func test_notReadyIsPreparingNeverZeroRunning() {
        let headline = FleetTileHeadline.resolved(fromError: BurnBarFleetClientError.notReady)
        XCTAssertEqual(headline, .preparing)
        XCTAssertEqual(headline.label, "Preparing first snapshot")
        XCTAssertFalse(headline.label.contains("0"))
        XCTAssertEqual(headline.tileState, .unavailable("Checking fleet…"))
        XCTAssertEqual(headline.chipLabel, "Checking")
    }

    func test_daemonUnavailableIsDownNotZero() {
        let headline = FleetTileHeadline.resolved(
            fromError: BurnBarFleetClientError.daemonUnavailable("connect failed")
        )
        XCTAssertEqual(headline, .daemonDown)
        XCTAssertEqual(headline.label, "Daemon not serving fleet yet")
        XCTAssertEqual(headline.tileState, .unavailable("Daemon not serving fleet"))
        XCTAssertEqual(headline.chipLabel, "Unavailable")
    }

    func test_headerCopyNeverShowsZeroBeforeSnapshot() {
        XCTAssertEqual(FleetHeaderCopy.runningReadout(.checking), "Checking…")
        XCTAssertEqual(FleetHeaderCopy.runningAccessibility(.checking), "Checking fleet snapshot")
        XCTAssertFalse(FleetHeaderCopy.runningReadout(.checking).contains("0"))
        XCTAssertEqual(FleetHeaderCopy.runningReadout(.unavailable), "Unavailable")
        XCTAssertEqual(FleetHeaderCopy.runningReadout(.running(0)), "0 running")
        XCTAssertEqual(FleetHeaderCopy.runningReadout(.running(2)), "2 running")
    }
}
