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
}

extension FunctionsRepository: HostedQuotaEntitlementServicing {}

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
    static let productID = "com.openburnbar.hostedQuotaSync.monthly"

    private let functions: any HostedQuotaEntitlementServicing

    private(set) var product: Product?
    private(set) var isActive = false
    private(set) var expirationDate: Date?
    private(set) var isLoading = false
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

    nonisolated(unsafe) private var transactionUpdatesTask: Task<Void, Never>?

    /// Serializes inbound `verifyOnServer` calls. StoreKit can race a
    /// `purchase()`-emitted `verifyOnServer` against a near-simultaneous
    /// `Transaction.updates` event for the same JWS. We coalesce on the
    /// JWS representation so the second call awaits the first.
    private var inFlightVerifyByJWS: [String: Task<Void, Error>] = [:]

    init(functions: any HostedQuotaEntitlementServicing = FunctionsRepository.shared) {
        self.functions = functions
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            try await refreshEntitlement()
            startObservingTransactionUpdates()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Buy the hosted-quota subscription. The pre-purchase
    /// `beginEntitlementBinding` call is what allows the server to
    /// attribute the resulting JWS back to this Firebase UID without
    /// trusting any client-supplied identifier.
    func purchase() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            if product == nil {
                product = try await Product.products(for: [Self.productID]).first
            }
            guard let product else {
                throw HostedQuotaSubscriptionError.productUnavailable
            }
            let token = try await mintAppAccountToken()
            let purchaseOptions: Set<Product.PurchaseOption> = [
                .appAccountToken(token),
            ]
            let result = try await product.purchase(options: purchaseOptions)
            switch result {
            case .success(let verification):
                let transaction = try checked(verification)
                try await verifyOnServer(jws: verification.jwsRepresentation)
                await transaction.finish()
            case .pending, .userCancelled:
                break
            @unknown default:
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
            try await AppStore.sync()

            // 2) Walk local entitlements. The first matching active JWS
            //    wins; we forward only the raw JWS so the server is the
            //    sole arbiter of activation.
            let matchedJWS = await findCurrentEntitlementJWS()
            if let matchedJWS {
                let response = try await functions.restoreHostedQuotaEntitlement(
                    productID: Self.productID,
                    signedTransactionJWS: matchedJWS
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
        if let matchedJWS = await findCurrentEntitlementJWS() {
            try await verifyOnServer(jws: matchedJWS)
        } else {
            // No local entitlement to surface. Try the server-side
            // restore path so users who previously paid (and have a
            // doc on file) still see their entitlement on this device.
            do {
                let response = try await functions.restoreHostedQuotaEntitlement(
                    productID: Self.productID,
                    signedTransactionJWS: nil
                )
                apply(response: response)
            } catch {
                isActive = false
                expirationDate = nil
            }
        }
    }

    /// Walk `Transaction.currentEntitlements` and return the JWS of the
    /// first verified, non-revoked, non-expired transaction matching
    /// our productID. Returns `nil` when no qualifying entitlement is
    /// present locally. As a side-effect, captures `purchaseDate` and
    /// `latestTransactionID` from the matched transaction for display in
    /// the member card.
    private func findCurrentEntitlementJWS() async -> String? {
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checked(result)
                guard transaction.productID == Self.productID else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expires = transaction.expirationDate, expires <= Date() {
                    continue
                }
                purchaseDate = transaction.originalPurchaseDate
                latestTransactionID = transaction.id
                return result.jwsRepresentation
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
            let transaction = try checked(update)
            guard transaction.productID == Self.productID else { return }
            try await verifyOnServer(jws: update.jwsRepresentation)
            await transaction.finish()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mintAppAccountToken() async throws -> UUID {
        let raw = try await functions.beginEntitlementBinding(
            productID: Self.productID,
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
    private func verifyOnServer(jws: String) async throws {
        if let existing = inFlightVerifyByJWS[jws] {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let response = try await self.functions.verifyHostedQuotaEntitlement(
                signedTransactionJWS: jws,
                signedRenewalInfoJWS: nil,
                productID: Self.productID
            )
            await MainActor.run { self.apply(response: response) }
        }
        inFlightVerifyByJWS[jws] = task
        defer { inFlightVerifyByJWS.removeValue(forKey: jws) }
        try await task.value
    }

    private func apply(response: HostedQuotaEntitlementResponse) {
        isActive = response.active
        expirationDate = response.expiresAt
    }

    private func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }

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

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "Hosted Quota Sync is not available in the App Store configuration."
        case .invalidBindingToken:
            return "Could not initialize the entitlement binding token. Please try again."
        }
    }
}
