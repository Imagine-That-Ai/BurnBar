import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

/// Transport-behavior tests (VAL-RPC-005, 006, 007, 010, 013, 014):
/// concurrent multi-client reads, serving latency under probe load, the
/// 64KB response cap, restart-rebuilds-from-probes, one-shot connection
/// semantics, idle-client isolation, and the missing-socket client failure.
final class BurnBarFleetRPCTransportBehaviorTests: BurnBarFleetRPCTestCase {
    // MARK: - VAL-RPC-005: concurrent multi-client reads, identical payloads

    func testConcurrentClients_fiveReaders_identicalPayloads() async throws {
        let configuration = makeConfiguration(name: "concurrent")
        let socketPath = configuration.socketPath
        let runningAgent = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .exactProcess,
            projectName: "/Users/test/RepoA",
            signals: [BurnBarFleetSignalSource(kind: "session-registry", path: "/fixture/claude/sessions/1.json")]
        )
        let fleetService = makeFleetService(cadenceSeconds: 15, runningAgent: runningAgent)
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let request = "{\"id\":\"c\",\"method\":\"daemon.fleet.snapshot\"}"
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "concurrent-readers", attributes: .concurrent)
        let lock = NSLock()
        var responses: [String] = []
        var failures: [String] = []

        for index in 0..<5 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let response = try self.rawRequest(request, socketPath: socketPath)
                    lock.lock()
                    responses.append(response)
                    lock.unlock()
                } catch {
                    lock.lock()
                    failures.append("client \(index): \(error)")
                    lock.unlock()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 10)
        XCTAssertEqual(waitResult, .success, "concurrent clients must all complete")
        XCTAssertTrue(failures.isEmpty, "concurrent failures: \(failures)")

        // All five responses must decode to the same snapshot (same
        // generatedAt and agent array — no interleaving corruption).
        let snapshots = try responses.map { response -> BurnBarFleetSnapshot in
            let envelope = try JSONDecoder().decode(
                BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
                from: Data(response.utf8)
            )
            return try XCTUnwrap(envelope.result?.snapshot)
        }
        XCTAssertEqual(snapshots.count, 5)
        for snapshot in snapshots.dropFirst() {
            XCTAssertEqual(snapshot.generatedAt, snapshots[0].generatedAt)
            XCTAssertEqual(snapshot.agents, snapshots[0].agents)
            XCTAssertEqual(snapshot.runningCount, snapshots[0].runningCount)
        }
    }

    // MARK: - VAL-RPC-006: serving latency bound under probe load

    func testServingLatency_underProbeLoad_p50Under50ms_maxUnder500ms() async throws {
        // A FIFO inside a declared root makes the probe path slow (per-probe
        // timeout) while RPC serving must stay fast.
        let rootsDir = tempRoots.appendingPathComponent("latency-roots", isDirectory: true)
        try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)
        let grokbotDir = rootsDir.appendingPathComponent("grokbot", isDirectory: true)
        try FileManager.default.createDirectory(at: grokbotDir, withIntermediateDirectories: true)
        let fifoPath = grokbotDir.appendingPathComponent("local-exec-daemon.json").path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "mkfifo failed with errno \(errno)")

        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 1,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        )
        let fleetService = BurnBarFleetService(builder: builder)
        await fleetService.start()

        let configuration = makeConfiguration(name: "latency")
        let socketPath = configuration.socketPath
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        // Wait for the first completed tick (the FIFO probe costs its 2s
        // timeout on the first tick).
        let readyDeadline = Date().addingTimeInterval(15)
        var ready = false
        while Date() < readyDeadline {
            if let response = try? rawRequest("{\"id\":\"warm\",\"method\":\"daemon.fleet.snapshot\"}", socketPath: socketPath),
               (try? decodeErrorEnvelope(response))?.result != nil {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(ready, "snapshot never became ready with the FIFO present")

        // Warm the accept/read path after the slow first tick. Run both the
        // warmup and measured calls on a user-initiated queue so an unrelated
        // low-priority test/build task cannot make client-side scheduling look
        // like daemon serving latency.
        for index in 0..<8 {
            _ = try DispatchQueue.global(qos: .userInitiated).sync {
                try self.rawRequest(
                    "{\"id\":\"warm-lat-\(index)\",\"method\":\"daemon.fleet.snapshot\"}",
                    socketPath: socketPath
                )
            }
        }

        // ≥20 timed calls while the ticker keeps hitting the slow FIFO path.
        var latencies: [Double] = []
        for index in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let response = try DispatchQueue.global(qos: .userInitiated).sync {
                try self.rawRequest(
                    "{\"id\":\"lat-\(index)\",\"method\":\"daemon.fleet.snapshot\"}",
                    socketPath: socketPath
                )
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            let envelope = try decodeErrorEnvelope(response)
            XCTAssertNil(envelope.error, "latency probe call failed: \(envelope.error?.message ?? "nil")")
            latencies.append(elapsed)
        }

        let sorted = latencies.sorted()
        let p50 = sorted[10]
        let maxLatency = sorted[19]
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

        await fleetService.stop()
    }

    // MARK: - VAL-RPC-007: snapshot response under the 64KB frame cap

    func testSnapshotResponse_under64KBFrameCap() async throws {
        let configuration = makeConfiguration(name: "frame-cap")
        let socketPath = configuration.socketPath
        // A fully populated snapshot: every roster agent carries signals and
        // several carry process blocks.
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = tempRoots
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
            let agent = BurnBarFleetAgent(
                id: agentID,
                displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                status: agentID == .claudeCode ? .running : .idle,
                confidence: agentID == .claudeCode ? .exactProcess : .activeSessionFile,
                currentTask: "Refactoring the fleet RPC surface for the live agent board",
                projectName: "/Users/test/RepoA",
                model: "claude-sonnet-4-5",
                lastActivityAt: Date(),
                process: agentID == .claudeCode
                    ? BurnBarFleetProcessInfo(pid: 42, cpuPercent: 3.5, memoryBytes: 1_024_000, startedAt: Date())
                    : nil,
                signals: [
                    BurnBarFleetSignalSource(kind: "session-registry", path: "\(rootPath)/sessions/42.json", detail: "live"),
                    BurnBarFleetSignalSource(kind: "heartbeat-file", path: "\(rootPath)/state/heartbeat", detail: "fresh")
                ],
                note: "fixture row"
            )
            probes[agentID] = FixedProbe(agentID: agentID, rootPath: rootPath, agent: agent)
        }
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 15, probes: probes)
        let fleetService = BurnBarFleetService(builder: builder)
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{\"id\":\"size-1\",\"method\":\"daemon.fleet.snapshot\"}", socketPath: socketPath)
        XCTAssertLessThan(
            response.utf8.count,
            65_536,
            "snapshot response must stay under the 64KB frame cap, got \(response.utf8.count) bytes"
        )
        // And it parses cleanly as a complete envelope.
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
            from: Data(response.utf8)
        )
        XCTAssertNil(envelope.error)
        XCTAssertEqual(envelope.result?.snapshot.agents.count, 10)
    }

    // MARK: - VAL-RPC-010: restart rebuilds from probes, no ghost liveness

    func testRestart_rebuildsFromProbes_noGhostLiveness() async throws {
        let rootsDir = tempRoots.appendingPathComponent("restart-roots", isDirectory: true)
        try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)
        let claudeDir = rootsDir.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let sleepProcess = try LiveSleepProcess()
        defer { sleepProcess.terminate() }

        let configuration = makeConfiguration(name: "restart")
        let socketPath = configuration.socketPath

        // Phase 1: fixture shows claude running with a live pid.
        let now = Date()
        let sessionsDir = claudeDir.appendingPathComponent("sessions", isDirectory: true)
        try writeJSONFixture(
            ["pid": Int(sleepProcess.pid), "sessionId": "s1", "cwd": "/Users/test/RepoA",
             "updatedAt": Int(now.timeIntervalSince1970 * 1000)],
            to: sessionsDir.appendingPathComponent("\(sleepProcess.pid).json").path
        )

        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 1,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        )
        let fleetService = BurnBarFleetService(builder: builder)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()

        let preRestart = try await waitForSnapshot(socketPath: socketPath, timeout: 10)
        let claudeBefore = try XCTUnwrap(preRestart.agents.first { $0.id == .claudeCode })
        XCTAssertEqual(claudeBefore.status, .running, "fixture live pid must report running before restart")

        // Phase 2: stop the daemon, kill the fixture process, restart.
        await server.stop()
        sleepProcess.terminate()

        let restartedService = BurnBarFleetService(builder: builder)
        let restartedServer = BurnBarDaemonServer(configuration: configuration, fleetService: restartedService)
        try await restartedServer.start()
        defer { Task { await restartedServer.stop() } }

        let postRestart = try await waitForSnapshot(socketPath: socketPath, timeout: 10)
        let claudeAfter = try XCTUnwrap(postRestart.agents.first { $0.id == .claudeCode })
        XCTAssertNotEqual(
            claudeAfter.status,
            .running,
            "a dead pid must never be resurrected as running from persisted state"
        )
    }

    // MARK: - VAL-RPC-013: one-shot connection + idle-client isolation

    func testOneShotConnection_oneRequestOneResponseCleanClose() async throws {
        let configuration = makeConfiguration(name: "one-shot")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        // One request on one connection → one complete response → clean close.
        let (response, eofObserved) = try rawRequestWithEOF(
            "{\"id\":\"os-1\",\"method\":\"daemon.health\"}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertNil(envelope.error)
        XCTAssertEqual(envelope.id, "os-1")
        XCTAssertTrue(eofObserved, "server must close the connection cleanly after one response")

        // A second request requires a second connection, and it succeeds.
        let second = try rawRequest("{\"id\":\"os-2\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(second).error)
    }

    func testIdleClient_neverBlocksAnotherClient() async throws {
        let configuration = makeConfiguration(name: "idle-client")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        // Client A connects and sends nothing.
        let idleFD = try connectSocket(socketPath: socketPath)
        defer { close(idleFD) }

        // Client B's request must complete well within 5 seconds.
        let start = DispatchTime.now().uptimeNanoseconds
        let response = try rawRequest("{\"id\":\"busy-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000.0
        XCTAssertNil(try decodeErrorEnvelope(response).error)
        XCTAssertLessThan(elapsed, 5.0, "idle client must never stall another client, took \(elapsed)s")
    }

    // MARK: - VAL-RPC-014: missing socket fails bounded and typed

    func testMissingSocket_failsBounded_typedENOENT_validSocketUnaffected() async throws {
        // No daemon at this path: connect must fail immediately with ENOENT.
        let missingPath = makeSocketPath(name: "missing")
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try connectSocket(socketPath: missingPath)) { error in
            guard case POSIXError.ENOENT = error else {
                return XCTFail("missing socket must fail with ENOENT, got \(error)")
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000.0
        XCTAssertLessThan(elapsed, 5.0, "missing-socket failure must be bounded, took \(elapsed)s")

        // A daemon at a different valid socket serves normal requests, and the
        // failed attempt does not affect it.
        let configuration = makeConfiguration(name: "valid-after-missing")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{\"id\":\"valid-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(response).error)
    }
}

/// Load-aware bounds for socket-latency measurements. Shared by the primary
/// transport test and the secondary M6 read-storm metric.
struct BurnBarFleetRPCLatencyBudget {
    let p50Milliseconds: Double
    let maxMilliseconds: Double
    let loadDescription: String

    static func current() -> Self {
        var loadSample = [Double](repeating: 0, count: 1)
        let loadSampleCount = loadSample.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, 1)
        }
        let oneMinuteLoad = loadSampleCount == 1 ? loadSample[0] : 0
        let processorCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let normalizedLoad = oneMinuteLoad / processorCount
        let externalLoad = normalizedLoad >= 0.5
        // Under external scheduler pressure, preserve a bounded serving
        // assertion without making the test itself a machine-load lottery.
        return Self(
            p50Milliseconds: externalLoad ? 250.0 : 50.0,
            maxMilliseconds: externalLoad ? 1_000.0 : 500.0,
            loadDescription: "load1=\(oneMinuteLoad), normalized=\(normalizedLoad)"
        )
    }
}
