import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseRemoteConfig
import Foundation
import OpenBurnBarMedia

/// iOS-side listener for the public media budget envelope (ADR 006).
@MainActor
final class MobileMediaBudgetStatusStore: ObservableObject {
    static let shared = MobileMediaBudgetStatusStore()

    private var listener: ListenerRegistration?
    private(set) var latestStatus: MediaBudgetStatus?
    private(set) var lastKnownStatus: MediaBudgetStatus?
    private(set) var failClosedDueToPermissionDenied = false
    @Published private(set) var mediaKillSwitch = false

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

    var effectiveStatus: MediaBudgetStatus {
        if failClosedDueToPermissionDenied, let lastKnownStatus {
            return lastKnownStatus
        }
        return latestStatus ?? lastKnownStatus ?? Self.initialNormal
    }

    func start() {
        refreshRemoteConfigKillSwitch()
        startListening()
    }

    func refreshRemoteConfigKillSwitch() {
        guard FirebaseApp.app() != nil else { return }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults(["media_kill_switch": false as NSObject])
        remoteConfig.fetchAndActivate { [weak self] _, _ in
            Task { @MainActor in
                self?.mediaKillSwitch = remoteConfig.configValue(forKey: "media_kill_switch").boolValue
            }
        }
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

    func deniesMediaSession(for feature: MediaStreamClass.Feature) -> MediaCapabilityDenialReason? {
        if mediaKillSwitch {
            return .killSwitchActive
        }
        let status = effectiveStatus
        switch status.level {
        case .hardCap:
            return .budgetHardCapReached
        case .softCap:
            if !status.activeEnvelope.allowsSession(for: feature) {
                return .budgetSoftCapReached
            }
            return nil
        case .normal:
            return nil
        }
    }

    private func handleSnapshot(snapshot: DocumentSnapshot?, error: Error?) {
        if let error {
            handleListenerError(error)
            return
        }
        failClosedDueToPermissionDenied = false
        guard let data = snapshot?.data() else { return }
        let status = Self.parsePublicEnvelope(data)
        latestStatus = status
        lastKnownStatus = status
    }

    private func handleListenerError(_ error: Error) {
        let nsError = error as NSError
        let code = FirestoreErrorCode.Code(rawValue: nsError.code)
        switch code {
        case .permissionDenied where isSignedInProvider():
            failClosedDueToPermissionDenied = true
            if lastKnownStatus == nil {
                latestStatus = nil
            }
        default:
            break
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
