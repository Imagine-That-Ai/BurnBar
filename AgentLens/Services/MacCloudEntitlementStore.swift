@preconcurrency import Foundation
import SwiftUI
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Mac Cloud Entitlement Store
//
// Cross-platform parity with the Android `HostedQuotaSubscriptionStore`
// Firestore listener and iOS `HostedQuotaSubscriptionStore`. The canonical
// entitlement doc written by Cloud Functions after a StoreKit purchase is the
// authoritative source. We listen here so the Mac UI reflects "Cloud Member"
// state whether the user bought on Mac, iPhone, or iPad.
//
// Doc path: `users/{uid}/entitlements/hosted_quota_sync`
// Fields:
//   • active           — Bool
//   • productID        — String
//   • expiresAt        — Timestamp (or seconds, or ISO-8601 string)
//   • originalPurchaseDate — same shapes as `expiresAt`
//
// Use as a `@StateObject` or a shared singleton — the listener fans out
// across the Cloud settings pane, the menu-bar popover, and the dashboard
// sidebar identity row.

/// The membership tier the server resolved for this Mac. Ordered so callers can
/// compare hierarchy (`ultra > pro > cloud > free`). Mirrors the website's
/// four-tier pricing model and the iOS `getDataDomainUsage().tier` string.
enum MacCloudTier: Int, Comparable, CaseIterable {
    case free = 0
    case cloud = 1
    case pro = 2
    case ultra = 3

