import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarMedia

/// Listens to the public envelope at `ops/media_budget_status/state/current`.
/// Operator USD metrics live at `metrics/current` (ADR 006) and are not read here.
@MainActor
final class MediaBudgetStatusStore {
    static let shared = MediaBudgetStatusStore()

    private var listener: ListenerRegistration?
    private(set) var latestStatus: MediaBudgetStatus?
    private(set) var lastKnownStatus: MediaBudgetStatus?
    private(set) var failClosedDueToPermissionDenied = false

    var onStatusChanged: ((MediaBudgetStatus) -> Void)?

    private let documentPath: String
    private let isSignedInProvider: () -> Bool

    init(
        documentPath: String = "ops/media_budget_status/state/current",
        isSignedInProvider: @escaping () -> Bool = {
            Auth.auth().currentUser != nil
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

    var effectiveStatus: MediaBudgetStatus {
        if failClosedDueToPermissionDenied, let lastKnownStatus {
            return lastKnownStatus
        }
        return latestStatus ?? lastKnownStatus ?? Self.initialNormal
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
        let status = Self.parsePublicEnvelope(data)
        latestStatus = status
        lastKnownStatus = status
        onStatusChanged?(status)
    }

    private func handleListenerError(_ error: Error) {
        let nsError = error as NSError
        let code = FirestoreErrorCode.Code(rawValue: nsError.code)
        AppLogger.sync.error(
            "media_budget_listener_failed",
            metadata: [
                "error": error.localizedDescription,
                "code": String(describing: code),
            ]
        )

        switch code {
        case .permissionDenied where isSignedInProvider():
            failClosedDueToPermissionDenied = true
            if lastKnownStatus == nil {
                latestStatus = nil
            }
        case .unavailable, .deadlineExceeded, .resourceExhausted:
            failClosedDueToPermissionDenied = false
        default:
            failClosedDueToPermissionDenied = false
        }
    }

    static let initialNormal = MediaBudgetStatus(
        level: .normal,
        projectedMonthEndUSD: 0,
        monthToDateUSD: 0,
        lastEvaluatedAt: Date(timeIntervalSince1970: 0),
        activeEnvelope: .normal
    )

    static func parsePublicEnvelope(_ data: [String: Any]) -> MediaBudgetStatus {
        let levelRaw = data["level"] as? String ?? MediaBudgetStatus.Level.normal.rawValue
        let level = MediaBudgetStatus.Level(rawValue: levelRaw) ?? .normal
        let envelopeMap = data["activeEnvelope"] as? [String: Any] ?? [:]
        let envelope = MediaBudgetEnvelope(
            screenShareDailyMinutes: envelopeMap["screenShareDailyMinutes"] as? Int ?? 0,
            screenSharePerSessionMinutes: envelopeMap["screenSharePerSessionMinutes"] as? Int ?? 0,
            videoCallDailyMinutes: envelopeMap["videoCallDailyMinutes"] as? Int ?? 0,
            videoCallPerCallMinutes: envelopeMap["videoCallPerCallMinutes"] as? Int ?? 0,
            fileTransferDailyGBIn: envelopeMap["fileTransferDailyGBIn"] as? Int ?? 0,
            fileTransferDailyGBOut: envelopeMap["fileTransferDailyGBOut"] as? Int ?? 0
        )
        return MediaBudgetStatus(
            level: level,
            projectedMonthEndUSD: 0,
            monthToDateUSD: 0,
            lastEvaluatedAt: (data["lastEvaluatedAt"] as? Timestamp)?.dateValue() ?? Date(),
            activeEnvelope: envelope
        )
    }
}
