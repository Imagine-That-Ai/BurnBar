import Foundation
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Provider Accounts Servicing

/// Provider-account domain slice of the Firebase callable surface, split out
/// of `FunctionsRepository` (tech-debt finding-67). Covers credential/account
/// connect + lifecycle, quota refresh/upload, usage-rollup repair, and the
/// per-device account links. Method bodies are verbatim moves from
/// `FunctionsRepository`; the repository remains a facade that forwards here,
/// so existing call sites keep compiling unchanged.
@MainActor
protocol ProviderAccountsServicing: AnyObject {
    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc

    func connectProviderAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String?,
        sourceDeviceID: String?,
        deviceDisplayName: String?,
        metadata: ProviderAccountConnectMetadata?
    ) async throws -> ProviderAccountDoc

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        label: String?,
        accountID: String?,
        sourceDeviceID: String?,
        deviceDisplayName: String?
    ) async throws -> ProviderAccountDoc

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String?,
        sourceDeviceID: String?,
        deviceDisplayName: String?
    ) async throws -> ProviderAccountDoc

    func connectSelfHostedQuotaAccount(
        providerID: ProviderID,
        label: String?,
        accountID: String?,
        sourceDeviceID: String?,
        deviceDisplayName: String?
    ) async throws -> ProviderAccountDoc

    func deleteProviderCredential(provider: String) async throws
    func refreshProviderQuota(provider: String) async throws
    func refreshProviderAccountQuota(accountID: String) async throws -> ProviderQuotaSnapshot
    func deleteHostedQuotaCredentials(accountID: String) async throws
    func updateProviderAccount(accountID: String, label: String?, isDefault: Bool?, disabled: Bool?) async throws -> ProviderAccountDoc
    func deleteProviderAccount(accountID: String) async throws
    func rebuildUsageRollups(force: Bool) async throws
    func uploadProviderQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot) async throws -> ProviderQuotaSnapshot

    func adoptProviderAccountForDevice(
        accountID: String,
        deviceID: String,
        deviceDisplayName: String,
        capability: DeviceLinkCapability
    ) async throws

    func revokeProviderAccountDeviceLink(accountID: String, deviceID: String) async throws
    func backfillProviderAccountDeviceLinks() async throws
}

// MARK: - Provider Accounts API

@MainActor
final class ProviderAccountsAPI: ProviderAccountsServicing {
    private let client: FunctionsClientProvider

    init(client: FunctionsClientProvider) {
        self.client = client
    }

    private func functionsClient() throws -> Functions {
        try client.client()
    }

    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc {
        let callable = try functionsClient().httpsCallable("connectProviderCredential")
        let result = try await callable.call([
            "provider": provider,
            "credential": credential,
            "credentialKind": kind.rawValue
        ])
        // Representative migration (WP2-TYPED-IOS): the response decode now flows
        // through the shared helper, which surfaces `DecodingError` context via
        // `FunctionsError.responseDecodingFailed` instead of the previous `try?`
        // that silently collapsed every parse failure into `.decodingFailed`.
        return try FirebaseCallableExecutor.decodeResponse(ProviderConnectionDoc.self, from: result.data)
    }

