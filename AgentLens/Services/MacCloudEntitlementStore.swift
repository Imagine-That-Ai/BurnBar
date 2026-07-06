@preconcurrency import Foundation
import Combine
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import StoreKit

// MARK: - Mac Cloud Entitlement Store
//
// Cross-platform parity with the Android `HostedQuotaSubscriptionStore`
// Firestore listener and iOS `HostedQuotaSubscriptionStore`. The canonical
// entitlement doc written by Cloud Functions after a StoreKit purchase is the
// authoritative source. When that doc is absent, a locally verified StoreKit 2
// snapshot fills the gap so fresh Mac purchases resolve before Firestore catches
// up. We listen here so the Mac UI reflects "Cloud Member" state whether the
// user bought on Mac, iPhone, or iPad.
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

enum MacCloudStoreKitProductCatalog {
    static let cloudMonthlyProductID = "com.openburnbar.pro.monthly"
    static let cloudAnnualProductID = "com.openburnbar.pro.annual"
    static let cloudProMonthlyProductID = "com.openburnbar.proMax.v2.monthly"
    static let cloudProAnnualProductID = "com.openburnbar.proMax.annual"
    static let cloudUltraMonthlyProductID = "com.openburnbar.ultra.monthly"
    static let cloudUltraAnnualProductID = "com.openburnbar.ultra.annual.v2"
    static let legacyCloudUltraAnnualProductID = "com.openburnbar.ultra.annual"
    static let legacyHostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"
    static let legacyHostedQuotaOriginalProductID = "com.openburnbar.hostedQuotaSync.monthly"
    static let legacyHostedComputerUseProductID = "com.openburnbar.hostedComputerUseSync.monthly"
    static let legacyComputerUseProductID = "com.openburnbar.computerUse.monthly"
    static let legacyProMaxProductID = "com.openburnbar.proMax.monthly"
    static let legacyProMaxBundleProductID = "com.openburnbar.proMax.bundle.monthly"

    static let cloudProductIDs: Set<String> = [
        cloudMonthlyProductID,
        cloudAnnualProductID,
        legacyHostedQuotaProductID,
        legacyHostedQuotaOriginalProductID
    ]

    static let proProductIDs: Set<String> = [
        cloudProMonthlyProductID,
        cloudProAnnualProductID,
        legacyComputerUseProductID,
        legacyHostedComputerUseProductID,
        legacyProMaxProductID,
        legacyProMaxBundleProductID
    ]

    static let ultraProductIDs: Set<String> = [
        cloudUltraMonthlyProductID,
        cloudUltraAnnualProductID,
        legacyCloudUltraAnnualProductID
    ]

    static let entitlementProductIDs = cloudProductIDs
        .union(proProductIDs)
        .union(ultraProductIDs)

    static func tier(for productID: String?) -> MacCloudTier? {
        guard let productID else { return nil }
        if ultraProductIDs.contains(productID) { return .ultra }
        if proProductIDs.contains(productID) { return .pro }
        if cloudProductIDs.contains(productID) { return .cloud }
        return nil
    }
}

struct MacStoreKitEntitlementSnapshot: Equatable, Sendable {
    let productID: String
    let expirationDate: Date?
    let purchaseDate: Date?
    let revocationDate: Date?
    let transactionID: UInt64?
    let appAccountToken: UUID?

    init(
        productID: String,
        expirationDate: Date? = nil,
        purchaseDate: Date? = nil,
        revocationDate: Date? = nil,
        transactionID: UInt64? = nil,
        appAccountToken: UUID? = nil
    ) {
        self.productID = productID
        self.expirationDate = expirationDate
        self.purchaseDate = purchaseDate
        self.revocationDate = revocationDate
        self.transactionID = transactionID
        self.appAccountToken = appAccountToken
    }
}

@MainActor
protocol MacStoreKitAppAccountTokenBindingProviding {
    func appAccountToken(_ token: UUID, isBoundToFirebaseUID uid: String) -> Bool
}

@MainActor
final class MacStoreKitAppAccountTokenBindingStore: MacStoreKitAppAccountTokenBindingProviding {
    static let shared = MacStoreKitAppAccountTokenBindingStore()

    private struct Binding: Codable, Equatable {
        let uid: String
        let productID: String
        let createdAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey = "OpenBurnBar.MacStoreKitAppAccountTokenBindings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(appAccountToken token: UUID, uid: String, productID: String) {
        var bindings = load()
        bindings[Self.key(for: token)] = Binding(uid: uid, productID: productID, createdAt: Date())
        save(bindings)
    }

