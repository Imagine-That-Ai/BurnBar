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
            XCTFail("Expected quota exhaustion event")
            return
        }
        XCTAssertEqual(source, .stderr)
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("5-hour"))
        XCTAssertTrue(supervisor.snapshot().localizedCaseInsensitiveContains("weekly limit reached"))
    }

    func test_supervisor_detectsOpenCodeMonthlyQuota() {
        let recorder = SupervisorEventRecorder()
        let supervisor = CLITerminalSessionSupervisor(cliType: .opencode) { event in
            recorder.record(event)
        }

        supervisor.ingest("OpenCode Go monthly credit limit reached for this account\n", source: .stderr)

        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .quotaExhausted(let detail, let source) = events[0] else {
            XCTFail("Expected quota exhaustion event")
            return
        }
        XCTAssertEqual(source, .stderr)
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("monthly credit limit"))
    }

    func test_classifierTreatsQuotaAnchoredOutOfLimitAsFiveHourQuotaWindow() {
        let detail = "Codex quota is out of limit for this account."
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .codex, in: detail),
            detail
        )

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = CLIQuotaExhaustionClassifier.exhaustionWindowEnd(from: detail, now: now)
        XCTAssertEqual(reset, now.addingTimeInterval(5 * 60 * 60))
    }

    func test_classifierIgnoresUnanchoredOutOfLimitText() {
        let detail = "The assistant draft says these examples are out of limits, then keeps writing."

        XCTAssertNil(CLIQuotaExhaustionClassifier.classify(for: .codex, in: detail))
    }

    func test_classifierIgnoresIdentityAnchoredOutOfLimitText() {
        let detail = "Codex generated a test fixture that says values are out of limits."

        XCTAssertNil(CLIQuotaExhaustionClassifier.classify(for: .codex, in: detail))
    }

    func test_classifierDoesNotAnchorWeakLimitPhraseAcrossLines() {
        let detail = """
        Codex quota dashboard loaded.
        The build output says these layout values are out of limits.
        """

        XCTAssertNil(CLIQuotaExhaustionClassifier.classify(for: .codex, in: detail))
    }

    func test_supervisorDoesNotEmitQuotaEventForUnanchoredOutOfLimitText() {
        let recorder = SupervisorEventRecorder()
        let supervisor = CLITerminalSessionSupervisor(cliType: .codex) { event in
            recorder.record(event)
        }

        supervisor.ingest(
            "Here is normal model output discussing values that are out of limits.\n",
            source: .stdout
        )

        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    func test_attachedPipeDrainsLargeAvailableOutputInOneReadEvent() throws {
        let eventExpectation = expectation(description: "quota event emitted")
        let recorder = SupervisorEventRecorder(expectation: eventExpectation)
        let supervisor = CLITerminalSessionSupervisor(cliType: .codex) { event in
            recorder.record(event)
        }
        let pipe = Pipe()
        let observer = supervisor.attach(
            to: pipe,
            source: .stderr,
            queue: DispatchQueue(label: "test.cli-terminal-session-supervisor.pipe-drain")
        )
        defer { observer.cancel() }

        let prefix = String(repeating: "log-line-before-quota\n", count: 350)
        let marker = "Codex 5-hour limit reached for this account.\n"
        pipe.fileHandleForWriting.write(Data((prefix + marker).utf8))
        try pipe.fileHandleForWriting.close()

        wait(for: [eventExpectation], timeout: 2.0)

        let snapshot = supervisor.snapshot()
        XCTAssertGreaterThan(snapshot.utf8.count, 4096)
        XCTAssertTrue(snapshot.hasSuffix(marker))

        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 1)
        guard case .quotaExhausted(let detail, let source) = events[0] else {
            XCTFail("Expected quota exhaustion event")
            return
        }
        XCTAssertEqual(source, .stderr)
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("5-hour"))
    }

    func test_piClassifierDoesNotTreatSubstringAsQuotaIdentity() {
        XCTAssertNil(
            CLIQuotaExhaustionClassifier.classify(
                for: .pi,
                in: "The pipeline output is out of limits for this layout, but the run continues."
            )
        )
    }

    func test_piClassifierStillAcceptsQuotaAnchoredWeakLimitPhrase() {
        let detail = "Pi quota is out of limits for this account."
        XCTAssertEqual(CLIQuotaExhaustionClassifier.classify(for: .pi, in: detail), detail)
    }

    func test_classifierMatchesNewCLIQuotaPhrases() {
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .hermes, in: "hermes quota exceeded"),
            "hermes quota exceeded"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .goose, in: "block goose quota reached"),
            "block goose quota reached"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .windsurf, in: "flex credit exhausted"),
            "flex credit exhausted"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .openClaude, in: "claude code usage limit reached"),
            "claude code usage limit reached"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .openClaw, in: "openclaw limit reached"),
            "openclaw limit reached"
        )
    }
}

private final class SupervisorEventRecorder: Sendable {
    private let state = Locked<[CLITerminalSessionEvent]>([])
    private let expectation: XCTestExpectation?

    init(expectation: XCTestExpectation? = nil) {
        self.expectation = expectation
    }

    func record(_ event: CLITerminalSessionEvent) {
        state.withLock { $0.append(event) }
        expectation?.fulfill()
    }

    func snapshot() -> [CLITerminalSessionEvent] {
        state.read()
    }
}
