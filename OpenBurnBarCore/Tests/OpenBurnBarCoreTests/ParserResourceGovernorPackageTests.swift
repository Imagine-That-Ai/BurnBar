import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBarLogParsers

final class ParserResourceGovernorPackageTests: XCTestCase {
    func testAdmitFileAllowsBoundaryCrossingThenDefersWithoutCharging() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 100)
        )

        XCTAssertTrue(governor.admitFile(estimatedBytes: 60))
        XCTAssertTrue(governor.admitFile(estimatedBytes: 60))
        XCTAssertFalse(governor.admitFile(estimatedBytes: 1))
        XCTAssertFalse(governor.admitFile(estimatedBytes: 10_000))
        XCTAssertEqual(governor.consumedBytes, 120)
        XCTAssertEqual(governor.deferredFileCount, 2)
    }

    func testAdmitFileWithoutBudgetAdmitsAndAccountsForEveryFile() {
        let governor = ParserResourceGovernor(limits: .unlimited)

        XCTAssertTrue(governor.admitFile(estimatedBytes: 1_000))
        XCTAssertTrue(governor.admitFile(estimatedBytes: 2_000))
        XCTAssertEqual(governor.consumedBytes, 3_000)
        XCTAssertEqual(governor.deferredFileCount, 0)
    }

    func testCheckpointSamplesFirstAndEveryThirtySecondCall() throws {
        let providerCalls = Locked(0)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 100),
            footprintProvider: {
                providerCalls.withLock { calls in
                    calls += 1
                    return calls == 1 ? 50 : 200
                }
            }
        )

        try governor.checkpoint()
        for _ in 2...32 {
            try governor.checkpoint()
        }
        XCTAssertEqual(providerCalls.read(), 1)

        XCTAssertThrowsError(try governor.checkpoint()) { error in
            XCTAssertEqual(
                error as? ParserResourceExceeded,
                .memoryCeiling(footprintBytes: 200, ceilingBytes: 100)
            )
        }
        XCTAssertEqual(providerCalls.read(), 2)
    }

    func testCheckpointReportsSoftLimitOnlyOnce() throws {
        let softLimitFootprints = Locked<[Int64]>([])
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memorySoftLimitBytes: 100),
            footprintProvider: { 200 },
            onSoftLimit: { footprint in
                softLimitFootprints.withLock { $0.append(footprint) }
            }
        )

        for _ in 0..<100 {
            try governor.checkpoint()
        }

        XCTAssertEqual(softLimitFootprints.read(), [200])
    }

    func testCheckpointWithoutMemoryLimitsDoesNotSample() throws {
        let providerCalls = Locked(0)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 1),
            footprintProvider: {
                providerCalls.withLock { $0 += 1 }
                return .max
            }
        )

        for _ in 0..<100 {
            try governor.checkpoint()
        }

        XCTAssertEqual(providerCalls.read(), 0)
    }

    func testCheckpointIgnoresUnavailableFootprint() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 1),
            footprintProvider: { 0 }
        )

        XCTAssertNoThrow(try governor.checkpoint())
    }
}
