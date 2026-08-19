import Foundation
import StoreKit
import OpenBurnBarCore
import os.log
#if os(iOS)
import UIKit
#endif

@MainActor
protocol HostedQuotaEntitlementServicing: AnyObject {
    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String?
    ) async throws -> String

    func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        signedRenewalInfoJWS: String?,
        productID: String?
    ) async throws -> HostedQuotaEntitlementResponse

    func restoreHostedQuotaEntitlement(
        productID: String?,
        signedTransactionJWS: String?
    ) async throws -> HostedQuotaEntitlementResponse

    func verifyCloudProTopUp(
        signedTransactionJWS: String,
        productID: String
    ) async throws -> CloudProTopUpCreditResponse
}

extension FunctionsRepository: HostedQuotaEntitlementServicing {}

/// Reads the canonical Firestore entitlement doc directly. Used as a fallback
/// when the App Store Server API roundtrip in `restoreHostedQuotaEntitlement`
/// cannot replay the transaction — the doc is still the same authority the
/// Firestore security rules consult to gate the relay, so trusting it here
/// keeps the UI aligned with what the server already permits.
@MainActor
protocol HostedQuotaEntitlementDirectReading: AnyObject {
    func fetchHostedQuotaEntitlement() async throws -> HostedQuotaEntitlementResponse?
}

@MainActor
protocol HostedQuotaTierReading: AnyObject {
    func fetchHostedQuotaTier() async throws -> String?
}

enum HostedQuotaPurchaseOutcome {
    case success(signedTransactionJWS: String, finish: @MainActor () async -> Void)
    case pending
    case userCancelled
}

enum OpenBurnBarStoreProductRole: String, Sendable {
    case subscription
    case topUp
}

struct OpenBurnBarStoreProduct: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let cadence: String
    let fallbackDisplayPrice: String
    let entitlementID: String?
    let role: OpenBurnBarStoreProductRole
    let included: String
    let disclosure: String
    let topUpKind: String?
}

enum OpenBurnBarProductCatalog {
    static let cloudMonthlyProductID = "com.openburnbar.pro.monthly"
    static let cloudAnnualProductID = "com.openburnbar.pro.annual"
    static let cloudProMonthlyProductID = "com.openburnbar.proMax.v2.monthly"
    static let cloudProAnnualProductID = "com.openburnbar.proMax.annual"
    static let cloudUltraMonthlyProductID = "com.openburnbar.ultra.monthly"
    static let cloudUltraAnnualProductID = "com.openburnbar.ultra.annual.v2"
    static let googlePlayCloudProMonthlyProductID = "com.openburnbar.promax.v2.monthly"
    static let googlePlayCloudProAnnualProductID = "com.openburnbar.promax.annual"
    static let googlePlayCloudUltraAnnualProductID = "com.openburnbar.ultra.annual"
    static let agentControl100ActionsProductID = "com.openburnbar.agentControl.actions100"
    static let flooRelay50GBProductID = "com.openburnbar.floo.relay50gb"
    static let elderWandSearches100ProductID = "com.openburnbar.elderWand.searches100"
    static let elderWandSearches500ProductID = "com.openburnbar.elderWand.searches500"
    static let legacyHostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"
    static let legacyHostedQuotaOriginalProductID = "com.openburnbar.hostedQuotaSync.monthly"
    static let legacyHostedComputerUseProductID = "com.openburnbar.hostedComputerUseSync.monthly"
    static let legacyComputerUseProductID = "com.openburnbar.computerUse.monthly"
    static let legacyProMaxProductID = "com.openburnbar.proMax.monthly"
    static let legacyProMaxBundleProductID = "com.openburnbar.proMax.bundle.monthly"

    static let subscriptions: [OpenBurnBarStoreProduct] = [
        OpenBurnBarStoreProduct(
            id: cloudMonthlyProductID,
            title: "BurnBar Cloud",
            cadence: "Monthly",
            fallbackDisplayPrice: "$7.99",
            entitlementID: "burnbar_pro",
            role: .subscription,
            included: "Sync, encrypted session backup, cloud search, Intelligence Brief fallback, remote relay, and Hosted Remote MCP.",
            disclosure: "1 month, auto-renews monthly. Apple shows any eligible introductory offer before purchase.",
            topUpKind: nil
        ),
        OpenBurnBarStoreProduct(
            id: cloudAnnualProductID,
            title: "BurnBar Cloud",
            cadence: "Annual",
            fallbackDisplayPrice: "$79",
            entitlementID: "burnbar_pro",
            role: .subscription,
            included: "Everything in BurnBar Cloud monthly with annual billing.",
            disclosure: "1 year, auto-renews annually. Apple shows any eligible introductory offer before purchase.",
            topUpKind: nil
        ),
        OpenBurnBarStoreProduct(
            id: cloudProMonthlyProductID,
            title: "BurnBar Cloud Pro",
            cadence: "Monthly",
            fallbackDisplayPrice: "$24.99",
            entitlementID: "burnbar_pro_max",
            role: .subscription,
            included: "BurnBar Cloud plus Floo live phone-to-Mac control, file transfer, calls, shared clipboard, supervised Agent Control, 500 hosted actions, and 50 relay GB.",
            disclosure: "1 month, auto-renews monthly.",
            topUpKind: nil
        ),
        OpenBurnBarStoreProduct(
            id: cloudProAnnualProductID,
            title: "BurnBar Cloud Pro",
            cadence: "Annual",
            fallbackDisplayPrice: "$249",
            entitlementID: "burnbar_pro_max",
            role: .subscription,
            included: "Everything in BurnBar Cloud Pro monthly with annual billing.",
            disclosure: "1 year, auto-renews annually.",
            topUpKind: nil
        ),
        OpenBurnBarStoreProduct(
            id: cloudUltraMonthlyProductID,
            title: "BurnBar Cloud Ultra",
            cadence: "Monthly",
            fallbackDisplayPrice: "$59.99",
            entitlementID: "burnbar_ultra",
            role: .subscription,
            included: "Everything in BurnBar Cloud Pro plus 10x agent memory — 100 sources, 500,000 chunks, 10 GB. Memory text is sealed on-device; hosted recall is opt-in and the cloaked structures still reveal patterns. Same hosted Agent Control and relay allowance as Pro.",
            disclosure: "1 month, auto-renews monthly.",
            topUpKind: nil
        ),
        OpenBurnBarStoreProduct(
            id: cloudUltraAnnualProductID,
            title: "BurnBar Cloud Ultra",
            cadence: "Annual",
            fallbackDisplayPrice: "$599",
            entitlementID: "burnbar_ultra",
            role: .subscription,
            included: "Everything in BurnBar Cloud Ultra monthly with annual billing.",
            disclosure: "1 year, auto-renews annually.",
            topUpKind: nil
        )
    ]

