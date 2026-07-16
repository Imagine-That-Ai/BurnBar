import Foundation
import XCTest
@testable import OpenBurnBarCore

final class ParserResourceGovernorTests: XCTestCase {
    // MARK: - ParserResourceLimits

    func test_unlimitedLimitsLeaveAllBoundsUnenforced() {
        let limits = ParserResourceLimits.unlimited
        XCTAssertNil(limits.fileByteBudget, "unlimited must not cap the byte budget")
        XCTAssertNil(limits.memoryCeilingBytes, "unlimited must not cap the memory ceiling")
        XCTAssertNil(limits.memorySoftLimitBytes, "unlimited must not set a soft limit")
    }

    func test_limitsStoreConfiguredBounds() {
        let limits = ParserResourceLimits(
            fileByteBudget: 1_024,
            memoryCeilingBytes: 2_048,
            memorySoftLimitBytes: 1_024
        )
        XCTAssertEqual(limits.fileByteBudget, 1_024)
        XCTAssertEqual(limits.memoryCeilingBytes, 2_048)
        XCTAssertEqual(limits.memorySoftLimitBytes, 1_024)
    }

    // MARK: - byte budget admission

    func test_nilByteBudgetAdmitsEveryFileAndChargesConsumedBytes() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: nil)
        )
        // Three files of varying sizes all admitted; nil budget never defers.
        XCTAssertTrue(governor.admitFile(estimatedBytes: 10))
        XCTAssertTrue(governor.admitFile(estimatedBytes: 0))
        XCTAssertTrue(governor.admitFile(estimatedBytes: 1_000_000))
        XCTAssertEqual(governor.consumedBytes, 1_000_010)
        XCTAssertEqual(governor.deferredFileCount, 0)
    }

    func test_budgetSoftBoundaryAdmitsCrossingFileThenDefersRest() {
        // The budget is soft at the boundary: the admission that crosses the
        // budget is allowed (a single file larger than the whole budget still
        // makes progress), but every file after it is deferred.
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 1_000)
        )
        // First file within budget — admitted, consumes 400.
        XCTAssertTrue(governor.admitFile(estimatedBytes: 400))
        XCTAssertEqual(governor.consumedBytes, 400)
        XCTAssertEqual(governor.deferredFileCount, 0)

        // Second file crosses the 1_000 budget — still admitted (soft boundary).
        XCTAssertTrue(governor.admitFile(estimatedBytes: 700))
        XCTAssertEqual(governor.consumedBytes, 1_100)
        XCTAssertEqual(governor.deferredFileCount, 0)

        // Budget now exhausted — subsequent files deferred, not charged.
        XCTAssertFalse(governor.admitFile(estimatedBytes: 50))
        XCTAssertFalse(governor.admitFile(estimatedBytes: 1))
        XCTAssertEqual(governor.consumedBytes, 1_100, "deferred files must not charge the budget")
        XCTAssertEqual(governor.deferredFileCount, 2)
    }

    func test_singleFileLargerThanEntireBudgetIsAdmitted() {
        // A pass always makes progress even when a single file exceeds the
        // whole budget — this is the regression-prone boundary.
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 100)
        )
        XCTAssertTrue(governor.admitFile(estimatedBytes: 10_000))
        XCTAssertEqual(governor.consumedBytes, 10_000)
        XCTAssertEqual(governor.deferredFileCount, 0)
    }

    func test_zeroByteFileAdmittedEvenWhenBudgetExactlyExhausted() {
        // consumedBytes == budget is the exact boundary: the guard is
        // `consumedBytes < budget`, so at exactly the budget a zero-byte file
        // is deferred. This pins the off-by-one boundary.
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 500)
        )
        XCTAssertTrue(governor.admitFile(estimatedBytes: 500))
        XCTAssertEqual(governor.consumedBytes, 500)
        // Now consumed == budget, so even a zero-byte file is deferred.
        XCTAssertFalse(governor.admitFile(estimatedBytes: 0))
        XCTAssertEqual(governor.deferredFileCount, 1)
    }

    // MARK: - memory ceiling

    func test_checkpointWithoutCeilingOrSoftLimitNeverThrowsOrSamples() {
        // With no memory bounds, checkpoint must short-circuit before sampling
        // the footprint provider — so a provider that returns a huge value
        // still never throws.
        var sampled = false
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(),
            footprintProvider: { sampled = true; return Int64.max }
        )
        for _ in 0..<100 {
            XCTAssertNoThrow(try governor.checkpoint())
        }
        XCTAssertFalse(sampled, "footprint must not be sampled when no memory bound is set")
    }

    func test_memoryCeilingThrowsWhenFootprintCrossesIt() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 1_000),
            footprintProvider: { 1_500 }
        )
        // checkpoint samples on the 1st, 33rd, 65th, ... call. The first
        // checkpoint samples and should throw.
        XCTAssertThrowsError(try governor.checkpoint()) { error in
            guard case let ParserResourceExceeded.memoryCeiling(footprint, ceiling) = error else {
                XCTFail("expected memoryCeiling, got \(error)")
                return
            }
            XCTAssertEqual(footprint, 1_500)
            XCTAssertEqual(ceiling, 1_000)
        }
    }

    func test_memoryCeilingDoesNotThrowBelowOrAtBoundary() {
        // footprint <= ceiling must not throw (the guard is `footprint > ceiling`).
        let atCeiling = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 1_000),
            footprintProvider: { 1_000 }
        )
        XCTAssertNoThrow(try atCeiling.checkpoint(), "footprint == ceiling must not throw")

        let belowCeiling = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 1_000),
            footprintProvider: { 999 }
        )
        XCTAssertNoThrow(try belowCeiling.checkpoint(), "footprint < ceiling must not throw")
    }

    func test_zeroFootprintNeverTriggersCeilingOrSoftLimit() {
        // A footprint provider returning 0 (unavailable platform) must never
        // trip either bound — `guard footprint > 0` is the early-out.
        var softCalled = false
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(
                memoryCeilingBytes: 1,
                memorySoftLimitBytes: 1
            ),
            footprintProvider: { 0 },
            onSoftLimit: { _ in softCalled = true }
        )
        for _ in 0..<40 { XCTAssertNoThrow(try governor.checkpoint()) }
        XCTAssertFalse(softCalled, "zero footprint must not trigger the soft-limit callback")
    }

    // MARK: - soft limit callback

    func test_softLimitCallbackFiresOncePerPass() {
        var calls: [Int64] = []
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: nil, memorySoftLimitBytes: 1_000),
            footprintProvider: { 2_000 },
            onSoftLimit: { calls.append($0) }
        )
        // The soft limit fires at most once per pass (softLimitReported guard).
        // Sampling happens every 32 checkpoints (1st, 33rd, 65th, ...), so run
        // enough checkpoints to sample three times.
        for _ in 0..<100 { XCTAssertNoThrow(try governor.checkpoint()) }
        XCTAssertEqual(calls, [2_000], "soft-limit callback must fire exactly once with the crossing footprint")
    }

    func test_softLimitDoesNotFireBelowBoundary() {
        var calls = 0
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memorySoftLimitBytes: 1_000),
            footprintProvider: { 1_000 },
            onSoftLimit: { _ in calls += 1 }
        )
        // footprint == soft limit: guard is `footprint > soft`, so equal does not fire.
        for _ in 0..<100 { XCTAssertNoThrow(try governor.checkpoint()) }
        XCTAssertEqual(calls, 0, "footprint == soft limit must not fire the callback")
    }

    // MARK: - checkpoint sampling rate

    func test_checkpointSamplesEveryThirtyTwoIterations() {
        // The ceiling is only evaluated on sampled checkpoints (counter % 32 == 1).
        // The 1st, 33rd, 65th, ... calls sample; all others short-circuit before
        // reading the footprint. So a footprint that crosses the ceiling on a
        // non-sampled call must not throw.
        var footprint = Int64(0)
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 500),
            footprintProvider: { footprint }
        )
        // First checkpoint: counter becomes 1 → sampled. footprint 0 does not
        // cross the 500 ceiling, so this must not throw.
        XCTAssertNoThrow(try governor.checkpoint(), "first sampled checkpoint with safe footprint must not throw")
        // Iterations 2..32: counter 2..32 → not sampled. Raise the footprint
        // above the ceiling; none of these should throw because the footprint
        // is never read on non-sampled checkpoints.
        for i in 2...32 {
            footprint = 1_000
            XCTAssertNoThrow(try governor.checkpoint(), "non-sampled checkpoint \(i) must not throw")
        }
        // Iteration 33: counter becomes 33 → sampled. Now the footprint (1_000)
        // crosses the 500 ceiling and must throw.
        footprint = 1_000
        XCTAssertThrowsError(try governor.checkpoint(), "33rd sampled checkpoint must throw when ceiling is crossed")
    }

    // MARK: - ParserResourceExceeded

    func test_memoryCeilingErrorEqualityAndDescription() {
        let a = ParserResourceExceeded.memoryCeiling(footprintBytes: 2_097_152, ceilingBytes: 1_048_576)
        let b = ParserResourceExceeded.memoryCeiling(footprintBytes: 2_097_152, ceilingBytes: 1_048_576)
        let c = ParserResourceExceeded.memoryCeiling(footprintBytes: 3_145_728, ceilingBytes: 1_048_576)
        XCTAssertEqual(a, b, "same footprint and ceiling must be equal")
        XCTAssertNotEqual(a, c, "different footprint must not be equal")
        // Description surfaces MB-granularity numbers for operators reading CI logs.
        XCTAssertTrue(a.description.contains("2MB"), "description must report footprint in MB: \(a.description)")
        XCTAssertTrue(a.description.contains("1MB"), "description must report ceiling in MB: \(a.description)")
    }
}
