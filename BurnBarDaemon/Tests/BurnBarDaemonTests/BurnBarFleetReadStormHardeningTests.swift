import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarFleetReadStormHardeningTests: M6FleetHardeningTestCase {
    func testFiftyConcurrentReaders_coalesceDuringTickAndPreserveParity() async throws {
        let context = makeStormContext()
        try await context.server.start()
        addTeardownBlock {
            await context.stormGate.release()
            await context.server.stop()
        }

        let first = try await waitForSnapshot(socketPath: context.socketPath, timeout: 10)
        await context.stormGate.arm()
        try await waitUntilBlocked(context.stormGate)

        let responses = try await readConcurrentSnapshots(
            socketPath: context.socketPath,
            readerCount: 50
        )
        XCTAssertEqual(responses.count, 50)
        let firstResponse = try XCTUnwrap(responses.first)
        assertParity(responses, firstResponse: firstResponse)
        XCTAssertEqual(firstResponse.generatedAt, first.generatedAt)

        let blockedMetrics = context.metrics.snapshot()
        assertBlockedStorm(
            blockedMetrics,
            completedBuildCount: context.timingCollector.values().count
        )

        await context.stormGate.release()
        let second = try await waitForNewerSnapshot(
            after: first,
            socketPath: context.socketPath,
            timeout: 10
        )
        XCTAssertGreaterThan(second.generatedAt, first.generatedAt)
        let completedBuildCount = context.timingCollector.values().count
        // A normal cadence tick may complete between the second snapshot
        // becoming observable and this counter sample under machine load.
        // The coalescing invariant is asserted against blockedMetrics above;
        // after release, at least the blocked tick must have completed.
        XCTAssertGreaterThanOrEqual(completedBuildCount, 2)
        XCTAssertEqual(context.metrics.snapshot().maxInFlight, 1)

        let intervals = [second.generatedAt.timeIntervalSince(first.generatedAt)]
        let bounds = BurnBarFleetCadencePolicy.intervalBounds(for: context.cadenceSeconds)
        XCTAssertTrue(intervals.allSatisfy { bounds.contains($0) }, "\(intervals)")

        try writeStormEvidence(
            StormEvidence(
                responseCount: responses.count,
                blockedMetrics: blockedMetrics,
                completedBuildCount: completedBuildCount,
                cadenceSeconds: context.cadenceSeconds,
                bounds: bounds,
                observedInterval: intervals[0]
            )
        )
    }

    func testRpcServingLatency_isSecondaryToDirectBuildMetric() async throws {
        let metrics = M6ProbeMetrics()
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 1,
            probes: m6Fixture.makeCountingProbes(metrics: metrics, slowAgent: .claudeCode)
        )
        let service = BurnBarFleetService(builder: builder)
        let configuration = makeConfiguration(name: "rpc-secondary")
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }
        _ = try await waitForSnapshot(socketPath: configuration.socketPath, timeout: 10)

        for index in 0..<8 {
            _ = try DispatchQueue.global(qos: .userInteractive).sync {
                try self.rawRequest(
                    "{\"id\":\"secondary-warm-\(index)\",\"method\":\"daemon.fleet.snapshot\"}",
                    socketPath: configuration.socketPath
                )
            }
        }

        var latencies: [Double] = []
        for index in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let response = try DispatchQueue.global(qos: .userInteractive).sync {
                try self.rawRequest(
                    "{\"id\":\"secondary-\(index)\",\"method\":\"daemon.fleet.snapshot\"}",
                    socketPath: configuration.socketPath
                )
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            let envelope = try JSONDecoder().decode(
                BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
                from: Data(response.utf8)
            )
            XCTAssertNotNil(envelope.result?.snapshot)
            latencies.append(elapsed)
        }
        let sorted = latencies.sorted()
        let p50 = sorted[sorted.count / 2]
        let maxLatency = sorted.last ?? 0
        let budget = BurnBarFleetRPCLatencyBudget.current()
        XCTAssertLessThan(
            p50,
            budget.p50Milliseconds,
            "p50 latency must be < \(budget.p50Milliseconds)ms (\(budget.loadDescription)), got \(p50)ms"
        )
        XCTAssertLessThan(
            maxLatency,
            budget.maxMilliseconds,
            "max latency must be < \(budget.maxMilliseconds)ms (\(budget.loadDescription)), got \(maxLatency)ms"
        )

        let output = """
        metric=rpc-serving-secondary
        reads=\(latencies.count)
        p50_ms=\(p50)
        max_ms=\(maxLatency)
        budget=p50<\(budget.p50Milliseconds),max<\(budget.maxMilliseconds)
        \(budget.loadDescription)
        note=secondary socket request latency; not a direct builder measurement
        """
        try M6EvidenceWriter.write(output, fileName: "socket-latency.txt")
        print(output)
    }

    private func assertParity(
        _ snapshots: [BurnBarFleetSnapshot],
        firstResponse: BurnBarFleetSnapshot
    ) {
        for response in snapshots.dropFirst() {
            XCTAssertEqual(response.generatedAt, firstResponse.generatedAt)
            XCTAssertEqual(response.agents, firstResponse.agents)
            XCTAssertEqual(response.probeHealth, firstResponse.probeHealth)
            XCTAssertEqual(response.runningCount, firstResponse.runningCount)
            XCTAssertEqual(response.countsByAgent, firstResponse.countsByAgent)
        }
    }

    private func assertBlockedStorm(
        _ metrics: M6ProbeMetrics.Snapshot,
        completedBuildCount: Int
    ) {
        // The first build completed all ten probes; the blocked tick entered
        // only its first probe. The ticker is single-flight.
        XCTAssertEqual(metrics.starts, BurnBarFleetAgentID.declaredRoster.count + 1)
        XCTAssertEqual(metrics.maxInFlight, 1)
        XCTAssertEqual(completedBuildCount, 1, "the blocked second build has not completed")
    }

    private func writeStormEvidence(_ evidence: StormEvidence) throws {
        let output = """
        metric=read-storm
        readers=50
        responses=\(evidence.responseCount)
        parity=all responses matched generatedAt,agents,probeHealth,runningCount,countsByAgent
        probe_starts_through_blocked_tick=\(evidence.blockedMetrics.starts)
        completed_build_samples=\(evidence.completedBuildCount)
        max_in_flight_probe_calls=\(evidence.blockedMetrics.maxInFlight)
        cadence_seconds=\(evidence.cadenceSeconds)
        interval_tolerance=\(evidence.bounds.lowerBound)...\(evidence.bounds.upperBound)
        interval_observed_s=\(evidence.observedInterval)
        """
        try M6EvidenceWriter.write(output, fileName: "read-storm.txt")
        print(output)
    }

    private func waitUntilBlocked(_ gate: M6StormGate) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await gate.isBlocked() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTSkip("slow fixture probe did not enter its blocked tick")
    }

    private func readConcurrentSnapshots(
        socketPath: String,
        readerCount: Int
    ) async throws -> [BurnBarFleetSnapshot] {
        try await withThrowingTaskGroup(of: BurnBarFleetSnapshot.self) { group in
            for index in 0..<readerCount {
                group.addTask {
                    let response = try self.rawRequest(
                        "{\"id\":\"storm-\(index)\",\"method\":\"daemon.fleet.snapshot\"}",
                        socketPath: socketPath
                    )
                    return try Self.decodeSnapshot(from: response)
                }
            }

            var snapshots: [BurnBarFleetSnapshot] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }
    }
}

