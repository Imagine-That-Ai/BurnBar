import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarFleetCadenceHardeningTests: M6FleetHardeningTestCase {
    func testDefaultCadencePolicy_matchesDocumented13To17WindowAndNoDrift() {
        XCTAssertEqual(BurnBarFleetCadencePolicy.toleranceSeconds(for: 15), 2)
        XCTAssertEqual(BurnBarFleetCadencePolicy.intervalBounds(for: 15), 13...17)

        var schedule = BurnBarFleetCadenceSchedule(startingAt: 1_000_000, cadenceSeconds: 15)
        var currentTick = schedule.nextDeadline
        var intervals: [Double] = []
        for buildDuration in [0.1, 0.3, 1.2, 0.4, 0.8, 0.2, 1.0, 0.6, 0.5, 0.9,
                              0.7, 0.2, 1.1, 0.4, 0.3, 0.8, 0.6, 0.2, 0.9] {
            let completedAt = currentTick + UInt64(buildDuration * 1_000_000_000)
            let nextTick = schedule.deadline(afterBuildAt: completedAt)
            intervals.append(Double(nextTick - currentTick) / 1_000_000_000)
            currentTick = nextTick
        }
        let cumulativeDrift = abs(
            Double(currentTick - 1_000_000) / 1_000_000_000 - 19 * 15
        )
        XCTAssertTrue(intervals.allSatisfy { (13.0...17.0).contains($0) })
        XCTAssertLessThanOrEqual(cumulativeDrift, BurnBarFleetCadencePolicy.toleranceSeconds(for: 15))
    }

    func testOverrideCadence_runsTwentyTicksWithinFormulaWithoutCumulativeDrift() async throws {
        let cadenceSeconds = 1
        let metrics = M6ProbeMetrics()
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: m6Fixture.makeCountingProbes(
                metrics: metrics,
                degradedAgent: .grokBot
            )
        )
        let service = BurnBarFleetService(builder: builder)
        await service.start()
        addTeardownBlock { await service.stop() }

        let snapshots = try await collectSnapshots(
            from: service,
            count: 20,
            timeout: 30
        )
        let intervals = zip(snapshots, snapshots.dropFirst()).map {
            $1.generatedAt.timeIntervalSince($0.generatedAt)
        }
        let bounds = BurnBarFleetCadencePolicy.intervalBounds(for: cadenceSeconds)
        XCTAssertEqual(intervals.count, 19)
        XCTAssertTrue(intervals.allSatisfy { bounds.contains($0) }, "\(intervals)")

        let elapsed = snapshots.last!.generatedAt.timeIntervalSince(
            snapshots.first!.generatedAt
        )
        let expected = Double(snapshots.count - 1) * Double(cadenceSeconds)
        let cumulativeDrift = abs(elapsed - expected)
        let tolerance = BurnBarFleetCadencePolicy.toleranceSeconds(for: cadenceSeconds)
        XCTAssertLessThanOrEqual(
            cumulativeDrift,
            tolerance,
            "intervals=\(intervals), cumulative drift=\(cumulativeDrift)s"
        )

        let output = """
        metric=cadence
        cadence_seconds=\(cadenceSeconds)
        tolerance_formula=max(0.5,2*\(cadenceSeconds)/15)=\(tolerance)
        interval_bounds=\(bounds.lowerBound)...\(bounds.upperBound)
        tick_count=\(snapshots.count)
        interval_min_s=\(intervals.min() ?? 0)
        interval_max_s=\(intervals.max() ?? 0)
        interval_mean_s=\(intervals.reduce(0, +) / Double(max(intervals.count, 1)))
        cumulative_drift_s=\(cumulativeDrift)
        """
        try M6EvidenceWriter.write(output, fileName: "cadence.txt")
        print(output)
    }

    func testDefaultCadence_runsRealTickerWithinDocumentedWindow() async throws {
        let cadenceSeconds = BurnBarFleetCadencePolicy.defaultCadenceSeconds
        let metrics = M6ProbeMetrics()
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: m6Fixture.makeCountingProbes(
                metrics: metrics,
                degradedAgent: .grokBot
            )
        )
        let service = BurnBarFleetService(builder: builder)
        await service.start()
        addTeardownBlock { await service.stop() }

        let snapshots = try await collectSnapshots(
            from: service,
            count: 3,
            timeout: 40
        )
        let intervals = zip(snapshots, snapshots.dropFirst()).map {
            $1.generatedAt.timeIntervalSince($0.generatedAt)
        }
        let bounds = BurnBarFleetCadencePolicy.intervalBounds(for: cadenceSeconds)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertTrue(intervals.allSatisfy { bounds.contains($0) }, "\(intervals)")

        let elapsed = snapshots.last!.generatedAt.timeIntervalSince(
            snapshots.first!.generatedAt
        )
        let expected = Double(snapshots.count - 1) * Double(cadenceSeconds)
        let cumulativeDrift = abs(elapsed - expected)
        let tolerance = BurnBarFleetCadencePolicy.toleranceSeconds(for: cadenceSeconds)
        XCTAssertLessThanOrEqual(
            cumulativeDrift,
            tolerance,
            "intervals=\(intervals), cumulative drift=\(cumulativeDrift)s"
        )

        let output = """
        metric=cadence-default-real
        cadence_seconds=\(cadenceSeconds)
        tolerance_formula=max(0.5,2*\(cadenceSeconds)/15)=\(tolerance)
        interval_bounds=\(bounds.lowerBound)...\(bounds.upperBound)
        tick_count=\(snapshots.count)
        interval_min_s=\(intervals.min() ?? 0)
        interval_max_s=\(intervals.max() ?? 0)
        interval_mean_s=\(intervals.reduce(0, +) / Double(max(intervals.count, 1)))
        cumulative_drift_s=\(cumulativeDrift)
        """
        try M6EvidenceWriter.write(output, fileName: "cadence-default-real.txt")
        print(output)
    }

    private func collectSnapshots(
        from service: BurnBarFleetService,
        count: Int,
        timeout: TimeInterval
    ) async throws -> [BurnBarFleetSnapshot] {
        let deadline = Date().addingTimeInterval(timeout)
        var snapshots: [BurnBarFleetSnapshot] = []
        var lastGeneratedAt: Date?
        while snapshots.count < count, Date() < deadline {
            if case .ready(let snapshot) = await service.readLatestSnapshot(),
               lastGeneratedAt.map({ snapshot.generatedAt > $0 }) ?? true {
                snapshots.append(snapshot)
                lastGeneratedAt = snapshot.generatedAt
            } else {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard snapshots.count == count else {
            throw BurnBarFleetTestTimeoutError.deadlineExceeded(
                operation: "cadence tick collection (\(snapshots.count)/\(count) ticks)",
                timeout: timeout
            )
        }
        return snapshots
    }
}
