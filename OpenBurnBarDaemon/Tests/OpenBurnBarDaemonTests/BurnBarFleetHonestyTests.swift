import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarFleetHonestyTests: XCTestCase {
    func test_unreadServiceIsNotReadyNotEmpty() async {
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: [:])
        let service = BurnBarFleetService(builder: builder)
        let state = await service.readLatestSnapshot()
        guard case .notReady = state else {
            XCTFail("pre-first-tick must be notReady, got \(String(describing: state))")
            return
        }
    }

    func test_builderWithoutProbesEmitsTenNonRunningRosterRows() async throws {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: [:])
        let snapshot = try await builder.build(
            now: now,
            orchestrator: BurnBarOrchestratorState(designation: .none),
            persistenceHealth: .ok
        )

        XCTAssertEqual(snapshot.agents.count, 10)
        XCTAssertEqual(snapshot.probeHealth.count, 10)
        XCTAssertEqual(Set(snapshot.agents.map(\.id)), Set(BurnBarFleetAgentID.declaredRoster))
        XCTAssertEqual(snapshot.runningCount, 0)
        XCTAssertTrue(snapshot.agents.allSatisfy { $0.status != .running })
        XCTAssertTrue(snapshot.agents.allSatisfy { $0.confidence == .unsupported })
        XCTAssertEqual(snapshot.cadenceSeconds, 15)
    }

    func test_builderRejectsProbeOutsideRoster() async {
        let rogue = BurnBarFleetAgentID.unknown("aider")
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 15,
            probes: [rogue: StubFleetProbe(agentID: rogue)]
        )
        do {
            _ = try await builder.build(now: Date())
            XCTFail("expected probeRegisteredOutsideRoster")
        } catch let error as BurnBarFleetSnapshotBuilderError {
            XCTAssertEqual(error, .probeRegisteredOutsideRoster(rogue))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

}

private struct StubFleetProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID
    var rootPath: String { "/tmp/\(agentID.wireValue)" }

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        BurnBarFleetProbeResult(
            agent: BurnBarFleetAgent(
                id: agentID,
                displayName: agentID.wireValue,
                status: .unknown,
                confidence: .unsupported
            ),
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }
}
