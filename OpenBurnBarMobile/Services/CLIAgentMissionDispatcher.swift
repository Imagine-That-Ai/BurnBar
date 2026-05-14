import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

@MainActor
final class CLIAgentMissionDispatcher {
    static let shared = CLIAgentMissionDispatcher()

    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func dispatch(
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String = "auto"
    ) async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        let id = UUID().uuidString
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Insights mission"
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw DispatchError.emptyPrompt
        }

        let payload: [String: Any] = [
            "id": id,
            "title": trimmedTitle,
            "prompt": trimmedPrompt,
            "missionKind": missionKind,
            "requestedRuntime": requestedRuntime,
            "source": "ios-insights",
            "status": "pending",
            "liveSummary": "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
            "events": [
                [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "phase": "queued",
                    "message": "Mission queued from this device.",
                    "source": "ios"
                ]
            ],
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 2
        ]
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
            .setData(payload, merge: false)
        return id
    }

    func observe(
        requestID: String,
        onUpdate: @escaping @MainActor (CLIAgentMissionSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }

        let registration = firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error.localizedDescription) }
                    return
                }
                guard let snapshot, snapshot.exists,
                      let mission = CLIAgentMissionSnapshot(documentID: requestID, data: snapshot.data() ?? [:]) else {
                    Task { @MainActor in onError("Mission request disappeared before the Mac returned a result.") }
                    return
                }
                Task { @MainActor in onUpdate(mission) }
            }
        return CLIAgentMissionObservation(registration: registration)
    }

    enum DispatchError: LocalizedError {
        case firebaseUnavailable
        case notSignedIn
        case emptyPrompt

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notSignedIn:
                return "Sign in before dispatching Mac agent missions."
            case .emptyPrompt:
                return "Mission prompt was empty."
            }
        }
    }
}

final class CLIAgentMissionObservation {
    private let registration: ListenerRegistration

    init(registration: ListenerRegistration) {
        self.registration = registration
    }

    func cancel() {
        registration.remove()
    }

    deinit {
        registration.remove()
    }
}

struct CLIAgentMissionEvent: Equatable, Sendable, Identifiable {
    let timestamp: String
    let phase: String
    let message: String
    let runtime: String?
    let source: String?

    var id: String { "\(timestamp)-\(phase)-\(message)" }

    init?(data: Any) {
        guard let map = data as? [String: Any],
              let timestamp = map["timestamp"] as? String,
              let phase = map["phase"] as? String,
              let message = map["message"] as? String else {
            return nil
        }
        self.timestamp = timestamp
        self.phase = phase
        self.message = message
        self.runtime = map["runtime"] as? String
        self.source = map["source"] as? String
    }
}

struct CLIAgentMissionSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let status: String
    let requestedRuntime: String
    let selectedRuntime: String?
    let selectedRuntimeName: String?
    let liveSummary: String?
    let resultPreview: String?
    let errorMessage: String?
    let sessionID: String?
    let events: [CLIAgentMissionEvent]

    init?(documentID: String, data: [String: Any]) {
        guard let title = data["title"] as? String,
              let status = data["status"] as? String else {
            return nil
        }
        self.id = (data["id"] as? String) ?? documentID
        self.title = title
        self.status = status
        self.requestedRuntime = (data["requestedRuntime"] as? String) ?? "auto"
        self.selectedRuntime = data["selectedRuntime"] as? String
        self.selectedRuntimeName = data["selectedRuntimeName"] as? String
        self.liveSummary = data["liveSummary"] as? String
        self.resultPreview = data["resultPreview"] as? String
        self.errorMessage = data["errorMessage"] as? String
        self.sessionID = data["sessionId"] as? String
        self.events = (data["events"] as? [Any] ?? []).compactMap(CLIAgentMissionEvent.init(data:))
    }

    var runtimeLabel: String {
        selectedRuntimeName
            ?? selectedRuntime
            ?? (requestedRuntime == "auto" ? "Mac agent fleet" : requestedRuntime)
    }

    var isTerminal: Bool {
        status == "completed" || status == "failed"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
