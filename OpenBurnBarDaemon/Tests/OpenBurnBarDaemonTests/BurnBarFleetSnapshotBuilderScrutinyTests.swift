import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarFleetSnapshotBuilderScrutinyTests: XCTestCase {
    func testBuilderRejectsProbeReturningUnexpectedAgentIdentity() async {
        let probes = makeProbes(
            resultAgent: .hermes,
            healthAgent: .claudeCode,
            for: .claudeCode
        )
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: probes)

        do {
            _ = try await builder.build()
            XCTFail("an unexpected probe agent identity must fail the build")
        } catch let error as BurnBarFleetSnapshotBuilderError {
            XCTAssertEqual(
                error,
                .probeReturnedUnexpectedAgent(expected: .claudeCode, actual: .hermes)
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBuilderRejectsProbeReturningUnexpectedHealthIdentity() async {
        let probes = makeProbes(
            resultAgent: .claudeCode,
            healthAgent: .hermes,
            for: .claudeCode
        )
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: probes)

        do {
            _ = try await builder.build()
            XCTFail("an unexpected probe health identity must fail the build")
        } catch let error as BurnBarFleetSnapshotBuilderError {
            XCTAssertEqual(
                error,
                .probeReturnedUnexpectedHealth(expected: .claudeCode, actual: .hermes)
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBuilderRejectsProbeRegisteredOutsideFixedRoster() async {
        var probes = makeProbes()
        probes[.unknown("rogue-agent")] = IdentityProbe(
            resultAgent: .unknown("rogue-agent"),
            healthAgent: .unknown("rogue-agent")
        )
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: probes)

        do {
            _ = try await builder.build()
            XCTFail("a probe outside the declared roster must fail the build")
        } catch let error as BurnBarFleetSnapshotBuilderError {
            XCTAssertEqual(error, .probeRegisteredOutsideRoster(.unknown("rogue-agent")))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTickerSurfacesBuilderValidationFailureAsCurrentTickDegradation() async throws {
        let probes = makeProbes(
            resultAgent: .hermes,
            healthAgent: .claudeCode,
            for: .claudeCode
        )
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        )
        await service.start()
        defer { Task { await service.stop() } }

        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if case .degraded(let reason, let previousSnapshot) = await service.readLatestSnapshot() {
                XCTAssertTrue(reason.contains("claude-code"))
                XCTAssertNil(previousSnapshot)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("ticker did not surface the builder validation failure")
    }

    private func makeProbes(
        resultAgent: BurnBarFleetAgentID? = nil,
        healthAgent: BurnBarFleetAgentID? = nil,
        for target: BurnBarFleetAgentID? = nil
    ) -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            probes[agentID] = IdentityProbe(
                resultAgent: agentID == target ? (resultAgent ?? agentID) : agentID,
                healthAgent: agentID == target ? (healthAgent ?? agentID) : agentID
            )
        }
        return probes
    }
}

private struct IdentityProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID = .unknown("test")
    let rootPath = ""
    let resultAgent: BurnBarFleetAgentID
    let healthAgent: BurnBarFleetAgentID

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        BurnBarFleetProbeResult(
            agent: BurnBarFleetAgent(
                id: resultAgent,
                displayName: BurnBarFleetSnapshotBuilder.displayName(for: resultAgent),
                status: .unknown,
                confidence: .unsupported
            ),
            health: BurnBarFleetProbeHealth(
                agent: healthAgent,
                state: .ok,
                rootPath: "",
                checkedAt: now
            )
        )
    }
}
