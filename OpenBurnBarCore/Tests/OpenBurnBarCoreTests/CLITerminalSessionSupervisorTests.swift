import XCTest
@testable import OpenBurnBarCore

final class CLITerminalSessionSupervisorTests: XCTestCase {
    func test_supervisor_emitsQuotaEventOnceAcrossMultipleChunks() {
        let recorder = SupervisorEventRecorder()
        let supervisor = CLITerminalSessionSupervisor(cliType: .codex) { event in
            recorder.record(event)
        }

        supervisor.ingest("Everything healthy so far\n", source: .stdout)
        supervisor.ingest("Warning: 5-hour ", source: .stderr)
        supervisor.ingest("limit reached for this account\n", source: .stderr)
        supervisor.ingest("weekly limit reached too\n", source: .stderr)

        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .quotaExhausted(let detail, let source) = events[0] else {
            return XCTFail("Expected quota exhaustion event")
        }
        XCTAssertEqual(source, .stderr)
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("5-hour"))
        XCTAssertTrue(supervisor.snapshot().localizedCaseInsensitiveContains("weekly limit reached"))
    }
}

private final class SupervisorEventRecorder: Sendable {
    private let state = Locked<[CLITerminalSessionEvent]>([])

    func record(_ event: CLITerminalSessionEvent) {
        state.withLock { $0.append(event) }
    }

    func snapshot() -> [CLITerminalSessionEvent] {
        state.read()
    }
}
