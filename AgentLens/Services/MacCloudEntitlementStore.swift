import Foundation
import SwiftUI
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore

// MARK: - Mac Cloud Entitlement Store
//
// Cross-platform parity with the Android `HostedQuotaSubscriptionStore`
// Firestore listener and iOS `HostedQuotaSubscriptionStore`. macOS has no
// StoreKit purchase flow yet; the canonical entitlement doc written by
// Cloud Functions when an iOS purchase is verified is the authoritative
// source. We listen here so the Mac UI reflects "Cloud Member" state
// without needing a local purchase.
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

@MainActor
final class MacCloudEntitlementStore: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var expirationDate: Date?
    @Published private(set) var purchaseDate: Date?
    @Published private(set) var error: String?

    static let shared = MacCloudEntitlementStore()

    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var started = false

    deinit {
        listener?.remove()
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
        guard let uid else {
            isActive = false
            expirationDate = nil
            purchaseDate = nil
            return
        }
        listener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("entitlements")
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
                    self.apply(data: data)
                }
            }
    }

    private func apply(data: [String: Any]) {
        let active = (data["active"] as? Bool) ?? false
        let expiresAt = parseDate(data["expiresAt"]) ?? parseDate(data["expirationDate"])
        let purchase = parseDate(data["originalPurchaseDate"]) ?? parseDate(data["purchaseDate"])

        let notExpired = expiresAt.map { $0 > Date() } ?? true
        isActive = active && notExpired
        expirationDate = expiresAt
        purchaseDate = purchase
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
