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

    func dispatch(title: String, prompt: String, missionKind: String) async throws -> String {
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
            "requestedRuntime": "auto",
            "source": "ios-insights",
            "status": "pending",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
            .setData(payload, merge: false)
        return id
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
