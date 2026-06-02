import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore

/// Listens to the public envelope at `ops/computer_use_budget_status/state/current`.
/// Operator USD metrics live at `metrics/current` (ADR 006) and are not read here.
@MainActor
final class ComputerUseBudgetStatusStore {
    static let shared = ComputerUseBudgetStatusStore()

    private var listener: ListenerRegistration?
    private(set) var latestEnvelope: ComputerUseBudgetEnvelope?
    private(set) var lastKnownEnvelope: ComputerUseBudgetEnvelope?
    private(set) var failClosedDueToPermissionDenied = false

    var onEnvelopeChanged: ((ComputerUseBudgetEnvelope) -> Void)?

    private let documentPath: String
    private let isSignedInProvider: () -> Bool

    init(
        documentPath: String = "ops/computer_use_budget_status/state/current",
        isSignedInProvider: @escaping () -> Bool = {
            guard FirebaseApp.app() != nil else { return false }
            return Auth.auth().currentUser != nil
        }
    ) {
        self.documentPath = documentPath
        self.isSignedInProvider = isSignedInProvider
    }

    func startListening() {
        guard listener == nil else { return }
        guard FirebaseApp.app() != nil else { return }
        listener = Firestore.firestore()
            .document(documentPath)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    self?.handleSnapshot(snapshot: snapshot, error: error)
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    /// Envelope for admission decisions — respects fail-closed and last-known cache.
    var effectiveEnvelope: ComputerUseBudgetEnvelope {
        if failClosedDueToPermissionDenied, let lastKnownEnvelope {
            return lastKnownEnvelope
        }
        return latestEnvelope ?? lastKnownEnvelope ?? .initialNormal
    }

    func handleSnapshot(snapshot: DocumentSnapshot?, error: Error?) {
        if let error {
            handleListenerError(error)
            return
        }
        failClosedDueToPermissionDenied = false
        guard let data = snapshot?.data() else { return }
        applyPublicEnvelopeData(data)
    }

    func applyPublicEnvelopeData(_ data: [String: Any]) {
        let envelope = Self.parsePublicEnvelope(data)
        latestEnvelope = envelope
        lastKnownEnvelope = envelope
        onEnvelopeChanged?(envelope)
    }

    private func handleListenerError(_ error: Error) {
        let nsError = error as NSError
        let code = FirestoreErrorCode.Code(rawValue: nsError.code)
        AppLogger.sync.error(
            "computer_use_budget_listener_failed",
            metadata: [
                "error": error.localizedDescription,
                "code": String(describing: code),
            ]
        )

        switch code {
        case .permissionDenied where isSignedInProvider():
            failClosedDueToPermissionDenied = true
            if lastKnownEnvelope == nil {
                latestEnvelope = nil
            }
        case .unavailable, .deadlineExceeded, .resourceExhausted:
            failClosedDueToPermissionDenied = false
        default:
            failClosedDueToPermissionDenied = false
        }
    }

    static func parsePublicEnvelope(_ data: [String: Any]) -> ComputerUseBudgetEnvelope {
        let levelRaw = data["level"] as? String ?? ComputerUseBudgetEnvelope.Level.normal.rawValue
        let level = ComputerUseBudgetEnvelope.Level(rawValue: levelRaw) ?? .normal
        return ComputerUseBudgetEnvelope(
            level: level,
            projectedMonthEndUSD: 0,
            monthToDateUSD: 0,
            activeActionsPerRun: data["activeActionsPerRun"] as? Int ?? 0,
            activeActionsPerDay: data["activeActionsPerDay"] as? Int ?? 0,
            activeSessionsPerDay: data["activeSessionsPerDay"] as? Int ?? 0,
            perUserDailySpendCeilingUSD: data["perUserDailySpendCeilingUSD"] as? Double ?? 0,
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }
}
