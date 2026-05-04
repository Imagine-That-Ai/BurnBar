import Foundation
import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Functions Repository

@MainActor
final class FunctionsRepository {
    static let shared = FunctionsRepository()

    private let functions = Functions.functions()

    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc {
        let callable = functions.httpsCallable("connectProviderCredential")
        let result = try await callable.call([
            "provider": provider,
            "credential": credential,
            "credentialKind": kind.rawValue
        ])
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderConnectionDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func connectProviderAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = functions.httpsCallable("connectProviderAccount")
        var payload: [String: Any] = [
            "provider": providerID.rawValue,
            "credential": credential,
            "credentialKind": kind.rawValue
        ]
        if let label, label.isEmpty == false {
            payload["label"] = label
        }
        if let accountID, accountID.isEmpty == false {
            payload["accountID"] = accountID
        }
        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderAccountDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func deleteProviderCredential(provider: String) async throws {
        let callable = functions.httpsCallable("deleteProviderCredential")
        _ = try await callable.call(["provider": provider])
    }

    func refreshProviderQuota(provider: String) async throws {
        let callable = functions.httpsCallable("refreshProviderQuota")
        _ = try await callable.call(["provider": provider])
    }

    func refreshProviderAccountQuota(accountID: String) async throws -> ProviderQuotaSnapshot {
        let callable = functions.httpsCallable("refreshProviderAccountQuota")
        let result = try await callable.call(["accountID": accountID])
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let snap = try? JSONDecoder().decode(ProviderQuotaSnapshot.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return snap
    }

    func updateProviderAccount(accountID: String, label: String? = nil, isDefault: Bool? = nil, disabled: Bool? = nil) async throws -> ProviderAccountDoc {
        let callable = functions.httpsCallable("updateProviderAccount")
        var payload: [String: Any] = ["accountID": accountID]
        if let label { payload["label"] = label }
        if let isDefault { payload["isDefault"] = isDefault }
        if let disabled { payload["disabled"] = disabled }
        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderAccountDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func deleteProviderAccount(accountID: String) async throws {
        let callable = functions.httpsCallable("deleteProviderAccount")
        _ = try await callable.call(["accountID": accountID])
    }

    func rebuildUsageRollups() async throws {
        let callable = functions.httpsCallable("rebuildUsageRollups")
        _ = try await callable.call([:])
    }

    func uploadProviderQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot) async throws -> ProviderQuotaSnapshot {
        let callable = functions.httpsCallable("uploadProviderQuotaSnapshot")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(snapshot)
        guard let payload = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw FunctionsError.decodingFailed
        }
        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let responseData = try? JSONSerialization.data(withJSONObject: sanitized),
              let snap = try? JSONDecoder().decode(ProviderQuotaSnapshot.self, from: responseData) else {
            throw FunctionsError.decodingFailed
        }
        return snap
    }

    // MARK: Apple-verified hosted quota entitlement

    /// Mint a fresh `appAccountToken` UUID before calling `Product.purchase()`.
    /// The server records the token alongside the signed-in UID so the
    /// reconciler can later attribute the purchase to the correct user
    /// without trusting any in-flight callable arguments.
    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String? = nil
    ) async throws -> String {
        let callable = functions.httpsCallable("beginEntitlementBinding")
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
        let callable = functions.httpsCallable("verifyHostedQuotaEntitlement")
        var payload: [String: Any] = ["signedTransactionJWS": signedTransactionJWS]
        if let signedRenewalInfoJWS { payload["signedRenewalInfoJWS"] = signedRenewalInfoJWS }
        if let productID { payload["productID"] = productID }
        let result = try await callable.call(payload)
        return try decodeHostedQuotaEntitlement(result.data)
    }

    /// Re-run live App Store Server reconciliation for the signed-in user's
    /// known `originalTransactionID`. Used by the "Restore Purchases"
    /// surface; safe to call without any active StoreKit transaction.
    @discardableResult
    func restoreHostedQuotaEntitlement(
        productID: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        let callable = functions.httpsCallable("restoreHostedQuotaEntitlement")
        var payload: [String: Any] = [:]
        if let productID { payload["productID"] = productID }
        let result = try await callable.call(payload)
        return try decodeHostedQuotaEntitlement(result.data)
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

// MARK: - Functions Error

enum FunctionsError: Error, LocalizedError {
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .decodingFailed: return "Failed to decode cloud function response."
        }
    }
}
