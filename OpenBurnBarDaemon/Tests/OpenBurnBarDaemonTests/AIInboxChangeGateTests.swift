import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Behavior of the change gate, the cost control that makes the common tick free.
///
/// The gate must open on any real movement (config, conversations, ledger,
/// workspaces), stay closed when nothing moved, and sample the remote phase on
/// a fixed cadence so GitHub polling never depends on local activity.
final class AIInboxChangeGateTests: XCTestCase {
    private var databaseURL: URL!
    private var store: BurnBarAIInboxStore!
    private var gate: BurnBarAIInboxChangeGate!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-gate-tests-\(UUID().uuidString).sqlite")
        store = try BurnBarAIInboxStore(
            databasePath: databaseURL.path,
            logger: BurnBarDaemonLogger(category: "test")
        )
        gate = BurnBarAIInboxChangeGate(
            store: store,
            logger: BurnBarDaemonLogger(category: "test")
        )
    }

    override func tearDownWithError() throws {
        gate = nil
        store = nil
        if let databaseURL { try? FileManager.default.removeItem(at: databaseURL) }
        try super.tearDownWithError()
    }

    // MARK: - Decision properties

    func test_decisionPropertiesDescribeEachCase() {
        let skip = BurnBarAIInboxGateDecision.skip(signature: "sig-skip")
        XCTAssertEqual(skip.signature, "sig-skip")
        XCTAssertFalse(skip.runsPipeline)
        XCTAssertFalse(skip.includesRemote)
        XCTAssertEqual(skip.telemetryResult, .skippedUnchanged)

        let local = BurnBarAIInboxGateDecision.localChanged(signature: "sig-local")
        XCTAssertEqual(local.signature, "sig-local")
        XCTAssertTrue(local.runsPipeline)
        XCTAssertFalse(local.includesRemote)
        XCTAssertEqual(local.telemetryResult, .localChanged)

        let remote = BurnBarAIInboxGateDecision.remotePhase(signature: "sig-remote")
        XCTAssertEqual(remote.signature, "sig-remote")
        XCTAssertTrue(remote.runsPipeline)
        XCTAssertTrue(remote.includesRemote)
        XCTAssertEqual(remote.telemetryResult, .remotePhase)

        let forced = BurnBarAIInboxGateDecision.forced(signature: "sig-forced")
        XCTAssertEqual(forced.signature, "sig-forced")
        XCTAssertTrue(forced.runsPipeline)
        XCTAssertTrue(forced.includesRemote)
        XCTAssertEqual(forced.telemetryResult, .forced)
    }

    // MARK: - decide()

    /// A tick time far past any real file mtime, so the agent-log portion of
    /// the signature counts zero recent files and stays byte-stable even while
    /// a live agent is writing session logs on the machine running this test.
    private static let quiescentNow = Date(timeIntervalSince1970: 4_000_000_000)

    func test_forcedTickBypassesTheGateEntirely() {
        let decision = decide(forced: true)
        guard case .forced = decision else {
            XCTFail("An operator-forced tick must always run: \(decision)")
            return
        }
        XCTAssertFalse(decision.signature.isEmpty)
    }

    func test_firstTickIsLocalChangeAndCommitClosesTheGate() {
        let now = Self.quiescentNow
        let first = decide(now: now)
        guard case .localChanged = first else {
            XCTFail("With no stored signature the gate must open: \(first)")
            return
        }

        gate.commit(signature: first.signature, now: now)

        // Same inputs, off-cadence tick index: nothing moved, so skip.
        let second = decide(tickIndex: 2, now: now)
        guard case .skip = second else {
            XCTFail("An unchanged world must be a free tick: \(second)")
            return
        }
        XCTAssertEqual(second.signature, first.signature, "The signature is deterministic")
    }

    func test_remotePhaseFiresOnTheConfiguredCadenceWhenUnchanged() {
        let now = Self.quiescentNow
        let first = decide(now: now)
        gate.commit(signature: first.signature, now: now)

        // remotePhaseEveryNTicks = 3 (default): tick 3 samples GitHub.
        let onCadence = decide(tickIndex: 3, now: now)
        guard case .remotePhase = onCadence else {
            XCTFail("The Nth unchanged tick must poll the remote: \(onCadence)")
            return
        }

        let offCadence = decide(tickIndex: 4, now: now)
        guard case .skip = offCadence else {
            XCTFail("An off-cadence unchanged tick must skip: \(offCadence)")
            return
        }
    }

    func test_configChangeReopensTheGateImmediately() {
        let now = Self.quiescentNow
        let baseline = decide(now: now)
        gate.commit(signature: baseline.signature, now: now)

        let changed = gate.decide(
            config: BurnBarInboxConfig(enabled: true, egressMode: .cloud),
            tickIndex: 2,
            forced: false,
            usageLedgerSignature: "ledger-a",
            workspaceSignatures: ["ws-a"],
            now: now
        )
        guard case .localChanged = changed else {
            XCTFail("Flipping egress mode must re-analyze without waiting: \(changed)")
            return
        }
        XCTAssertNotEqual(changed.signature, baseline.signature)
    }

    func test_usageLedgerMovementReopensTheGate() {
        let now = Self.quiescentNow
        let baseline = decide(now: now)
        gate.commit(signature: baseline.signature, now: now)

        let moved = decide(tickIndex: 2, usageLedgerSignature: "ledger-b", now: now)
        guard case .localChanged = moved else {
            XCTFail("New spend must open the gate: \(moved)")
            return
        }
        XCTAssertNotEqual(moved.signature, baseline.signature)
    }

    func test_workspaceSignatureOrderDoesNotChangeTheGateSignature() {
        let now = Self.quiescentNow
        let forward = decide(workspaceSignatures: ["ws-a", "ws-b"], now: now)
        let reversed = decide(workspaceSignatures: ["ws-b", "ws-a"], now: now)
        XCTAssertEqual(
            forward.signature,
            reversed.signature,
            "Workspace ordering is an enumeration artifact, not a change"
        )
    }

    // MARK: - Agent log signature

    func test_agentLogSignatureIsDeterministicForTheSameWindow() {
        // A far-future window makes every watched root report zero recent
        // files, so the hash is stable regardless of what this machine has.
        let since = Date.distantFuture
        let first = BurnBarAIInboxChangeGate.agentLogSignature(since: since)
        let second = BurnBarAIInboxChangeGate.agentLogSignature(since: since)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    func test_watchedLogRootsCoverTheKnownAgentHomes() {
        XCTAssertTrue(BurnBarAIInboxChangeGate.watchedLogRoots.contains(".claude/projects"))
        XCTAssertTrue(BurnBarAIInboxChangeGate.watchedLogRoots.contains(".codex/sessions"))
        XCTAssertFalse(BurnBarAIInboxChangeGate.watchedLogRoots.isEmpty)
    }

    // MARK: - Helpers

    private func decide(
        config: BurnBarInboxConfig = BurnBarInboxConfig(enabled: true),
        tickIndex: Int = 1,
        forced: Bool = false,
        usageLedgerSignature: String = "ledger-a",
        workspaceSignatures: [String] = ["ws-a"],
        now: Date = Date()
    ) -> BurnBarAIInboxGateDecision {
        gate.decide(
            config: config,
            tickIndex: tickIndex,
            forced: forced,
            usageLedgerSignature: usageLedgerSignature,
            workspaceSignatures: workspaceSignatures,
            now: now
        )
    }
}
