import Foundation
import StoreKit
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
    static let agentControl100ActionsProductID = "com.openburnbar.agentControl.actions100"
    static let flooRelay50GBProductID = "com.openburnbar.floo.relay50gb"
    static let legacyHostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"
    static let legacyHostedQuotaOriginalProductID = "com.openburnbar.hostedQuotaSync.monthly"
    static let legacyHostedComputerUseProductID = "com.openburnbar.hostedComputerUseSync.monthly"
    static let legacyComputerUseProductID = "com.openburnbar.computerUse.monthly"
    static let legacyProMaxProductID = "com.openburnbar.proMax.v2.monthly"
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
            disclosure: "1 month, auto-renews monthly after a 14-day free trial for new subscribers.",
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
            disclosure: "1 year, auto-renews annually after a 14-day free trial for new subscribers.",
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
            disclosure: "1 month, auto-renews monthly. No introductory trial.",
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
            disclosure: "1 year, auto-renews annually. No introductory trial.",
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
            included: "Adds 100 prepaid hosted Agent Control actions to the current Cloud Pro month.",
            disclosure: "Consumable top-up. Requires an active BurnBar Cloud Pro subscription.",
            topUpKind: "agent_control_actions_100"
        ),
        OpenBurnBarStoreProduct(
            id: flooRelay50GBProductID,
            title: "Floo relay data",
            cadence: "50 relay GB",
            fallbackDisplayPrice: "$4.99",
            entitlementID: nil,
            role: .topUp,
            included: "Adds 50 prepaid Floo relay GB to the current Cloud Pro month.",
            disclosure: "Consumable top-up. Requires an active BurnBar Cloud Pro subscription.",
            topUpKind: "floo_relay_50gb"
        )
    ]

    static let visibleProducts = subscriptions + topUps
    static let visibleProductIDs = visibleProducts.map(\.id)
    static let entitlementProductIDs: Set<String> = Set(subscriptions.map(\.id)).union([
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
    static let agentControl100ActionsProductID = OpenBurnBarProductCatalog.agentControl100ActionsProductID
    static let flooRelay50GBProductID = OpenBurnBarProductCatalog.flooRelay50GBProductID

    /// Every App Store-reviewable auto-renewable subscription and consumable
    /// top-up this build presents in StoreKit.
    static let appStoreReviewVisibleProductIDs = OpenBurnBarProductCatalog.visibleProductIDs

    private static let entitlementProductIDs = OpenBurnBarProductCatalog.entitlementProductIDs

    private let functions: any HostedQuotaEntitlementServicing
    private let directReader: (any HostedQuotaEntitlementDirectReading)?
    private let purchaseProduct: HostedQuotaProductPurchaseExecutor
    private let syncAppStore: HostedQuotaAppStoreSync
    private let fetchProducts: HostedQuotaProductCatalogFetcher
    private let isSignedIn: HostedQuotaAuthStateReader

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
    private var inFlightVerifyByJWS: [String: Task<Void, Error>] = [:]

    init(
        functions: any HostedQuotaEntitlementServicing = FunctionsRepository.shared,
        directReader: (any HostedQuotaEntitlementDirectReading)? = FirestoreRepository.shared,
        purchaseProduct: @escaping HostedQuotaProductPurchaseExecutor = HostedQuotaSubscriptionStore.purchaseProduct,
        syncAppStore: @escaping HostedQuotaAppStoreSync = HostedQuotaSubscriptionStore.syncAppStore,
        fetchProducts: @escaping HostedQuotaProductCatalogFetcher = HostedQuotaSubscriptionStore.fetchProducts,
        isSignedIn: @escaping HostedQuotaAuthStateReader = { AuthRepository.shared.isSignedIn }
    ) {
        self.functions = functions
        self.directReader = directReader
        self.purchaseProduct = purchaseProduct
        self.syncAppStore = syncAppStore
        self.fetchProducts = fetchProducts
        self.isSignedIn = isSignedIn
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        startObservingTransactionUpdates()
        guard isSignedIn() else {
            isActive = false
            activeProductID = nil
            expirationDate = nil
            purchaseDate = nil
            latestTransactionID = nil
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
        if isTopUp, !isSignedIn() {
            error = HostedQuotaSubscriptionError.signedOutConsumablePurchase.localizedDescription
            return
        }
        let canBindEntitlement = isSignedIn()
        isPurchasing = true
        error = nil
        defer { isPurchasing = false }
        do {
            let product = try await productMetadata(for: productID)
            if productID == Self.productID {
                self.product = product
            }
            let purchaseOptions: Set<Product.PurchaseOption>
            if canBindEntitlement {
                let token = try await mintAppAccountToken(productID: productID)
                purchaseOptions = [.appAccountToken(token)]
            } else {
                purchaseOptions = []
            }
            let result = try await purchaseProduct(product, purchaseOptions)
            switch result {
            case .success(let signedTransactionJWS, let finish):
                if isTopUp {
                    try await verifyTopUpOnServer(jws: signedTransactionJWS, productID: productID)
                    await finish()
                    return
                }
                guard canBindEntitlement else {
                    await finish()
                    isActive = false
                    activeProductID = nil
                    expirationDate = nil
                    purchaseDate = nil
                    latestTransactionID = nil
                    error = Self.signedOutPurchaseMessage
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
                    signedTransactionJWS: matchedEntitlement.jws
                )
                apply(response: response)
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
        } catch {
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
        guard isSignedIn() else {
            isActive = false
            activeProductID = nil
            expirationDate = nil
            purchaseDate = nil
            latestTransactionID = nil
            return
        }

        if let matchedEntitlement = await findCurrentEntitlement() {
            try await verifyOnServer(jws: matchedEntitlement.jws, productID: matchedEntitlement.productID)
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
                    await applyDirectReadIfActive()
                }
            } catch {
                // ASC roundtrip failed (e.g. owner-seeded test entitlement
                // with no real Apple transaction). Fall back to the same
                // entitlement doc the Firestore rules use to gate the relay.
                if !(await applyDirectReadIfActive()) {
                    isActive = false
                    activeProductID = nil
                    expirationDate = nil
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
                  let expires = response.expiresAt,
                  expires > Date() else {
                return false
            }
            apply(response: response)
            return isActive
        } catch {
            return false
        }
    }

    /// Walk `Transaction.currentEntitlements` and return the JWS of the
    /// first verified, non-revoked, non-expired transaction matching
    /// our productID. Returns `nil` when no qualifying entitlement is
    /// present locally. As a side-effect, captures `purchaseDate` and
    /// `latestTransactionID` from the matched transaction for display in
    /// the member card.
    private func findCurrentEntitlement() async -> CurrentEntitlement? {
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try Self.checked(result)
                guard Self.entitlementProductIDs.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expires = transaction.expirationDate, expires <= Date() {
                    continue
                }
                purchaseDate = transaction.originalPurchaseDate
                latestTransactionID = transaction.id
                return CurrentEntitlement(productID: transaction.productID, jws: result.jwsRepresentation)
            } catch {
                // Skip unverified entitlements — the server is the
                // source of truth, but there's no point sending a
                // payload StoreKit itself flagged as suspect.
                continue
            }
        }
        return nil
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
            do {
                try await verifyOnServer(jws: update.jwsRepresentation, productID: transaction.productID)
                await transaction.finish()
            } catch {
                if await recoverEntitlementAfterVerificationFailure(jws: update.jwsRepresentation, productID: transaction.productID) {
                    await transaction.finish()
                } else {
                    throw error
                }
            }
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
    private func verifyOnServer(jws: String, productID: String = HostedQuotaSubscriptionStore.productID) async throws {
        if let existing = inFlightVerifyByJWS[jws] {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let response = try await self.functions.verifyHostedQuotaEntitlement(
                signedTransactionJWS: jws,
                signedRenewalInfoJWS: nil,
                productID: productID
            )
            await MainActor.run { self.apply(response: response) }
        }
        inFlightVerifyByJWS[jws] = task
        defer { inFlightVerifyByJWS.removeValue(forKey: jws) }
        try await task.value
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
        }
        return await applyDirectReadIfActive()
    }

    private func apply(response: HostedQuotaEntitlementResponse) {
        isActive = response.active
        activeProductID = response.active ? response.productID : nil
        expirationDate = response.expiresAt
    }

    var isActivePro: Bool {
        activeProductID == Self.cloudProMonthlyProductID ||
            activeProductID == Self.cloudProAnnualProductID ||
            activeProductID == Self.legacyProMaxProductID ||
            activeProductID == Self.proMaxProductID ||
            activeProductID == Self.legacyHostedComputerUseProductID ||
            activeProductID == Self.hostedComputerUseProductID
    }

    func storeProduct(for productID: String) -> HostedQuotaStoreProduct? {
        productsByID[productID]
    }

    func displayPrice(for catalogProduct: OpenBurnBarStoreProduct) -> String {
        storeProduct(for: catalogProduct.id)?.displayPrice ?? catalogProduct.fallbackDisplayPrice
    }

    func subscriptionPlan(for productID: String) -> OpenBurnBarStoreProduct? {
        OpenBurnBarProductCatalog.subscriptions.first(where: { $0.id == productID })
    }

    private struct CurrentEntitlement {
        let productID: String
        let jws: String
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
                displayPrice: catalogProduct.fallbackDisplayPrice
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

    private static let signedOutPurchaseMessage =
        "Apple purchase completed. Sign in to OpenBurnBar and tap Restore Purchases so OpenBurnBar Cloud can link the subscription to your account."

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
        }
    }
}
