import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Stub probe returning a fixed row, used to seed the fleet service with
/// deterministic content for RPC tests.
private struct FixedProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID
    let rootPath: String
    let agent: BurnBarFleetAgent

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        BurnBarFleetProbeResult(
            agent: agent,
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }
}

/// Probe that blocks until released, holding the first tick open so the
/// pre-first-tick typed RPC behavior is observable.
private final class GateProbe: BurnBarFleetProbe, @unchecked Sendable {
    let agentID: BurnBarFleetAgentID
    let rootPath: String
    private let gate = DispatchSemaphore(value: 0)

    init(agentID: BurnBarFleetAgentID, rootPath: String) {
        self.agentID = agentID
        self.rootPath = rootPath
    }

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        gate.wait()
        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: .unknown,
            confidence: .unsupported
        )
        return BurnBarFleetProbeResult(
            agent: agent,
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }

    func release() {
        gate.signal()
    }
}

final class BurnBarFleetServerRPCTests: XCTestCase {
    private func makeProbes(
        runningAgent: BurnBarFleetAgent? = nil
    ) -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = "/tmp/fixture-roots/\(BurnBarFleetRootResolver.rootDirectoryName(for: agentID))"
            let agent: BurnBarFleetAgent
            if let runningAgent, runningAgent.id == agentID {
                agent = runningAgent
            } else {
                agent = BurnBarFleetAgent(
                    id: agentID,
                    displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                    status: .unknown,
                    confidence: .unsupported
                )
            }
            probes[agentID] = FixedProbe(agentID: agentID, rootPath: rootPath, agent: agent)
        }
        return probes
    }

    private func makeFleetService(
        cadenceSeconds: Int = 15,
        runningAgent: BurnBarFleetAgent? = nil
    ) -> BurnBarFleetService {
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: makeProbes(runningAgent: runningAgent)
        )
        return BurnBarFleetService(builder: builder)
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/burnbar-daemon-fleet-rpc-\(name)-\(UUID().uuidString).sock"
    }

    // MARK: - VAL-RPC-001: versioned envelope with typed result

    func testFleetSnapshot_returnsVersionedEnvelopeWithTypedResult() async throws {
        let socketPath = makeSocketPath(name: "snapshot")
        let runningAgent = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .exactProcess,
            projectName: "/Users/test/RepoA",
            signals: [BurnBarFleetSignalSource(kind: "session-registry", path: "/fixture/claude/sessions/1.json")]
        )
        let fleetService = makeFleetService(cadenceSeconds: 15, runningAgent: runningAgent)
        // Pre-build so the first RPC read is deterministically ready (the
        // ticker would otherwise race the request).
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath, socketAuthToken: fleetTestAuthToken, startsMissionControlBackgroundLoops: false),
            fleetService: fleetService
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let response: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "fleet-1",
                method: .fleetSnapshot,
                params: BurnBarFleetSnapshotRequest()
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.id, "fleet-1")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.error)
        let snapshot = try XCTUnwrap(response.result?.snapshot)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.cadenceSeconds, 15)
        XCTAssertEqual(snapshot.agents.count, 10)
        XCTAssertEqual(snapshot.probeHealth.count, 10)
        XCTAssertEqual(snapshot.runningCount, 1)
        XCTAssertEqual(snapshot.countsByAgent["claude-code"], 1)
        let claude = try XCTUnwrap(snapshot.agents.first { $0.id == .claudeCode })
        XCTAssertEqual(claude.status, .running)
        XCTAssertEqual(claude.confidence, .exactProcess)
        XCTAssertEqual(claude.projectName, "/Users/test/RepoA")
        XCTAssertEqual(snapshot.persistenceHealth, .ok)
    }

    // MARK: - VAL-FLEET-018: pre-first-tick typed behavior over RPC

    func testFleetSnapshot_preFirstTick_typedNotReadyError() async throws {
        let socketPath = makeSocketPath(name: "pre-tick")
        let gate = GateProbe(agentID: .claudeCode, rootPath: "/fixture/claude")
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            if agentID == .claudeCode {
                probes[agentID] = gate
            } else {
                probes[agentID] = FixedProbe(
                    agentID: agentID,
                    rootPath: "/fixture/\(agentID.wireValue)",
                    agent: BurnBarFleetAgent(
                        id: agentID,
                        displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                        status: .unknown,
                        confidence: .unsupported
                    )
                )
            }
        }
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: probes)
        let fleetService = BurnBarFleetService(builder: builder)
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath, socketAuthToken: fleetTestAuthToken, startsMissionControlBackgroundLoops: false),
            fleetService: fleetService
        )
        try await server.start()
        defer { Task { await server.stop() } }

        // The first tick is blocked on the gate probe, so the read must be
        // typed not-ready — never a fabricated empty snapshot.
        let response: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "fleet-pre",
                method: .fleetSnapshot,
                params: BurnBarFleetSnapshotRequest()
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.id, "fleet-pre")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32603)
        XCTAssertEqual(
            response.error?.message.contains("not ready"),
            true,
            "pre-first-tick error must be typed not-ready, got: \(response.error?.message ?? "nil")"
        )

        // Release the gate: the next read serves a real snapshot.
        gate.release()
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        var readyResponse: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let attempt: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "fleet-after",
                    method: .fleetSnapshot,
                    params: BurnBarFleetSnapshotRequest()
                ),
                socketPath: socketPath
            )
            if attempt.result?.snapshot != nil {
                readyResponse = attempt
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let ready = try XCTUnwrap(readyResponse, "snapshot never became ready after gate release")
        XCTAssertNil(ready.error)
        XCTAssertEqual(ready.result?.snapshot.agents.count, 10)
    }

    // MARK: - VAL-FLEET-025: configured cadence reflected over RPC

    func testFleetSnapshot_cadenceOverrideReflected() async throws {
        let socketPath = makeSocketPath(name: "cadence")
        let fleetService = makeFleetService(cadenceSeconds: 3)
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath, socketAuthToken: fleetTestAuthToken, startsMissionControlBackgroundLoops: false),
            fleetService: fleetService
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let response: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "fleet-cadence",
                method: .fleetSnapshot,
                params: BurnBarFleetSnapshotRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(response.result?.snapshot.cadenceSeconds, 3)
    }

    // MARK: - Server keeps serving after fleet calls

    func testFleetSnapshot_healthStillServed() async throws {
        let socketPath = makeSocketPath(name: "health-after-fleet")
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath, socketAuthToken: fleetTestAuthToken, startsMissionControlBackgroundLoops: false),
            fleetService: fleetService
        )
        try await server.start()
        defer { Task { await server.stop() } }

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "fleet-1",
                method: .fleetSnapshot,
                params: BurnBarFleetSnapshotRequest()
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>

        let health: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "health-1", method: .health),
            socketPath: socketPath
        )
        XCTAssertEqual(health.result?.ok, true)
    }

    // MARK: - Socket helpers (mirrors BurnBarDaemonServerTests)

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendFleetEnvelope(envelope, socketPath: socketPath)
    }
}
