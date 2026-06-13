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
    private let defaults: UserDefaults
    private static let lastKnownStatusDefaultsKey = "com.openburnbar.media.budget.lastKnownStatus"

    init(
        documentPath: String = "ops/media_budget_status/state/current",
        isSignedInProvider: @escaping () -> Bool = {
            Auth.auth().currentUser != nil
        },
        defaults: UserDefaults = .standard
    ) {
        self.documentPath = documentPath
        self.isSignedInProvider = isSignedInProvider
        self.defaults = defaults
        // Rehydrate last-known-good so a cold start after a previous online
        // session reuses the last published envelope instead of failing open
        // to `initialNormal` (RR-9). A persisted hard-cap therefore keeps
        // engaging across launches even before the listener reconnects.
        self.lastKnownStatus = Self.loadPersistedLastKnownStatus(from: defaults)
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
        // Cold-start / transient-unavailable with no value to trust resolves to
        // the CONSERVATIVE closed status, not the most-permissive `initialNormal`
        // (RR-9). Once a live envelope (or a rehydrated last-known-good) exists we
        // prefer it; otherwise the caps stay engaged until the budget doc is read.
        return latestStatus ?? lastKnownStatus ?? Self.conservativeClosed
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
        persistLastKnownStatus(status)
        onStatusChanged?(status)
    }

    private func persistLastKnownStatus(_ status: MediaBudgetStatus) {
        do {
            let encoded = try JSONEncoder().encode(status)
            defaults.set(encoded, forKey: Self.lastKnownStatusDefaultsKey)
        } catch {
            AppLogger.sync.error(
                "media_budget_status_persist_failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private static func loadPersistedLastKnownStatus(from defaults: UserDefaults) -> MediaBudgetStatus? {
        guard let data = defaults.data(forKey: lastKnownStatusDefaultsKey) else { return nil }
        do {
            return try JSONDecoder().decode(MediaBudgetStatus.self, from: data)
        } catch {
            AppLogger.sync.error(
                "media_budget_status_load_failed",
                metadata: ["error": error.localizedDescription]
            )
            defaults.removeObject(forKey: lastKnownStatusDefaultsKey)
            return nil
        }
    }

    private func handleListenerError(_ error: Error) {
        let nsError = error as NSError
        let code = FirestoreErrorCode.Code(rawValue: nsError.code)
        AppLogger.sync.error(
            "media_budget_listener_failed",
            metadata: [
                "error": error.localizedDescription,
                "code": String(describing: code)
            ]
        )

        switch code {
        case .permissionDenied where isSignedInProvider():
            failClosedDueToPermissionDenied = true
            if lastKnownStatus == nil {
                latestStatus = nil
            }
        case .unavailable, .deadlineExceeded, .resourceExhausted:
            // Transient outage: hold last-known-good rather than failing open.
            // Promote any live value into `lastKnownStatus` so a later
            // `latestStatus` reset still resolves to the last good envelope, and
            // when there is no good value `effectiveStatus` falls to the
            // conservative closed default (RR-9).
            failClosedDueToPermissionDenied = false
            if let latestStatus {
                lastKnownStatus = latestStatus
                persistLastKnownStatus(latestStatus)
            }
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

    /// Conservative fail-closed status used when there is nothing trustworthy to
    /// report — cold start before the first read, or a transient-unavailable
    /// listener with no last-known-good (RR-9). Hard cap engages the same way
    /// the budget evaluator's hard-cap publish does, so admission control stays
    /// closed until a real envelope arrives rather than running on the
    /// most-permissive `initialNormal`.
    static let conservativeClosed = MediaBudgetStatus(
        level: .hardCap,
        projectedMonthEndUSD: 0,
        monthToDateUSD: 0,
        lastEvaluatedAt: Date(timeIntervalSince1970: 0),
        activeEnvelope: .hardCap
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
