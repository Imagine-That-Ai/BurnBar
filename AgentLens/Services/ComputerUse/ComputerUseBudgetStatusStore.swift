import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore

/// Listens to `ops/computer_use_budget_status/state/current` and publishes envelope updates.
@MainActor
final class ComputerUseBudgetStatusStore {
    static let shared = ComputerUseBudgetStatusStore()

    private var listener: ListenerRegistration?
    private(set) var latestEnvelope: ComputerUseBudgetEnvelope?

    var onEnvelopeChanged: ((ComputerUseBudgetEnvelope) -> Void)?

    private init() {}

    func startListening() {
        guard listener == nil else { return }
        guard FirebaseApp.app() != nil else { return }
        listener = Firestore.firestore()
            .document("ops/computer_use_budget_status/state/current")
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    AppLogger.sync.error(
                        "computer_use_budget_listener_failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    return
                }
                guard let data = snapshot?.data() else { return }
                Task { @MainActor in
                    let envelope = Self.parseEnvelope(data)
                    self?.latestEnvelope = envelope
                    self?.onEnvelopeChanged?(envelope)
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    private static func parseEnvelope(_ data: [String: Any]) -> ComputerUseBudgetEnvelope {
        let levelRaw = data["level"] as? String ?? ComputerUseBudgetEnvelope.Level.normal.rawValue
        let level = ComputerUseBudgetEnvelope.Level(rawValue: levelRaw) ?? .normal
        return ComputerUseBudgetEnvelope(
            level: level,
            projectedMonthEndUSD: data["projectedMonthEndUSD"] as? Double ?? 0,
            monthToDateUSD: data["monthToDateUSD"] as? Double ?? 0,
            activeActionsPerRun: data["activeActionsPerRun"] as? Int ?? 0,
            activeActionsPerDay: data["activeActionsPerDay"] as? Int ?? 0,
            activeSessionsPerDay: data["activeSessionsPerDay"] as? Int ?? 0,
            perUserDailySpendCeilingUSD: data["perUserDailySpendCeilingUSD"] as? Double ?? 0,
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
        )
    }
}
