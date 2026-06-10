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
    private static let commercialRemoteConfigDefaults: [String: NSObject] = [
        "media_kill_switch": NSNumber(value: false),
        "media_budget_soft_usd": NSNumber(value: 600),
        "media_budget_hard_usd": NSNumber(value: 1_000),
        "media_normal_file_gb_per_day": NSNumber(value: 5),
        "media_soft_file_gb_per_day": NSNumber(value: 2),
        "media_normal_screen_share_min_per_day": NSNumber(value: 120),
        "media_soft_screen_share_min_per_day": NSNumber(value: 30),
        "computer_use_budget_soft_usd": NSNumber(value: 1_500),
        "computer_use_budget_hard_usd": NSNumber(value: 2_500),
        "computer_use_kill_switch": NSNumber(value: false),
        "computer_use_phone_control_attestation_required": NSNumber(value: false),
        "computer_use_phone_control_secure_enclave_key": NSNumber(value: false),
        "computer_use_actions_per_run_normal": NSNumber(value: 50),
        "computer_use_actions_per_day_normal": NSNumber(value: 200),
        "computer_use_usd_per_user_day_normal": NSNumber(value: 5),
        "computer_use_actions_per_run_soft": NSNumber(value: 25),
        "computer_use_actions_per_day_soft": NSNumber(value: 100),
        "hosted_quota_daily_refresh_limit": NSNumber(value: 30),
        "hosted_quota_monthly_refresh_limit": NSNumber(value: 300),
        "cloud_pro_included_hosted_actions_monthly": NSNumber(value: 500),
        "cloud_pro_action_topup_unit": NSNumber(value: 100),
        "cloud_pro_monthly_hosted_action_cap": NSNumber(value: 2_000),
        "cloud_pro_included_relay_gb_monthly": NSNumber(value: 50),
        "cloud_pro_relay_topup_unit_gb": NSNumber(value: 50),
        "cloud_pro_monthly_relay_gb_cap": NSNumber(value: 300)
    ]

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
        remoteConfig.setDefaults(Self.commercialRemoteConfigDefaults)
        remoteConfig.fetchAndActivate { [weak self] _, _ in
            let mediaKillSwitch = remoteConfig.configValue(forKey: "media_kill_switch").boolValue
            Task { @MainActor in
                self?.mediaKillSwitch = mediaKillSwitch
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
