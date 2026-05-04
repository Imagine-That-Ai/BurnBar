import Foundation
import StoreKit

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
    static let productID = "com.burnbar.hostedQuotaSync.monthly"

    private let functions: FunctionsRepository

    private(set) var product: Product?
    private(set) var isActive = false
    private(set) var expirationDate: Date?
    private(set) var isLoading = false
    private(set) var error: String?

    nonisolated(unsafe) private var transactionUpdatesTask: Task<Void, Never>?

    init(functions: FunctionsRepository = .shared) {
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

    /// Re-run the App Store Server reconciliation for the signed-in
    /// user's existing `originalTransactionID`. Surfaced as the
    /// "Restore Purchases" affordance.
    func restorePurchases() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response = try await functions.restoreHostedQuotaEntitlement(
                productID: Self.productID
            )
            apply(response: response)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sync any active StoreKit entitlement up to the server, or mark
    /// the user inactive locally if no signed transaction exists.
    func refreshEntitlement() async throws {
        var matchedJWS: String?
        for await result in Transaction.currentEntitlements {
            let transaction = try checked(result)
            guard transaction.productID == Self.productID else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let expires = transaction.expirationDate, expires <= Date() { continue }
            matchedJWS = result.jwsRepresentation
            break
        }

        if let matchedJWS {
            try await verifyOnServer(jws: matchedJWS)
        } else {
            // No local entitlement to surface — but the server may still
            // have a record of this user's subscription, so prefer the
            // server's view over flipping `isActive` to false purely on
            // the local StoreKit cache.
            do {
                let response = try await functions.restoreHostedQuotaEntitlement(
                    productID: Self.productID
                )
                apply(response: response)
            } catch {
                isActive = false
                expirationDate = nil
            }
        }
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

    private func verifyOnServer(jws: String) async throws {
        let response = try await functions.verifyHostedQuotaEntitlement(
            signedTransactionJWS: jws,
            productID: Self.productID
        )
        apply(response: response)
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

#if os(iOS)
import UIKit
#endif

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
