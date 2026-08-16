import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import GRDB

final class M6TimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []

    func record(_ timing: BurnBarFleetBuildTiming) {
        lock.lock()
        samples.append(timing.elapsedMilliseconds)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func hook() -> BurnBarFleetBuildTimingHook {
        { [self] timing in
            record(timing)
        }
    }
}

final class M6ProbeMetrics: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let starts: Int
        let inFlight: Int
        let maxInFlight: Int
    }

    private let lock = NSLock()
    private var starts = 0
    private var inFlight = 0
    private var maxInFlight = 0

    func begin() {
        lock.lock()
        starts += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        lock.unlock()
    }

    func end() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(starts: starts, inFlight: inFlight, maxInFlight: maxInFlight)
    }
}

actor M6StormGate {
    private var armed = false
    private var blocked = false
    private var released = false

    func arm() {
        armed = true
        blocked = false
        released = false
    }

    func waitIfArmed() async {
        guard armed else { return }
        armed = false
        blocked = true
        while !released {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        blocked = false
        released = false
    }

    func isBlocked() -> Bool {
        blocked
    }

    func release() {
        released = true
    }
}

struct M6CountingProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID
    let rootPath: String
    let metrics: M6ProbeMetrics
    let stormGate: M6StormGate?
    let delayNanoseconds: UInt64
    let isDegraded: Bool

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        metrics.begin()
        defer { metrics.end() }

        if let stormGate {
            await stormGate.waitIfArmed()
        }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let isRunning = agentID == .claudeCode
        let isIdleInfrastructure = agentID == .grokBot
        let status: BurnBarFleetAgentStatus = isRunning
            ? .running
            : (isIdleInfrastructure ? .idle : .unknown)
        let confidence: BurnBarFleetConfidence = isRunning || isIdleInfrastructure
            ? .exactProcess
            : .unsupported
        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: status,
            confidence: confidence,
            currentTask: isRunning ? "M6 hardening fixture" : nil,
            projectName: isRunning ? "/fixture/AgentLens" : nil,
            signals: [
                BurnBarFleetSignalSource(
                    kind: "m6-fixture",
                    path: "\(rootPath)/fixture.signal"
                )
            ]
        )
        return BurnBarFleetProbeResult(
            agent: agent,
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: isDegraded
                    ? .degraded(reason: "M6 fixture root is intentionally degraded")
                    : .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }
}

struct M6FixedFixture {
    let root: URL

    static func make(at root: URL) throws -> M6FixedFixture {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let agentRoot = root.appendingPathComponent(
                BurnBarFleetRootResolver.rootDirectoryName(for: agentID),
                isDirectory: true
            )
            try fileManager.createDirectory(at: agentRoot, withIntermediateDirectories: true)
        }

        try writeProcessFixtures(in: root)
        try writeRegistryFixtures(in: root)
        try writeFileSignalFixtures(in: root)

