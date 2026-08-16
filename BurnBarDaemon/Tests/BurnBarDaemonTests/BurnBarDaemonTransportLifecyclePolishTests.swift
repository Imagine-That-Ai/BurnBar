import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

final class BurnBarDaemonTransportLifecyclePolishTests: BurnBarFleetRPCTestCase {
    func testSplitDispatcher_preservesRepresentativeRPCRoutes() async throws {
        let configuration = makeConfiguration(name: "dispatch-polish")
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        let health = try decodeErrorEnvelope(
            rawRequest(
                #"{"id":"dispatch-health","method":"daemon.health"}"#,
                socketPath: configuration.socketPath
            )
        )
        XCTAssertNil(health.error)
        XCTAssertEqual(health.id, "dispatch-health")

        let catalog = try decodeErrorEnvelope(
            rawRequest(
                #"{"id":"dispatch-catalog","method":"daemon.catalog"}"#,
                socketPath: configuration.socketPath
            )
        )
        XCTAssertNil(catalog.error)
        XCTAssertEqual(catalog.id, "dispatch-catalog")

        let fleet = try rawRequest(
            #"{"id":"dispatch-fleet","method":"daemon.fleet.snapshot"}"#,
            socketPath: configuration.socketPath
        )
        let fleetEnvelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
            from: Data(fleet.utf8)
        )
        XCTAssertEqual(fleetEnvelope.id, "dispatch-fleet")
        XCTAssertNotNil(fleetEnvelope.result?.snapshot)
    }

    func testIdleClients_areTrackedAndClosedAfterReadDeadline() async throws {
        let configuration = makeConfiguration(name: "idle-cleanup")
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        var clientFileDescriptors: [Int32] = []
        for _ in 0..<12 {
            clientFileDescriptors.append(
                try connectSocket(socketPath: configuration.socketPath)
            )
        }
        defer {
            clientFileDescriptors.forEach { close($0) }
        }

        let acceptedDeadline = Date().addingTimeInterval(2)
        while Date() < acceptedDeadline {
            if await server.trackedClientConnectionCount == clientFileDescriptors.count,
               await server.trackedClientTaskCount == clientFileDescriptors.count {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let acceptedClientCount = await server.trackedClientConnectionCount
        let trackedTaskCount = await server.trackedClientTaskCount
        XCTAssertEqual(
            acceptedClientCount,
            clientFileDescriptors.count,
            "every accepted idle client must be tracked by descriptor"
        )
        XCTAssertEqual(
            trackedTaskCount,
            clientFileDescriptors.count,
            "every accepted idle client must be tracked by task"
        )

        let cleanupDeadline = Date().addingTimeInterval(3)
        while Date() < cleanupDeadline {
            if await server.trackedClientConnectionCount == 0,
               await server.trackedClientTaskCount == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let remainingClientCount = await server.trackedClientConnectionCount
        let remainingTaskCount = await server.trackedClientTaskCount
        XCTAssertEqual(remainingClientCount, 0)
        XCTAssertEqual(remainingTaskCount, 0)
    }

    func testStopStart_waitsForCancelledTickerBeforeStartingNextBuild() async throws {
        let state = LifecycleProbeState()
        let probes = BurnBarFleetAgentID.declaredRoster.reduce(
            into: [BurnBarFleetAgentID: any BurnBarFleetProbe]()
        ) { probes, agentID in
            probes[agentID] = LifecycleProbe(agentID: agentID, state: state)
        }
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(cadenceSeconds: 60, probes: probes)
        )
        addTeardownBlock {
            await state.releaseFirstProbe()
            await service.stop()
        }

        await service.start()
        try await waitUntil(timeout: 2) {
            await state.firstProbeEntered
        }

        let stopFinished = LifecycleProbeState()
        let stopTask = Task {
            await service.stop()
            await stopFinished.markFinished()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopReturnedEarly = await stopFinished.finished
        XCTAssertFalse(
            stopReturnedEarly,
            "stop must await an in-flight cooperative build instead of returning after cancellation"
        )

        await state.releaseFirstProbe()
        await stopTask.value
        let stopFinishedAfterRelease = await stopFinished.finished
        XCTAssertTrue(stopFinishedAfterRelease)

        let callsBeforeRestart = await state.callCount
        await service.start()
        try await waitUntil(timeout: 2) {
            await state.callCount >= callsBeforeRestart + BurnBarFleetAgentID.declaredRoster.count
        }
        await service.stop()

        let maxConcurrent = await state.maxConcurrent
        XCTAssertEqual(
            maxConcurrent,
            1,
            "a rapid stop/start cycle must never overlap cooperative builds"
        )
    }

    func testStartStopOverlap_duringInitialization_doesNotPublishTicker() async throws {
        let state = LifecycleProbeState()
        let initialization = LifecycleInitializationState()
        let probes = BurnBarFleetAgentID.declaredRoster.reduce(
            into: [BurnBarFleetAgentID: any BurnBarFleetProbe]()
        ) { probes, agentID in
            probes[agentID] = LifecycleProbe(agentID: agentID, state: state)
        }
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(cadenceSeconds: 60, probes: probes),
            startInitializationHook: {
                await initialization.waitUntilReleased()
            }
        )

        let startTask = Task { await service.start() }
        try await waitUntil(timeout: 2) {
            await initialization.entered
        }

        let stopTask = Task { await service.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let releasedBeforeUnblock = await initialization.released
        XCTAssertFalse(releasedBeforeUnblock)

        await initialization.release()
        await startTask.value
        await stopTask.value

        let callsAfterStop = await state.callCount
        try await Task.sleep(nanoseconds: 100_000_000)
        let callsAfterSettling = await state.callCount
        XCTAssertEqual(
            callsAfterSettling,
            callsAfterStop,
            "stop must invalidate suspended initialization before it can publish a ticker"
        )
    }

    func testConcurrentStarts_shareOneInitializationAndTicker() async throws {
        let state = LifecycleProbeState()
        let initialization = LifecycleInitializationState()
        let probes = BurnBarFleetAgentID.declaredRoster.reduce(
            into: [BurnBarFleetAgentID: any BurnBarFleetProbe]()
        ) { probes, agentID in
            probes[agentID] = LifecycleProbe(agentID: agentID, state: state)
        }
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(cadenceSeconds: 60, probes: probes),
            startInitializationHook: {
                await initialization.waitUntilReleased()
            }
        )

        let firstStart = Task { await service.start() }
        try await waitUntil(timeout: 2) {
            await initialization.entered
        }
        let secondStart = Task { await service.start() }
        await initialization.release()
        await firstStart.value
        await secondStart.value

        await state.releaseFirstProbe()
        try await waitUntil(timeout: 2) {
            await state.callCount >= BurnBarFleetAgentID.declaredRoster.count
        }
        await service.stop()
        let maxConcurrent = await state.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testServerStartStopOverlap_doesNotPublishDeadAcceptLoop() async throws {
        let configuration = makeConfiguration(name: "start-stop-overlap")
        let initialization = LifecycleInitializationState()
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(
                cadenceSeconds: 60,
                probes: makeProbes()
            ),
            startInitializationHook: {
                await initialization.waitUntilReleased()
            }
        )
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)

        let startTask = Task { try await server.start() }
        try await waitUntil(timeout: 2) {
            await initialization.entered
        }
        let stopTask = Task { await server.stop() }
        await initialization.release()
        try await startTask.value
        await stopTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.socketPath))
        try await server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.socketPath))
        await server.stop()
    }

    func testStop_cancelsBlockedHandlerAndBoundsBlockedResponseWrite() async throws {
        let configuration = makeConfiguration(name: "blocked-write")
        let handlerState = LifecycleHandlerState()
        let service = makeFleetService()
        _ = try await service.buildOnce()
        let server = BurnBarDaemonServer(
            configuration: configuration,
            fleetService: service,
            responseDataOverride: { _ in
                await handlerState.markEntered()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    await handlerState.markCancelled()
                    throw error
                }
                return Data(repeating: 0x78, count: 16 * 1024 * 1024)
            }
        )
        try await server.start()

        let client = try connectSocket(socketPath: configuration.socketPath)
        defer { close(client) }
        try writeAll(
            Data(#"{"id":"blocked","method":"daemon.health"}"#.utf8) + Data([0x0A]),
            to: client
        )
        try await waitUntil(timeout: 2) {
            await handlerState.entered
        }

        let startedAt = Date()
        await server.stop()
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(elapsed, 2, "shutdown must not await an active handler or blocked write indefinitely")
        let handlerCancelled = await handlerState.cancelled
        XCTAssertTrue(handlerCancelled, "shutdown must cancel the active handler task")
        let trackedConnections = await server.trackedClientConnectionCount
        XCTAssertEqual(trackedConnections, 0)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition did not become true within \(timeout)s")
    }
}

