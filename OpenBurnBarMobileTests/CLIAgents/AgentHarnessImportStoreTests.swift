import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// MARK: - AgentHarnessImportStore behavior (audit wave 4, item 15)
//
// The "Import agent history from Mac" job lifecycle moved out of
// `CLIAgentConversationListView.startImport` into `AgentHarnessImportStore`.
// These tests lock the moved behavior through the new
// `AgentHarnessImportJobDispatching` seam: optimistic pending snapshot,
// live progress updates, terminal refresh of the session reader, and both
// failure paths surfacing as failed snapshots (never swallowed).

@MainActor
final class AgentHarnessImportStoreTests: XCTestCase {

    func test_start_publishesPendingSnapshot_andObservesJob() async {
        let dispatcher = FakeImportJobDispatcher()
        dispatcher.jobID = "import-job-1"
        let store = makeStore(dispatcher: dispatcher)

        await store.start(harnesses: ["codex", "claude"])

        XCTAssertEqual(dispatcher.createdHarnesses, [["codex", "claude"]])
        XCTAssertEqual(dispatcher.createdSources, ["ios-import"])
        XCTAssertEqual(dispatcher.observedJobIDs, ["import-job-1"])
        XCTAssertEqual(store.snapshot?.id, "import-job-1")
        XCTAssertEqual(store.snapshot?.status, "pending")
        XCTAssertEqual(store.snapshot?.progressMessage, "Waiting for a trusted Mac.")
        XCTAssertFalse(store.snapshot?.isTerminal ?? true)
    }

    func test_observerUpdates_replaceSnapshot_andTerminalRefreshesReader() async throws {
        let dispatcher = FakeImportJobDispatcher()
        dispatcher.jobID = "import-job-2"
        let source = StubCLISource()
        let reader = CLIAgentChatReader(remote: source, observeAuthChanges: false)
        let store = makeStore(dispatcher: dispatcher, reader: reader)

        await store.start(harnesses: ["codex"])
        let onUpdate = try XCTUnwrap(dispatcher.onUpdate)

        // Mid-flight progress replaces the optimistic snapshot.
        onUpdate(makeSnapshot(id: "import-job-2", status: "running", progress: "Scanning Codex logs.", scanned: 12))
        XCTAssertEqual(store.snapshot?.status, "running")
        XCTAssertEqual(store.snapshot?.scannedCount, 12)
        XCTAssertNil(reader.lastRefreshedAt)

        // A terminal update refreshes the mirrored-session reader.
        onUpdate(makeSnapshot(id: "import-job-2", status: "completed", progress: "Done.", scanned: 12))
        XCTAssertEqual(store.snapshot?.status, "completed")
        XCTAssertTrue(store.snapshot?.isTerminal ?? false)
        // The refresh runs on a detached Task; give it a beat.
        for _ in 0..<50 where reader.lastRefreshedAt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(reader.lastRefreshedAt)
    }

    func test_createFailure_surfacesFailedSnapshot() async {
        let dispatcher = FakeImportJobDispatcher()
        dispatcher.createError = FakeImportError.macUnavailable
        let store = makeStore(dispatcher: dispatcher)

        await store.start(harnesses: ["codex"])

        XCTAssertEqual(store.snapshot?.status, "failed")
        XCTAssertEqual(store.snapshot?.progressMessage, "Could not start import.")
        XCTAssertEqual(store.snapshot?.errorMessage, FakeImportError.macUnavailable.localizedDescription)
        XCTAssertTrue(dispatcher.observedJobIDs.isEmpty)
    }

    func test_observerError_surfacesFailedWatcherSnapshot() async throws {
        let dispatcher = FakeImportJobDispatcher()
        dispatcher.jobID = "import-job-3"
        let store = makeStore(dispatcher: dispatcher)

        await store.start(harnesses: ["codex"])
        let onError = try XCTUnwrap(dispatcher.onError)
        onError("permission denied")

        XCTAssertEqual(store.snapshot?.id, "import-job-3")
        XCTAssertEqual(store.snapshot?.status, "failed")
        XCTAssertEqual(store.snapshot?.progressMessage, "Import watcher failed.")
        XCTAssertEqual(store.snapshot?.errorMessage, "permission denied")
    }

    func test_cancelObservation_keepsLastSnapshot() async {
        let dispatcher = FakeImportJobDispatcher()
        dispatcher.jobID = "import-job-4"
        let store = makeStore(dispatcher: dispatcher)

        await store.start(harnesses: ["codex"])
        store.cancelObservation()

        // The sheet re-presents with the last known state.
        XCTAssertEqual(store.snapshot?.id, "import-job-4")
    }

    // MARK: - Fixtures

    private func makeStore(
        dispatcher: FakeImportJobDispatcher,
        reader: CLIAgentChatReader? = nil
    ) -> AgentHarnessImportStore {
        AgentHarnessImportStore(
            dispatcher: dispatcher,
            sessionReader: reader ?? CLIAgentChatReader(remote: StubCLISource(), observeAuthChanges: false)
        )
    }

    private func makeSnapshot(
        id: String,
        status: String,
        progress: String,
        scanned: Int
    ) -> AgentHarnessImportJobSnapshot {
        AgentHarnessImportJobSnapshot(
            documentID: id,
            data: [
                "id": id,
                "status": status,
                "progressMessage": progress,
                "scannedCount": scanned,
                "importedCount": 0,
                "mirroredSessionCount": 0,
                "uploadedSessionLogCount": 0
            ]
        )!
    }
}

// MARK: - Fakes

private enum FakeImportError: LocalizedError {
    case macUnavailable

    var errorDescription: String? { "No trusted Mac is reachable." }
}

@MainActor
private final class FakeImportJobDispatcher: AgentHarnessImportJobDispatching {
    var jobID = "import-fake"
    var createError: Error?
    var observeError: Error?

    private(set) var createdHarnesses: [[String]] = []
    private(set) var createdSources: [String] = []
    private(set) var observedJobIDs: [String] = []
    private(set) var onUpdate: (@MainActor (AgentHarnessImportJobSnapshot) -> Void)?
    private(set) var onError: (@MainActor (String) -> Void)?

    func create(selectedHarnesses: [String], source: String) async throws -> String {
        if let createError { throw createError }
        createdHarnesses.append(selectedHarnesses)
        createdSources.append(source)
        return jobID
    }

    func observe(
        jobID: String,
        onUpdate: @escaping @MainActor (AgentHarnessImportJobSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        if let observeError { throw observeError }
        observedJobIDs.append(jobID)
        self.onUpdate = onUpdate
        self.onError = onError
        return CLIAgentMissionObservation(registrations: [])
    }
}
