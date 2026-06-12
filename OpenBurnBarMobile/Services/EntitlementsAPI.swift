import Foundation
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Entitlements API (Apple-verified hosted quota)

/// StoreKit-entitlement domain slice of the Firebase callable surface, split
/// out of `FunctionsRepository` (tech-debt finding-67). Owns the
/// Apple-verified hosted-quota entitlement callables (binding, verify,
/// restore, top-up credit) behind the existing
/// `HostedQuotaEntitlementServicing` protocol that
/// `HostedQuotaSubscriptionStore` already consumes. Method bodies are
/// verbatim moves from `FunctionsRepository`; the repository remains a facade
/// that forwards here, so existing call sites keep compiling unchanged.
@MainActor
final class EntitlementsAPI: HostedQuotaEntitlementServicing {
    private let client: FunctionsClientProvider

    init(client: FunctionsClientProvider) {
        self.client = client
    }

    private func functionsClient() throws -> Functions {
        try client.client()
    }

    /// Mint a fresh `appAccountToken` UUID before calling `Product.purchase()`.
    /// The server records the token alongside the signed-in UID so the
    /// reconciler can later attribute the purchase to the correct user
    /// without trusting any in-flight callable arguments.
    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String? = nil
    ) async throws -> String {
        let callable = try functionsClient().httpsCallable("beginEntitlementBinding")
        var payload: [String: Any] = ["productID": productID]
        if let clientPlatform { payload["clientPlatform"] = clientPlatform }
        let result = try await callable.call(payload)
        guard
            let dict = result.data as? [String: Any],
            let token = dict["appAccountToken"] as? String,
            !token.isEmpty
        else {
            throw FunctionsError.decodingFailed
        }
        return token
    }

    /// Send a verified StoreKit 2 transaction JWS to the server. The server
    /// chain-verifies the JWS against AppleRootCA-G3 / G2 / AppleInc Root,
    /// reconciles live state via the App Store Server API, and returns
    /// the canonical `HostedQuotaEntitlementDoc` it just wrote.
    @discardableResult
    func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        signedRenewalInfoJWS: String? = nil,
        productID: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        let callable = try functionsClient().httpsCallable("verifyHostedQuotaEntitlement")
        var payload: [String: Any] = ["signedTransactionJWS": signedTransactionJWS]
        if let signedRenewalInfoJWS { payload["signedRenewalInfoJWS"] = signedRenewalInfoJWS }
        if let productID { payload["productID"] = productID }
        let result = try await callable.call(payload)
        return try decodeHostedQuotaEntitlement(result.data)
    }

    /// Re-run live App Store Server reconciliation. Powers the
    /// "Restore Purchases" affordance.
    ///
    /// Two callable contracts:
    ///   - With `signedTransactionJWS` (preferred): the server verifies
    ///     it through the same pipeline as `verifyHostedQuotaEntitlement`,
    ///     so even a brand-new install with no server doc can recover an
    ///     entitlement after `AppStore.sync()` populates
    ///     `Transaction.currentEntitlements`.
    ///   - Without `signedTransactionJWS`: the server reads the existing
    ///     entitlement doc's `originalTransactionID`, pulls live state
    ///     from ASC, and reconciles. Returns `failed-precondition` when
    ///     no doc exists on file.
    @discardableResult
    func restoreHostedQuotaEntitlement(
        productID: String? = nil,
        signedTransactionJWS: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        let callable = try functionsClient().httpsCallable("restoreHostedQuotaEntitlement")
        var payload: [String: Any] = [:]
        if let productID { payload["productID"] = productID }
        if let signedTransactionJWS, !signedTransactionJWS.isEmpty {
            payload["signedTransactionJWS"] = signedTransactionJWS
        }
        let result = try await callable.call(payload)
        return try decodeHostedQuotaEntitlement(result.data)
    }

    @discardableResult
    func verifyCloudProTopUp(
        signedTransactionJWS: String,
        productID: String
    ) async throws -> CloudProTopUpCreditResponse {
        let callable = try functionsClient().httpsCallable("verifyCloudProTopUp")
        let result = try await callable.call([
            "signedTransactionJWS": signedTransactionJWS,
            "productID": productID
        ])
        return try decodeCloudProTopUpCredit(result.data)
    }

    private func decodeHostedQuotaEntitlement(_ raw: Any?) throws -> HostedQuotaEntitlementResponse {
        guard let dict = raw as? [String: Any] else {
            throw FunctionsError.decodingFailed
        }
        let active = dict["active"] as? Bool ?? false
        let productID = (dict["productID"] as? String) ?? ""
        let transactionID = dict["transactionID"] as? String
        let originalTransactionID = dict["originalTransactionID"] as? String
        let environment = dict["environment"] as? String
        let expiresAt = (dict["expiresAt"] as? String).flatMap(Self.iso8601.date(from:))
        let revokedAt = (dict["revokedAt"] as? String).flatMap(Self.iso8601.date(from:))
        let revocationReason = dict["revocationReason"] as? Int
        return HostedQuotaEntitlementResponse(
            active: active,
            productID: productID,
            transactionID: transactionID,
            originalTransactionID: originalTransactionID,
            environment: environment,
            expiresAt: expiresAt,
            revokedAt: revokedAt,
            revocationReason: revocationReason
        )
    }

    private func decodeCloudProTopUpCredit(_ raw: Any?) throws -> CloudProTopUpCreditResponse {
        guard let dict = raw as? [String: Any],
              let monthKey = dict["monthKey"] as? String,
              let kind = dict["kind"] as? String else {
            throw FunctionsError.decodingFailed
        }
        let credited = dict["credited"] as? Bool ?? false
        let units = (dict["units"] as? Int) ?? Int(dict["units"] as? Double ?? 0)
        return CloudProTopUpCreditResponse(
            credited: credited,
            monthKey: monthKey,
            units: units,
            kind: kind
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Apple-verified hosted quota entitlement DTO

/// Trust-narrow snapshot of the server's `HostedQuotaEntitlementDoc`. The
/// canonical Firestore document at `users/{uid}/entitlements/hosted_quota_sync`
/// remains the source of truth; the iOS surface only consumes the fields it
/// renders so we don't accidentally treat client-side state as authoritative.
struct HostedQuotaEntitlementResponse: Equatable, Sendable {
    let active: Bool
    let productID: String
    let transactionID: String?
    let originalTransactionID: String?
    let environment: String?
    let expiresAt: Date?
    let revokedAt: Date?
    let revocationReason: Int?
}
