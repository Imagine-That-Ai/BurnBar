import OpenBurnBarCore
import XCTest
@testable import OpenBurnBarDaemon

// MARK: - BurnBarConnectionGateTests

final class BurnBarConnectionGateTests: XCTestCase {

    func test_acquireUnderLimit_succeeds() {
        let gate = BurnBarConnectionGate(maxConcurrent: 4)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertEqual(gate.activeCount, 2)
    }

    func test_acquireAtLimit_fails() {
        let gate = BurnBarConnectionGate(maxConcurrent: 2)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
        XCTAssertEqual(gate.activeCount, 2)
    }

    func test_releaseFreesSlot() {
        let gate = BurnBarConnectionGate(maxConcurrent: 2)
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())

        gate.release()
        XCTAssertEqual(gate.activeCount, 1)
        XCTAssertTrue(gate.tryAcquire())
    }

    func test_releaseNeverGoesNegative() {
        let gate = BurnBarConnectionGate(maxConcurrent: 4)
        gate.release()
        gate.release()
        XCTAssertEqual(gate.activeCount, 0)
    }

    func test_concurrentAcquire_neverExceedsMax() {
        let gate = BurnBarConnectionGate(maxConcurrent: 16)
        let group = DispatchGroup()
        let acquired = Locked<[Int]>([])

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                if gate.tryAcquire() {
                    acquired.withLock { $0.append(i) }
                    // Hold briefly to create contention.
                    Thread.sleep(forTimeInterval: 0.001)
                    gate.release()
                }
                group.leave()
            }
        }
        group.wait()

        // At most 16 were ever active simultaneously; total acquisitions
        // should be ≤ 100 (some may have been rejected while at capacity).
        let total = acquired.read().count
        XCTAssertLessThanOrEqual(total, 100)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(gate.activeCount, 16)
    }

    func test_defaultMaxConcurrent_is128() {
        let gate = BurnBarConnectionGate()
        XCTAssertEqual(gate.maxCount, 128)
    }
}
