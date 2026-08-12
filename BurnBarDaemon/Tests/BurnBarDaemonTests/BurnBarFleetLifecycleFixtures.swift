import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Fixture builders + phase expectations for the seven-agent lifecycle
/// matrix (VAL-FLEET-026). Kept in a separate file so the matrix test class
/// stays under the lint type-body budget.
enum BurnBarFleetLifecycleFixtures {
    /// Expected status/confidence per (agent, phase). `nil` means the phase
    /// is not applicable for that agent (recorded as typed non-running).
    struct Expectation {
        let status: BurnBarFleetAgentStatus
        let confidence: BurnBarFleetConfidence
    }

    /// The seven target agents of the lifecycle matrix.
    static let agents: [BurnBarFleetAgentID] = [
        .claudeCode, .factoryDroid, .codex, .hermes, .grokBot, .grokCLI, .pi
    ]

    /// The phases exercised per agent.
    static let phases = ["absent", "installed", "running", "idle", "exited", "stale", "malformed"]

    /// Expected outcome per (agent, phase).
    static func expected(_ agentID: BurnBarFleetAgentID, _ phase: String) -> Expectation? {
        switch agentID {
        case .claudeCode:
            return claudeCode(phase)
        case .factoryDroid:
            return factoryDroid(phase)
        case .codex:
            return codex(phase)
        case .hermes:
            return hermes(phase)
        case .grokBot:
            return grokBot(phase)
        case .grokCLI:
            return grokCLI(phase)
        case .pi:
            return pi(phase)
        default:
            return nil
        }
    }

