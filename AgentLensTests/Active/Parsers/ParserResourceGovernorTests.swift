import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

// MARK: - ParserResourceGovernorTests

/// Unit coverage for the per-pass resource governor introduced by the
/// 2026-07-16 usage-refresh resource-exhaustion fix: byte-budget admission
/// (with deferral accounting) and the sampled memory-ceiling checkpoint.
final class ParserResourceGovernorTests: XCTestCase {

    // MARK: - Byte-budget admission

    func test_admitFile_admitsUntilBudgetCrossed_thenDefersAndCounts() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 100)
        )

        // 0 < 100: admitted, charged.
        XCTAssertTrue(governor.admitFile(estimatedBytes: 60))
        XCTAssertEqual(governor.consumedBytes, 60)
        XCTAssertEqual(governor.deferredFileCount, 0)

        // 60 < 100: the admission that crosses the budget is still allowed
        // (a pass always makes progress).
        XCTAssertTrue(governor.admitFile(estimatedBytes: 60))
        XCTAssertEqual(governor.consumedBytes, 120)
        XCTAssertEqual(governor.deferredFileCount, 0)

        // 120 >= 100: budget exhausted — every further file defers.
        XCTAssertFalse(governor.admitFile(estimatedBytes: 1))
        XCTAssertEqual(governor.deferredFileCount, 1)
        XCTAssertFalse(governor.admitFile(estimatedBytes: 10_000))
        XCTAssertEqual(governor.deferredFileCount, 2)

        // Deferred files are never charged.
        XCTAssertEqual(governor.consumedBytes, 120)
    }

    func test_admitFile_firstFileLargerThanWholeBudget_isStillAdmitted() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 10)
        )

        XCTAssertTrue(
            governor.admitFile(estimatedBytes: 1_000_000),
            "A cold cache with one giant file must still make progress"
        )
        XCTAssertEqual(governor.consumedBytes, 1_000_000)

        // But the pass is now over budget: the next file defers.
        XCTAssertFalse(governor.admitFile(estimatedBytes: 1))
        XCTAssertEqual(governor.deferredFileCount, 1)
    }

    func test_admitFile_withoutBudget_admitsEverythingAndStillAccounts() {
        let governor = ParserResourceGovernor(limits: .unlimited)

        for _ in 0..<5 {
            XCTAssertTrue(governor.admitFile(estimatedBytes: 1 << 30))
        }
        XCTAssertEqual(governor.consumedBytes, 5 << 30)
        XCTAssertEqual(governor.deferredFileCount, 0)
    }

    // MARK: - Memory-ceiling checkpoint

    func test_checkpoint_throwsMemoryCeiling_whenFootprintExceedsCeiling() {
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 100),
            footprintProvider: { 200 }
        )

        // The very first checkpoint samples the footprint.
        XCTAssertThrowsError(try governor.checkpoint()) { error in
            XCTAssertEqual(
                error as? ParserResourceExceeded,
                .memoryCeiling(footprintBytes: 200, ceilingBytes: 100)
            )
        }
    }

    func test_checkpoint_samplesFirstAndThenEveryThirtySecondCall() throws {
        // Footprint is healthy on the first sample and critical afterwards;
        // the throw must land exactly on the next sampled checkpoint (#33),
        // proving calls 2...32 do not sample.
        let providerCalls = ManagedAtomicCounter()
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 100),
            footprintProvider: {
                providerCalls.increment() == 1 ? 50 : 200
            }
        )

        try governor.checkpoint() // call 1: samples 50, under ceiling
        for call in 2...32 {
            XCTAssertNoThrow(try governor.checkpoint(), "call \(call) must not sample")
        }
        XCTAssertEqual(providerCalls.value, 1, "only checkpoint #1 samples in the first window")

        XCTAssertThrowsError(try governor.checkpoint()) { error in // call 33 samples
            XCTAssertEqual(
                error as? ParserResourceExceeded,
                .memoryCeiling(footprintBytes: 200, ceilingBytes: 100)
            )
        }
        XCTAssertEqual(providerCalls.value, 2)
    }

    func test_checkpoint_softLimitCallback_firesExactlyOncePerPass() throws {
        let softLimitHits = ManagedAtomicCounter()
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memorySoftLimitBytes: 100),
            footprintProvider: { 200 },
            onSoftLimit: { footprint in
                XCTAssertEqual(footprint, 200)
                _ = softLimitHits.increment()
            }
        )

        // Many checkpoints, several of which sample (#1, #33, #65, ...):
        // the callback still fires exactly once for the whole pass.
        for _ in 0..<200 {
            try governor.checkpoint()
        }
        XCTAssertEqual(softLimitHits.value, 1)
    }

    func test_checkpoint_withNoMemoryLimits_neverThrowsAndNeverSamples() {
        let providerCalls = ManagedAtomicCounter()
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(fileByteBudget: 10),
            footprintProvider: {
                _ = providerCalls.increment()
                return .max
            }
        )

        for _ in 0..<100 {
            XCTAssertNoThrow(try governor.checkpoint())
        }
        XCTAssertEqual(providerCalls.value, 0, "no memory limits => the footprint is never sampled")
    }

    func test_checkpoint_zeroFootprint_isIgnored() {
        // Platforms where the footprint is unavailable report 0; the governor
        // must treat that as "unknown", not "over/under the ceiling".
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(memoryCeilingBytes: 1),
            footprintProvider: { 0 }
        )
        XCTAssertNoThrow(try governor.checkpoint())
    }

    // MARK: - Live footprint probe

    func test_currentPhysicalFootprint_reportsPositiveValueOnDarwin() {
        XCTAssertGreaterThan(
            ParserResourceGovernor.currentPhysicalFootprint(),
            0,
            "task_info(TASK_VM_INFO) must report a real footprint for the test process"
        )
    }
}

// MARK: - Helpers

/// Minimal lock-guarded counter (the governor may invoke the injected
/// closures under its own lock discipline; keep the test side race-free).
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