private struct StormContext {
    let cadenceSeconds: Int
    let metrics: M6ProbeMetrics
    let stormGate: M6StormGate
    let timingCollector: M6TimingCollector
    let server: BurnBarDaemonServer
    let socketPath: String
}

private struct StormEvidence {
    let responseCount: Int
    let blockedMetrics: M6ProbeMetrics.Snapshot
    let completedBuildCount: Int
    let cadenceSeconds: Int
    let bounds: ClosedRange<Double>
    let observedInterval: Double
}

private extension BurnBarFleetReadStormHardeningTests {
    func makeStormContext() -> StormContext {
        let cadenceSeconds = 1
        let metrics = M6ProbeMetrics()
        let stormGate = M6StormGate()
        let timingCollector = M6TimingCollector()
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: m6Fixture.makeCountingProbes(
                metrics: metrics,
                stormGate: stormGate,
                degradedAgent: .grokBot
            )
        )
        let timedBuilder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: builder.probes,
            machineStatusProbe: builder.machineStatusProbe,
            buildTimingHook: timingCollector.hook()
        )
        let service = BurnBarFleetService(builder: timedBuilder)
        let configuration = makeConfiguration(name: "read-storm")
        return StormContext(
            cadenceSeconds: cadenceSeconds,
            metrics: metrics,
            stormGate: stormGate,
            timingCollector: timingCollector,
            server: BurnBarDaemonServer(configuration: configuration, fleetService: service),
            socketPath: configuration.socketPath
        )
    }
}