    static let topUps: [OpenBurnBarStoreProduct] = [
        OpenBurnBarStoreProduct(
            id: agentControl100ActionsProductID,
            title: "Agent Control actions",
            cadence: "100 hosted actions",
            fallbackDisplayPrice: "$4.99",
            entitlementID: nil,
            role: .topUp,
            included: "Adds 100 prepaid hosted Agent Control actions to the current Cloud Pro or Ultra month.",
            disclosure: "Consumable top-up. Requires an active BurnBar Cloud Pro or Ultra subscription.",
            topUpKind: "agent_control_actions_100"
        ),
        OpenBurnBarStoreProduct(
            id: flooRelay50GBProductID,
            title: "Floo relay data",
            cadence: "50 relay GB",
            fallbackDisplayPrice: "$4.99",
            entitlementID: nil,
            role: .topUp,
            included: "Adds 50 prepaid Floo relay GB to the current Cloud Pro or Ultra month.",
            disclosure: "Consumable top-up. Requires an active BurnBar Cloud Pro or Ultra subscription.",
            topUpKind: "floo_relay_50gb"
        ),
        OpenBurnBarStoreProduct(
            id: elderWandSearches100ProductID,
            title: "Elder Wand Search",
            cadence: "100 hosted searches",
            fallbackDisplayPrice: "$4.99",
            entitlementID: nil,
            role: .topUp,
            included: "Adds 100 hosted web_search credits for Elder Wand Fusion to the current Cloud Pro or Ultra month.",
            disclosure: "Consumable top-up. Requires an active BurnBar Cloud Pro or Ultra subscription.",
            topUpKind: "elder_wand_searches_100"
        ),
        OpenBurnBarStoreProduct(
            id: elderWandSearches500ProductID,
            title: "Elder Wand Search",
            cadence: "500 hosted searches",
            fallbackDisplayPrice: "$19.99",
            entitlementID: nil,
            role: .topUp,
            included: "Adds 500 hosted web_search credits for Elder Wand Fusion to the current Cloud Pro or Ultra month.",
            disclosure: "Consumable top-up. Requires an active BurnBar Cloud Pro or Ultra subscription.",
            topUpKind: "elder_wand_searches_500"
        )
    ]

    /// What the storefront actually SELLS today. The Agent Control and Floo
    /// relay packs are deliberately withheld: their reserve callables have no
    /// client callers yet, so a purchased pack would credit units nothing can
    /// ever spend. They return to sale the day a client calls the reserve.
    /// The full `topUps` catalog stays intact so prior purchases still
    /// restore, credit, and display correctly.
    static let purchasableTopUps = topUps.filter {
        $0.topUpKind?.hasPrefix("elder_wand_") == true
    }

    static let visibleProducts = subscriptions + topUps
    static let visibleProductIDs = visibleProducts.map(\.id)
    static let entitlementProductIDs: Set<String> = Set(subscriptions.map(\.id)).union([
        googlePlayCloudProMonthlyProductID,
        googlePlayCloudProAnnualProductID,
        googlePlayCloudUltraAnnualProductID,
        legacyHostedQuotaProductID,
        legacyHostedQuotaOriginalProductID,
        legacyComputerUseProductID,
        legacyProMaxBundleProductID,
        legacyHostedComputerUseProductID,
        legacyProMaxProductID
    ])

    static func product(for id: String) -> OpenBurnBarStoreProduct? {
        visibleProducts.first(where: { $0.id == id })
    }
}

struct CloudProTopUpCreditResponse: Equatable, Sendable {
    let credited: Bool
    let monthKey: String
    let units: Int
    let kind: String
}

struct HostedQuotaStoreProduct: Identifiable, Sendable {
    let id: String
    let displayPrice: String
    fileprivate let storeKitProduct: Product?

    init(id: String, displayPrice: String, storeKitProduct: Product? = nil) {
        self.id = id
        self.displayPrice = displayPrice
        self.storeKitProduct = storeKitProduct
    }
}

typealias HostedQuotaProductPurchaseExecutor = @MainActor (
    HostedQuotaStoreProduct,
    Set<Product.PurchaseOption>
) async throws -> HostedQuotaPurchaseOutcome

typealias HostedQuotaAppStoreSync = @MainActor () async throws -> Void
typealias HostedQuotaProductCatalogFetcher = @MainActor ([String]) async throws -> [HostedQuotaStoreProduct]
typealias HostedQuotaAuthStateReader = @MainActor () -> Bool
typealias HostedQuotaEntitlementEnvironmentFilter = @MainActor (String?) -> Bool

struct HostedQuotaCurrentEntitlement: Sendable {
    let productID: String
    let signedTransactionJWS: String
    let expirationDate: Date?
    let purchaseDate: Date?
    let transactionID: UInt64?
}

typealias HostedQuotaCurrentEntitlementReader = @MainActor () async -> [HostedQuotaCurrentEntitlement]