    func appAccountToken(_ token: UUID, isBoundToFirebaseUID uid: String) -> Bool {
        load()[Self.key(for: token)]?.uid == uid
    }

    private static func key(for token: UUID) -> String {
        token.uuidString.lowercased()
    }

    private func load() -> [String: Binding] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Binding].self, from: data)
        } catch {
            return [:]
        }
    }

    private func save(_ bindings: [String: Binding]) {
        do {
            let data = try JSONEncoder().encode(bindings)
            defaults.set(data, forKey: storageKey)
        } catch {
            return
        }
    }
}

@MainActor
protocol MacStoreKitEntitlementProviding {
    func currentEntitlements() async -> [MacStoreKitEntitlementSnapshot]
    func transactionUpdates() -> AsyncStream<Void>
}

struct StoreKitMacEntitlementProvider: MacStoreKitEntitlementProviding {
    func currentEntitlements() async -> [MacStoreKitEntitlementSnapshot] {
        var entitlements: [MacStoreKitEntitlementSnapshot] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            do {
                let transaction = try Self.checked(result)
                guard MacCloudStoreKitProductCatalog.entitlementProductIDs.contains(transaction.productID) else {
                    continue
                }
                entitlements.append(
                    MacStoreKitEntitlementSnapshot(
                        productID: transaction.productID,
                        expirationDate: transaction.expirationDate,
                        purchaseDate: transaction.originalPurchaseDate,
                        revocationDate: transaction.revocationDate,
                        transactionID: transaction.id,
                        appAccountToken: transaction.appAccountToken
                    )
                )
            } catch {
                continue
            }
        }
        return entitlements
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task.detached {
                for await update in StoreKit.Transaction.updates {
                    do {
                        let transaction = try Self.checked(update)
                        guard MacCloudStoreKitProductCatalog.entitlementProductIDs.contains(transaction.productID) else {
                            continue
                        }
                        continuation.yield(())
                    } catch {
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }
}

private struct MacEntitlementActiveState: Equatable {
    let isActive: Bool
    let expiresAt: Date?
    let purchase: Date?
    let transactionID: UInt64?

    static let inactive = MacEntitlementActiveState(
        isActive: false,
        expiresAt: nil,
        purchase: nil,
        transactionID: nil
    )

    func preferred(over existing: MacEntitlementActiveState) -> MacEntitlementActiveState {
        guard isActive else { return existing }
        guard existing.isActive else { return self }
        switch (expiresAt, existing.expiresAt) {
        case let (candidate?, current?):
            return candidate > current ? self : existing
        case (_?, nil):
            return self
        case (nil, _?):
            return existing
        case (nil, nil):
            return self
        }
    }
}

private struct MacMembershipEntitlementState: Equatable {
    var cloud: MacEntitlementActiveState = .inactive
    var pro: MacEntitlementActiveState = .inactive
    var ultra: MacEntitlementActiveState = .inactive

    var isEmpty: Bool {
        !cloud.isActive && !pro.isActive && !ultra.isActive
    }

    mutating func merge(_ entitlement: MacEntitlementActiveState, tier: MacCloudTier) {
        switch tier {
        case .free:
            return
        case .cloud:
            cloud = entitlement.preferred(over: cloud)
        case .pro:
            cloud = entitlement.preferred(over: cloud)
            pro = entitlement.preferred(over: pro)
        case .ultra:
            cloud = entitlement.preferred(over: cloud)
            pro = entitlement.preferred(over: pro)
            ultra = entitlement.preferred(over: ultra)
        }
    }

    static func combined(_ states: [MacMembershipEntitlementState]) -> MacMembershipEntitlementState {
        var combined = MacMembershipEntitlementState()
        for state in states {
            combined.cloud = state.cloud.preferred(over: combined.cloud)
            combined.pro = state.pro.preferred(over: combined.pro)
            combined.ultra = state.ultra.preferred(over: combined.ultra)
        }
        return combined
    }
}

private enum MacCloudMembershipSourceState {
    case missing
    case present(MacMembershipEntitlementState)

    var membership: MacMembershipEntitlementState? {
        switch self {
        case .missing: return nil
        case .present(let state): return state
        }
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
    private var storeKitUpdatesTask: Task<Void, Never>?
    private var started = false
    private let storeKitEntitlementProvider: any MacStoreKitEntitlementProviding
    private let appAccountTokenBindingProvider: any MacStoreKitAppAccountTokenBindingProviding
    private let observesStoreKitTransactions: Bool
    private var signedInUID: String?
    private var hostedQuotaSourceState: MacCloudMembershipSourceState = .missing
    private var hostedComputerUseSourceState: MacCloudMembershipSourceState = .missing
    private var proMaxSourceState: MacCloudMembershipSourceState = .missing
    private var ultraSourceState: MacCloudMembershipSourceState = .missing
    private var localStoreKitMembershipState = MacMembershipEntitlementState()
    private(set) var hasVerifiedStoreKitEntitlementSnapshot = false

    /// Highest tier the member currently holds, resolved from live entitlement
    /// docs with a verified StoreKit 2 fallback. Ultra implies Pro implies Cloud.
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

    init(
        storeKitEntitlementProvider: any MacStoreKitEntitlementProviding = StoreKitMacEntitlementProvider(),
        appAccountTokenBindingProvider: any MacStoreKitAppAccountTokenBindingProviding =
            MacStoreKitAppAccountTokenBindingStore.shared,
        observesStoreKitTransactions: Bool = true,
        signedInUID: String? = nil
    ) {
        self.storeKitEntitlementProvider = storeKitEntitlementProvider
        self.appAccountTokenBindingProvider = appAccountTokenBindingProvider
        self.observesStoreKitTransactions = observesStoreKitTransactions
        self.signedInUID = signedInUID
    }

    deinit {
        listener?.remove()
        computerUseListener?.remove()
        mediaListener?.remove()
        proMaxListener?.remove()
        ultraListener?.remove()
        storeKitUpdatesTask?.cancel()
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
        if observesStoreKitTransactions {
            startObservingStoreKitEntitlements()
        }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartListener(uid: user?.uid)
            }
        }
        restartListener(uid: Auth.auth().currentUser?.uid)
    }

    private func restartListener(uid: String?) {
        let uidChanged = signedInUID != uid
        signedInUID = uid
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
        hostedQuotaSourceState = .missing
        hostedComputerUseSourceState = .missing
        proMaxSourceState = .missing
        ultraSourceState = .missing
        if uidChanged {
            localStoreKitMembershipState = MacMembershipEntitlementState()
            hasVerifiedStoreKitEntitlementSnapshot = false
        }
        guard let uid else {
            localStoreKitMembershipState = MacMembershipEntitlementState()
            hasVerifiedStoreKitEntitlementSnapshot = false
            publishMembershipEntitlements()
            clearHostedMediaEntitlement()
            return
        }
        Task { [weak self] in
            await self?.refreshStoreKitEntitlements()
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
                        // No entitlement doc — leave the local StoreKit 2
                        // snapshot authoritative when it has been verified.
                        self.hostedQuotaSourceState = .missing
                        self.publishMembershipEntitlements()
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
                        self.hostedComputerUseSourceState = .missing
                        self.publishMembershipEntitlements()
                        return
                    }
                    self.applyHostedComputerUse(data: data)
                }
            }
        // cov:ignore-start -- Firebase snapshot callback delivery is integration-only; parser/clear paths are unit-tested
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
        // cov:ignore-end
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
                        self.proMaxSourceState = .missing
                        self.publishMembershipEntitlements()
                        return
                    }
                    self.proMaxSourceState = .present(
                        self.membershipState(data: data, defaultTier: .pro)
                    )
                    self.publishMembershipEntitlements()
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
                        self.ultraSourceState = .missing
                        self.publishMembershipEntitlements()
                        return
                    }
                    self.ultraSourceState = .present(
                        self.membershipState(data: data, defaultTier: .ultra)
                    )
                    self.publishMembershipEntitlements()
                }
            }
    }

    func applyHostedQuota(data: [String: Any]) {
        hostedQuotaSourceState = .present(membershipState(data: data, defaultTier: .cloud))
        publishMembershipEntitlements()
    }

    private func applyHostedComputerUse(data: [String: Any]) {
        hostedComputerUseSourceState = .present(membershipState(data: data, defaultTier: .pro))
        publishMembershipEntitlements()
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

    private func activeEntitlementState(data: [String: Any]) -> MacEntitlementActiveState {
        let active = (data["active"] as? Bool) ?? false
        let expiresAt = parseDate(data["expireAt"])
            ?? parseDate(data["expiresAt"])
            ?? parseDate(data["expirationDate"])
        let purchase = parseDate(data["originalPurchaseDate"]) ?? parseDate(data["purchaseDate"])
        let notExpired = expiresAt.map { $0 > Date() } ?? true
        return MacEntitlementActiveState(
            isActive: active && notExpired,
            expiresAt: expiresAt,
            purchase: purchase,
            transactionID: nil
        )
    }

    private func membershipState(data: [String: Any], defaultTier: MacCloudTier) -> MacMembershipEntitlementState {
        let entitlement = activeEntitlementState(data: data)
        let productID = (data["productID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = MacCloudStoreKitProductCatalog.tier(for: productID) ?? defaultTier
        var state = MacMembershipEntitlementState()
        state.merge(entitlement, tier: tier)
        return state
    }

    private func publishMembershipEntitlements() {
        let cloudStates = [
            hostedQuotaSourceState.membership,
            hostedComputerUseSourceState.membership,
            proMaxSourceState.membership,
            ultraSourceState.membership
        ].compactMap { $0 }

        let effective = cloudStates.isEmpty
            ? localStoreKitMembershipState
            : MacMembershipEntitlementState.combined(cloudStates)

        isActive = effective.cloud.isActive
        expirationDate = effective.cloud.expiresAt
        purchaseDate = effective.cloud.purchase
        hostedComputerUseIsActive = effective.pro.isActive
        hostedComputerUseExpirationDate = effective.pro.expiresAt
        hostedComputerUsePurchaseDate = effective.pro.purchase
        isUltraActive = effective.ultra.isActive
        ultraExpirationDate = effective.ultra.expiresAt
        ultraPurchaseDate = effective.ultra.purchase
    }

    func refreshStoreKitEntitlementsForTesting() async {
        await refreshStoreKitEntitlements()
    }

    func startStoreKitEntitlementObservationForTesting() {
        startObservingStoreKitEntitlements()
    }

    private func startObservingStoreKitEntitlements() {
        guard storeKitUpdatesTask == nil else { return }
        storeKitUpdatesTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.storeKitEntitlementProvider.transactionUpdates() {
                await self.refreshStoreKitEntitlements()
            }
        }
    }

    private func refreshStoreKitEntitlements() async {
        guard let signedInUID else {
            localStoreKitMembershipState = MacMembershipEntitlementState()
            hasVerifiedStoreKitEntitlementSnapshot = false
            publishMembershipEntitlements()
            return
        }
        let snapshots = await storeKitEntitlementProvider.currentEntitlements()
        localStoreKitMembershipState = Self.membershipState(
            fromStoreKitSnapshots: snapshots,
            signedInUID: signedInUID,
            appAccountTokenBindingProvider: appAccountTokenBindingProvider
        )
        hasVerifiedStoreKitEntitlementSnapshot = true
        publishMembershipEntitlements()
    }

    private static func membershipState(
        fromStoreKitSnapshots snapshots: [MacStoreKitEntitlementSnapshot],
        signedInUID: String,
        appAccountTokenBindingProvider: any MacStoreKitAppAccountTokenBindingProviding
    ) -> MacMembershipEntitlementState {
        var state = MacMembershipEntitlementState()
        for snapshot in snapshots {
            // StoreKit entitlements are Apple-ID scoped. The local fallback only
            // trusts transactions carrying a server-minted appAccountToken that
            // this Mac recorded for the currently signed-in Firebase UID. Missing
            // or legacy tokens fail closed to free; migrated legacy purchases must
            // come through the server-authored cloud entitlement docs.
            guard MacCloudStoreKitProductCatalog.entitlementProductIDs.contains(snapshot.productID),
                  snapshot.revocationDate == nil,
                  snapshot.expirationDate.map({ $0 > Date() }) ?? true,
                  let tier = MacCloudStoreKitProductCatalog.tier(for: snapshot.productID),
                  let appAccountToken = snapshot.appAccountToken,
                  appAccountTokenBindingProvider.appAccountToken(
                    appAccountToken,
                    isBoundToFirebaseUID: signedInUID
                  )
            else {
                continue
            }
            state.merge(
                MacEntitlementActiveState(
                    isActive: true,
                    expiresAt: snapshot.expirationDate,
                    purchase: snapshot.purchaseDate,
                    transactionID: snapshot.transactionID
                ),
                tier: tier
            )
        }
        return state
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
