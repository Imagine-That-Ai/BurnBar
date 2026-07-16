import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBarLogParsers

final class ParserResourceGovernorTests: XCTestCase {
    func testByteBudgetAllowsCrossingAdmissionThenDefersFollowingFiles() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 100)
        )

        XCTAssertTrue(governor.admitFile(estimatedBytes: 60))
        XCTAssertTrue(governor.admitFile(estimatedBytes: 60))
        XCTAssertFalse(governor.admitFile(estimatedBytes: 1))
        XCTAssertEqual(governor.consumedBytes, 120)
        XCTAssertEqual(governor.deferredFileCount, 1)
    }

    func testUnlimitedBudgetTracksEveryAdmission() {
        let governor = ParserResourceGovernor(limits: .unlimited)

        XCTAssertTrue(governor.admitFile(estimatedBytes: 40))
        XCTAssertTrue(governor.admitFile(estimatedBytes: 2))
        XCTAssertEqual(governor.consumedBytes, 42)
        XCTAssertEqual(governor.deferredFileCount, 0)
    }

    func testSoftLimitReportsOnceAndHardLimitThrows() throws {
        let reports = Locked<[Int64]>([])
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(
                memoryCeilingBytes: 200,
                memorySoftLimitBytes: 100
            ),
            footprintProvider: { 250 },
            onSoftLimit: { footprint in
                reports.withLock { $0.append(footprint) }
            }
        )

        XCTAssertThrowsError(try governor.checkpoint()) { error in
            XCTAssertEqual(
                error as? ParserResourceExceeded,
                .memoryCeiling(footprintBytes: 250, ceilingBytes: 200)
            )
        }
        for _ in 0..<32 {
            _ = try? governor.checkpoint()
        }
        XCTAssertEqual(reports.withLock { $0 }, [250])
    }

    func testCheckpointSamplesFootprintEveryThirtyTwoCalls() throws {
        let sampleCount = Locked(0)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memorySoftLimitBytes: 100),
            footprintProvider: {
                sampleCount.withLock {
                    $0 += 1
                    return 50
                }
            }
        )

        for _ in 0..<33 {
            try governor.checkpoint()
        }
        XCTAssertEqual(sampleCount.withLock { $0 }, 2)
    }

    func testZeroFootprintIsTreatedAsUnavailable() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 1),
            footprintProvider: { 0 }
        )

        XCTAssertNoThrow(try governor.checkpoint())
    }

    func testExceededDescriptionUsesMegabytes() {
        let error = ParserResourceExceeded.memoryCeiling(
            footprintBytes: 25 * 1024 * 1024,
            ceilingBytes: 20 * 1024 * 1024
        )

        XCTAssertEqual(
            error.description,
            "parse aborted: process footprint 25MB crossed the 20MB ceiling"
        )
    }

    func testParserAutoreleasePoolReturnsValuesAndPropagatesErrors() {
        XCTAssertEqual(ParserAutoreleasePool.run { 42 }, 42)

        XCTAssertThrowsError(
            try ParserAutoreleasePool.run {
                throw TestError.expected
            }
        ) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }
    }

    private enum TestError: Error, Equatable {
        case expected
    }
}