/// StoreKit 2 surface for the Apple-verified hosted-quota entitlement.
///
/// Trust model:
///   - The server is the single source of truth for entitlement state.
///     Cloud Functions verify every JWS against AppleRootCA-G3 / G2 /
///     AppleInc Root, reconcile against the App Store Server API, and
///     write `users/{uid}/entitlements/hosted_quota_sync`.
///   - This client never trusts a `VerificationResult` on its own; it
///     only forwards the raw signed JWS string to the server and renders
///     the canonical response.
///   - Before `Product.purchase()`, the client calls
///     `beginEntitlementBinding` to mint an `appAccountToken` (UUID)
///     bound to the signed-in Firebase UID. StoreKit embeds that token
///     in the resulting transaction JWS, which the server uses to
///     attribute the purchase without trusting in-flight callable args.
///   - `Transaction.updates` is observed for the lifetime of the app so
///     renewals and revocations refresh the entitlement automatically.
@Observable
@MainActor
final class HostedQuotaSubscriptionStore {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "HostedQuotaSubscriptionStore")
    static let productID = OpenBurnBarProductCatalog.cloudMonthlyProductID
    static let legacyHostedQuotaProductID = OpenBurnBarProductCatalog.legacyHostedQuotaProductID
    static let legacyHostedQuotaOriginalProductID = OpenBurnBarProductCatalog.legacyHostedQuotaOriginalProductID
    static let hostedComputerUseProductID = OpenBurnBarProductCatalog.legacyComputerUseProductID
    static let proMaxProductID = OpenBurnBarProductCatalog.legacyProMaxBundleProductID
    static let legacyHostedComputerUseProductID = OpenBurnBarProductCatalog.legacyHostedComputerUseProductID
    static let legacyProMaxProductID = OpenBurnBarProductCatalog.legacyProMaxProductID
    static let cloudAnnualProductID = OpenBurnBarProductCatalog.cloudAnnualProductID
    static let cloudProMonthlyProductID = OpenBurnBarProductCatalog.cloudProMonthlyProductID
    static let cloudProAnnualProductID = OpenBurnBarProductCatalog.cloudProAnnualProductID
    static let cloudUltraMonthlyProductID = OpenBurnBarProductCatalog.cloudUltraMonthlyProductID
    static let cloudUltraAnnualProductID = OpenBurnBarProductCatalog.cloudUltraAnnualProductID
    static let agentControl100ActionsProductID = OpenBurnBarProductCatalog.agentControl100ActionsProductID
    static let flooRelay50GBProductID = OpenBurnBarProductCatalog.flooRelay50GBProductID
    static let elderWandSearches100ProductID = OpenBurnBarProductCatalog.elderWandSearches100ProductID
    static let elderWandSearches500ProductID = OpenBurnBarProductCatalog.elderWandSearches500ProductID

    /// Every App Store-reviewable auto-renewable subscription and consumable
    /// top-up this build presents in StoreKit.
    static let appStoreReviewVisibleProductIDs = OpenBurnBarProductCatalog.visibleProductIDs

    private static let entitlementProductIDs = OpenBurnBarProductCatalog.entitlementProductIDs

    private let functions: any HostedQuotaEntitlementServicing
    private let directReader: (any HostedQuotaEntitlementDirectReading)?
    private let tierReader: (any HostedQuotaTierReading)?
    private let purchaseProduct: HostedQuotaProductPurchaseExecutor
    private let syncAppStore: HostedQuotaAppStoreSync
    private let fetchProducts: HostedQuotaProductCatalogFetcher
    private let isSignedIn: HostedQuotaAuthStateReader
    private let acceptsEntitlementEnvironment: HostedQuotaEntitlementEnvironmentFilter
    private let currentEntitlementReader: HostedQuotaCurrentEntitlementReader
    private let observeTransactionUpdates: Bool

    private(set) var product: HostedQuotaStoreProduct?
    private(set) var productsByID: [String: HostedQuotaStoreProduct] = [:]
    private(set) var isActive = false
    private(set) var activeProductID: String?
    private(set) var expirationDate: Date?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var error: String?

    /// First-purchase date of the user's currently-active entitlement, sourced
    /// from `Transaction.originalPurchaseDate`. Used by the store screen's
    /// member card ("Member since …"). `nil` while no local entitlement is
    /// visible (server-only restores fall back to `expirationDate` for chrome).
    private(set) var purchaseDate: Date?

    /// The StoreKit transaction id for the entitlement currently displayed.
    /// Surfaced for diagnostics in the member card footer; not used for any
    /// trust decision.
    private(set) var latestTransactionID: UInt64?
    private(set) var lastTopUpCredit: CloudProTopUpCreditResponse?

    @ObservationIgnored private nonisolated(unsafe) var transactionUpdatesTask: Task<Void, Never>?

    /// Serializes inbound `verifyOnServer` calls. StoreKit can race a
    /// `purchase()`-emitted `verifyOnServer` against a near-simultaneous
    /// `Transaction.updates` event for the same JWS. We coalesce on the
    /// JWS representation so the second call awaits the first.
    private var inFlightVerifyByJWS: [String: Task<HostedQuotaEntitlementResponse, Error>] = [:]

    init(
        functions: any HostedQuotaEntitlementServicing = FunctionsRepository.shared,
        directReader: (any HostedQuotaEntitlementDirectReading)? = FirestoreRepository.shared,
        tierReader: (any HostedQuotaTierReading)? = FunctionsDataVaultService.shared,
        purchaseProduct: @escaping HostedQuotaProductPurchaseExecutor = HostedQuotaSubscriptionStore.purchaseProduct,
        syncAppStore: @escaping HostedQuotaAppStoreSync = HostedQuotaSubscriptionStore.syncAppStore,
        fetchProducts: @escaping HostedQuotaProductCatalogFetcher = HostedQuotaSubscriptionStore.fetchProducts,
        isSignedIn: @escaping HostedQuotaAuthStateReader = { AuthRepository.shared.isSignedIn },
        acceptsEntitlementEnvironment: @escaping HostedQuotaEntitlementEnvironmentFilter =
            HostedQuotaSubscriptionStore.acceptsCurrentRuntimeEntitlementEnvironment,
        currentEntitlementReader: @escaping HostedQuotaCurrentEntitlementReader =
            HostedQuotaSubscriptionStore.currentStoreKitEntitlements,
        observeTransactionUpdates: Bool = true
    ) {
        self.functions = functions
        self.directReader = directReader
        self.tierReader = tierReader
        self.purchaseProduct = purchaseProduct
        self.syncAppStore = syncAppStore
        self.fetchProducts = fetchProducts
        self.isSignedIn = isSignedIn
        self.acceptsEntitlementEnvironment = acceptsEntitlementEnvironment
        self.currentEntitlementReader = currentEntitlementReader
        self.observeTransactionUpdates = observeTransactionUpdates
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    private func clearEntitlementState() {
        isActive = false
        activeProductID = nil
        expirationDate = nil
        purchaseDate = nil
        latestTransactionID = nil
        UltraTierBridge.shared.tier = nil
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        if observeTransactionUpdates {
            startObservingTransactionUpdates()
        }
        guard isSignedIn() else {
            clearEntitlementState()
            await loadProductMetadataIfAvailable()
            return
        }
        do {
            try await refreshEntitlement()
        } catch {
            if self.error == nil {
                self.error = error.localizedDescription
            }
        }
        await loadProductMetadataIfAvailable()
    }

    /// Buy the hosted-quota subscription. The pre-purchase
    /// `beginEntitlementBinding` call is what allows the server to
    /// attribute the resulting JWS back to this Firebase UID without
    /// trusting any client-supplied identifier.
    func purchase(productID: String = HostedQuotaSubscriptionStore.productID) async {
        guard !isPurchasing else { return }
        let catalogProduct = OpenBurnBarProductCatalog.product(for: productID)
        let isTopUp = catalogProduct?.role == .topUp
        let signedIn = isSignedIn()
        if isTopUp, !signedIn {
            error = HostedQuotaSubscriptionError.signedOutConsumablePurchase.localizedDescription
            return
        }
        guard isTopUp || signedIn else {
            error = HostedQuotaSubscriptionError.signedOutSubscriptionPurchase.localizedDescription
            return
        }
        isPurchasing = true
        error = nil
        defer { isPurchasing = false }
        do {
            let product = try await productMetadata(for: productID)
            if productID == Self.productID {
                self.product = product
            }
            let token = try await mintAppAccountToken(productID: productID)
            let purchaseOptions: Set<Product.PurchaseOption> = [.appAccountToken(token)]
            let result = try await purchaseProduct(product, purchaseOptions)
            switch result {
            case .success(let signedTransactionJWS, let finish):
                if isTopUp {
                    try await verifyTopUpOnServer(jws: signedTransactionJWS, productID: productID)
                    await finish()
                    return
                }
                do {
                    try await verifyOnServer(jws: signedTransactionJWS, productID: productID)
                    await finish()
                } catch {
                    if await recoverEntitlementAfterVerificationFailure(jws: signedTransactionJWS, productID: productID) {
                        await finish()
                    } else {
                        throw error
                    }
                }
            case .pending, .userCancelled:
                break
            }
        } catch {
            if !isTopUp, await recoverExistingEntitlementAfterStoreKitFailure() {
                return
            }
            self.error = error.localizedDescription
        }
    }

    /// Apple's HIG-mandated "Restore Purchases" affordance. Triggers an
    /// `AppStore.sync()` (forces StoreKit to revalidate with Apple
    /// servers, can prompt for App Store password), then walks
    /// `Transaction.currentEntitlements` for any active subscription
    /// matching our productID. If found, the JWS is forwarded to the
    /// server for verification + reconciliation. If not, falls back to
    /// the server-side reconcile path keyed off any existing entitlement
    /// doc, so users who paid on a previous install can still recover.
    func restorePurchases() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // 1) Force StoreKit to refresh from Apple. May prompt the
            //    user for their Apple ID password — that's the expected
            //    Apple behaviour and the only way `currentEntitlements`
            //    reflects fresh server state on a brand-new install.
            try await syncAppStore()

            // 2) Walk local entitlements. The first matching active JWS
            //    wins; we forward only the raw JWS so the server is the
            //    sole arbiter of activation.
            let matchedEntitlement = await findCurrentEntitlement()
            guard isSignedIn() else {
                self.error = Self.signedOutRestoreMessage
                return
            }
            if let matchedEntitlement {
                let response = try await functions.restoreHostedQuotaEntitlement(
                    productID: matchedEntitlement.productID,
                    signedTransactionJWS: matchedEntitlement.signedTransactionJWS
                )
                apply(response: response)
                return
            }

            if await applyDirectReadIfActive() {
                return
            }
            if await applyServerResolvedTierIfActive() {
                return
            }

            // 3) No local entitlement — try the server-side fallback
            //    (works only if a prior entitlement doc exists for the
            //    signed-in UID).
            let response = try await functions.restoreHostedQuotaEntitlement(
                productID: Self.productID,
                signedTransactionJWS: nil
            )
            apply(response: response)
            if !isActive {
                if await applyDirectReadIfActive() {
                    return
                }
                await applyServerResolvedTierIfActive()
            }
        } catch {
            if await recoverExistingEntitlementAfterStoreKitFailure() {
                return
            }
            // We surface the human-readable form. The server's
            // `failed-precondition` for "no entitlement on file" is
            // expected when a brand-new user taps Restore without ever
            // having purchased; the message is clear enough as-is.
            self.error = error.localizedDescription
        }
    }

    /// Sync any active StoreKit entitlement up to the server, or fall
    /// back to the server's view when no local transaction exists.
    func refreshEntitlement() async throws {
        try await refreshEntitlement(preverifiedResponse: nil)
    }

    private func refreshEntitlement(
        preverifiedResponse: (jws: String, response: HostedQuotaEntitlementResponse)?
    ) async throws {
        guard isSignedIn() else {
            clearEntitlementState()
            return
        }

        if let matchedEntitlement = await findCurrentEntitlement() {
            if preverifiedResponse?.jws == matchedEntitlement.signedTransactionJWS,
               let response = preverifiedResponse?.response {
                apply(response: response)
            } else {
                try await verifyOnServer(
                    jws: matchedEntitlement.signedTransactionJWS,
                    productID: matchedEntitlement.productID
                )
            }
            if !isActive {
                await applyDirectReadIfActive()
            }
        } else {
            // Server-seeded and pro-mirrored members may not have a local
            // StoreKit transaction on this device. Read the canonical
            // Firestore entitlement first so membership chrome matches the
            // same doc the relay/rules already trust, then use the callable
            // restore path only as a reconciliation fallback.
            if await applyDirectReadIfActive() {
                return
            }
            if await applyServerResolvedTierIfActive() {
                return
            }

            // No local entitlement to surface. Try the server-side
            // restore path so users who previously paid (and have a
            // doc on file) still see their entitlement on this device.
            do {
                let response = try await functions.restoreHostedQuotaEntitlement(
                    productID: Self.productID,
                    signedTransactionJWS: nil
                )
                apply(response: response)
                if !isActive {
                    if await applyDirectReadIfActive() {
                        return
                    }
                    await applyServerResolvedTierIfActive()
                }
            } catch {
                // ASC roundtrip failed (e.g. owner-seeded test entitlement
                // with no real Apple transaction). Fall back to the same
                // entitlement doc the Firestore rules use to gate the relay.
                let directReadRecovered = await applyDirectReadIfActive()
                let serverTierRecovered = directReadRecovered ? false : await applyServerResolvedTierIfActive()
                if !directReadRecovered && !serverTierRecovered {
                    clearEntitlementState()
                }
            }
        }
    }

    /// Read the Firestore entitlement doc directly and apply it when it
    /// represents an active, unexpired entitlement for the configured product.
    /// Returns `true` when the direct read flipped state to active.
    @discardableResult
    private func applyDirectReadIfActive() async -> Bool {
        guard let directReader else { return false }
        do {
            guard let response = try await directReader.fetchHostedQuotaEntitlement() else {
                return false
            }
            guard response.active,
                  Self.entitlementProductIDs.contains(response.productID),
                  acceptsEntitlementEnvironment(response.environment),
                  let expires = response.expiresAt,
                  expires > Date() else {
                return false
            }
            apply(response: response)
            return isActive
        } catch {
            // Recovery probe — "false" just moves callers to the next source,
            // but log the read failure so entitlement-recovery gaps are traceable.
            Self.log.warning("applyDirectReadIfActive: entitlement document read failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// iOS 27 keeps Firestore networking disabled to avoid a Firebase gRPC crash,
    /// so direct document reads can miss a live entitlement. The Data Vault
    /// callable resolves the same tier server-side over the Functions channel.
    @discardableResult
    private func applyServerResolvedTierIfActive() async -> Bool {
        guard let tierReader else { return false }
        do {
            guard let tier = try await tierReader.fetchHostedQuotaTier() else {
                return false
            }
            return apply(serverResolvedTier: tier)
        } catch {
            // Recovery probe — "false" just moves callers to the next source,
            // but log the callable failure so entitlement-recovery gaps are traceable.
            Self.log.warning("applyServerResolvedTierIfActive: tier callable failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func apply(serverResolvedTier rawTier: String) -> Bool {
        let tier = rawTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let productID: String
        switch tier {
        case "ultra":
            productID = Self.cloudUltraMonthlyProductID
        case "pro", "cloud_pro", "cloudpro":
            productID = Self.cloudProMonthlyProductID
        case "cloud", "premium":
            productID = Self.productID
        default:
            clearEntitlementState()
            return false
        }
        UltraTierBridge.shared.tier = tier
        isActive = true
        activeProductID = productID
        expirationDate = nil
        return true
    }

    /// Resolve all verified StoreKit entitlements to one deterministic
    /// membership authority. Tier always wins before dates
    /// (Ultra → Pro → Cloud); within a tier, the later expiration, purchase,
    /// and transaction id win in that order. StoreKit sequence order is never
    /// treated as entitlement authority.
    private func findCurrentEntitlement() async -> HostedQuotaCurrentEntitlement? {
        guard let entitlement = Self.preferredCurrentEntitlement(
            from: await currentEntitlementReader()
        ) else { return nil }
        purchaseDate = entitlement.purchaseDate
        latestTransactionID = entitlement.transactionID
        return entitlement
    }

    static func preferredCurrentEntitlement(
        from entitlements: [HostedQuotaCurrentEntitlement]
    ) -> HostedQuotaCurrentEntitlement? {
        entitlements
            .filter { entitlementProductIDs.contains($0.productID) }
            .max { lhs, rhs in
                let lhsTier = entitlementTierRank(for: lhs.productID)
                let rhsTier = entitlementTierRank(for: rhs.productID)
                if lhsTier != rhsTier { return lhsTier < rhsTier }

                let lhsExpiration = lhs.expirationDate ?? .distantFuture
                let rhsExpiration = rhs.expirationDate ?? .distantFuture
                if lhsExpiration != rhsExpiration { return lhsExpiration < rhsExpiration }

                let lhsPurchase = lhs.purchaseDate ?? .distantPast
                let rhsPurchase = rhs.purchaseDate ?? .distantPast
                if lhsPurchase != rhsPurchase { return lhsPurchase < rhsPurchase }

                let lhsTransactionID = lhs.transactionID ?? 0
                let rhsTransactionID = rhs.transactionID ?? 0
                if lhsTransactionID != rhsTransactionID {
                    return lhsTransactionID < rhsTransactionID
                }
                return lhs.productID < rhs.productID
            }
    }

    private static func entitlementTierRank(for productID: String) -> Int {
        switch resolvedTierName(for: productID) {
        case "ultra": return 3
        case "pro": return 2
        case "cloud": return 1
        default: return 0
        }
    }

    private static func currentStoreKitEntitlements() async -> [HostedQuotaCurrentEntitlement] {
        var entitlements: [HostedQuotaCurrentEntitlement] = []
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try Self.checked(result)
                guard Self.entitlementProductIDs.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expires = transaction.expirationDate, expires <= Date() {
                    continue
                }
                entitlements.append(
                    HostedQuotaCurrentEntitlement(
                        productID: transaction.productID,
                        signedTransactionJWS: result.jwsRepresentation,
                        expirationDate: transaction.expirationDate,
                        purchaseDate: transaction.originalPurchaseDate,
                        transactionID: transaction.id
                    )
                )
            } catch {
                // Skip unverified entitlements — the server is the
                // source of truth, but there's no point sending a
                // payload StoreKit itself flagged as suspect.
                continue
            }
        }
        return entitlements
    }

    // MARK: Internals

    private func startObservingTransactionUpdates() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(update)
            }
        }
    }

    private func handleTransactionUpdate(_ update: VerificationResult<Transaction>) async {
        do {
            let transaction = try Self.checked(update)
            guard Self.entitlementProductIDs.contains(transaction.productID) else { return }
            await reconcileTransactionUpdate(
                signedTransactionJWS: update.jwsRepresentation,
                productID: transaction.productID,
                finish: { await transaction.finish() }
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reconcile the updated transaction server-side without applying its tier
    /// directly, then atomically resolve the complete current-entitlement set.
    /// This prevents a lower-tier renewal/update from visually downgrading an
    /// active Ultra or Pro membership while multiple StoreKit entitlements
    /// overlap.
    func reconcileTransactionUpdate(
        signedTransactionJWS: String,
        productID: String,
        finish: @MainActor () async -> Void
    ) async {
        guard Self.entitlementProductIDs.contains(productID) else { return }
        do {
            let reconciledResponse: HostedQuotaEntitlementResponse
            do {
                reconciledResponse = try await verifyOnServer(
                    jws: signedTransactionJWS,
                    productID: productID,
                    applyResponse: false
                )
            } catch {
                reconciledResponse = try await functions.restoreHostedQuotaEntitlement(
                    productID: productID,
                    signedTransactionJWS: signedTransactionJWS
                )
            }
            try await refreshEntitlement(
                preverifiedResponse: (
                    jws: signedTransactionJWS,
                    response: reconciledResponse
                )
            )
            await finish()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mintAppAccountToken(productID: String = HostedQuotaSubscriptionStore.productID) async throws -> UUID {
        let raw = try await functions.beginEntitlementBinding(
            productID: productID,
            clientPlatform: HostedQuotaSubscriptionStore.platformIdentifier
        )
        guard let uuid = UUID(uuidString: raw) else {
            throw HostedQuotaSubscriptionError.invalidBindingToken
        }
        return uuid
    }

    /// Verify a JWS against the server. Concurrent calls for the same
    /// JWS share a single in-flight Task, so a `purchase()` outcome
    /// racing a `Transaction.updates` event won't double-call the
    /// callable nor cause UI flicker on the entitlement state.
    @discardableResult
    private func verifyOnServer(
        jws: String,
        productID: String = HostedQuotaSubscriptionStore.productID,
        applyResponse: Bool = true
    ) async throws -> HostedQuotaEntitlementResponse {
        if let existing = inFlightVerifyByJWS[jws] {
            let response = try await existing.value
            if applyResponse {
                apply(response: response)
            }
            return response
        }
        let task = Task<HostedQuotaEntitlementResponse, Error> { [weak self] in
            guard let self else {
                throw HostedQuotaSubscriptionError.entitlementStoreReleased
            }
            return try await self.functions.verifyHostedQuotaEntitlement(
                signedTransactionJWS: jws,
                signedRenewalInfoJWS: nil,
                productID: productID
            )
        }
        inFlightVerifyByJWS[jws] = task
        defer { inFlightVerifyByJWS.removeValue(forKey: jws) }
        let response = try await task.value
        if applyResponse {
            apply(response: response)
        }
        return response
    }

    @discardableResult
    private func recoverEntitlementAfterVerificationFailure(jws: String, productID: String = HostedQuotaSubscriptionStore.productID) async -> Bool {
        do {
            let response = try await functions.restoreHostedQuotaEntitlement(
                productID: productID,
                signedTransactionJWS: jws
            )
            apply(response: response)
            if isActive { return true }
        } catch {
            // Fall through to the Firestore read used by relay security rules.
            Self.log.warning("recoverEntitlementAfterVerificationFailure: restore callable failed: \(error.localizedDescription, privacy: .public)")
        }
        if await applyDirectReadIfActive() {
            return true
        }
        return await applyServerResolvedTierIfActive()
    }

    private func recoverExistingEntitlementAfterStoreKitFailure() async -> Bool {
        guard isSignedIn() else { return false }
        if await applyDirectReadIfActive() {
            error = nil
            return true
        }
        if await applyServerResolvedTierIfActive() {
            error = nil
            return true
        }
        do {
            try await refreshEntitlement()
            if isActive {
                error = nil
                return true
            }
        } catch {
            // Keep the original StoreKit-facing error unless the recovery path
            // finds a live server entitlement.
            Self.log.warning("recoverExistingEntitlementAfterStoreKitFailure: refreshEntitlement failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    private func apply(response: HostedQuotaEntitlementResponse) {
        let active = response.active &&
            Self.entitlementProductIDs.contains(response.productID) &&
            acceptsEntitlementEnvironment(response.environment)
        guard active else {
            clearEntitlementState()
            return
        }
        isActive = true
        activeProductID = response.productID
        expirationDate = response.expiresAt
        UltraTierBridge.shared.tier = Self.resolvedTierName(for: response.productID)
    }

    private static func resolvedTierName(for productID: String) -> String? {
        if productID == Self.cloudUltraMonthlyProductID ||
            productID == Self.cloudUltraAnnualProductID ||
            productID == OpenBurnBarProductCatalog.googlePlayCloudUltraAnnualProductID {
            return "ultra"
        }
        if productID == Self.cloudProMonthlyProductID ||
            productID == Self.cloudProAnnualProductID ||
            productID == OpenBurnBarProductCatalog.googlePlayCloudProMonthlyProductID ||
            productID == OpenBurnBarProductCatalog.googlePlayCloudProAnnualProductID ||
            productID == Self.legacyProMaxProductID ||
            productID == Self.proMaxProductID ||
            productID == Self.legacyHostedComputerUseProductID ||
            productID == Self.hostedComputerUseProductID {
            return "pro"
        }
        if productID == Self.productID ||
            productID == Self.cloudAnnualProductID ||
            productID == Self.legacyHostedQuotaProductID ||
            productID == Self.legacyHostedQuotaOriginalProductID {
            return "cloud"
        }
        return nil
    }

    var isActivePro: Bool {
        activeProductID == Self.cloudProMonthlyProductID ||
            activeProductID == Self.cloudProAnnualProductID ||
            // Ultra is strictly above Pro (Ultra ⇒ Pro), so an active Ultra
            // StoreKit subscription unlocks every Pro-gated surface (top-ups,
            // Floo, Agent Control) without re-plumbing each gate.
            activeProductID == Self.cloudUltraMonthlyProductID ||
            activeProductID == Self.cloudUltraAnnualProductID ||
            activeProductID == OpenBurnBarProductCatalog.googlePlayCloudUltraAnnualProductID ||
            activeProductID == OpenBurnBarProductCatalog.googlePlayCloudProMonthlyProductID ||
            activeProductID == OpenBurnBarProductCatalog.googlePlayCloudProAnnualProductID ||
            activeProductID == Self.legacyProMaxProductID ||
            activeProductID == Self.proMaxProductID ||
            activeProductID == Self.legacyHostedComputerUseProductID ||
            activeProductID == Self.hostedComputerUseProductID
    }

    /// True when an *Ultra* auto-renewable subscription product is the active
    /// entitlement. This covers both StoreKit purchases and Firestore direct
    /// reads that return the server-resolved `burnbar_ultra` document.
    var hasActiveUltraStoreKitProduct: Bool {
        activeProductID == Self.cloudUltraMonthlyProductID ||
            activeProductID == Self.cloudUltraAnnualProductID ||
            activeProductID == OpenBurnBarProductCatalog.googlePlayCloudUltraAnnualProductID
    }

    /// The user's resolved membership tier, derived from the same canonical
    /// entitlement predicates the relay/rules trust. Higher tiers strictly
    /// satisfy every lower-tier gate (`CloudTier.satisfies`), so feature
    /// gating reads `store.cloudTier.satisfies(feature.requiredTier)`.
    ///
    /// Resolution order mirrors the gating spec §4.2 (Ultra ⇒ Pro ⇒ Cloud):
    ///   ultra → .ultra; else pro → .pro; else active → .cloud; else .none.
    /// Ultra is the union of the server-resolved data tier and a current Apple
    /// StoreKit Ultra subscription. Server-resolved state also covers purchases
    /// made on Android or granted administratively.
    var cloudTier: CloudTier {
        if isActiveUltra || hasActiveUltraStoreKitProduct { return .ultra }
        if isActivePro { return .pro }
        if isActive { return .cloud }
        return .none
    }

    func storeProduct(for productID: String) -> HostedQuotaStoreProduct? {
        productsByID[productID]
    }

    func displayPrice(for catalogProduct: OpenBurnBarStoreProduct) -> String {
        MobileStoreEntitlementPolicy.displayPrice(
            livePrice: storeProduct(for: catalogProduct.id)?.displayPrice
        ).customerFacingText
    }

    /// Per-month equivalent of an annual plan's price ("$20.75"), derived from
    /// the live StoreKit price when loaded and the catalog fallback otherwise.
    /// `nil` for non-annual products or unparseable prices.
    func monthlyEquivalentDisplayPrice(for catalogProduct: OpenBurnBarStoreProduct) -> String? {
        guard catalogProduct.cadence == "Annual" else { return nil }
        if let product = storeProduct(for: catalogProduct.id)?.storeKitProduct {
            return Self.monthlyEquivalent(annualPrice: product.price, format: product.priceFormatStyle)
        }
        guard let value = Self.numericPrice(from: catalogProduct.fallbackDisplayPrice), value > 0 else { return nil }
        let symbol = catalogProduct.fallbackDisplayPrice.prefix(while: { !$0.isNumber })
        let monthly = NSDecimalNumber(decimal: value / 12).doubleValue
        return "\(symbol)\(String(format: "%.2f", monthly))"
    }

    /// Whole months effectively free on the annual plan versus twelve monthly
    /// renewals (e.g. $249/yr vs $24.99/mo → 2). Uses live StoreKit prices only
    /// when BOTH products are loaded (never mixes a live price with a USD
    /// fallback), and the catalog fallbacks otherwise. `nil` when the saving
    /// comes to less than one month.
    func annualFreeMonths(monthly: OpenBurnBarStoreProduct, annual: OpenBurnBarStoreProduct) -> Int? {
        let monthlyPrice: Decimal?
        let annualPrice: Decimal?
        if let liveMonthly = storeProduct(for: monthly.id)?.storeKitProduct?.price,
           let liveAnnual = storeProduct(for: annual.id)?.storeKitProduct?.price {
            monthlyPrice = liveMonthly
            annualPrice = liveAnnual
        } else {
            monthlyPrice = Self.numericPrice(from: monthly.fallbackDisplayPrice)
            annualPrice = Self.numericPrice(from: annual.fallbackDisplayPrice)
        }
        guard let m = monthlyPrice, let a = annualPrice, m > 0 else { return nil }
        // Round the Decimal BEFORE bridging to NSDecimalNumber.intValue —
        // a full-precision division result overflows the 64-bit mantissa and
        // intValue returns garbage.
        var ratio = (m * 12 - a) / m
        var wholeMonths = Decimal()
        NSDecimalRound(&wholeMonths, &ratio, 0, .down)
        let months = NSDecimalNumber(decimal: wholeMonths).intValue
        return months >= 1 ? months : nil
    }

    /// Per-month equivalent of an annual price, formatted with the currency's
    /// OWN precision — JPY/KRW render whole units, USD renders two decimals.
    /// Never force a fraction length here: zero-fraction currencies would show
    /// bogus sub-units. Internal so tests can pin the behavior per currency.
    static func monthlyEquivalent(annualPrice: Decimal, format: Decimal.FormatStyle.Currency) -> String {
        (annualPrice / 12).formatted(format)
    }

    /// Parses the CATALOG FALLBACK price strings only — those are hardcoded
    /// US-format ("$249") by construction. Do not feed localized strings in:
    /// comma decimal separators and suffix symbols would parse to garbage.
    private static func numericPrice(from display: String) -> Decimal? {
        Decimal(string: display.filter { $0.isNumber || $0 == "." })
    }

    func subscriptionPlan(for productID: String) -> OpenBurnBarStoreProduct? {
        OpenBurnBarProductCatalog.subscriptions.first(where: { $0.id == productID })
    }

    private static func purchaseProduct(
        _ product: HostedQuotaStoreProduct,
        options: Set<Product.PurchaseOption>
    ) async throws -> HostedQuotaPurchaseOutcome {
        guard let storeKitProduct = product.storeKitProduct else {
            throw HostedQuotaSubscriptionError.productUnavailable
        }
        #if os(iOS)
        guard let scene = activePurchaseScene() else {
            throw HostedQuotaSubscriptionError.purchasePresentationUnavailable
        }
        let result = try await storeKitProduct.purchase(confirmIn: scene, options: options)
        #else
        let result = try await storeKitProduct.purchase(options: options)
        #endif
        switch result {
        case .success(let verification):
            let transaction = try checked(verification)
            return .success(
                signedTransactionJWS: verification.jwsRepresentation,
                finish: { await transaction.finish() }
            )
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .pending
        }
    }

    #if os(iOS)
    private static func activePurchaseScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive && !$0.windows.isEmpty })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive && !$0.windows.isEmpty })
            ?? scenes.first(where: { !$0.windows.isEmpty })
            ?? scenes.first
    }
    #endif

    private static func syncAppStore() async throws {
        try await AppStore.sync()
    }

    private static func acceptsCurrentRuntimeEntitlementEnvironment(_ environment: String?) -> Bool {
        guard let environment else { return true }
        switch environment {
        case "Production":
            return true
        case "Sandbox", "Xcode", "LocalTesting":
            return isSandboxStoreKitRuntime
        default:
            return true
        }
    }

    private static var isSandboxStoreKitRuntime: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private static func fetchProducts(for identifiers: [String]) async throws -> [HostedQuotaStoreProduct] {
        let products = try await Product.products(for: identifiers)
        return products.map { HostedQuotaStoreProduct(id: $0.id, displayPrice: $0.displayPrice, storeKitProduct: $0) }
    }

    private func loadProductMetadataIfAvailable() async {
        do {
            let fetched = try await fetchProducts(Self.appStoreReviewVisibleProductIDs)
            productsByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            fillMissingCatalogProducts()
            product = productsByID[Self.productID]
        } catch {
            if self.error == nil {
                self.error = error.localizedDescription
            }
        }
    }

    private func productMetadata(for productID: String) async throws -> HostedQuotaStoreProduct {
        if let product = productsByID[productID] {
            return product
        }
        let fetched = try await fetchProducts([productID])
        for product in fetched {
            productsByID[product.id] = product
        }
        fillMissingCatalogProducts()
        guard let product = productsByID[productID] else {
            throw HostedQuotaSubscriptionError.productUnavailable
        }
        return product
    }

    private func fillMissingCatalogProducts() {
        for catalogProduct in OpenBurnBarProductCatalog.visibleProducts where productsByID[catalogProduct.id] == nil {
            productsByID[catalogProduct.id] = HostedQuotaStoreProduct(
                id: catalogProduct.id,
                displayPrice: MobileStoreEntitlementPolicy.unavailablePriceLabel
            )
        }
    }

    private func verifyTopUpOnServer(jws: String, productID: String) async throws {
        lastTopUpCredit = try await functions.verifyCloudProTopUp(
            signedTransactionJWS: jws,
            productID: productID
        )
    }

    private static func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }

    private static let signedOutRestoreMessage =
        "Sign in to OpenBurnBar before restoring purchases so Apple can link OpenBurnBar Cloud to your account."

    /// Platform tag passed to `beginEntitlementBinding` for diagnostics.
    /// Reading `UIDevice.current` requires a hop to MainActor on iOS;
    /// the enclosing static var is invoked from `@MainActor`-isolated
    /// `mintAppAccountToken`, so this is safe.
    private static var platformIdentifier: String {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "ipados"
        }
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }
}

enum HostedQuotaSubscriptionError: Error, LocalizedError {
    case productUnavailable
    case invalidBindingToken
    case purchasePresentationUnavailable
    case signedOutConsumablePurchase
    case signedOutSubscriptionPurchase
    case entitlementStoreReleased

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "OpenBurnBar Cloud is still loading from the App Store. Please try Subscribe again in a moment."
        case .invalidBindingToken:
            return "Could not initialize the entitlement binding token. Please try again."
        case .purchasePresentationUnavailable:
            return "Could not open the App Store purchase sheet. Please keep OpenBurnBar in the foreground and tap Subscribe again."
        case .signedOutConsumablePurchase:
            return "Sign in to OpenBurnBar before buying Cloud Pro top-ups so the prepaid allowance can be credited to your account."
        case .signedOutSubscriptionPurchase:
            return "Sign in to OpenBurnBar before subscribing so Apple can link OpenBurnBar Cloud to your account."
        case .entitlementStoreReleased:
            return "The Cloud membership store closed before Apple verification completed. Please try again."
        }
    }
}
