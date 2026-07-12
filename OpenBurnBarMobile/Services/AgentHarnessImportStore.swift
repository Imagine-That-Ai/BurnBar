import Foundation
import Observation

// MARK: - Agent Harness Import Store (audit wave 4, item 15)
//
// Owns the "Import agent history from Mac" job lifecycle for
// `CLIAgentConversationListView`: creating the Firestore-backed import job,
// observing its progress, and refreshing the mirrored-session reader when
// the job finishes. The view used to run this directly in its `startImport`
// helper; now it renders `snapshot` and sends `start` / `cancelObservation`
// intents only. Dependencies arrive via `init` (item 16).

/// Seam over `AgentHarnessImportJobDispatcher` so the store is testable
/// without Firebase — the same idiom as `CLIAgentRelayChatTransporting` /
/// `CLIRuntimeCatalogProviding`. The production dispatcher already has
/// exactly these signatures, so the conformance below adds no code.
@MainActor
protocol AgentHarnessImportJobDispatching: AnyObject {
    func create(selectedHarnesses: [String], source: String) async throws -> String
    func observe(
        jobID: String,
        onUpdate: @escaping @MainActor (AgentHarnessImportJobSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation
}

extension AgentHarnessImportJobDispatcher: AgentHarnessImportJobDispatching {}

@MainActor
@Observable
final class AgentHarnessImportStore {
    /// Latest known state of the in-flight (or finished) import job. Nil
    /// until the first `start` — the import sheet shows its explainer copy.
    private(set) var snapshot: AgentHarnessImportJobSnapshot?

    private let dispatcher: any AgentHarnessImportJobDispatching
    private let sessionReader: CLIAgentChatReader
    @ObservationIgnored private var observation: CLIAgentMissionObservation?

    init(
        dispatcher: any AgentHarnessImportJobDispatching = AgentHarnessImportJobDispatcher.shared,
        sessionReader: CLIAgentChatReader = .shared
    ) {
        self.dispatcher = dispatcher
        self.sessionReader = sessionReader
    }

    /// Creates the import job on the paired Mac's queue and starts observing
    /// its progress. Failures land in `snapshot` as a failed job so the sheet
    /// surfaces them — never swallowed.
    func start(harnesses: [String]) async {
        do {
            let jobID = try await dispatcher.create(selectedHarnesses: harnesses, source: "ios-import")
            snapshot = AgentHarnessImportJobSnapshot(
                documentID: jobID,
                data: [
                    "id": jobID,
                    "status": "pending",
                    "progressMessage": "Waiting for a trusted Mac.",
                    "scannedCount": 0,
                    "importedCount": 0,
                    "mirroredSessionCount": 0,
                    "uploadedSessionLogCount": 0
                ]
            )
            observation?.cancel()
            observation = try dispatcher.observe(
                jobID: jobID,
                onUpdate: { [weak self] snapshot in
                    guard let self else { return }
                    self.snapshot = snapshot
                    if snapshot.isTerminal {
                        let reader = self.sessionReader
                        Task {
                            await reader.refresh()
                        }
                    }
                },
                onError: { [weak self] message in
                    self?.snapshot = AgentHarnessImportJobSnapshot(
                        documentID: jobID,
                        data: [
                            "id": jobID,
                            "status": "failed",
                            "progressMessage": "Import watcher failed.",
                            "errorMessage": message,
                            "scannedCount": 0,
                            "importedCount": 0,
                            "mirroredSessionCount": 0,
                            "uploadedSessionLogCount": 0
                        ]
                    )
                }
            )
        } catch {
            snapshot = AgentHarnessImportJobSnapshot(
                documentID: "local-error",
                data: [
                    "status": "failed",
                    "progressMessage": "Could not start import.",
                    "errorMessage": error.localizedDescription,
                    "scannedCount": 0,
                    "importedCount": 0,
                    "mirroredSessionCount": 0,
                    "uploadedSessionLogCount": 0
                ]
            )
        }
    }

    /// Stops watching the current job (view teardown). The snapshot is kept
    /// so a re-presented sheet still shows the last known state.
    func cancelObservation() {
        observation?.cancel()
        observation = nil
    }
}