        return M6FixedFixture(root: root)
    }

    private static func writeProcessFixtures(in root: URL) throws {
        let nowMilliseconds = Int(Date().timeIntervalSince1970 * 1_000)
        let processID = Int(ProcessInfo.processInfo.processIdentifier)
        let claudeSessions = root
            .appendingPathComponent("claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        try writeJSONFixture(
            [
                "pid": processID,
                "sessionId": "m6-fixed-claude",
                "cwd": "/fixture/AgentLens",
                "updatedAt": nowMilliseconds
            ],
            to: claudeSessions.appendingPathComponent("\(processID).json").path
        )

        let grokbotRoot = root.appendingPathComponent("grokbot", isDirectory: true)
        try writeJSONFixture(
            ["pid": processID, "inflightCount": 0],
            to: grokbotRoot.appendingPathComponent("local-exec-daemon.json").path
        )
        try writeJSONFixture(
            ["pid": processID, "at": nowMilliseconds],
            to: grokbotRoot.appendingPathComponent("local-exec-supervisor.json").path
        )
    }

    private static func writeRegistryFixtures(in root: URL) throws {
        let grokRoot = root.appendingPathComponent("grok", isDirectory: true)
        try writeJSONFixture([], to: grokRoot.appendingPathComponent("active_sessions.json").path)

        let hermesRoot = root.appendingPathComponent("hermes", isDirectory: true)
        try writeJSONFixture(
            ["pid": Int(ProcessInfo.processInfo.processIdentifier), "gateway_state": "idle", "active_agents": 0],
            to: hermesRoot.appendingPathComponent("gateway_state.json").path
        )
        try writeJSONFixture([], to: hermesRoot.appendingPathComponent("processes.json").path)

        let factoryRoot = root.appendingPathComponent("factory", isDirectory: true)
        try writeJSONFixture(
            ["invocations": []],
            to: factoryRoot.appendingPathComponent("task-invocations.json").path
        )
        try writeJSONFixture(
            ["processes": []],
            to: factoryRoot.appendingPathComponent("background-processes.json").path
        )
        for directory in ["sessions", "missions", "artifacts"] {
            try FileManager.default.createDirectory(
                at: factoryRoot.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("excluded fixture sentinel".utf8).write(
            to: factoryRoot.appendingPathComponent("artifacts/ignored.txt")
        )
    }

    private static func writeFileSignalFixtures(in root: URL) throws {
        let codexLocks = root.appendingPathComponent(
            "codex/thread-writer-locks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: codexLocks, withIntermediateDirectories: true)
        try Data().write(to: codexLocks.appendingPathComponent("m6.lock"))

        let piSessions = root.appendingPathComponent(
            "pi/agent/sessions/--fixture--AgentLens",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: piSessions, withIntermediateDirectories: true)
        try Data(
            #"{"type":"session","id":"m6-pi","cwd":"/fixture/AgentLens","timestamp":"2026-08-15T00:00:00Z"}"#.utf8
        ).write(to: piSessions.appendingPathComponent("m6.jsonl"))

        let cursorRoot = root.appendingPathComponent("cursor", isDirectory: true)
        try writeJSONFixture(
            ["workerIdsByDisplayName": ["AgentLens @ fixture": "m6-worker"]],
            to: cursorRoot.appendingPathComponent("agent-cli-state.json").path
        )
        let cursorTracking = cursorRoot.appendingPathComponent("ai-tracking", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorTracking, withIntermediateDirectories: true)
        try Data("m6 tracking".utf8).write(to: cursorTracking.appendingPathComponent("tracking.db"))
    }

    var description: String {
        "10 declared roots; synthetic JSON registries, one lock, one transcript, "
            + "one Cursor tracking file; factory/artifacts sentinel explicitly excluded"
    }

    func makeDefaultBuilder(
        cadenceSeconds: Int,
        timingHook: BurnBarFleetBuildTimingHook? = nil
    ) -> BurnBarFleetSnapshotBuilder {
        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": root.path],
            homeDirectory: URL(fileURLWithPath: "/Users/m6-fixture")
        )
        let probes = BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        return BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: probes,
            buildTimingHook: timingHook
        )
    }

    func makeCountingProbes(
        metrics: M6ProbeMetrics,
        stormGate: M6StormGate? = nil,
        slowAgent: BurnBarFleetAgentID? = nil,
        degradedAgent: BurnBarFleetAgentID? = nil
    ) -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        Dictionary(uniqueKeysWithValues: BurnBarFleetAgentID.declaredRoster.map { agentID in
            let agentRoot = root.appendingPathComponent(
                BurnBarFleetRootResolver.rootDirectoryName(for: agentID),
                isDirectory: true
            )
            return (
                agentID,
                M6CountingProbe(
                    agentID: agentID,
                    rootPath: agentRoot.path,
                    metrics: metrics,
                    stormGate: agentID == .claudeCode ? stormGate : nil,
                    delayNanoseconds: agentID == slowAgent ? 150_000_000 : 0,
                    isDegraded: agentID == degradedAgent
                )
            )
        })
    }

}

enum M6SQLiteInspection {
    static func rowCounts(databasePath: String) throws -> (snapshots: Int, events: Int) {
        let queue = try DatabaseQueue(path: databasePath, configuration: {
            var configuration = Configuration()
            configuration.readonly = true
            return configuration
        }())
        defer { try? queue.close() }
        return try queue.read { database in
            let snapshots = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM fleet_snapshots") ?? 0
            let events = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM fleet_events") ?? 0
            return (snapshots, events)
        }
    }
}

extension BurnBarFleetSnapshot {
    func m6ReplacingGeneratedAt(_ generatedAt: Date) -> BurnBarFleetSnapshot {
        BurnBarFleetSnapshot(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: machine,
            agents: agents,
            repos: repos,
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: orchestrator,
            probeHealth: probeHealth,
            persistenceHealth: persistenceHealth
        )
    }
}

enum M6EvidenceWriter {
    static func write(_ contents: String, fileName: String, sourceFilePath: String = #filePath) throws {
        let repositoryRoot = URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let evidenceDirectory = repositoryRoot
            .appendingPathComponent("validation", isDirectory: true)
            .appendingPathComponent("M6-hardening", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try contents.write(
            to: evidenceDirectory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }
}

struct M6TimingStats: Sendable {
    let allValues: [Double]
    let count: Int
    let minMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double

    init(values: [Double]) {
        let sorted = values.sorted()
        allValues = sorted
        count = sorted.count
        minMilliseconds = sorted.first ?? 0
        medianMilliseconds = Self.percentile(sorted, fraction: 0.50)
        p95Milliseconds = Self.percentile(sorted, fraction: 0.95)
        maxMilliseconds = sorted.last ?? 0
    }

    var distributionLine: String {
        allValues.map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(
            sorted.count - 1,
            Int(ceil(fraction * Double(sorted.count))) - 1
        )
        return sorted[max(index, 0)]
    }
}

class M6FleetHardeningTestCase: BurnBarFleetRPCTestCase {
    var m6Fixture: M6FixedFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        m6Fixture = try M6FixedFixture.make(
            at: tempRoots.appendingPathComponent("fixed-fixture", isDirectory: true)
        )
    }
}