    static func < (lhs: MacCloudTier, rhs: MacCloudTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
final class MacCloudEntitlementStore: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var hostedComputerUseIsActive: Bool = false
    @Published private(set) var hostedMediaIsActive: Bool = false
    /// True when the member holds the BurnBar Ultra entitlement (server-resolved
    /// `burnbar_ultra` doc). Ultra ⇒ Pro ⇒ Cloud, so use `currentTier` for
    /// hierarchy decisions and this flag only for the literal Ultra check.
    @Published private(set) var isUltraActive: Bool = false
    @Published private(set) var expirationDate: Date?
    @Published private(set) var hostedComputerUseExpirationDate: Date?
    @Published private(set) var hostedMediaExpirationDate: Date?
    @Published private(set) var ultraExpirationDate: Date?
    @Published private(set) var purchaseDate: Date?
    @Published private(set) var hostedComputerUsePurchaseDate: Date?
    @Published private(set) var hostedMediaPurchaseDate: Date?
    @Published private(set) var ultraPurchaseDate: Date?
    @Published private(set) var error: String?

    static let shared = MacCloudEntitlementStore()

    private var listener: ListenerRegistration?
    private var computerUseListener: ListenerRegistration?
    private var mediaListener: ListenerRegistration?
    private var proMaxListener: ListenerRegistration?
    private var ultraListener: ListenerRegistration?
    private nonisolated(unsafe) var authHandle: AuthStateDidChangeListenerHandle?
    private var started = false
    private var hostedComputerUseState: (isActive: Bool, expiresAt: Date?, purchase: Date?) = (false, nil, nil)
    private var proMaxComputerUseState: (isActive: Bool, expiresAt: Date?, purchase: Date?) = (false, nil, nil)

    /// Highest tier the member currently holds, resolved from the live
    /// entitlement docs. Ultra implies Pro implies Cloud.
    var currentTier: MacCloudTier {
        if isUltraActive { return .ultra }
        if hostedComputerUseIsActive { return .pro }
        if isActive { return .cloud }
        return .free
    }

    /// The shared cross-platform `CloudTier` (from `OpenBurnBarCore`) the
    /// feature-gating catalog consumes. Resolved from the same live entitlement
    /// predicates as `currentTier`, following spec §4.2:
    /// `isUltraActive → .ultra`, else `hostedComputerUseIsActive → .pro`, else
    /// `isActive → .cloud`, else `.none`. Use this with `GatedFeature` /
    /// `FeatureUnlockSheet` / `LockedFeatureVeil` so the unlock copy matches iOS.
    var cloudTier: CloudTier {
        if isUltraActive { return .ultra }
        if hostedComputerUseIsActive { return .pro }
        if isActive { return .cloud }
        return .none
    }

    deinit {
        listener?.remove()
        computerUseListener?.remove()
        mediaListener?.remove()
        proMaxListener?.remove()
        ultraListener?.remove()
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
    }

    /// Idempotent — safe to call from every observer's `.onAppear`.
    func start() {
        guard !started else { return }
        guard FirebaseApp.app() != nil else {
            error = "Cloud is not configured on this Mac."
            return
        }
        started = true
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartListener(uid: user?.uid)
            }
        }
        restartListener(uid: Auth.auth().currentUser?.uid)
    }

    private func restartListener(uid: String?) {
        listener?.remove()
        listener = nil
        computerUseListener?.remove()
        computerUseListener = nil
        mediaListener?.remove()
        mediaListener = nil
        proMaxListener?.remove()
        proMaxListener = nil
        ultraListener?.remove()
        ultraListener = nil
        guard let uid else {
            isActive = false
            hostedComputerUseIsActive = false
            isUltraActive = false
            expirationDate = nil
            hostedComputerUseExpirationDate = nil
            ultraExpirationDate = nil
            purchaseDate = nil
            hostedComputerUsePurchaseDate = nil
            ultraPurchaseDate = nil
            hostedComputerUseState = (false, nil, nil)
            proMaxComputerUseState = (false, nil, nil)
            clearHostedMediaEntitlement()
            return
        }
        let entitlements = Firestore.firestore()
            .collection("users").document(uid)
            .collection("entitlements")
        listener = entitlements
            .document("hosted_quota_sync")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.error = error.localizedDescription
                        return
                    }
                    guard let data = snapshot?.data(), snapshot?.exists == true else {
                        // No entitlement doc — leave state unchanged so any
                        // local purchase path (future macOS StoreKit) stays
                        // authoritative. For now we just reflect "free".
                        self.isActive = false
                        self.expirationDate = nil
                        self.purchaseDate = nil
                        return
                    }
                    self.applyHostedQuota(data: data)
                }
            }
        computerUseListener = entitlements
            .document("hosted_computer_use_sync")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.error = error.localizedDescription
                        return
                    }
                    guard let data = snapshot?.data(), snapshot?.exists == true else {
                        self.hostedComputerUseState = (false, nil, nil)
                        self.publishComputerUseEntitlement()
                        return
                    }
                    self.applyHostedComputerUse(data: data)
                }
            }
        mediaListener = entitlements
            .document("hosted_media_sync")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.error = error.localizedDescription
                        return
                    }
                    guard let data = snapshot?.data(), snapshot?.exists == true else {
                        self.clearHostedMediaEntitlement()
                        return
                    }
                    self.applyHostedMedia(data: data)
                }
            }
        proMaxListener = entitlements
            .document("burnbar_pro_max")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.error = error.localizedDescription
                        return
                    }
                    guard let data = snapshot?.data(), snapshot?.exists == true else {
                        self.proMaxComputerUseState = (false, nil, nil)
                        self.publishComputerUseEntitlement()
                        return
                    }
                    self.proMaxComputerUseState = self.activeEntitlementState(data: data)
                    self.publishComputerUseEntitlement()
                }
            }
        ultraListener = entitlements
            .document("burnbar_ultra")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.error = error.localizedDescription
                        return
                    }
                    guard let data = snapshot?.data(), snapshot?.exists == true else {
                        self.isUltraActive = false
                        self.ultraExpirationDate = nil
                        self.ultraPurchaseDate = nil
                        return
                    }
                    let state = self.activeEntitlementState(data: data)
                    self.isUltraActive = state.isActive
                    self.ultraExpirationDate = state.expiresAt
                    self.ultraPurchaseDate = state.purchase
                }
            }
    }

    private func applyHostedQuota(data: [String: Any]) {
        let state = activeEntitlementState(data: data)
        isActive = state.isActive
        expirationDate = state.expiresAt
        purchaseDate = state.purchase
    }

    private func applyHostedComputerUse(data: [String: Any]) {
        hostedComputerUseState = activeEntitlementState(data: data)
        publishComputerUseEntitlement()
    }

    func applyHostedMedia(data: [String: Any]) {
        let state = activeEntitlementState(data: data)
        hostedMediaIsActive = state.isActive
        hostedMediaExpirationDate = state.expiresAt
        hostedMediaPurchaseDate = state.purchase
    }

    func clearHostedMediaEntitlement() {
        hostedMediaIsActive = false
        hostedMediaExpirationDate = nil
        hostedMediaPurchaseDate = nil
    }

    private func activeEntitlementState(data: [String: Any]) -> (isActive: Bool, expiresAt: Date?, purchase: Date?) {
        let active = (data["active"] as? Bool) ?? false
        let expiresAt = parseDate(data["expireAt"])
            ?? parseDate(data["expiresAt"])
            ?? parseDate(data["expirationDate"])
        let purchase = parseDate(data["originalPurchaseDate"]) ?? parseDate(data["purchaseDate"])
        let notExpired = expiresAt.map { $0 > Date() } ?? true
        return (active && notExpired, expiresAt, purchase)
    }

    private func publishComputerUseEntitlement() {
        let effective = hostedComputerUseState.isActive ? hostedComputerUseState : proMaxComputerUseState
        hostedComputerUseIsActive = effective.isActive
        hostedComputerUseExpirationDate = effective.expiresAt
        hostedComputerUsePurchaseDate = effective.purchase
    }

    private func parseDate(_ raw: Any?) -> Date? {
        switch raw {
        case let timestamp as Timestamp: return timestamp.dateValue()
        case let date as Date: return date
        case let seconds as TimeInterval: return Date(timeIntervalSince1970: seconds)
        case let int as Int: return Date(timeIntervalSince1970: TimeInterval(int))
        case let string as String:
            return ISO8601DateFormatter().date(from: string)
        default:
            return nil
        }
    }

    // MARK: - Derived copy helpers

    /// "Member since Apr 2026 · renews monthly" or the relative form. Clamps
    /// sentinel/far-future dates so the chrome never reads "Renews in 73
    /// years" the way the iOS bug did.
    var humanStatus: String {
        guard let expiration = expirationDate else {
            if let purchase = purchaseDate {
                return "Member since " + purchase.formatted(.dateTime.month(.abbreviated).year())
            }
            return "Active"
        }
        let interval = expiration.timeIntervalSinceNow
        let nearTerm = interval > 0 && interval < 90 * 24 * 60 * 60
        let renewClause: String = {
            if nearTerm {
                return "renews \(expiration.formatted(.relative(presentation: .named)))"
            }
            return "renews monthly"
        }()
        if let purchase = purchaseDate {
            return "Member since \(purchase.formatted(.dateTime.month(.abbreviated).year())) · \(renewClause)"
        }
        return "Active · \(renewClause)"
    }
}
