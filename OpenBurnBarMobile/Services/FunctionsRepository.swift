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

    func syncHostedQuotaEntitlement(
        productID: String,
        transactionID: String?,
        originalTransactionID: String?,
        expiresAt: Date?,
        signedTransactionJWS: String?,
        active: Bool
    ) async throws {
        let callable = functions.httpsCallable("syncHostedQuotaEntitlement")
        var payload: [String: Any] = [
            "productID": productID,
            "active": active
        ]
        if let transactionID { payload["transactionID"] = transactionID }
        if let originalTransactionID { payload["originalTransactionID"] = originalTransactionID }
        if let expiresAt { payload["expiresAt"] = ISO8601DateFormatter().string(from: expiresAt) }
        if let signedTransactionJWS { payload["signedTransactionJWS"] = signedTransactionJWS }
        _ = try await callable.call(payload)
    }

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = functions.httpsCallable("connectHostedQuotaAccount")
        var payload: [String: Any] = [
            "provider": providerID.rawValue,
            "credential": credential,
            "credentialKind": kind.rawValue
        ]
        if let label, label.isEmpty == false { payload["label"] = label }
        if let accountID, accountID.isEmpty == false { payload["accountID"] = accountID }
        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderAccountDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func connectSelfHostedQuotaAccount(
        providerID: ProviderID,
        label: String?,
        accountID: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = functions.httpsCallable("connectSelfHostedQuotaAccount")
        var payload: [String: Any] = ["provider": providerID.rawValue]
        if let label, label.isEmpty == false { payload["label"] = label }
        if let accountID, accountID.isEmpty == false { payload["accountID"] = accountID }
        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderAccountDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func uploadProviderQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot) async throws -> ProviderQuotaSnapshot {
        let callable = functions.httpsCallable("uploadProviderQuotaSnapshot")
        let payload = try snapshot.cloudPayload()
        let result = try await callable.call(["snapshot": payload])
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let snap = try? JSONDecoder().decode(ProviderQuotaSnapshot.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return snap
    }

    func deleteHostedQuotaCredentials() async throws {
        let callable = functions.httpsCallable("deleteHostedQuotaCredentials")
        _ = try await callable.call([:])
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
}

private extension ProviderQuotaSnapshot {
    func cloudPayload() throws -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let buckets = buckets.map { bucket -> [String: Any] in
            var payload: [String: Any] = [
                "name": bucket.name,
                "used": bucket.used,
                "limit": bucket.limit,
                "remaining": bucket.remaining
            ]
            if let window = bucket.window { payload["window"] = window }
            if let meta = bucket.meta { payload["meta"] = meta }
            return payload
        }
        var payload: [String: Any] = [
            "provider": provider,
            "providerID": providerID.rawValue,
            "sourceKind": sourceKind.rawValue,
            "sourceId": sourceId,
            "fetchedAt": formatter.string(from: fetchedAt),
            "source": source,
            "confidence": confidence.rawValue,
            "buckets": buckets,
            "schemaVersion": schemaVersion,
            "updatedAt": formatter.string(from: updatedAt)
        ]
        if let accountID { payload["accountID"] = accountID }
        if let accountLabel { payload["accountLabel"] = accountLabel }
        if let accountStorageScope { payload["accountStorageScope"] = accountStorageScope.rawValue }
        if let managementURL { payload["managementURL"] = managementURL }
        if let statusMessage { payload["statusMessage"] = statusMessage }
        return payload
    }
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
