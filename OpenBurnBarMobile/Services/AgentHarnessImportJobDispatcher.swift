import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

// MARK: - Agent harness import-job dispatcher
//
// Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14
// structural decomposition). Pure move — no behavior change.

@MainActor
final class AgentHarnessImportJobDispatcher {
    static let shared = AgentHarnessImportJobDispatcher()

    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func create(selectedHarnesses: [String], source: String = "ios-import") async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw CLIAgentMissionDispatcher.DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw CLIAgentMissionDispatcher.DispatchError.notSignedIn
        }
        let normalized = selectedHarnesses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else {
            throw CLIAgentMissionDispatcher.DispatchError.emptyPrompt
        }
        let id = "import-\(UUID().uuidString)"
        let payload: [String: Any] = [
            "id": id,
            "selectedHarnesses": Array(Set(normalized)).sorted(),
            "status": "pending",
            "source": source,
            "progressMessage": "Waiting for a trusted Mac.",
            "scannedCount": 0,
            "importedCount": 0,
            "mirroredSessionCount": 0,
            "uploadedSessionLogCount": 0,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("agent_import_jobs").document(id)
            .setData(payload, merge: false)
        return id
    }

    func observe(
        jobID: String,
        onUpdate: @escaping @MainActor (AgentHarnessImportJobSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else {
            throw CLIAgentMissionDispatcher.DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw CLIAgentMissionDispatcher.DispatchError.notSignedIn
        }
        let registration = firestoreProvider()
            .collection("users").document(uid)
            .collection("agent_import_jobs").document(jobID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error.localizedDescription) }
                    return
                }
                guard let data = snapshot?.data(),
                      let snapshot = AgentHarnessImportJobSnapshot(documentID: jobID, data: data) else { return }
                Task { @MainActor in onUpdate(snapshot) }
            }
        return CLIAgentMissionObservation(registrations: [registration])
    }
}

struct AgentHarnessImportJobSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let progressMessage: String
    let scannedCount: Int
    let importedCount: Int
    let mirroredSessionCount: Int
    let uploadedSessionLogCount: Int
    let errorMessage: String?

    init?(documentID: String, data: [String: Any]) {
        self.id = (data["id"] as? String)?.nilIfEmpty ?? documentID
        self.status = (data["status"] as? String)?.nilIfEmpty ?? "pending"
        self.progressMessage = (data["progressMessage"] as? String)?.nilIfEmpty ?? "Waiting for a trusted Mac."
        self.scannedCount = data["scannedCount"] as? Int ?? 0
        self.importedCount = data["importedCount"] as? Int ?? 0
        self.mirroredSessionCount = data["mirroredSessionCount"] as? Int ?? 0
        self.uploadedSessionLogCount = data["uploadedSessionLogCount"] as? Int ?? 0
        self.errorMessage = (data["errorMessage"] as? String)?.nilIfEmpty
    }

    var isTerminal: Bool {
        ["completed", "failed", "canceled", "cancelled"].contains(status)
    }
}