private actor LifecycleInitializationState {
    private(set) var entered = false
    private(set) var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        entered = true
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LifecycleHandlerState {
    private(set) var entered = false
    private(set) var cancelled = false

    func markEntered() {
        entered = true
    }

    func markCancelled() {
        cancelled = true
    }
}

private actor LifecycleProbeState {
    private(set) var callCount = 0
    private(set) var maxConcurrent = 0
    private(set) var firstProbeEntered = false
    private(set) var finished = false

    private var activeProbes = 0
    private var firstProbeContinuation: CheckedContinuation<Void, Never>?
    private var firstProbeReleased = false

    func beginProbe() -> Bool {
        callCount += 1
        activeProbes += 1
        maxConcurrent = max(maxConcurrent, activeProbes)
        if callCount == 1 {
            firstProbeEntered = true
            return true
        }
        return false
    }

    func waitForFirstProbeRelease() async {
        if firstProbeReleased {
            return
        }
        await withCheckedContinuation { continuation in
            if firstProbeReleased {
                continuation.resume()
            } else {
                firstProbeContinuation = continuation
            }
        }
    }

    func releaseFirstProbe() {
        firstProbeReleased = true
        firstProbeContinuation?.resume()
        firstProbeContinuation = nil
    }

    func endProbe() {
        activeProbes -= 1
    }

    func markFinished() {
        finished = true
    }
}

private struct LifecycleProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID
    let state: LifecycleProbeState

    var rootPath: String {
        "/tmp/burnbar-lifecycle-polish/\(agentID.wireValue)"
    }

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        let shouldBlock = await state.beginProbe()
        if shouldBlock {
            await state.waitForFirstProbeRelease()
        }
        await state.endProbe()

        return BurnBarFleetProbeResult(
            agent: BurnBarFleetAgent(
                id: agentID,
                displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
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