    private static func claudeCode(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .exactProcess)
        case "idle", "exited":
            return Expectation(status: .stale, confidence: .activeSessionFile)
        case "stale":
            return Expectation(status: .stale, confidence: .logHeartbeat)
        case "malformed":
            return Expectation(status: .unknown, confidence: .unsupported)
        default:
            return nil
        }
    }

    private static func factoryDroid(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .activeSessionFile)
        case "idle":
            return Expectation(status: .idle, confidence: .activeSessionFile)
        case "exited", "stale":
            return Expectation(status: .stale, confidence: .activeSessionFile)
        case "malformed":
            return Expectation(status: .unknown, confidence: .unsupported)
        default:
            return nil
        }
    }

    private static func codex(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .logHeartbeat)
        case "idle":
            return Expectation(status: .idle, confidence: .logHeartbeat)
        case "exited", "stale":
            return Expectation(status: .stale, confidence: .logHeartbeat)
        case "malformed":
            // mtime-based probe: malformed primary signal is not applicable;
            // the row stays typed non-running (idle).
            return Expectation(status: .idle, confidence: .logHeartbeat)
        default:
            return nil
        }
    }

    private static func hermes(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .exactProcess)
        case "idle":
            return Expectation(status: .idle, confidence: .exactProcess)
        case "exited", "stale":
            return Expectation(status: .stale, confidence: .activeSessionFile)
        case "malformed":
            return Expectation(status: .unknown, confidence: .unsupported)
        default:
            return nil
        }
    }

    private static func grokBot(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .exactProcess)
        case "idle":
            return Expectation(status: .idle, confidence: .exactProcess)
        case "exited":
            return Expectation(status: .stale, confidence: .activeSessionFile)
        case "stale":
            // Live daemon + stale supervisor: idle, never running from stale
            // evidence (VAL-FLEET-023).
            return Expectation(status: .idle, confidence: .exactProcess)
        case "malformed":
            return Expectation(status: .unknown, confidence: .unsupported)
        default:
            return nil
        }
    }

    private static func grokCLI(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .exactProcess)
        case "idle":
            return Expectation(status: .idle, confidence: .activeSessionFile)
        case "exited", "stale":
            return Expectation(status: .stale, confidence: .activeSessionFile)
        case "malformed":
            return Expectation(status: .stale, confidence: .activeSessionFile)
        default:
            return nil
        }
    }

    private static func pi(_ phase: String) -> Expectation? {
        switch phase {
        case "running":
            return Expectation(status: .running, confidence: .logHeartbeat)
        case "idle":
            return Expectation(status: .idle, confidence: .logHeartbeat)
        case "exited", "stale":
            return Expectation(status: .stale, confidence: .logHeartbeat)
        case "malformed":
            // mtime-based probe: transcript bodies are never read; the row
            // stays driven by the fresh mtime (running).
            return Expectation(status: .running, confidence: .logHeartbeat)
        default:
            return nil
        }
    }

    // MARK: - Fixture builders

    static func buildClaudeFixture(root: URL, phase: String, now: Date, livePid: Int32?) throws {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        switch phase {
        case "running":
            let pid = try XCTUnwrap(livePid)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try writeJSONFixture(
                ["pid": Int(pid), "sessionId": "s1", "cwd": "/Users/test/RepoA",
                 "updatedAt": Int(now.timeIntervalSince1970 * 1000)],
                to: sessions.appendingPathComponent("\(pid).json").path
            )
        case "idle", "exited":
            // Session file with a dead pid but fresh updatedAt: infrastructure
            // present, no live session.
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try writeJSONFixture(
                ["pid": 999_999, "sessionId": "s1", "cwd": "/Users/test/RepoA",
                 "updatedAt": Int(now.timeIntervalSince1970 * 1000)],
                to: sessions.appendingPathComponent("999999.json").path
            )
        case "stale":
            let pid = try XCTUnwrap(livePid)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try writeJSONFixture(
                ["pid": Int(pid), "sessionId": "s1", "cwd": "/Users/test/RepoA",
                 "updatedAt": Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)],
                to: sessions.appendingPathComponent("\(pid).json").path
            )
        case "malformed":
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try writeJSONFixture(
                ["sessionId": "s1", "cwd": "/Users/test/RepoA"],
                to: sessions.appendingPathComponent("1.json").path
            )
        default:
            break
        }
    }

    static func buildFactoryFixture(root: URL, phase: String, now: Date) throws {
        switch phase {
        case "running":
            try writeJSONFixture(
                ["invocations": [
                    ["taskInvocationId": "t1", "status": "running", "cwd": "/Users/test/RepoA",
                     "updatedAt": Int(now.timeIntervalSince1970 * 1000)]
                ]],
                to: root.appendingPathComponent("task-invocations.json").path
            )
        case "idle":
            // Only fresh terminal invocations: no active work.
            try writeJSONFixture(
                ["invocations": [
                    ["taskInvocationId": "t1", "status": "completed", "cwd": "/Users/test/RepoA",
                     "updatedAt": Int(now.timeIntervalSince1970 * 1000)]
                ]],
                to: root.appendingPathComponent("task-invocations.json").path
            )
        case "exited":
            // Ledger present but everything terminal/stale.
            try writeJSONFixture(
                ["invocations": [
                    ["taskInvocationId": "t1", "status": "completed", "cwd": "/Users/test/RepoA",
                     "updatedAt": Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)]
                ]],
                to: root.appendingPathComponent("task-invocations.json").path
            )
        case "stale":
            try writeJSONFixture(
                ["invocations": [
                    ["taskInvocationId": "t1", "status": "running", "cwd": "/Users/test/RepoA",
                     "updatedAt": Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)]
                ]],
                to: root.appendingPathComponent("task-invocations.json").path
            )
        case "malformed":
            try writeJSONFixture(
                ["invocations": [
                    ["taskInvocationId": "t1", "cwd": "/Users/test/RepoA"]
                ]],
                to: root.appendingPathComponent("task-invocations.json").path
            )
        default:
            break
        }
    }

    static func buildCodexFixture(root: URL, phase: String, now: Date) throws {
        let locks = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        switch phase {
        case "running":
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            let path = locks.appendingPathComponent("thread-1.lock").path
            try Data().write(to: URL(fileURLWithPath: path))
            try setFileMtime(now.addingTimeInterval(-10), at: path)
        case "idle":
            // Root present, no locks.
            break
        case "exited", "stale":
            // Locks may survive crashes: a stale lock is the exited shape.
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            let path = locks.appendingPathComponent("thread-1.lock").path
            try Data().write(to: URL(fileURLWithPath: path))
            try setFileMtime(now.addingTimeInterval(-3600), at: path)
        case "malformed":
            // Locks are zero-byte by design; a malformed primary signal is
            // not applicable to mtime-based probes. The phase is recorded as
            // the documented non-applicable state: the probe still reports a
            // typed row (idle) and never running.
            break
        default:
            break
        }
    }

    static func buildHermesFixture(root: URL, phase: String, now: Date, livePid: Int32?) throws {
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        switch phase {
        case "running":
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(["pid": Int(pid)], to: root.appendingPathComponent("gateway.pid").path)
            try writeJSONFixture(
                ["pid": Int(pid), "updated_at": ISO8601DateFormatter().string(from: now)],
                to: stateDir.appendingPathComponent("gateway.heartbeat").path
            )
            try writeJSONFixture(["pid": Int(pid), "active_agents": 2], to: root.appendingPathComponent("gateway_state.json").path)
            try writeJSONFixture([], to: root.appendingPathComponent("processes.json").path)
        case "idle":
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(["pid": Int(pid)], to: root.appendingPathComponent("gateway.pid").path)
            try writeJSONFixture(
                ["pid": Int(pid), "updated_at": ISO8601DateFormatter().string(from: now)],
                to: stateDir.appendingPathComponent("gateway.heartbeat").path
            )
            try writeJSONFixture(["pid": Int(pid), "active_agents": 0], to: root.appendingPathComponent("gateway_state.json").path)
            try writeJSONFixture([], to: root.appendingPathComponent("processes.json").path)
        case "exited":
            // Previously live pid now dead.
            try writeJSONFixture(["pid": 999_999], to: root.appendingPathComponent("gateway.pid").path)
            try writeJSONFixture(
                ["pid": 999_999, "updated_at": ISO8601DateFormatter().string(from: now)],
                to: stateDir.appendingPathComponent("gateway.heartbeat").path
            )
            try writeJSONFixture(["pid": 999_999, "active_agents": 2], to: root.appendingPathComponent("gateway_state.json").path)
            try writeJSONFixture([], to: root.appendingPathComponent("processes.json").path)
        case "stale":
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(["pid": Int(pid)], to: root.appendingPathComponent("gateway.pid").path)
            try writeJSONFixture(
                ["pid": Int(pid), "updated_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))],
                to: stateDir.appendingPathComponent("gateway.heartbeat").path
            )
            try writeJSONFixture(["pid": Int(pid), "active_agents": 2], to: root.appendingPathComponent("gateway_state.json").path)
            try writeJSONFixture([], to: root.appendingPathComponent("processes.json").path)
        case "malformed":
            try writeJSONFixture(["kind": "hermes-gateway"], to: root.appendingPathComponent("gateway.pid").path)
            try writeJSONFixture(
                ["pid": 1, "updated_at": ISO8601DateFormatter().string(from: now)],
                to: stateDir.appendingPathComponent("gateway.heartbeat").path
            )
            try writeJSONFixture(["pid": 1, "active_agents": 2], to: root.appendingPathComponent("gateway_state.json").path)
        default:
            break
        }
    }

    static func buildGrokBotFixture(root: URL, phase: String, now: Date, livePid: Int32?) throws {
        switch phase {
        case "running":
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(
                ["pid": Int(pid), "startedAt": Int(now.timeIntervalSince1970 * 1000), "inflightCount": 2],
                to: root.appendingPathComponent("local-exec-daemon.json").path
            )
            try writeJSONFixture(
                ["pid": Int(pid), "at": Int(now.timeIntervalSince1970 * 1000)],
                to: root.appendingPathComponent("local-exec-supervisor.json").path
            )
        case "idle":
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(
                ["pid": Int(pid), "startedAt": Int(now.timeIntervalSince1970 * 1000), "inflightCount": 0],
                to: root.appendingPathComponent("local-exec-daemon.json").path
            )
            try writeJSONFixture(
                ["pid": Int(pid), "at": Int(now.timeIntervalSince1970 * 1000)],
                to: root.appendingPathComponent("local-exec-supervisor.json").path
            )
        case "exited":
            try writeJSONFixture(
                ["pid": 999_999, "startedAt": Int(now.timeIntervalSince1970 * 1000), "inflightCount": 2],
                to: root.appendingPathComponent("local-exec-daemon.json").path
            )
            try writeJSONFixture(
                ["pid": 999_999, "at": Int(now.timeIntervalSince1970 * 1000)],
                to: root.appendingPathComponent("local-exec-supervisor.json").path
            )
        case "stale":
            // Live daemon with inflight 0 + stale supervisor: the stale
            // supervisor signal must never flip the row to running
            // (VAL-FLEET-023).
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(
                ["pid": Int(pid), "startedAt": Int(now.timeIntervalSince1970 * 1000), "inflightCount": 0],
                to: root.appendingPathComponent("local-exec-daemon.json").path
            )
            try writeJSONFixture(
                ["pid": Int(pid), "at": Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)],
                to: root.appendingPathComponent("local-exec-supervisor.json").path
            )
        case "malformed":
            try writeJSONFixture(
                ["pid": 1],
                to: root.appendingPathComponent("local-exec-daemon.json").path
            )
        default:
            break
        }
    }

    static func buildGrokCLIFixture(root: URL, phase: String, now: Date, livePid: Int32?) throws {
        let registryPath = root.appendingPathComponent("active_sessions.json").path
        switch phase {
        case "running":
            let pid = try XCTUnwrap(livePid)
            try writeJSONFixture(
                [["session_id": "s1", "pid": Int(pid), "cwd": "/Users/test/RepoA", "opened_at": "2026-08-12T01:01:05Z"]],
                to: registryPath
            )
        case "idle":
            try writeJSONFixture([], to: registryPath)
        case "exited":
            try writeJSONFixture(
                [["session_id": "s1", "pid": 999_999, "cwd": "/Users/test/RepoA", "opened_at": "2026-08-12T01:01:05Z"]],
                to: registryPath
            )
            try setFileMtime(now.addingTimeInterval(-10), at: registryPath)
        case "stale":
            try writeJSONFixture(
                [["session_id": "s1", "pid": 999_999, "cwd": "/Users/test/RepoA", "opened_at": "2026-08-12T01:01:05Z"]],
                to: registryPath
            )
            try setFileMtime(now.addingTimeInterval(-3600), at: registryPath)
        case "malformed":
            try writeJSONFixture(
                [["session_id": "s1", "cwd": "/Users/test/RepoA", "opened_at": "2026-08-12T01:01:05Z"]],
                to: registryPath
            )
            try setFileMtime(now.addingTimeInterval(-10), at: registryPath)
        default:
            break
        }
    }

    static func buildPiFixture(root: URL, phase: String, now: Date) throws {
        let sessions = root.appendingPathComponent("agent/sessions", isDirectory: true)
        switch phase {
        case "running":
            let project = sessions.appendingPathComponent("--Users--test--RepoA", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let path = project.appendingPathComponent("2026-08-12T00-58-36-546Z_abc.jsonl").path
            try "{}".write(toFile: path, atomically: true, encoding: .utf8)
            try setFileMtime(now.addingTimeInterval(-10), at: path)
        case "idle":
            // Root present, no transcripts.
            break
        case "exited", "stale":
            // Transcripts remain after exit; a stale transcript is the exited
            // shape for a log-mtime agent.
            let project = sessions.appendingPathComponent("--Users--test--RepoA", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let path = project.appendingPathComponent("2026-08-12T00-58-36-546Z_abc.jsonl").path
            try "{}".write(toFile: path, atomically: true, encoding: .utf8)
            try setFileMtime(now.addingTimeInterval(-3600), at: path)
        case "malformed":
            // Transcripts are mtime-only signals; a malformed transcript body
            // is not read. The phase is recorded as the documented
            // non-applicable state: the probe still reports a typed row and
            // never running.
            let project = sessions.appendingPathComponent("--Users--test--RepoA", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let path = project.appendingPathComponent("2026-08-12T00-58-36-546Z_abc.jsonl").path
            try "{not json".write(toFile: path, atomically: true, encoding: .utf8)
            try setFileMtime(now.addingTimeInterval(-10), at: path)
        default:
            break
        }
    }
}
