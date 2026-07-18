import Foundation
import XCTest
@testable import OpenBurnBarCore

final class ParserResourceGovernorTests: XCTestCase {
    // MARK: - ParserResourceLimits


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

    // MARK: - Governed read telemetry

    func test_fileReadGateChargesAdmittedBytesOnceAndReportsBudgetDeferral() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-parser-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let bytes = Data("0123456789".utf8)
        try bytes.write(to: file)

        let governor = ParserResourceGovernor(limits: ParserResourceLimits(fileByteBudget: Int64(bytes.count)))
        let metrics = ParserPassMetrics()
        let gate = ParserFileReadGate(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: governor,
            metrics: metrics
        ))

        XCTAssertTrue(try gate.shouldRead(file))
        XCTAssertFalse(try gate.shouldRead(file), "a second candidate after the pass budget is exhausted must be deferred")

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.candidateCount, 2)
        XCTAssertEqual(snapshot.metadataStatCount, 2)
        XCTAssertEqual(snapshot.contentReadCount, 1)
        XCTAssertEqual(snapshot.contentReadBytes, Int64(bytes.count))
        XCTAssertEqual(snapshot.deferredFileCount, 1)
        XCTAssertEqual(snapshot.byteBudgetDeferredCount, 1)
        XCTAssertEqual(governor.consumedBytes, Int64(bytes.count), "deferred candidates must not be charged")
    }

    func test_fileReadGateMissingMetadataDefersWithoutReadAdmission() throws {
        let governor = ParserResourceGovernor(limits: .unlimited)
        let metrics = ParserPassMetrics()
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-missing-parser-file-\(UUID().uuidString)")
        let gate = ParserFileReadGate(options: LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: .distantPast,
            resourceGovernor: governor,
            metrics: metrics
        ))

        XCTAssertFalse(try gate.shouldRead(missingFile))

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.candidateCount, 1)
        XCTAssertEqual(snapshot.metadataStatCount, 1)
        XCTAssertEqual(snapshot.contentReadCount, 0)
        XCTAssertEqual(snapshot.contentReadBytes, 0)
        XCTAssertEqual(snapshot.deferredFileCount, 1)
        XCTAssertEqual(snapshot.metadataUnavailableDeferredCount, 1)
        XCTAssertEqual(governor.deferredFileCount, 1, "missing metadata must freeze the caller's checkpoint")
    }

    func test_passMetricsSnapshotsPreserveReasonBreakdownAndMonotonicElapsedTime() {
        let metrics = ParserPassMetrics()
        metrics.recordCandidate(count: 4)
        metrics.recordMetadataStat(count: 5)
        metrics.recordContentRead(count: 2, bytes: 123)
        metrics.recordDeferred(.byteBudget)
        metrics.recordDeferred(.metadataUnavailable)
        metrics.recordDeferred(.byteCountOverflow)
        metrics.recordDeferred(.contentReadFailed)
        let first = metrics.snapshot()

        metrics.recordCandidate()
        let second = metrics.snapshot()

        XCTAssertEqual(first.candidateCount, 4)
        XCTAssertEqual(first.metadataStatCount, 5)
        XCTAssertEqual(first.contentReadCount, 2)
        XCTAssertEqual(first.contentReadBytes, 123)
        XCTAssertEqual(first.deferredFileCount, 4)
        XCTAssertEqual(first.byteBudgetDeferredCount, 1)
        XCTAssertEqual(first.metadataUnavailableDeferredCount, 1)
        XCTAssertEqual(first.byteCountOverflowDeferredCount, 1)
        XCTAssertEqual(first.contentReadFailedDeferredCount, 1)
        XCTAssertEqual(second.candidateCount, 5)
        XCTAssertGreaterThanOrEqual(
            second.elapsedMilliseconds,
            first.elapsedMilliseconds,
            "successive snapshots from one pass must never move elapsed time backwards"
        )
    }

    func test_parseConvenienceDispatchesToTheOnlyGovernedProtocolRequirement() async throws {
        let recorder = ParserOptionsInvocationRecorder()
        let parser: any LogParser = OptionsOnlyLogParser(recorder: recorder)

        _ = try await parser.parse()

        let invocationCount = await recorder.invocationCount()
        XCTAssertEqual(invocationCount, 1)
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

private actor ParserOptionsInvocationRecorder {
    private var count = 0

    func recordInvocation() {
        count += 1
    }

    func invocationCount() -> Int {
        count
    }
}

private struct OptionsOnlyLogParser: LogParser {
    let provider: AgentProvider = .factory
    let recorder: ParserOptionsInvocationRecorder

    func parse(options: LogParseOptions) async throws -> ParseResult {
        await recorder.recordInvocation()
        return ParseResult(usages: [], conversations: [])
    }
}