    func connectProviderAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil,
        metadata: ProviderAccountConnectMetadata? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = try functionsClient().httpsCallable("connectProviderAccount")
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
        if let sourceDeviceID, sourceDeviceID.isEmpty == false {
            payload["sourceDeviceID"] = sourceDeviceID
        }
        if let deviceDisplayName, deviceDisplayName.isEmpty == false {
            payload["deviceDisplayName"] = deviceDisplayName
        }
        if let metadata {
            if let endpointProfileID = metadata.endpointProfileID {
                payload["endpointProfileID"] = endpointProfileID
            }
            if let region = metadata.region {
                payload["region"] = region.rawValue
            }
            if let tier = metadata.tokenPlanTier {
                payload["tokenPlanTier"] = tier.rawValue
            }
            if let cycle = metadata.tokenPlanBillingCycle {
                payload["tokenPlanBillingCycle"] = cycle.rawValue
            }
            if let authMethodID = metadata.authMethodID {
                payload["authMethodID"] = authMethodID
            }
        }
        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderAccountDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = try functionsClient().httpsCallable("connectHostedQuotaAccount")
        var payload: [String: Any] = [
            "provider": providerID.rawValue,
            "credential": credential
        ]
        if let label, label.isEmpty == false {
            payload["label"] = label
        }
        if let accountID, accountID.isEmpty == false {
            payload["accountID"] = accountID
        }
        if let sourceDeviceID, sourceDeviceID.isEmpty == false {
            payload["sourceDeviceID"] = sourceDeviceID
        }
        if let deviceDisplayName, deviceDisplayName.isEmpty == false {
            payload["deviceDisplayName"] = deviceDisplayName
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

    func connectSelfHostedQuotaAccount(
        providerID: ProviderID,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = try functionsClient().httpsCallable("connectSelfHostedQuotaAccount")
        var payload: [String: Any] = ["provider": providerID.rawValue]
        if let label, label.isEmpty == false {
            payload["label"] = label
        }
        if let accountID, accountID.isEmpty == false {
            payload["accountID"] = accountID
        }
        if let sourceDeviceID, sourceDeviceID.isEmpty == false {
            payload["sourceDeviceID"] = sourceDeviceID
        }
        if let deviceDisplayName, deviceDisplayName.isEmpty == false {
            payload["deviceDisplayName"] = deviceDisplayName
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
        let callable = try functionsClient().httpsCallable("deleteProviderCredential")
        _ = try await callable.call(["provider": provider])
    }

    func refreshProviderQuota(provider: String) async throws {
        let callable = try functionsClient().httpsCallable("refreshProviderQuota")
        _ = try await callable.call(["provider": provider])
    }

    func refreshProviderAccountQuota(accountID: String) async throws -> ProviderQuotaSnapshot {
        // Representative migration to the typed callable helper (WP2-TYPED-IOS):
        // request is `Encodable`, response is `Decodable`, and a malformed
        // response surfaces `DecodingError` context instead of collapsing into an
        // opaque `try?` failure. The encoded request `{accountID}` is byte-for-byte
        // the same wire shape as the previous `["accountID": accountID]` dictionary.
        struct Request: Encodable { let accountID: String }
        return try await FirebaseCallableExecutor.call(
            "refreshProviderAccountQuota",
            Request(accountID: accountID),
            using: functionsClient()
        )
    }

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = try functionsClient().httpsCallable("connectHostedQuotaAccount")
        var payload: [String: Any] = [
            "provider": providerID.rawValue,
            "credential": credential,
            "credentialKind": kind.rawValue
        ]
        if let label, label.isEmpty == false { payload["label"] = label }
        if let accountID, accountID.isEmpty == false { payload["accountID"] = accountID }
        if let sourceDeviceID, sourceDeviceID.isEmpty == false { payload["sourceDeviceID"] = sourceDeviceID }
        if let deviceDisplayName, deviceDisplayName.isEmpty == false { payload["deviceDisplayName"] = deviceDisplayName }
        let result = try await callable.call(payload)
        guard let data = result.data as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(data) as? [String: Any],
              let jsonData = try? JSONSerialization.data(withJSONObject: sanitized),
              let doc = try? JSONDecoder().decode(ProviderAccountDoc.self, from: jsonData) else {
            throw FunctionsError.decodingFailed
        }
        return doc
    }

    func deleteHostedQuotaCredentials(accountID: String = "codex_default") async throws {
        let callable = try functionsClient().httpsCallable("deleteHostedQuotaCredentials")
        _ = try await callable.call(["accountID": accountID])
    }

    func updateProviderAccount(accountID: String, label: String? = nil, isDefault: Bool? = nil, disabled: Bool? = nil) async throws -> ProviderAccountDoc {
        let callable = try functionsClient().httpsCallable("updateProviderAccount")
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
        let callable = try functionsClient().httpsCallable("deleteProviderAccount")
        _ = try await callable.call(["accountID": accountID])
    }

    /// `force` is the explicit repair path: the server rebuilds the usage
    /// counters from raw history. Routine refreshes omit it and are served
    /// from the incremental counters when those are healthy.
    func rebuildUsageRollups(force: Bool = false) async throws {
        let callable = try functionsClient().httpsCallable("rebuildUsageRollups")
        _ = try await callable.call(["force": force])
    }

    func uploadProviderQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot) async throws -> ProviderQuotaSnapshot {
        let callable = try functionsClient().httpsCallable("uploadProviderQuotaSnapshot")
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

    // MARK: Provider account device links

    /// Adopt a provider account onto this device with the given capability.
    /// Mirrors the macOS owner-link write that happens automatically when
    /// `connectSelfHostedQuotaAccount` runs on the Mac.
    func adoptProviderAccountForDevice(
        accountID: String,
        deviceID: String,
        deviceDisplayName: String,
        capability: DeviceLinkCapability
    ) async throws {
        let callable = try functionsClient().httpsCallable("adoptProviderAccountForDevice")
        _ = try await callable.call([
            "accountID": accountID,
            "deviceID": deviceID,
            "deviceDisplayName": deviceDisplayName,
            "capability": capability.rawValue
        ])
    }

    func revokeProviderAccountDeviceLink(accountID: String, deviceID: String) async throws {
        let callable = try functionsClient().httpsCallable("revokeProviderAccountDeviceLink")
        _ = try await callable.call([
            "accountID": accountID,
            "deviceID": deviceID
        ])
    }

    func backfillProviderAccountDeviceLinks() async throws {
        let callable = try functionsClient().httpsCallable("backfillProviderAccountDeviceLinks")
        _ = try await callable.call([:])
    }
}
