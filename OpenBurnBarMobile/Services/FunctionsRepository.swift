import CryptoKit
import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

struct StreamSearchHit: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let title: String
    let snippet: String
    let score: Double
    let usage: TokenUsage
}

struct CloudConversationSearchHit: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let chunkID: String
    let documentID: String
    let sourceKind: String
    let sourceID: String
    let provider: String?
    let sealedTitle: CloudVaultSealedText
    let sealedSnippet: CloudVaultSealedText
    let sealedBodyPreview: CloudVaultSealedText?
    let storagePath: String
    let bodyHash: String
    let bodyHashVersion: Int?
    let score: Double
    let tokenScore: Double?
    let semanticScore: Double?
    let matchKind: String?
    let tokenHashVersion: Int?
    let semanticHashVersion: Int?
    let indexVersion: Int?
}

/// Server-computed dashboard rollups for the conversation cockpit: exact count, cost, and token
/// sums over the *filtered* set (not just the loaded page). `nil` when the matching Firestore
/// aggregate index is still building, in which case the cockpit shows page rows without KPIs.
struct ConversationQueryAggregates: Decodable, Hashable, Sendable {
    let count: Int
    let totalCostUSD: Double
    let totalTokens: Int
}

/// One encrypted session-log manifest as returned by `queryConversations`. Server-visible facets
/// are operational metadata (provider/model/tokens/cost/timing/device/source); text-like fields
/// such as project names, paths, titles, previews, and bodies stay sealed or hash-only. Numeric
/// facets are optional so manifests written before the facet backfill still decode.
struct ConversationFacetRow: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let provider: String?
    let projectName: String?
    let sourceType: String?
    let deviceId: String?
    let model: String?
    let facetSchemaVersion: Int?
    let messageCount: Int?
    let userWordCount: Int?
    let assistantWordCount: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int?
    let costUSD: Double?
    let workingDirectory: String?
    let toolTags: [String]?
    let durationSeconds: Int?
    let sealedTitle: CloudVaultSealedText?
    let sealedBodyPreview: CloudVaultSealedText?
    let storagePath: String?
    let bodyHash: String?
    let bodyHashVersion: Int?
    let startTime: Date?
    let endTime: Date?
    let updatedAt: Date?
}

/// Decoded response of the `queryConversations` callable: a page of facet rows, an opaque
/// pagination cursor (`nil` when exhausted), the effective sort applied by the server, and the
/// optional filtered-set aggregates.
struct ConversationQueryResponse: Decodable, Sendable {
    let rows: [ConversationFacetRow]
    let nextCursor: String?
    let sort: String?
    let direction: String?
    let aggregates: ConversationQueryAggregates?
}

struct HermesGatewayClientRecord: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let status: String
    let tokenPreview: String
    let scopes: [String]
    let homeDestinationId: String
    let lastSeenAt: String?
    let runtimeModelId: String?
    let runtimeProviderId: String?
    let runtimeModelOptions: [HermesGatewayModelOptionRecord]
    let runtimeUpdatedAt: String?
    let agentVersion: String?
    let pendingModelId: String?
    let pendingModelRequestedAt: String?
    let oversightMode: String?
    /// The agent's published P-256 relay public key (X9.63 base64). The phone
    /// wraps per-event symmetric keys to this so only the paired agent can open
    /// `hermes_gateway_events`.
    let relayPublicKey: String?
    let relayKeyVersion: Int?
    let relayEncryption: String?
    let phoneRelayPublicKey: String?
    let phoneRelayKeyVersion: Int?
    let phoneRelayEncryption: String?
    let supportsRelayEnvelopeVersions: [Int]
    let preferredRelayEnvelopeVersion: Int
    let supportsHpkeV3: Bool
    let agentRatchetIdentityPublicKey: String?
    let agentRatchetSigningPublicKey: String?
    let agentRatchetSignedPreKeyPublicKey: String?
    let agentRatchetSignedPreKeyId: String?
    let agentRatchetSignedPreKeySignature: String?
    let agentSupportsRatchetV1: Bool?
    let phoneRatchetIdentityPublicKey: String?
    let phoneRatchetSigningPublicKey: String?
    let phoneRatchetSignedPreKeyPublicKey: String?
    let phoneRatchetSignedPreKeyId: String?
    let phoneRatchetSignedPreKeySignature: String?
    let phoneSupportsRatchetV1: Bool?
    let supportsRatchetV1: Bool
    let revokedAt: String?
    let createdAt: String
    let updatedAt: String
    let schemaVersion: Int

    var isActive: Bool { status == "active" }

    /// True once the agent has published a usable relay pubkey, so the phone can
    /// seal event text end-to-end instead of sending plaintext. Mirrors the
    /// realtime-relay `canSealToHost` guard in `HermesService`.
    var canSealToAgent: Bool {
        relayEncryption == HermesRelayCrypto.algorithm && (relayPublicKey?.isEmpty == false)
    }

    func isPairedWithThisDevice(relayPublicKeyBase64 localRelayPublicKey: String) -> Bool {
        guard
            let phoneRelayPublicKey = phoneRelayPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !phoneRelayPublicKey.isEmpty
        else { return false }
        return phoneRelayPublicKey == localRelayPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var preferredRelayEnvelopeVersionForSeal: Int {
        supportsRelayEnvelopeVersions.contains(preferredRelayEnvelopeVersion)
            ? preferredRelayEnvelopeVersion
            : HermesRelayCrypto.gatewayRelayKeyVersion
    }

    /// True only when both peers have published complete, echoed Phase 6 ratchet
    /// public material. The UI may show this as ratchet-capable, but transport
    /// still binds the identities through the safety-code path before trust.
    var canRatchetToAgent: Bool {
        supportsRatchetV1
            && agentSupportsRatchetV1 != false
            && phoneSupportsRatchetV1 != false
            && Self.nonEmpty(agentRatchetIdentityPublicKey)
            && Self.nonEmpty(agentRatchetSigningPublicKey)
            && Self.nonEmpty(agentRatchetSignedPreKeyPublicKey)
            && Self.nonEmpty(agentRatchetSignedPreKeyId)
            && Self.nonEmpty(agentRatchetSignedPreKeySignature)
            && Self.nonEmpty(phoneRatchetIdentityPublicKey)
            && Self.nonEmpty(phoneRatchetSigningPublicKey)
            && Self.nonEmpty(phoneRatchetSignedPreKeyPublicKey)
            && Self.nonEmpty(phoneRatchetSignedPreKeyId)
            && Self.nonEmpty(phoneRatchetSignedPreKeySignature)
    }

    /// Treat an unset `oversightMode` as the safe `supervised` default so the
    /// phone never implies a gateway is running autonomously when the server
    /// hasn't explicitly opted into it.
    var isOversightSupervised: Bool { oversightMode != "autonomous" }

    /// True while the gateway has accepted a model-switch request but is not yet
    /// reporting that model as its live runtime model.
    var isSwitchingModel: Bool {
        guard let pendingModelId, !pendingModelId.isEmpty else { return false }
        return pendingModelId != runtimeModelId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case status
        case tokenPreview
        case scopes
        case homeDestinationId
        case lastSeenAt
        case runtimeModelId
        case runtimeProviderId
        case runtimeModelOptions
        case runtimeUpdatedAt
        case agentVersion
        case pendingModelId
        case pendingModelRequestedAt
        case oversightMode
        case relayPublicKey
        case relayKeyVersion
        case relayEncryption
        case supportsRelayEnvelopeVersions
        case preferredRelayEnvelopeVersion
        case supportsHpkeV3
        case agentRelayPublicKey
        case agentRelayKeyVersion
        case agentRelayEncryption
        case phoneRelayPublicKey
        case phoneRelayKeyVersion
        case phoneRelayEncryption
        case agentRatchetIdentityPublicKey
        case agentRatchetSigningPublicKey
        case agentRatchetSignedPreKeyPublicKey
        case agentRatchetSignedPreKeyId
        case agentRatchetSignedPreKeySignature
        case agentSupportsRatchetV1
        case phoneRatchetIdentityPublicKey
        case phoneRatchetSigningPublicKey
        case phoneRatchetSignedPreKeyPublicKey
        case phoneRatchetSignedPreKeyId
        case phoneRatchetSignedPreKeySignature
        case phoneSupportsRatchetV1
        case supportsRatchetV1
        case revokedAt
        case createdAt
        case updatedAt
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            status: try container.decode(String.self, forKey: .status),
            tokenPreview: try container.decode(String.self, forKey: .tokenPreview),
            scopes: try container.decodeIfPresent([String].self, forKey: .scopes) ?? [],
            homeDestinationId: try container.decode(String.self, forKey: .homeDestinationId),
            lastSeenAt: try container.decodeIfPresent(String.self, forKey: .lastSeenAt),
            revokedAt: try container.decodeIfPresent(String.self, forKey: .revokedAt),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            updatedAt: try container.decode(String.self, forKey: .updatedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            runtimeModelId: try container.decodeIfPresent(String.self, forKey: .runtimeModelId),
            runtimeProviderId: try container.decodeIfPresent(String.self, forKey: .runtimeProviderId),
            runtimeModelOptions: try container.decodeIfPresent([HermesGatewayModelOptionRecord].self, forKey: .runtimeModelOptions) ?? [],
            runtimeUpdatedAt: try container.decodeIfPresent(String.self, forKey: .runtimeUpdatedAt),
            agentVersion: try container.decodeIfPresent(String.self, forKey: .agentVersion),
            pendingModelId: try container.decodeIfPresent(String.self, forKey: .pendingModelId),
            pendingModelRequestedAt: try container.decodeIfPresent(String.self, forKey: .pendingModelRequestedAt),
            oversightMode: try container.decodeIfPresent(String.self, forKey: .oversightMode),
            relayPublicKey: try container.decodeIfPresent(String.self, forKey: .relayPublicKey)
                ?? container.decodeIfPresent(String.self, forKey: .agentRelayPublicKey),
            relayKeyVersion: try container.decodeIfPresent(Int.self, forKey: .relayKeyVersion)
                ?? container.decodeIfPresent(Int.self, forKey: .agentRelayKeyVersion),
            relayEncryption: try container.decodeIfPresent(String.self, forKey: .relayEncryption)
                ?? container.decodeIfPresent(String.self, forKey: .agentRelayEncryption),
            phoneRelayPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRelayPublicKey),
            phoneRelayKeyVersion: try container.decodeIfPresent(Int.self, forKey: .phoneRelayKeyVersion),
            phoneRelayEncryption: try container.decodeIfPresent(String.self, forKey: .phoneRelayEncryption),
            supportsRelayEnvelopeVersions: try container.decodeIfPresent([Int].self, forKey: .supportsRelayEnvelopeVersions) ?? [HermesRelayCrypto.gatewayRelayKeyVersion],
            preferredRelayEnvelopeVersion: try container.decodeIfPresent(Int.self, forKey: .preferredRelayEnvelopeVersion) ?? HermesRelayCrypto.gatewayRelayKeyVersion,
            supportsHpkeV3: try container.decodeIfPresent(Bool.self, forKey: .supportsHpkeV3) ?? false,
            agentRatchetIdentityPublicKey: try container.decodeIfPresent(String.self, forKey: .agentRatchetIdentityPublicKey),
            agentRatchetSigningPublicKey: try container.decodeIfPresent(String.self, forKey: .agentRatchetSigningPublicKey),
            agentRatchetSignedPreKeyPublicKey: try container.decodeIfPresent(String.self, forKey: .agentRatchetSignedPreKeyPublicKey),
            agentRatchetSignedPreKeyId: try container.decodeIfPresent(String.self, forKey: .agentRatchetSignedPreKeyId),
            agentRatchetSignedPreKeySignature: try container.decodeIfPresent(String.self, forKey: .agentRatchetSignedPreKeySignature),
            agentSupportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .agentSupportsRatchetV1),
            phoneRatchetIdentityPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetIdentityPublicKey),
            phoneRatchetSigningPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSigningPublicKey),
            phoneRatchetSignedPreKeyPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeyPublicKey),
            phoneRatchetSignedPreKeyId: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeyId),
            phoneRatchetSignedPreKeySignature: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeySignature),
            phoneSupportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .phoneSupportsRatchetV1),
            supportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .supportsRatchetV1) ?? false
        )
    }

    init(
        id: String,
        displayName: String,
        status: String,
        tokenPreview: String,
        scopes: [String],
        homeDestinationId: String,
        lastSeenAt: String?,
        revokedAt: String?,
        createdAt: String,
        updatedAt: String,
        schemaVersion: Int,
        runtimeModelId: String? = nil,
        runtimeProviderId: String? = nil,
        runtimeModelOptions: [HermesGatewayModelOptionRecord] = [],
        runtimeUpdatedAt: String? = nil,
        agentVersion: String? = nil,
        pendingModelId: String? = nil,
        pendingModelRequestedAt: String? = nil,
        oversightMode: String? = nil,
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        phoneRelayPublicKey: String? = nil,
        phoneRelayKeyVersion: Int? = nil,
        phoneRelayEncryption: String? = nil,
        supportsRelayEnvelopeVersions: [Int] = [HermesRelayCrypto.gatewayRelayKeyVersion],
        preferredRelayEnvelopeVersion: Int = HermesRelayCrypto.gatewayRelayKeyVersion,
        supportsHpkeV3: Bool = false,
        agentRatchetIdentityPublicKey: String? = nil,
        agentRatchetSigningPublicKey: String? = nil,
        agentRatchetSignedPreKeyPublicKey: String? = nil,
        agentRatchetSignedPreKeyId: String? = nil,
        agentRatchetSignedPreKeySignature: String? = nil,
        agentSupportsRatchetV1: Bool? = nil,
        phoneRatchetIdentityPublicKey: String? = nil,
        phoneRatchetSigningPublicKey: String? = nil,
        phoneRatchetSignedPreKeyPublicKey: String? = nil,
        phoneRatchetSignedPreKeyId: String? = nil,
        phoneRatchetSignedPreKeySignature: String? = nil,
        phoneSupportsRatchetV1: Bool? = nil,
        supportsRatchetV1: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.tokenPreview = tokenPreview
        self.scopes = scopes
        self.homeDestinationId = homeDestinationId
        self.lastSeenAt = lastSeenAt
        self.runtimeModelId = runtimeModelId
        self.runtimeProviderId = runtimeProviderId
        self.runtimeModelOptions = runtimeModelOptions
        self.runtimeUpdatedAt = runtimeUpdatedAt
        self.agentVersion = agentVersion
        self.pendingModelId = pendingModelId
        self.pendingModelRequestedAt = pendingModelRequestedAt
        self.oversightMode = oversightMode
        self.relayPublicKey = relayPublicKey
        self.relayKeyVersion = relayKeyVersion
        self.relayEncryption = relayEncryption
        self.phoneRelayPublicKey = phoneRelayPublicKey
        self.phoneRelayKeyVersion = phoneRelayKeyVersion
        self.phoneRelayEncryption = phoneRelayEncryption
        self.supportsRelayEnvelopeVersions = supportsRelayEnvelopeVersions
        self.preferredRelayEnvelopeVersion = preferredRelayEnvelopeVersion
        self.supportsHpkeV3 = supportsHpkeV3
        self.agentRatchetIdentityPublicKey = agentRatchetIdentityPublicKey
        self.agentRatchetSigningPublicKey = agentRatchetSigningPublicKey
        self.agentRatchetSignedPreKeyPublicKey = agentRatchetSignedPreKeyPublicKey
        self.agentRatchetSignedPreKeyId = agentRatchetSignedPreKeyId
        self.agentRatchetSignedPreKeySignature = agentRatchetSignedPreKeySignature
        self.agentSupportsRatchetV1 = agentSupportsRatchetV1
        self.phoneRatchetIdentityPublicKey = phoneRatchetIdentityPublicKey
        self.phoneRatchetSigningPublicKey = phoneRatchetSigningPublicKey
        self.phoneRatchetSignedPreKeyPublicKey = phoneRatchetSignedPreKeyPublicKey
        self.phoneRatchetSignedPreKeyId = phoneRatchetSignedPreKeyId
        self.phoneRatchetSignedPreKeySignature = phoneRatchetSignedPreKeySignature
        self.phoneSupportsRatchetV1 = phoneSupportsRatchetV1
        self.supportsRatchetV1 = supportsRatchetV1
        self.revokedAt = revokedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension HermesGatewayClientRecord {
    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let displayName = Self.string(data["displayName"]),
            let status = Self.string(data["status"]),
            let tokenPreview = Self.string(data["tokenPreview"]),
            let homeDestinationId = Self.string(data["homeDestinationId"]),
            let createdAt = Self.string(data["createdAt"]),
            let updatedAt = Self.string(data["updatedAt"])
        else { return nil }
        self.init(
            id: id,
            displayName: displayName,
            status: status,
            tokenPreview: tokenPreview,
            scopes: (data["scopes"] as? [Any])?.compactMap(Self.string) ?? [],
            homeDestinationId: homeDestinationId,
            lastSeenAt: Self.string(data["lastSeenAt"]),
            revokedAt: Self.string(data["revokedAt"]),
            createdAt: createdAt,
            updatedAt: updatedAt,
            schemaVersion: (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1,
            runtimeModelId: Self.string(data["runtimeModelId"]),
            runtimeProviderId: Self.string(data["runtimeProviderId"]),
            runtimeModelOptions: Self.modelOptions(data["runtimeModelOptions"]),
            runtimeUpdatedAt: Self.string(data["runtimeUpdatedAt"]),
            agentVersion: Self.string(data["agentVersion"]),
            pendingModelId: Self.string(data["pendingModelId"]),
            pendingModelRequestedAt: Self.string(data["pendingModelRequestedAt"]),
            oversightMode: Self.string(data["oversightMode"]),
            relayPublicKey: Self.string(data["relayPublicKey"]) ?? Self.string(data["agentRelayPublicKey"]),
            relayKeyVersion: (data["relayKeyVersion"] as? NSNumber)?.intValue
                ?? (data["relayKeyVersion"] as? Int)
                ?? (data["agentRelayKeyVersion"] as? NSNumber)?.intValue
                ?? (data["agentRelayKeyVersion"] as? Int),
            relayEncryption: Self.string(data["relayEncryption"]) ?? Self.string(data["agentRelayEncryption"]),
            phoneRelayPublicKey: Self.string(data["phoneRelayPublicKey"]),
            phoneRelayKeyVersion: (data["phoneRelayKeyVersion"] as? NSNumber)?.intValue
                ?? (data["phoneRelayKeyVersion"] as? Int),
            phoneRelayEncryption: Self.string(data["phoneRelayEncryption"]),
            supportsRelayEnvelopeVersions: Self.intArray(data["supportsRelayEnvelopeVersions"], fallback: [HermesRelayCrypto.gatewayRelayKeyVersion]),
            preferredRelayEnvelopeVersion: (data["preferredRelayEnvelopeVersion"] as? NSNumber)?.intValue
                ?? (data["preferredRelayEnvelopeVersion"] as? Int)
                ?? HermesRelayCrypto.gatewayRelayKeyVersion,
            supportsHpkeV3: (data["supportsHpkeV3"] as? Bool) ?? false,
            agentRatchetIdentityPublicKey: Self.string(data["agentRatchetIdentityPublicKey"]),
            agentRatchetSigningPublicKey: Self.string(data["agentRatchetSigningPublicKey"]),
            agentRatchetSignedPreKeyPublicKey: Self.string(data["agentRatchetSignedPreKeyPublicKey"]),
            agentRatchetSignedPreKeyId: Self.string(data["agentRatchetSignedPreKeyId"]),
            agentRatchetSignedPreKeySignature: Self.string(data["agentRatchetSignedPreKeySignature"]),
            agentSupportsRatchetV1: data["agentSupportsRatchetV1"] as? Bool,
            phoneRatchetIdentityPublicKey: Self.string(data["phoneRatchetIdentityPublicKey"]),
            phoneRatchetSigningPublicKey: Self.string(data["phoneRatchetSigningPublicKey"]),
            phoneRatchetSignedPreKeyPublicKey: Self.string(data["phoneRatchetSignedPreKeyPublicKey"]),
            phoneRatchetSignedPreKeyId: Self.string(data["phoneRatchetSignedPreKeyId"]),
            phoneRatchetSignedPreKeySignature: Self.string(data["phoneRatchetSignedPreKeySignature"]),
            phoneSupportsRatchetV1: data["phoneSupportsRatchetV1"] as? Bool,
            supportsRatchetV1: (data["supportsRatchetV1"] as? Bool) ?? false
        )
    }

    var lastSeenDate: Date? {
        guard let lastSeenAt else { return nil }
        return Self.gatewayDate(from: lastSeenAt)
    }

    func isOnline(relativeTo now: Date = Date(), staleAfter interval: TimeInterval = 90) -> Bool {
        guard isActive, let lastSeenDate else { return false }
        return now.timeIntervalSince(lastSeenDate) <= interval
    }

    private static func gatewayDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSString where value.length > 0:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func intArray(_ raw: Any?, fallback: [Int]) -> [Int] {
        guard let values = raw as? [Any] else { return fallback }
        let parsed = values.compactMap { item -> Int? in
            if let number = item as? NSNumber { return number.intValue }
            if let int = item as? Int { return int }
            if let string = item as? String { return Int(string) }
            return nil
        }
        return parsed.isEmpty ? fallback : parsed
    }

    private static func modelOptions(_ raw: Any?) -> [HermesGatewayModelOptionRecord] {
        (raw as? [Any])?.compactMap { item in
            guard let data = item as? [String: Any] else { return nil }
            return HermesGatewayModelOptionRecord(data: data)
        } ?? []
    }
}

struct HermesGatewayModelOptionRecord: Decodable, Hashable, Sendable {
    let providerId: String
    let providerName: String
    let modelId: String
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case providerId
        case providerName
        case modelId
        case displayName
    }

    init(providerId: String, providerName: String, modelId: String, displayName: String) {
        self.providerId = providerId
        self.providerName = providerName
        self.modelId = modelId
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modelId = try container.decode(String.self, forKey: .modelId)
        let providerId = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .providerId)) ?? "hermes"
        self.init(
            providerId: providerId,
            providerName: Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .providerName)) ?? providerId,
            modelId: modelId,
            displayName: Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .displayName)) ?? modelId
        )
    }

    init?(data: [String: Any]) {
        guard let modelId = Self.string(data["modelId"]) else { return nil }
        let providerId = Self.string(data["providerId"]) ?? "hermes"
        self.init(
            providerId: providerId,
            providerName: Self.string(data["providerName"]) ?? providerId,
            modelId: modelId,
            displayName: Self.string(data["displayName"]) ?? modelId
        )
    }

    var hermesRuntimeOption: HermesRuntimeModelOption {
        HermesRuntimeModelOption(
            providerID: providerId,
            providerName: providerName,
            modelID: modelId,
            displayName: displayName,
            sourceKind: "burnbar-cloud-gateway",
            routeEligible: true
        )
    }

    private static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSString where value.length > 0:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct HermesGatewayQueuedEvent: Decodable, Hashable, Sendable {
    let id: String
    let sequence: Int
    let targetClientId: String?
}

/// Owner-read view of a server-armed oversight gate at
/// `users/{uid}/hermes_gateway_approvals/{approvalId}`. The agent blocks on this
/// gate until a trusted native device approves or rejects via
/// `respondHermesGatewayApproval`.
struct HermesGatewayApprovalRecord: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let destinationId: String
    let actionId: String
    let toolName: String?
    let summary: String
    let status: String
    let requestedAt: String
    let expiresAt: String
    let respondedAt: String?
    let approvedByDeviceId: String?
    let schemaVersion: Int

    var isWaiting: Bool { status == "waiting_for_approval" }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case destinationId
        case actionId
        case toolName
        case summary
        case status
        case requestedAt
        case expiresAt
        case respondedAt
        case approvedByDeviceId
        case schemaVersion
    }

    init(
        id: String,
        clientId: String,
        destinationId: String,
        actionId: String,
        toolName: String?,
        summary: String,
        status: String,
        requestedAt: String,
        expiresAt: String,
        respondedAt: String? = nil,
        approvedByDeviceId: String? = nil,
        schemaVersion: Int
    ) {
        self.id = id
        self.clientId = clientId
        self.destinationId = destinationId
        self.actionId = actionId
        self.toolName = toolName
        self.summary = summary
        self.status = status
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.respondedAt = respondedAt
        self.approvedByDeviceId = approvedByDeviceId
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            clientId: try container.decode(String.self, forKey: .clientId),
            destinationId: try container.decode(String.self, forKey: .destinationId),
            actionId: try container.decode(String.self, forKey: .actionId),
            toolName: try container.decodeIfPresent(String.self, forKey: .toolName),
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            status: try container.decode(String.self, forKey: .status),
            requestedAt: try container.decode(String.self, forKey: .requestedAt),
            expiresAt: try container.decode(String.self, forKey: .expiresAt),
            respondedAt: try container.decodeIfPresent(String.self, forKey: .respondedAt),
            approvedByDeviceId: try container.decodeIfPresent(String.self, forKey: .approvedByDeviceId),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }
}

extension HermesGatewayApprovalRecord {
    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let clientId = Self.string(data["clientId"]),
            let destinationId = Self.string(data["destinationId"]),
            let actionId = Self.string(data["actionId"]),
            let status = Self.string(data["status"]),
            let requestedAt = Self.string(data["requestedAt"]),
            let expiresAt = Self.string(data["expiresAt"])
        else { return nil }
        self.init(
            id: id,
            clientId: clientId,
            destinationId: destinationId,
            actionId: actionId,
            toolName: Self.string(data["toolName"]),
            summary: Self.string(data["summary"]) ?? "",
            status: status,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            respondedAt: Self.string(data["respondedAt"]),
            approvedByDeviceId: Self.string(data["approvedByDeviceId"]),
            schemaVersion: (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1
        )
    }

    var expiresAtDate: Date? { Self.gatewayDate(from: expiresAt) }

    /// A gate is actionable only while it is still waiting and has not passed its
    /// server-stamped expiry.
    func isActionable(relativeTo now: Date = Date()) -> Bool {
        guard isWaiting else { return false }
        guard let expiresAtDate else { return true }
        return now < expiresAtDate
    }

    private static func gatewayDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSString where value.length > 0:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}

/// The sealed gateway message payload schema (MP-27): the agent seals JSON
/// `{text, actionId?, kind?}`; the phone decodes it (never renders the raw bytes)
/// and uses `actionId` to bind an approval detail to the right oversight gate
/// (MP-6). A payload missing `text` is rejected (decode throws → treated as
/// unopenable) so a malformed sealed body never surfaces as a reply.
private struct SealedGatewayPayload: Decodable {
    let text: String
    let actionId: String?
    let kind: String?
}

struct HermesGatewayMessageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let kind: String
    let destinationId: String
    let threadId: String?
    let replyToEventId: String?
    /// Legacy plaintext reply body. Present only on pre-seal (schemaVersion < 2)
    /// docs; sealed docs carry the body in `relayEnvelope.payloadCiphertext`
    /// instead.
    let text: String?
    let attachmentIds: [String]
    let createdAt: String
    let schemaVersion: Int
    /// Sealed reply body (agent→phone). The agent wraps the per-message key to
    /// this phone's relay pubkey; only this device can open it.
    let payloadCiphertext: String?
    let wrappedKey: String?
    let enc: String?
    let relayEncryption: String?
    let relayKeyVersion: Int?
    let ratchetEnvelope: HermesRatchetEnvelope?
    let ratchetEnvelopeCiphertextBase64: String?
    let ratchetEnvelopeAlgorithm: String?
    /// Plaintext recovered by opening `payloadCiphertext` in the snapshot handler.
    /// Held in-memory only; never persisted. `nil` until opened.
    var resolvedText: String?
    /// The `actionId` carried inside a sealed approval-detail payload (MP-27), used
    /// to bind the decrypted detail to the matching server approval gate (MP-6).
    /// `nil` for ordinary replies. In-memory only; never persisted.
    var resolvedActionId: String?
    /// The optional `kind` discriminator carried inside the sealed payload (e.g.
    /// "approval"). In-memory only; never persisted.
    var resolvedKind: String?
    /// Files recovered from `hermes_gateway_attachments`, downloaded from
    /// Storage, opened on this device, and written into the normal chat
    /// attachment workspace. Held in-memory until the chat service persists the
    /// rendered message.
    var openedAttachments: [HermesAttachment]
    /// Referenced gateway attachments that this device could not open during the
    /// latest hydration attempt. Held in-memory only so the UI can show a truthful
    /// recovery state instead of an empty attachment strip.
    var failedAttachmentIds: [String]
    /// True when this device has PINNED the agent's relay public key for this
    /// client (set in `decodedText` from the device Keychain). Once an agent key is
    /// pinned the pairing is relay-capable, so EVERY reply must arrive sealed — an
    /// unsealed reply is a server downgrade/forgery and its server-supplied
    /// plaintext is never rendered. The pin lives in this device's Keychain, so a
    /// hostile server cannot clear it to re-open a plaintext channel. Defaults to
    /// `false` (no pin → genuine legacy client; the plaintext read fallback stays
    /// allowed for pre-cutoff migration). Held in-memory only; never persisted.
    var requiresSealedReply: Bool

    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let clientId = Self.string(data["clientId"]),
            let kind = Self.string(data["kind"]),
            let destinationId = Self.string(data["destinationId"]),
            let createdAt = Self.string(data["createdAt"])
        else { return nil }
        self.id = id
        self.clientId = clientId
        self.kind = kind
        self.destinationId = destinationId
        self.threadId = Self.string(data["threadId"])
        self.replyToEventId = Self.string(data["replyToEventId"])
        self.text = Self.string(data["text"])
        self.attachmentIds = (data["attachmentIds"] as? [Any])?.compactMap(Self.string) ?? []
        self.createdAt = createdAt
        self.schemaVersion = (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1
        let relayEnvelope = Self.dictionary(data["relayEnvelope"])
        self.payloadCiphertext = Self.string(relayEnvelope?["payloadCiphertext"]) ?? Self.string(data["payloadCiphertext"])
        self.wrappedKey = Self.string(relayEnvelope?["wrappedKey"]) ?? Self.string(data["wrappedKey"])
        self.enc = Self.string(relayEnvelope?["enc"]) ?? Self.string(data["enc"])
        self.relayEncryption = Self.string(relayEnvelope?["relayEncryption"]) ?? Self.string(data["relayEncryption"])
        self.relayKeyVersion =
            (relayEnvelope?["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (relayEnvelope?["relayKeyVersion"] as? Int)
            ?? (data["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (data["relayKeyVersion"] as? Int)
        let ratchetEnvelope = Self.dictionary(data["ratchetEnvelope"])
        let ratchetHeader = Self.dictionary(ratchetEnvelope?["header"])
        self.ratchetEnvelope = Self.decodeRatchetEnvelope(ratchetEnvelope)
        self.ratchetEnvelopeCiphertextBase64 = Self.string(ratchetEnvelope?["ciphertextBase64"])
        self.ratchetEnvelopeAlgorithm = Self.string(ratchetHeader?["algorithm"])
        self.resolvedText = nil
        self.resolvedActionId = nil
        self.resolvedKind = nil
        self.openedAttachments = []
        self.failedAttachmentIds = []
        self.requiresSealedReply = false
    }

    /// True when the reply carries a sealed body that must be opened with the
    /// phone's relay key (vs. a legacy plaintext doc).
    var isSealed: Bool {
        isRelaySealed || isRatchetSealed
    }

    private var isRelaySealed: Bool {
        (relayEncryption == HermesRelayCrypto.algorithm || relayEncryption == HermesRelayCrypto.relayEncryptionV3)
            && (payloadCiphertext?.isEmpty == false)
            && (wrappedKey?.isEmpty == false)
    }

    private var isRatchetSealed: Bool {
        ratchetEnvelopeAlgorithm == HermesRatchetCrypto.algorithm
            && (ratchetEnvelopeCiphertextBase64?.isEmpty == false)
    }

    /// The body to render: the opened plaintext for sealed docs, otherwise the
    /// legacy plaintext `text` field. `nil` when a sealed doc has not yet been
    /// opened (or could not be opened on this device).
    var displayText: String? {
        if isSealed { return resolvedText }
        // Downgrade protection: once this device pinned the agent's relay key the
        // pairing is relay-capable, so a reply that is NOT sealed is a server
        // downgrade/forgery. Never surface the server-supplied plaintext `text`.
        if requiresSealedReply { return nil }
        return text
    }

    /// True when a reply that MUST be sealed (this device pinned the agent's relay
    /// key) instead arrived unsealed — a server downgrade/forgery this device
    /// refuses to render. Distinct from `isUndecryptableHere`'s sealed-for-another-
    /// device case so the chat surface can show honest, case-specific copy.
    var isRefusedUnsealedReply: Bool {
        requiresSealedReply && !isSealed
    }

    /// True when this reply is sealed for a different paired device (or otherwise
    /// could not be opened on this device): a sealed doc whose `resolvedText`
    /// stayed `nil` after `decodedText`. The chat surface renders a calm,
    /// jargon-free re-pair state for this instead of an empty/"no text" bubble.
    var isUndecryptableHere: Bool {
        (isSealed && resolvedText == nil) || isRefusedUnsealedReply
    }

    /// Calm, jargon-free copy shown when a reply was encrypted for another
    /// device this account paired. Deliberately avoids transport/crypto terms
    /// (no "relay key", "E2EE", "man-in-the-middle") per the copy policy, and
    /// names the recoverable action — re-pair on this device.
    static let sealedForAnotherDeviceText =
        "This reply was sent privately to another of your devices. Reconnect Hermes on this device to read replies here."

    /// Calm, jargon-free copy shown when a reply that should have been private
    /// instead arrived unprotected (a server downgrade this device refuses to
    /// trust). Avoids transport/crypto terms per the copy policy and names the
    /// recoverable action — reconnect to restore a trusted connection.
    static let unverifiedReplyText =
        "This reply couldn't be verified as coming from your agent, so it's hidden. Reconnect Hermes on this device to restore a trusted connection."

    static func attachmentOpenFailureText(count: Int) -> String {
        if count == 1 {
            return "One attachment could not open on this device. Reconnect Hermes here, then try again."
        }
        return "\(count) attachments could not open on this device. Reconnect Hermes here, then try again."
    }

    /// The single source of truth for what the conversation thread should show
    /// for a gateway reply: the opened body, the legacy plaintext, the
    /// re-pair state for a reply this device cannot open, or a benign fallback
    /// for an attachment-only / empty reply. Used by the live chat path and the
    /// Settings hero so the copy never diverges.
    func chatRenderText(
        emptyFallback: String = "Hermes sent a reply through BurnBar Cloud."
    ) -> String {
        // A reply that should have been sealed but arrived unsealed is a server
        // downgrade/forgery: refuse the ENTIRE reply (body and attachments) and
        // show the calm reconnect state — never render any server-supplied content
        // for a client whose agent key this device has pinned.
        if isRefusedUnsealedReply {
            return Self.unverifiedReplyText
        }
        let failedAttachmentText = failedAttachmentIds.isEmpty ? nil : Self.attachmentOpenFailureText(count: failedAttachmentIds.count)
        if let body = displayText?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            if let failedAttachmentText {
                return "\(body)\n\n\(failedAttachmentText)"
            }
            return body
        }
        // Files that already opened on this device render in the bubble; the
        // caption stays neutral rather than implying a re-pair is needed.
        if !openedAttachments.isEmpty {
            let count = openedAttachments.count
            if let failedAttachmentText {
                return "Hermes sent \(count) attachment\(count == 1 ? "" : "s"). \(failedAttachmentText)"
            }
            return "Hermes sent \(count) attachment\(count == 1 ? "" : "s")."
        }
        // A sealed reply this device cannot open (and with no opened files) shows
        // the calm re-pair state, never a blank/"no text" bubble or crypto jargon.
        if isUndecryptableHere {
            if let failedAttachmentText {
                return "\(Self.sealedForAnotherDeviceText)\n\n\(failedAttachmentText)"
            }
            return Self.sealedForAnotherDeviceText
        }
        if let failedAttachmentText {
            return failedAttachmentText
        }
        if !attachmentIds.isEmpty {
            let count = attachmentIds.count
            return "Hermes sent \(count) attachment\(count == 1 ? "" : "s")."
        }
        return emptyFallback
    }

    /// Open the sealed reply body with this phone's relay key, returning a copy of
    /// the record with `resolvedText` populated. Legacy plaintext docs are
    /// returned unchanged. A sealed doc this device cannot open (key mismatch /
    /// envelope sealed for another device) is returned with `resolvedText == nil`
    /// so the caller can show a graceful "sealed for another device" state rather
    /// than crash or render ciphertext.
    func decodedText(
        using keypair: HermesGatewayRelayKeypair,
        uid: String,
        targetClient: HermesGatewayClientRecord? = nil,
        pinStore: HermesGatewayAgentKeyPinStore = HermesGatewayAgentKeyPinStore()
    ) -> HermesGatewayMessageRecord {
        var resolved = self
        // Downgrade protection (evaluated for BOTH sealed and unsealed docs): if
        // this device has pinned the agent's relay key for this client, every reply
        // must arrive sealed. The render path then refuses an unsealed reply's
        // server-supplied plaintext (see `requiresSealedReply`). The pin is read
        // from the device Keychain, so a hostile server cannot suppress this gate;
        // `requiresSealedReplies` is fail-CLOSED on a Keychain read error (it treats
        // an unreadable pin as "must seal") so a transient Keychain failure can never
        // re-open the plaintext path.
        //
        // v2 closes the anonymous-sender residual: the wrap is now an authenticated
        // 2-DH KEM, and the open below binds the AGENT's PINNED relay key as the
        // sender. A swapped/forged sender key fails the GCM tag, so a compromised
        // relay can no longer seal a forged reply to this phone's public key.
        resolved.requiresSealedReply = pinStore.requiresSealedReplies(uid: uid, clientId: clientId)
        if isRatchetSealed {
            return decodedRatchetText(uid: uid, targetClient: targetClient, resolved: resolved)
        }
        guard isRelaySealed,
              let payloadCiphertext,
              let wrappedKey else {
            return resolved
        }
        guard let pinnedAgentKey = pinStore.pinnedKey(uid: uid, clientId: clientId) else {
            resolved.resolvedText = nil
            return resolved
        }
        do {
            let keyAAD = HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: id)
            let keyData: Data
            if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersion {
                guard relayEncryption == HermesRelayCrypto.algorithm else { return resolved }
                keyData = try HermesRelayCrypto.unwrapSymmetricKey(
                    wrappedKey,
                    privateKey: keypair.privateKey,
                    aad: keyAAD,
                    senderPublicKeyBase64: pinnedAgentKey
                )
            } else if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
                guard relayEncryption == HermesRelayCrypto.relayEncryptionV3,
                      let enc,
                      !enc.isEmpty else { return resolved }
                keyData = try HermesRelayCrypto.openKeyV3(
                    encBase64: enc,
                    wrappedKeyBase64: wrappedKey,
                    privateKey: keypair.privateKey,
                    pinnedSenderPublicKeyBase64: pinnedAgentKey,
                    aad: keyAAD
                )
            } else {
                return resolved
            }
            let plaintext = try HermesRelayCrypto.openBase64(
                ciphertext: payloadCiphertext,
                keyData: keyData,
                aad: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: id)
            )
            // MP-27: the agent seals JSON {text, actionId?, kind?}; decode it (never
            // render the raw bytes, which would show literal `{"text":...}`). A
            // payload without `text` fails to decode and is treated as unopenable.
            if let payload = try? JSONDecoder().decode(SealedGatewayPayload.self, from: plaintext) {
                resolved.resolvedText = payload.text
                resolved.resolvedActionId = payload.actionId
                resolved.resolvedKind = payload.kind
            } else {
                resolved.resolvedText = nil
            }
        } catch {
            resolved.resolvedText = nil
        }
        return resolved
    }

    private func decodedRatchetText(
        uid: String,
        targetClient: HermesGatewayClientRecord?,
        resolved initial: HermesGatewayMessageRecord
    ) -> HermesGatewayMessageRecord {
        var resolved = initial
        guard let envelope = ratchetEnvelope,
              let targetClient,
              targetClient.canRatchetToAgent,
              let agentIdentity = targetClient.agentRatchetIdentityPublicKey,
              let agentSigning = targetClient.agentRatchetSigningPublicKey,
              let agentSignedPreKey = targetClient.agentRatchetSignedPreKeyPublicKey,
              let agentSignedPreKeyID = targetClient.agentRatchetSignedPreKeyId,
              let agentSignature = targetClient.agentRatchetSignedPreKeySignature,
              HermesGatewayRatchetChatLane.verifySignedPreKey(
                signingPublicKeyBase64: agentSigning,
                identityPublicKeyBase64: agentIdentity,
                signedPreKeyPublicKeyBase64: agentSignedPreKey,
                signedPreKeyID: agentSignedPreKeyID,
                signatureBase64: agentSignature
              )
        else {
            resolved.resolvedText = nil
            return resolved
        }
        do {
            let local = try HermesGatewayRatchetPrekeyStore.loadOrCreatePrivateBundle()
            guard local.identityPublicKeyBase64 == targetClient.phoneRatchetIdentityPublicKey,
                  local.signedPreKeyPublicKeyBase64 == targetClient.phoneRatchetSignedPreKeyPublicKey else {
                resolved.resolvedText = nil
                return resolved
            }
            var state: HermesRatchetSessionState
            if let existing = try HermesGatewayRatchetSessionStore.load(sessionID: envelope.header.sessionID) {
                state = existing
            } else {
                guard envelope.header.senderDeviceID.hasPrefix("agent:") else {
                    resolved.resolvedText = nil
                    return resolved
                }
                let sharedSecret = try HermesGatewayRatchetChatLane.responderSharedSecret(
                    uid: uid,
                    clientId: clientId,
                    initiatorRole: .agent,
                    localIdentityPrivateKeyBase64: local.identityPrivateKeyBase64,
                    localSignedPreKeyPrivateKeyBase64: local.signedPreKeyPrivateKeyBase64,
                    localIdentityPublicKeyBase64: local.identityPublicKeyBase64,
                    localSignedPreKeyPublicKeyBase64: local.signedPreKeyPublicKeyBase64,
                    remoteIdentityPublicKeyBase64: agentIdentity,
                    remoteSignedPreKeyPublicKeyBase64: agentSignedPreKey,
                    remoteInitialRatchetPublicKeyBase64: envelope.header.ratchetPublicKeyBase64
                )
                state = try HermesRatchetCrypto.responderState(
                    sessionID: envelope.header.sessionID,
                    localDeviceID: envelope.header.receiverDeviceID,
                    remoteDeviceID: envelope.header.senderDeviceID,
                    sharedSecret: sharedSecret,
                    localInitialRatchetKeyPair: local.signedPreKeyPair
                )
            }
            let plaintext = try HermesRatchetCrypto.decrypt(
                envelope,
                state: &state,
                associatedData: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: id)
            )
            try HermesGatewayRatchetSessionStore.save(state)
            try HermesGatewayRatchetSessionStore.saveCurrentChatSessionID(state.sessionID, uid: uid, clientId: clientId)
            if let payload = try? JSONDecoder().decode(SealedGatewayPayload.self, from: plaintext) {
                resolved.resolvedText = payload.text
                resolved.resolvedActionId = payload.actionId
                resolved.resolvedKind = payload.kind
            } else {
                resolved.resolvedText = nil
            }
        } catch {
            resolved.resolvedText = nil
        }
        return resolved
    }

    func withOpenedAttachments(_ attachments: [HermesAttachment]) -> HermesGatewayMessageRecord {
        var copy = self
        copy.openedAttachments = attachments
        copy.failedAttachmentIds = []
        return copy
    }

    func withAttachmentHydration(opened attachments: [HermesAttachment], failedAttachmentIds: [String]) -> HermesGatewayMessageRecord {
        var copy = self
        copy.openedAttachments = attachments
        copy.failedAttachmentIds = failedAttachmentIds
        return copy
    }

    static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSString where value.length > 0:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    static func dictionary(_ raw: Any?) -> [String: Any]? {
        switch raw {
        case let dict as [String: Any]:
            return dict
        case let dict as NSDictionary:
            return dict as? [String: Any]
        default:
            return nil
        }
    }

    static func decodeRatchetEnvelope(_ raw: [String: Any]?) -> HermesRatchetEnvelope? {
        guard let raw,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return try? JSONDecoder().decode(HermesRatchetEnvelope.self, from: data)
    }
}

/// The opened content of an agent→phone sealed gateway attachment: the manifest
/// (filename / size / content type) plus the decrypted file bytes.
struct HermesGatewayOpenedAttachment: Hashable, Sendable {
    let attachmentId: String
    let fileName: String
    let byteCount: Int
    let contentType: String?
    let data: Data
}

/// An agent→phone sealed gateway attachment as stored in
/// `hermes_gateway_attachments`. The agent seals the file with a per-attachment
/// symmetric key wrapped to this phone's relay pubkey, stores the sealed
/// *manifest* (`{fileName, byteCount, contentType, destinationId}`) in `payloadCiphertext`, and
/// uploads the sealed *body* bytes to Cloud Storage at `bodyStoragePath`. The
/// phone unwraps the body key once and opens both the manifest and the body,
/// each bound to a distinct AAD label so a relay cannot swap one slot for the
/// other. Mirrors the Python adapter `seal_attachment` wire format.
///
/// The gateway settings store fetches only the attachment ids referenced by the
/// selected reply, downloads their sealed body blobs, calls these open
/// primitives, and renders the resulting `HermesAttachment` records through the
/// normal chat bubble strip. No bulk attachment download is needed.
struct HermesGatewayAttachmentRecord: Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let destinationId: String?
    let bodyStoragePath: String?
    let payloadCiphertext: String?
    let wrappedKey: String?
    let enc: String?
    let relayEncryption: String?
    let relayKeyVersion: Int?
    let ratchetEnvelopeCiphertextBase64: String?
    let ratchetEnvelopeAlgorithm: String?
    let createdAt: String?

    init?(documentID: String, data: [String: Any]) {
        guard
            let id = HermesGatewayMessageRecord.string(data["id"]) ?? HermesGatewayMessageRecord.string(data["attachmentId"]) ?? documentID.nilIfEmpty,
            let clientId = HermesGatewayMessageRecord.string(data["clientId"])
        else { return nil }
        self.id = id
        self.clientId = clientId
        self.destinationId = HermesGatewayMessageRecord.string(data["destinationId"])
        self.bodyStoragePath =
            HermesGatewayMessageRecord.string(data["bodyStoragePath"])
            ?? HermesGatewayMessageRecord.string(data["storagePath"])
        let relayEnvelope = HermesGatewayMessageRecord.dictionary(data["relayEnvelope"])
        self.payloadCiphertext =
            HermesGatewayMessageRecord.string(relayEnvelope?["payloadCiphertext"])
            ?? HermesGatewayMessageRecord.string(data["payloadCiphertext"])
        self.wrappedKey =
            HermesGatewayMessageRecord.string(relayEnvelope?["wrappedKey"])
            ?? HermesGatewayMessageRecord.string(data["wrappedKey"])
        self.enc =
            HermesGatewayMessageRecord.string(relayEnvelope?["enc"])
            ?? HermesGatewayMessageRecord.string(data["enc"])
        self.relayEncryption =
            HermesGatewayMessageRecord.string(relayEnvelope?["relayEncryption"])
            ?? HermesGatewayMessageRecord.string(data["relayEncryption"])
        self.relayKeyVersion =
            (relayEnvelope?["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (relayEnvelope?["relayKeyVersion"] as? Int)
            ?? (data["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (data["relayKeyVersion"] as? Int)
        let ratchetEnvelope = HermesGatewayMessageRecord.dictionary(data["ratchetEnvelope"])
        let ratchetHeader = HermesGatewayMessageRecord.dictionary(ratchetEnvelope?["header"])
        self.ratchetEnvelopeCiphertextBase64 = HermesGatewayMessageRecord.string(ratchetEnvelope?["ciphertextBase64"])
        self.ratchetEnvelopeAlgorithm = HermesGatewayMessageRecord.string(ratchetHeader?["algorithm"])
        self.createdAt = HermesGatewayMessageRecord.string(data["createdAt"])
    }

    /// True when this attachment carries a sealed body the phone must open with
    /// its relay key (vs. a legacy plaintext attachment).
    var isSealed: Bool {
        isRelaySealed || isRatchetSealed
    }

    private var isRelaySealed: Bool {
        (relayEncryption == HermesRelayCrypto.algorithm || relayEncryption == HermesRelayCrypto.relayEncryptionV3)
            && (payloadCiphertext?.isEmpty == false)
            && (wrappedKey?.isEmpty == false)
    }

    private var isRatchetSealed: Bool {
        ratchetEnvelopeAlgorithm == HermesRatchetCrypto.algorithm
            && (ratchetEnvelopeCiphertextBase64?.isEmpty == false)
    }

    /// Unwrap the per-attachment body key with this phone's relay key, binding
    /// the *key* AAD (`gatewayAttachmentKey`). Returns `nil` when the attachment
    /// is unsealed or the wrap was sealed for another device. This is the open
    /// primitive shared by the manifest-only and full-body paths.
    func unwrapBodyKey(using keypair: HermesGatewayRelayKeypair, uid: String, pinnedSenderKey: String?) -> Data? {
        guard isRelaySealed, let wrappedKey, let pinnedSenderKey else { return nil }
        let keyAAD = HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: id)
        if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersion {
            guard relayEncryption == HermesRelayCrypto.algorithm else { return nil }
            return try? HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKey,
                privateKey: keypair.privateKey,
                aad: keyAAD,
                senderPublicKeyBase64: pinnedSenderKey
            )
        }
        if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
            guard relayEncryption == HermesRelayCrypto.relayEncryptionV3,
                  let enc,
                  !enc.isEmpty else { return nil }
            return try? HermesRelayCrypto.openKeyV3(
                encBase64: enc,
                wrappedKeyBase64: wrappedKey,
                privateKey: keypair.privateKey,
                pinnedSenderPublicKeyBase64: pinnedSenderKey,
                aad: keyAAD
            )
        }
        return nil
    }

    /// Open the sealed manifest (`{fileName, byteCount, contentType, destinationId}`) with the
    /// already-unwrapped body key, binding the *manifest* AAD. Throws on a
    /// cross-slot swap (the body ciphertext fails the manifest tag) or malformed
    /// manifest JSON.
    func openManifest(bodyKey: Data, uid: String) throws -> HermesGatewayAttachmentManifest {
        guard let payloadCiphertext else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        let manifestData = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: id)
        )
        guard let manifest = HermesGatewayAttachmentManifest(jsonData: manifestData) else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        if let destinationId, !destinationId.isEmpty, manifest.destinationId != destinationId {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return manifest
    }

    /// Open the sealed body bytes with the already-unwrapped body key, binding
    /// the *body* AAD. `downloadedBody` is the raw blob fetched from
    /// `bodyStoragePath`; the agent uploads the base64 of the sealed body, so the
    /// blob is the ASCII base64 string of the ciphertext (matching the Python
    /// `seal_attachment` wire). Throws on a wrong-device key or a tampered body.
    func openBody(downloadedBody: Data, bodyKey: Data, uid: String) throws -> Data {
        guard let ciphertextBase64 = String(data: downloadedBody, encoding: .utf8),
              !ciphertextBase64.isEmpty else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return try HermesRelayCrypto.openBase64(
            ciphertext: ciphertextBase64,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: id)
        )
    }

    /// Full open: unwrap the body key, open the manifest for the filename, and
    /// open the body bytes — returning the rendered attachment. `downloadedBody`
    /// is the blob fetched from `bodyStoragePath` by the caller (the network
    /// download is the caller's responsibility so this stays pure/testable).
    /// Returns `nil` when this device cannot open the attachment (sealed for
    /// another device), so the caller can show the same calm re-pair state as a
    /// sealed reply.
    func opened(
        downloadedBody: Data,
        using keypair: HermesGatewayRelayKeypair,
        uid: String,
        pinnedSenderKey: String?
    ) -> HermesGatewayOpenedAttachment? {
        guard let bodyKey = unwrapBodyKey(using: keypair, uid: uid, pinnedSenderKey: pinnedSenderKey) else { return nil }
        do {
            let manifest = try openManifest(bodyKey: bodyKey, uid: uid)
            let body = try openBody(downloadedBody: downloadedBody, bodyKey: bodyKey, uid: uid)
            return HermesGatewayOpenedAttachment(
                attachmentId: id,
                fileName: manifest.fileName,
                byteCount: manifest.byteCount,
                contentType: manifest.contentType,
                data: body
            )
        } catch {
            return nil
        }
    }
}

/// Decoded gateway-attachment manifest. The agent seals exactly
/// `{fileName, byteCount, contentType, destinationId}` so the phone can name,
/// size, and route the file without ever exposing that to the server.
struct HermesGatewayAttachmentManifest: Hashable, Sendable {
    let fileName: String
    let byteCount: Int
    let contentType: String?
    let destinationId: String

    init?(jsonData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let fileName = HermesGatewayMessageRecord.string(object["fileName"]),
              let destinationId = HermesGatewayMessageRecord.string(object["destinationId"])
        else { return nil }
        self.fileName = fileName
        self.byteCount =
            (object["byteCount"] as? NSNumber)?.intValue
            ?? (object["byteCount"] as? Int)
            ?? 0
        self.contentType = HermesGatewayMessageRecord.string(object["contentType"])
        self.destinationId = destinationId
    }
}

enum HermesGatewayMessageResolver {
    static let defaultThreadID = "burnbar-ios-e2e"

    static func newestReply(
        for event: HermesGatewayQueuedEvent,
        in messages: [HermesGatewayMessageRecord],
        threadID: String = defaultThreadID,
        targetClientId: String? = nil,
        pendingEventSentAt: Date? = nil
    ) -> HermesGatewayMessageRecord? {
        let resolvedTargetClientId = nonEmpty(targetClientId) ?? nonEmpty(event.targetClientId)
        if let exactReply = messages.first(where: {
            $0.replyToEventId == event.id && matchesTarget($0, targetClientId: resolvedTargetClientId)
        }) {
            return exactReply
        }

        return messages.first { message in
            let hasThreadMatch = message.threadId == threadID
            let canUseSealedTimeFallback = message.isSealed && message.threadId == nil && pendingEventSentAt != nil
            guard hasThreadMatch || canUseSealedTimeFallback else { return false }
            guard matchesTarget(message, targetClientId: resolvedTargetClientId) else { return false }
            guard let pendingEventSentAt else { return true }
            guard let createdAt = gatewayDate(from: message.createdAt) else { return false }
            return createdAt >= pendingEventSentAt
        }
    }

    static func newestThreadReply(
        in messages: [HermesGatewayMessageRecord],
        threadID: String = defaultThreadID,
        targetClientId: String? = nil
    ) -> HermesGatewayMessageRecord? {
        messages.first { message in
            guard message.threadId == threadID || (message.isSealed && message.threadId == nil) else { return false }
            guard matchesTarget(message, targetClientId: nonEmpty(targetClientId)) else { return false }
            // A sealed reply is selectable even before it is opened — the snapshot
            // handler opens it and renders `displayText`. Legacy docs gate on the
            // plaintext `text`. Both directions still honor attachment-only replies.
            return message.isSealed
                || message.isRefusedUnsealedReply
                || message.displayText?.isEmpty == false
                || !message.attachmentIds.isEmpty
        }
    }

    static func wasCreatedWhileListening(
        _ reply: HermesGatewayMessageRecord,
        listenerStartedAt: Date?,
        clockSkewGraceInterval: TimeInterval = 30
    ) -> Bool {
        guard let listenerStartedAt,
              let createdAt = gatewayDate(from: reply.createdAt)
        else { return false }
        return createdAt >= listenerStartedAt.addingTimeInterval(-clockSkewGraceInterval)
    }

    private static func gatewayDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func matchesTarget(_ message: HermesGatewayMessageRecord, targetClientId: String?) -> Bool {
        guard let targetClientId else { return true }
        return message.clientId == targetClientId
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct HermesGatewayApprovalResponse: Decodable, Sendable {
    let client: HermesGatewayClientRecord
    let homeDestinationId: String
}

private struct HermesGatewayClientsResponse: Decodable, Sendable {
    let clients: [HermesGatewayClientRecord]
}

private struct FirebaseCallablePayload: @unchecked Sendable {
    let rawValue: NSDictionary

    init(_ payload: [String: Any]) {
        self.rawValue = Self.bridgeDictionary(payload)
    }

    private static func bridgeDictionary(_ dictionary: [String: Any]) -> NSDictionary {
        var bridged: [String: Any] = [:]
        for (key, value) in dictionary {
            bridged[key] = bridgeValue(value)
        }
        return NSDictionary(dictionary: bridged)
    }

    private static func bridgeArray(_ array: [Any]) -> NSArray {
        NSArray(array: array.map(bridgeValue))
    }

    private static func bridgeValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return bridgeDictionary(dictionary)
        }
        if let array = value as? [Any] {
            return bridgeArray(array)
        }
        if let string = value as? String {
            return string as NSString
        }
        if let number = value as? NSNumber {
            return number
        }
        if let bool = value as? Bool {
            return NSNumber(value: bool)
        }
        if let int = value as? Int {
            return NSNumber(value: int)
        }
        if let double = value as? Double {
            return NSNumber(value: double)
        }
        if let float = value as? Float {
            return NSNumber(value: float)
        }
        return value
    }
}

private final class FirebaseCallableExecutor: @unchecked Sendable {
    private let callable: HTTPSCallable

    init(_ callable: HTTPSCallable) {
        self.callable = callable
    }

    func call(_ payload: FirebaseCallablePayload) async throws -> HTTPSCallableResult {
        try await callable.call(payload.rawValue)
    }
}

// MARK: - Hermes Gateway Repository

@MainActor
protocol HermesGatewayRepository: AnyObject {
    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String?,
        destinationId: String,
        scopes: [String],
        phoneRelayPublicKey: String?,
        phoneRelayKeyVersion: Int?,
        phoneRelayEncryption: String?,
        phoneRatchetPrekeyBundle: HermesGatewayRatchetPrekeyBundle?
    ) async throws -> HermesGatewayClientRecord

    func listHermesGatewayClients(includeRevoked: Bool) async throws -> [HermesGatewayClientRecord]
    func revokeHermesGatewayClient(clientId: String) async throws

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String,
        threadId: String,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String,
        threadId: String,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent

    func setHermesGatewayOversightMode(clientId: String, mode: String, targetClient: HermesGatewayClientRecord?) async throws

    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws

    /// After a native approval callable succeeds, enqueue a sealed
    /// ``approval_decision`` event so the Hermes agent applies the choice without
    /// trusting relay-visible ``/approvals`` poll state.
    func enqueueHermesGatewayApprovalDecision(
        approvalId: String,
        approve: Bool,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?
    ) async throws
}

extension HermesGatewayRepository {
    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String? = nil
    ) async throws -> HermesGatewayClientRecord {
        // Publish this phone's persistent relay pubkey at pairing so the agent can
        // seal `hermes_gateway_messages` replies back to this device.
        let keypair = try HermesGatewayRelayKeypair.loadOrCreate()
        let ratchetBundle = try HermesGatewayRatchetPrekeyStore.loadOrCreateBundle()
        return try await approveHermesGatewayDeviceGrant(
            userCode: userCode,
            displayName: displayName,
            destinationId: "burnbar:home",
            scopes: [
                "hermes.gateway.read",
                "hermes.gateway.write",
                "hermes.gateway.manage"
            ],
            phoneRelayPublicKey: keypair.relayPublicKeyBase64,
            phoneRelayKeyVersion: keypair.keyVersion,
            phoneRelayEncryption: keypair.relayEncryption,
            phoneRatchetPrekeyBundle: ratchetBundle
        )
    }

    func listHermesGatewayClients() async throws -> [HermesGatewayClientRecord] {
        try await listHermesGatewayClients(includeRevoked: false)
    }

    func enqueueHermesGatewayEvent(
        text: String,
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await enqueueHermesGatewayEvent(
            text: text,
            destinationId: "burnbar:home",
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId ?? targetClient?.id,
            senderDisplayName: senderDisplayName
        )
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await enqueueHermesGatewayModelSwitch(
            modelId: modelId,
            destinationId: "burnbar:home",
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId ?? targetClient?.id,
            senderDisplayName: senderDisplayName
        )
    }
}

// MARK: - Functions Repository

@MainActor
final class FunctionsRepository: HermesGatewayRepository {
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
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil,
        metadata: ProviderAccountConnectMetadata? = nil
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
        let callable = functions.httpsCallable("connectHostedQuotaAccount")
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
        let callable = functions.httpsCallable("connectSelfHostedQuotaAccount")
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

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        let callable = functions.httpsCallable("connectHostedQuotaAccount")
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
        let callable = functions.httpsCallable("deleteHostedQuotaCredentials")
        _ = try await callable.call(["accountID": accountID])
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

    /// `force` is the explicit repair path: the server rebuilds the usage
    /// counters from raw history. Routine refreshes omit it and are served
    /// from the incremental counters when those are healthy.
    func rebuildUsageRollups(force: Bool = false) async throws {
        let callable = functions.httpsCallable("rebuildUsageRollups")
        _ = try await callable.call(["force": force])
    }

    func searchStreams(query: String, limit: Int = 25) async throws -> [StreamSearchHit] {
        let callable = functions.httpsCallable("searchStreams")
        let result = try await callable.call([
            "query": query,
            "limit": max(1, min(limit, 50))
        ])
        guard let dict = result.data as? [String: Any],
              let rawHits = dict["hits"] else {
            throw FunctionsError.decodingFailed
        }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(rawHits)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode([StreamSearchHit].self, from: data)
    }

    func searchEncryptedConversationIndex(
        tokenHashes: [String],
        semanticHashes: [String] = [],
        limit: Int = 25
    ) async throws -> [CloudConversationSearchHit] {
        let callable = functions.httpsCallable("searchEncryptedConversationIndex")
        let result = try await callable.call([
            "tokenHashes": Array(tokenHashes.prefix(10)),
            "semanticHashes": Array(semanticHashes.prefix(12)),
            "limit": max(1, min(limit, 50))
        ])
        guard let dict = result.data as? [String: Any],
              let rawHits = dict["hits"] else {
            throw FunctionsError.decodingFailed
        }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(rawHits)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CloudConversationSearchHit].self, from: data)
    }

    /// Faceted, paginated query over the user's encrypted session-log manifests for the cockpit.
    /// Server-side filters are limited to operational facets. Project/path/title/body search must
    /// use `searchEncryptedConversationIndex`, where the client sends keyed hashes and decrypts
    /// result labels locally. Pass `cursorDocId` from a prior `nextCursor` to page; request
    /// aggregates only on the first page (`includeAggregates`) since they cover the whole filtered
    /// set.
    func queryConversations(
        providers: [String] = [],
        models: [String] = [],
        deviceId: String? = nil,
        sourceType: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        sort: String = "updatedAt",
        direction: String = "desc",
        limit: Int = 30,
        cursorDocId: String? = nil,
        includeAggregates: Bool = true
    ) async throws -> ConversationQueryResponse {
        let callable = functions.httpsCallable("queryConversations")
        var payload: [String: Any] = [
            "sort": sort,
            "direction": direction,
            "limit": max(1, min(limit, 100)),
            "includeAggregates": includeAggregates
        ]
        if !providers.isEmpty { payload["providers"] = Array(providers.prefix(20)) }
        if !models.isEmpty { payload["models"] = Array(models.prefix(20)) }
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        if let sourceType, !sourceType.isEmpty { payload["sourceType"] = sourceType }
        let iso = ISO8601DateFormatter()
        if let dateFrom { payload["dateFrom"] = iso.string(from: dateFrom) }
        if let dateTo { payload["dateTo"] = iso.string(from: dateTo) }
        if let cursorDocId, !cursorDocId.isEmpty { payload["cursorDocId"] = cursorDocId }

        let result = try await callable.call(payload)
        return try Self.decodeConversationQueryResponse(result.data)
    }

    static func decodeConversationQueryResponse(_ raw: Any?) throws -> ConversationQueryResponse {
        guard let dict = raw as? [String: Any] else {
            throw FunctionsError.decodingFailed
        }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(dict)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(ConversationQueryResponse.self, from: data)
    }

    func encryptedSessionBlobDownloadURL(storagePath: String) async throws -> URL {
        let callable = functions.httpsCallable("getEncryptedSessionBlobDownloadUrl")
        let result = try await callable.call(["storagePath": storagePath])
        guard let dict = result.data as? [String: Any],
              let raw = dict["downloadURL"] as? String,
              let url = URL(string: raw) else {
            throw FunctionsError.decodingFailed
        }
        return url
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

    // MARK: Hermes host pairing

    func createHermesPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> HermesPairingSessionRecord {
        let callable = functions.httpsCallable("createHermesPairing")
        var payload: [String: Any] = [:]
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        if let platform, !platform.isEmpty { payload["platform"] = platform }
        if let displayName, !displayName.isEmpty { payload["displayName"] = displayName }

        let result = try await callable.call(payload)
        return try decodeHermesValue(HermesPairingSessionRecord.self, from: result.data)
    }

    func completeHermesPairing(
        pairingId: String,
        code: String,
        connectionId: String? = nil,
        displayName: String,
        endpointURL: String,
        advertisedModel: String? = nil,
        capabilities: [String] = ["chat_completions"]
    ) async throws -> HermesConnectionRecord {
        let callable = functions.httpsCallable("completeHermesPairing")
        var payload: [String: Any] = [
            "pairingId": pairingId,
            "code": code,
            "displayName": displayName,
            "mode": HermesConnectionMode.directURL.rawValue,
            "endpointURL": endpointURL,
            "capabilities": capabilities
        ]
        if let connectionId, !connectionId.isEmpty {
            payload["connectionId"] = connectionId
        }
        if let advertisedModel, !advertisedModel.isEmpty {
            payload["advertisedModel"] = advertisedModel
        }

        let result = try await callable.call(payload)
        return try decodeHermesValue(HermesConnectionRecord.self, from: result.data)
    }

    func listHermesConnections() async throws -> [HermesConnectionRecord] {
        let callable = functions.httpsCallable("listHermesConnections")
        let result = try await callable.call([:])
        guard
            let dict = result.data as? [String: Any],
            let connections = dict["connections"]
        else {
            throw FunctionsError.decodingFailed
        }
        return try decodeHermesValue([HermesConnectionRecord].self, from: connections)
    }

    func revokeHermesConnection(connectionId: String) async throws {
        let callable = functions.httpsCallable("revokeHermesConnection")
        _ = try await callable.call(["connectionId": connectionId])
    }

    func revokeRemoteMcpClient(clientID: String) async throws {
        let callable = functions.httpsCallable("revokeRemoteMcpClient")
        _ = try await callable.call(["clientId": clientID])
    }

    // MARK: Hermes Gateway platform adapter

    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String? = nil,
        destinationId: String = "burnbar:home",
        scopes: [String] = [
            "hermes.gateway.read",
            "hermes.gateway.write",
            "hermes.gateway.manage"
        ],
        phoneRelayPublicKey: String? = nil,
        phoneRelayKeyVersion: Int? = nil,
        phoneRelayEncryption: String? = nil,
        phoneRatchetPrekeyBundle: HermesGatewayRatchetPrekeyBundle? = nil
    ) async throws -> HermesGatewayClientRecord {
        let callable = functions.httpsCallable("approveHermesGatewayDeviceGrant")
        var payload: [String: Any] = [
            "userCode": userCode,
            "destinationId": destinationId,
            "scopes": scopes
        ]
        if let displayName, !displayName.isEmpty {
            payload["displayName"] = displayName
        }
        // Publish the phone's relay pubkey so the agent can seal replies to it.
        if let phoneRelayPublicKey, !phoneRelayPublicKey.isEmpty {
            payload["phoneRelayPublicKey"] = phoneRelayPublicKey
            payload["supportsRelayEnvelopeVersions"] = [
                HermesRelayCrypto.gatewayRelayKeyVersion,
                HermesRelayCrypto.gatewayRelayKeyVersionV3
            ]
            payload["preferredRelayEnvelopeVersion"] = HermesRelayCrypto.gatewayRelayKeyVersionV3
            payload["supportsHpkeV3"] = true
            payload["clientPlatform"] = "ios"
            payload["clientAppBuild"] =
                (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                ?? "unknown"
        }
        if let phoneRelayKeyVersion {
            payload["phoneRelayKeyVersion"] = phoneRelayKeyVersion
        }
        if let phoneRelayEncryption, !phoneRelayEncryption.isEmpty {
            payload["phoneRelayEncryption"] = phoneRelayEncryption
        }
        if let phoneRatchetPrekeyBundle {
            payload["phoneRatchetIdentityPublicKey"] = phoneRatchetPrekeyBundle.identityPublicKeyBase64
            payload["phoneRatchetSigningPublicKey"] = phoneRatchetPrekeyBundle.signingPublicKeyBase64
            payload["phoneRatchetSignedPreKeyPublicKey"] = phoneRatchetPrekeyBundle.signedPreKeyPublicKeyBase64
            payload["phoneRatchetSignedPreKeyId"] = phoneRatchetPrekeyBundle.signedPreKeyID
            payload["phoneRatchetSignedPreKeySignature"] = phoneRatchetPrekeyBundle.signedPreKeySignatureBase64
            payload["phoneSupportsRatchetV1"] = true
        }

        try await prepareHermesGatewayApprovalContext()
        let executor = FirebaseCallableExecutor(callable)
        let callablePayload = FirebaseCallablePayload(payload)
        let result: HTTPSCallableResult
        do {
            result = try await executor.call(callablePayload)
        } catch {
            guard Self.isUnauthenticatedCallableError(error) else {
                throw Self.mappedHermesGatewayApprovalError(error)
            }
            // Firebase Auth can lag the SwiftUI signed-in state immediately after
            // a sign-out/sign-in cycle. Force one more token/App Check refresh
            // before surfacing the error to the user.
            try await prepareHermesGatewayApprovalContext()
            do {
                result = try await executor.call(callablePayload)
            } catch {
                throw Self.mappedHermesGatewayApprovalError(error)
            }
        }
        return try Self.decodeHermesGatewayValue(HermesGatewayApprovalResponse.self, from: result.data).client
    }

    private func prepareHermesGatewayApprovalContext() async throws {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else {
            throw FunctionsError.gatewayApprovalNotAuthenticated
        }
        do {
            _ = try await user.getIDTokenResult(forcingRefresh: true)
        } catch {
            throw FunctionsError.gatewayApprovalNotAuthenticated
        }
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: true)
            guard !token.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FunctionsError.gatewayApprovalAppCheckBlocked
            }
        } catch let error as FunctionsError {
            throw error
        } catch {
            throw FunctionsError.gatewayApprovalAppCheckBlocked
        }
    }

    private static func mappedHermesGatewayApprovalError(_ error: Error) -> Error {
        guard isUnauthenticatedCallableError(error) else { return error }
        let message = (error as NSError).localizedDescription
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if message.contains("appcheck") || message.contains("attestation") {
            return FunctionsError.gatewayApprovalAppCheckBlocked
        }
        return FunctionsError.gatewayApprovalNotAuthenticated
    }

    private static func isUnauthenticatedCallableError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FunctionsErrorDomain
            && nsError.code == FunctionsErrorCode.unauthenticated.rawValue
    }

    func listHermesGatewayClients(includeRevoked: Bool = false) async throws -> [HermesGatewayClientRecord] {
        let callable = functions.httpsCallable("listHermesGatewayClients")
        let result = try await callable.call(["includeRevoked": includeRevoked])
        return try Self.decodeHermesGatewayValue(HermesGatewayClientsResponse.self, from: result.data).clients
    }

    func revokeHermesGatewayClient(clientId: String) async throws {
        let callable = functions.httpsCallable("revokeHermesGatewayClient")
        _ = try await callable.call(["clientId": clientId])
    }

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        let callable = functions.httpsCallable("enqueueHermesGatewayEvent")
        var payload: [String: Any] = [
            "destinationId": destinationId,
            "threadId": threadId,
            "senderId": "burnbar-ios"
        ]
        if let resolvedTargetClientId = Self.trimmedClientID(targetClientId) {
            payload["targetClientId"] = resolvedTargetClientId
        }
        try Self.applyGatewayEventSeal(
            into: &payload,
            text: text,
            senderDisplayName: senderDisplayName,
            threadId: threadId,
            modelId: nil,
            targetClient: targetClient
        )
        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try Self.decodeHermesGatewayValue(HermesGatewayQueuedEvent.self, from: result.data)
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        let callable = functions.httpsCallable("enqueueHermesGatewayEvent")
        var payload: [String: Any] = [
            "destinationId": destinationId,
            "senderId": "burnbar-ios",
            "eventKind": "model_switch"
        ]
        if let resolvedTargetClientId = Self.trimmedClientID(targetClientId) {
            payload["targetClientId"] = resolvedTargetClientId
        }
        if targetClient?.canSealToAgent == true {
            // E2E link: seal the model id into `relayEnvelope.payloadCiphertext`
            // (alongside text/senderDisplayName/threadId) like every other event,
            // so the model command never leaves the device in cleartext. The
            // agent opens `modelId` from inside the sealed payload after polling.
            // We now also stamp top-level `kind` inside the sealed payload so the
            // receiving agent dispatches it as a control (not chat text) per the
            // E2EE remediation requirement.
            try Self.applyGatewayEventSeal(
                into: &payload,
                text: "",
                senderDisplayName: senderDisplayName,
                threadId: threadId,
                modelId: modelId,
                targetClient: targetClient,
                kind: "model_switch"
            )
        } else {
            // Legacy (non-canSealToAgent) link during the grace window: the agent
            // has no relay key to wrap to, so the routing-only model id stays
            // cleartext per the gateway wire contract until that Mac re-pairs.
            // Wire stays identical to the pre-seal model_switch (no threadId).
            payload["modelId"] = modelId
        }
        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try Self.decodeHermesGatewayValue(HermesGatewayQueuedEvent.self, from: result.data)
    }

    private static func trimmedClientID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private nonisolated static func gatewayDestinationID(in payload: [String: Any]) -> String {
        if let value = payload["destinationId"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = payload["destinationId"] as? NSString, value.length > 0 {
            return value as String
        }
        return "burnbar:home"
    }

    private nonisolated static let gatewayEventCounterLock = NSLock()
    private nonisolated static let gatewayEventCounterKeyPrefix = "openburnbar.hermesGateway.eventReplayCounter.v1"
    private nonisolated static let gatewaySealedPayloadReservedKeys: Set<String> = [
        "text",
        "destinationId",
        "replayCounter",
        "eventCounter",
        "senderDisplayName",
        "threadId",
        "modelId",
        "kind"
    ]

    private nonisolated static func gatewayEventCounterStorageKey(
        uid: String,
        clientId: String,
        phoneRelayPublicKey: String
    ) -> String {
        let material = [uid, clientId, phoneRelayPublicKey].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(gatewayEventCounterKeyPrefix).\(digest)"
    }

    private nonisolated static func nextGatewayEventReplayCounter(
        uid: String,
        clientId: String,
        phoneRelayPublicKey: String,
        defaults: UserDefaults = .standard
    ) throws -> Int {
        let storageKey = gatewayEventCounterStorageKey(
            uid: uid,
            clientId: clientId,
            phoneRelayPublicKey: phoneRelayPublicKey
        )
        gatewayEventCounterLock.lock()
        defer { gatewayEventCounterLock.unlock() }

        let raw = defaults.object(forKey: storageKey)
        let current: Int
        if let value = raw as? Int {
            current = max(0, value)
        } else if let value = raw as? NSNumber {
            current = max(0, value.intValue)
        } else {
            current = 0
        }
        guard current < Int.max else {
            throw FunctionsError.gatewayReplayCounterExhausted
        }
        let next = current + 1
        defaults.set(next, forKey: storageKey)
        return next
    }

    private nonisolated static func applyExtraSealedFields(
        _ fields: [String: Any],
        to sealedPayload: inout [String: Any]
    ) throws {
        try validateExtraSealedFields(fields)
        for (rawKey, value) in fields {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            sealedPayload[key] = value
        }
    }

    private nonisolated static func validateExtraSealedFields(_ fields: [String: Any]) throws {
        for rawKey in fields.keys {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !gatewaySealedPayloadReservedKeys.contains(key) else {
                throw FunctionsError.gatewayInvalidSealedControlPayload
            }
        }
    }

    /// Seal the phone→agent event payload into `payload`, reusing the existing
    /// `HermesRelayCrypto` envelope. When the target agent has published a usable
    /// relay pubkey (`canSealToAgent`), the cleartext body never leaves the
    /// device: a per-event symmetric key seals `{text, destinationId,
    /// replayCounter, senderDisplayName, threadId[, modelId]}` and is wrapped to
    /// the agent's pubkey. The phone generates the `eventId` so it binds the AAD;
    /// the server honors it as the doc id. If the target cannot seal, the call
    /// fails before constructing any plaintext cloud payload.
    private static func applyGatewayEventSeal(
        into payload: inout [String: Any],
        text: String,
        senderDisplayName: String,
        threadId: String,
        modelId: String?,
        targetClient: HermesGatewayClientRecord?,
        pinStore: HermesGatewayAgentKeyPinStore = HermesGatewayAgentKeyPinStore(),
        kind: String? = nil,
        extraSealedFields: [String: Any] = [:]
    ) throws {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }
        try sealGatewayEventPayload(
            into: &payload,
            text: text,
            senderDisplayName: senderDisplayName,
            threadId: threadId,
            modelId: modelId,
            targetClient: targetClient,
            uid: uid,
            pinStore: pinStore,
            kind: kind,
            extraSealedFields: extraSealedFields
        )
    }

    /// Pure, `uid`-injected seal core shared by the live path and tests. Refuses
    /// to seal unless the target can seal AND its advertised relay pubkey passes
    /// the phone's TOFU pin check. Fails closed on every gap.
    nonisolated static func sealGatewayEventPayload(
        into payload: inout [String: Any],
        text: String,
        senderDisplayName: String,
        threadId: String,
        modelId: String?,
        targetClient: HermesGatewayClientRecord?,
        uid: String,
        pinStore: HermesGatewayAgentKeyPinStore = HermesGatewayAgentKeyPinStore(),
        kind: String? = nil,
        extraSealedFields: [String: Any] = [:]
    ) throws {
        guard let targetClient, !uid.isEmpty else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }
        try validateExtraSealedFields(extraSealedFields)

        if targetClient.canRatchetToAgent {
            try sealGatewayEventRatchetPayload(
                into: &payload,
                text: text,
                senderDisplayName: senderDisplayName,
                threadId: threadId,
                modelId: modelId,
                targetClient: targetClient,
                uid: uid,
                pinStore: pinStore,
                kind: kind,
                extraSealedFields: extraSealedFields
            )
            return
        }

        let keypair = try HermesGatewayRelayKeypair.loadOrCreate()
        guard targetClient.isPairedWithThisDevice(relayPublicKeyBase64: keypair.relayPublicKeyBase64) else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        guard targetClient.canSealToAgent,
              let relayPublicKey = targetClient.relayPublicKey
        else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        // Phone-side TOFU pin (defense-in-depth alongside the server immutability
        // fix): refuse to seal to a key that differs from the one we pinned at
        // first pairing. A mismatch — or a Keychain read failure we can't verify
        // against — fails closed: the encrypted payload is never built, so no
        // plaintext or attacker-readable ciphertext leaves the device.
        guard pinStore
            .verifyOrPin(agentPublicKeyBase64: relayPublicKey, uid: uid, clientId: targetClient.id)
            .allowsSeal
        else {
            throw FunctionsError.gatewayRelayKeyChanged
        }

        // v2 authenticated seal: the phone's own persistent gateway relay key is
        // the SENDER. The agent opens the event binding this phone key (which it
        // pinned at pairing), so a relay that cannot produce the phone's private
        // key cannot forge an event to the agent.
        let destinationId = gatewayDestinationID(in: payload)
        let eventId = "evt_\(UUID().uuidString.lowercased())"
        let replayCounter = try nextGatewayEventReplayCounter(
            uid: uid,
            clientId: targetClient.id,
            phoneRelayPublicKey: keypair.relayPublicKeyBase64
        )
        var sealedPayload: [String: Any] = [
            "text": text,
            "destinationId": destinationId,
            "replayCounter": replayCounter,
            "senderDisplayName": senderDisplayName,
            "threadId": threadId
        ]
        if let modelId, !modelId.isEmpty {
            sealedPayload["modelId"] = modelId
        }
        if let k = kind, !k.isEmpty {
            sealedPayload["kind"] = k
        }
        try applyExtraSealedFields(extraSealedFields, to: &sealedPayload)
        let plaintext = try JSONSerialization.data(withJSONObject: sealedPayload)
        let key = try HermesRelayCrypto.generateSymmetricKeyData()
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: plaintext,
            keyData: key,
            aad: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: targetClient.id, eventId: eventId)
        )
        let keyAAD = HermesRelayCrypto.gatewayEventKeyAAD(uid: uid, clientId: targetClient.id, eventId: eventId)
        var relayEnvelope: [String: Any] = [
            "payloadCiphertext": payloadCiphertext,
            "senderPublicKey": keypair.relayPublicKeyBase64
        ]
        if targetClient.preferredRelayEnvelopeVersionForSeal == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
            let wrap = try HermesRelayCrypto.sealKeyV3(
                key,
                recipientPublicKeyBase64: relayPublicKey,
                senderPrivateKey: keypair.privateKey,
                aad: keyAAD
            )
            relayEnvelope["wrappedKey"] = wrap.wrappedKey.base64EncodedString()
            relayEnvelope["enc"] = wrap.enc.base64EncodedString()
            relayEnvelope["relayEncryption"] = HermesRelayCrypto.relayEncryptionV3
            relayEnvelope["relayKeyVersion"] = HermesRelayCrypto.gatewayRelayKeyVersionV3
        } else {
            relayEnvelope["wrappedKey"] = try HermesRelayCrypto.wrapSymmetricKey(
                key,
                recipientPublicKeyBase64: relayPublicKey,
                aad: keyAAD,
                senderPrivateKey: keypair.privateKey
            )
            relayEnvelope["relayEncryption"] = HermesRelayCrypto.algorithm
            relayEnvelope["relayKeyVersion"] = HermesRelayCrypto.gatewayRelayKeyVersion
        }
        // Drop plaintext text/senderDisplayName/threadId from the top level — they
        // now live only inside `payloadCiphertext`. Keep routing fields. The
        // `relayKeyVersion` is the gateway wrap-protocol version the phone
        // authoritatively stamped for what it actually sealed. `senderPublicKey` is
        // a lookup hint; the agent authenticates against its pinned copy, never
        // this wire field.
        payload["eventId"] = eventId
        payload["relayEnvelope"] = relayEnvelope
    }

    private nonisolated static func sealGatewayEventRatchetPayload(
        into payload: inout [String: Any],
        text: String,
        senderDisplayName: String,
        threadId: String,
        modelId: String?,
        targetClient: HermesGatewayClientRecord,
        uid: String,
        pinStore: HermesGatewayAgentKeyPinStore,
        kind: String? = nil,
        extraSealedFields: [String: Any] = [:]
    ) throws {
        let localRelayKeypair = try HermesGatewayRelayKeypair.loadOrCreate()
        guard targetClient.isPairedWithThisDevice(relayPublicKeyBase64: localRelayKeypair.relayPublicKeyBase64) else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        guard targetClient.canSealToAgent,
              let relayPublicKey = targetClient.relayPublicKey,
              pinStore.verifyOrPin(agentPublicKeyBase64: relayPublicKey, uid: uid, clientId: targetClient.id).allowsSeal,
              let agentIdentity = targetClient.agentRatchetIdentityPublicKey,
              let agentSigning = targetClient.agentRatchetSigningPublicKey,
              let agentSignedPreKey = targetClient.agentRatchetSignedPreKeyPublicKey,
              let agentSignedPreKeyID = targetClient.agentRatchetSignedPreKeyId,
              let agentSignature = targetClient.agentRatchetSignedPreKeySignature,
              HermesGatewayRatchetChatLane.verifySignedPreKey(
                signingPublicKeyBase64: agentSigning,
                identityPublicKeyBase64: agentIdentity,
                signedPreKeyPublicKeyBase64: agentSignedPreKey,
                signedPreKeyID: agentSignedPreKeyID,
                signatureBase64: agentSignature
              )
        else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        let local = try HermesGatewayRatchetPrekeyStore.loadOrCreatePrivateBundle()
        guard local.identityPublicKeyBase64 == targetClient.phoneRatchetIdentityPublicKey,
              local.signedPreKeyPublicKeyBase64 == targetClient.phoneRatchetSignedPreKeyPublicKey else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        let destinationId = gatewayDestinationID(in: payload)
        let eventId = "evt_\(UUID().uuidString.lowercased())"
        let replayCounter = try nextGatewayEventReplayCounter(
            uid: uid,
            clientId: targetClient.id,
            phoneRelayPublicKey: localRelayKeypair.relayPublicKeyBase64
        )
        var sealedPayload: [String: Any] = [
            "text": text,
            "destinationId": destinationId,
            "replayCounter": replayCounter,
            "senderDisplayName": senderDisplayName,
            "threadId": threadId
        ]
        if let modelId, !modelId.isEmpty {
            sealedPayload["modelId"] = modelId
        }
        if let k = kind, !k.isEmpty {
            sealedPayload["kind"] = k
        }
        try applyExtraSealedFields(extraSealedFields, to: &sealedPayload)
        let plaintext = try JSONSerialization.data(withJSONObject: sealedPayload)
        let phoneDeviceID = try HermesGatewayRatchetChatLane.deviceID(prefix: "phone", identityPublicKeyBase64: local.identityPublicKeyBase64)
        let agentDeviceID = try HermesGatewayRatchetChatLane.deviceID(prefix: "agent", identityPublicKeyBase64: agentIdentity)
        var state: HermesRatchetSessionState
        if let sessionID = try HermesGatewayRatchetSessionStore.loadCurrentChatSessionID(uid: uid, clientId: targetClient.id),
           let existing = try HermesGatewayRatchetSessionStore.load(sessionID: sessionID) {
            state = existing
        } else {
            let initialRatchet = HermesRatchetCrypto.generateKeyPair()
            let sessionID = try HermesGatewayRatchetChatLane.sessionID(
                uid: uid,
                clientId: targetClient.id,
                initiatorRole: .phone,
                initiatorIdentityPublicKeyBase64: local.identityPublicKeyBase64,
                responderIdentityPublicKeyBase64: agentIdentity,
                initiatorSignedPreKeyPublicKeyBase64: local.signedPreKeyPublicKeyBase64,
                responderSignedPreKeyPublicKeyBase64: agentSignedPreKey,
                initiatorInitialRatchetPublicKeyBase64: initialRatchet.publicKeyBase64
            )
            let sharedSecret = try HermesGatewayRatchetChatLane.initiatorSharedSecret(
                uid: uid,
                clientId: targetClient.id,
                initiatorRole: .phone,
                localIdentityPrivateKeyBase64: local.identityPrivateKeyBase64,
                localSignedPreKeyPublicKeyBase64: local.signedPreKeyPublicKeyBase64,
                localInitialRatchetKeyPair: initialRatchet,
                remoteIdentityPublicKeyBase64: agentIdentity,
                remoteSignedPreKeyPublicKeyBase64: agentSignedPreKey
            )
            state = try HermesRatchetCrypto.initiatorState(
                sessionID: sessionID,
                localDeviceID: phoneDeviceID,
                remoteDeviceID: agentDeviceID,
                sharedSecret: sharedSecret,
                remoteInitialRatchetPublicKeyBase64: agentSignedPreKey,
                localInitialRatchetKeyPair: initialRatchet
            )
        }
        let envelope = try HermesRatchetCrypto.encrypt(
            plaintext: plaintext,
            state: &state,
            associatedData: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: targetClient.id, eventId: eventId)
        )
        try HermesGatewayRatchetSessionStore.save(state)
        try HermesGatewayRatchetSessionStore.saveCurrentChatSessionID(state.sessionID, uid: uid, clientId: targetClient.id)
        let envelopeData = try JSONEncoder().encode(envelope)
        guard let envelopeJSON = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
            throw HermesRatchetError.invalidEnvelope
        }
        payload["eventId"] = eventId
        payload["ratchetEnvelope"] = envelopeJSON
    }

    func setHermesGatewayOversightMode(clientId: String, mode: String, targetClient: HermesGatewayClientRecord?) async throws {
        // On E2E-paired links, also emit a sealed oversight_mode control event.
        // The agent on E2E links ignores the relay-visible client doc state for
        // oversight (to avoid relay-controlled flips) and only applies changes
        // delivered via pinned-sender sealed events. Build the envelope before
        // mutating the relay-visible doc so local key/pin failures fail cleanly.
        var sealedOversightPayload: [String: Any]?
        if let tc = targetClient, tc.canSealToAgent {
            var payload: [String: Any] = [
                "destinationId": "burnbar:home",
                "senderId": "burnbar-ios",
                "threadId": "burnbar-ios-oversight"
            ]
            if let rid = Self.trimmedClientID(tc.id) {
                payload["targetClientId"] = rid
            }
            let extra: [String: Any] = [
                "mode": mode,
                "senderId": "burnbar-ios"
            ]
            try Self.applyGatewayEventSeal(
                into: &payload,
                text: "",
                senderDisplayName: "OpenBurnBar iPhone",
                threadId: "burnbar-ios-oversight",
                modelId: nil,
                targetClient: tc,
                kind: "oversight_mode",
                extraSealedFields: extra
            )
            sealedOversightPayload = payload
        }

        let callable = functions.httpsCallable("setHermesGatewayOversightMode")
        _ = try await callable.call([
            "clientId": clientId,
            "mode": mode
        ])

        if let sealedOversightPayload {
            let ev = functions.httpsCallable("enqueueHermesGatewayEvent")
            _ = try await FirebaseCallableExecutor(ev).call(FirebaseCallablePayload(sealedOversightPayload))
        }
    }

    /// Bind a gateway oversight approve/reject decision to this trusted native
    /// escrow device, reusing the same App-Check-enforced device-trust path as
    /// the CLI-mission `respondMissionApproval` flow.
    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        try await ComputerUseSecurityCallableClient.respondHermesGatewayApproval(
            approvalId: approvalId,
            approve: approve,
            deviceId: deviceId
        )
    }

    func enqueueHermesGatewayApprovalDecision(
        approvalId: String,
        approve: Bool,
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil
    ) async throws {
        let choice = approve ? "approve" : "reject"
        // For E2E links we must emit the control fields (including "kind") at the
        // root of the sealed payload so the agent can dispatch to the special
        // _handle_sealed_approval_decision path (rather than treating it as chat
        // text). The legacy json-in-text path is retired for correctness.
        var payload: [String: Any] = [
            "destinationId": "burnbar:home",
            "senderId": "burnbar-ios",
            "threadId": "burnbar-ios-approval"
        ]
        if let resolvedTargetClientId = Self.trimmedClientID(targetClientId) ?? Self.trimmedClientID(targetClient?.id) {
            payload["targetClientId"] = resolvedTargetClientId
        }
        let extra: [String: Any] = [
            "actionId": approvalId,
            "choice": choice,
            "senderId": "burnbar-ios"
        ]
        try Self.applyGatewayEventSeal(
            into: &payload,
            text: "",
            senderDisplayName: "OpenBurnBar iPhone",
            threadId: "burnbar-ios-approval",
            modelId: nil,
            targetClient: targetClient,
            kind: "approval_decision",
            extraSealedFields: extra
        )
        let callable = functions.httpsCallable("enqueueHermesGatewayEvent")
        _ = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
    }

    // MARK: Pi Agent host pairing

    func createPiAgentPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> PiPairingSessionRecord {
        let callable = functions.httpsCallable("createPiAgentPairing")
        var payload: [String: Any] = [:]
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        if let platform, !platform.isEmpty { payload["platform"] = platform }
        if let displayName, !displayName.isEmpty { payload["displayName"] = displayName }

        let result = try await callable.call(payload)
        return try decodeHermesValue(PiPairingSessionRecord.self, from: result.data)
    }

    func completePiAgentPairing(
        pairingId: String,
        code: String,
        connectionId: String? = nil,
        displayName: String,
        mode: PiConnectionMode = .directURL,
        endpointURL: String,
        advertisedModel: String? = nil,
        selectedInstanceID: String? = nil,
        redisURL: String? = nil,
        capabilities: [String] = ["chat_completions"],
        instances: [PiAgentInstanceRecord] = [],
        models: [PiAgentRuntimeModelOption] = [],
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        realtimeRelayURL: String? = nil,
        realtimeRelayStatus: String? = nil,
        deviceId: String? = nil
    ) async throws -> PiConnectionRecord {
        let callable = functions.httpsCallable("completePiAgentPairing")
        var payload: [String: Any] = [
            "pairingId": pairingId,
            "code": code,
            "displayName": displayName,
            "mode": mode.rawValue,
            "endpointURL": endpointURL,
            "capabilities": capabilities
        ]
        if let connectionId, !connectionId.isEmpty { payload["connectionId"] = connectionId }
        if let advertisedModel, !advertisedModel.isEmpty { payload["advertisedModel"] = advertisedModel }
        if let selectedInstanceID, !selectedInstanceID.isEmpty { payload["selectedInstanceID"] = selectedInstanceID }
        if let redisURL, !redisURL.isEmpty { payload["redisURL"] = redisURL }
        if !instances.isEmpty { payload["instances"] = try encodedFunctionValue(instances) }
        if !models.isEmpty { payload["models"] = try encodedFunctionValue(models) }
        if let relayPublicKey, !relayPublicKey.isEmpty { payload["relayPublicKey"] = relayPublicKey }
        if let relayKeyVersion { payload["relayKeyVersion"] = relayKeyVersion }
        if let relayEncryption, !relayEncryption.isEmpty { payload["relayEncryption"] = relayEncryption }
        if let realtimeRelayURL, !realtimeRelayURL.isEmpty { payload["realtimeRelayURL"] = realtimeRelayURL }
        if let realtimeRelayStatus, !realtimeRelayStatus.isEmpty { payload["realtimeRelayStatus"] = realtimeRelayStatus }
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }

        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try decodeHermesValue(PiConnectionRecord.self, from: result.data)
    }

    func listPiAgentConnections(includeRevoked: Bool = false) async throws -> [PiConnectionRecord] {
        let callable = functions.httpsCallable("listPiAgentConnections")
        let result = try await callable.call(["includeRevoked": includeRevoked])
        guard
            let dict = result.data as? [String: Any],
            let connections = dict["connections"]
        else {
            throw FunctionsError.decodingFailed
        }
        return try decodeHermesValue([PiConnectionRecord].self, from: connections)
    }

    func revokePiAgentConnection(connectionId: String, deviceId: String? = nil) async throws {
        let callable = functions.httpsCallable("revokePiAgentConnection")
        var payload: [String: Any] = ["connectionId": connectionId]
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        _ = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
    }

    func updatePiAgentConnectionStatus(
        connectionId: String,
        status: PiConnectionStatus,
        advertisedModel: String? = nil,
        selectedInstanceID: String? = nil,
        capabilities: [String]? = nil,
        instances: [PiAgentInstanceRecord]? = nil,
        models: [PiAgentRuntimeModelOption]? = nil,
        deviceId: String? = nil
    ) async throws {
        let callable = functions.httpsCallable("updatePiAgentConnectionStatus")
        var payload: [String: Any] = [
            "connectionId": connectionId,
            "status": status.rawValue
        ]
        if let advertisedModel, !advertisedModel.isEmpty { payload["advertisedModel"] = advertisedModel }
        if let selectedInstanceID, !selectedInstanceID.isEmpty { payload["selectedInstanceID"] = selectedInstanceID }
        if let capabilities { payload["capabilities"] = capabilities }
        if let instances { payload["instances"] = try encodedFunctionValue(instances) }
        if let models { payload["models"] = try encodedFunctionValue(models) }
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        _ = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
    }

    private func decodeHermesValue<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(raw)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func decodeHermesGatewayValue<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let sanitized = sanitizeHermesGatewayJSON(raw)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func sanitizeHermesGatewayJSON(_ value: Any) -> Any {
        switch value {
        case let ts as Timestamp:
            return ISO8601DateFormatter().string(from: ts.dateValue())
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitizeHermesGatewayJSON(entry.value)
            }
        case let dict as NSDictionary:
            return dict.reduce(into: [String: Any]()) { result, entry in
                guard let key = entry.key as? String else { return }
                result[key] = sanitizeHermesGatewayJSON(entry.value)
            }
        case let arr as [Any]:
            return arr.map { sanitizeHermesGatewayJSON($0) }
        case let arr as NSArray:
            return arr.map { sanitizeHermesGatewayJSON($0) }
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    #if DEBUG
    nonisolated static func decodeHermesGatewayApprovalClientForTesting(_ raw: Any) throws -> HermesGatewayClientRecord {
        try decodeHermesGatewayValue(HermesGatewayApprovalResponse.self, from: raw).client
    }
    #endif

    private func encodedFunctionValue<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
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
        let callable = functions.httpsCallable("restoreHostedQuotaEntitlement")
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
        let callable = functions.httpsCallable("verifyCloudProTopUp")
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

enum FunctionsError: Error, LocalizedError, Equatable {
    case decodingFailed
    case gatewayTargetMissingRelayKey
    case gatewayRelayKeyChanged
    case gatewayAttachmentUnreadable
    case gatewayApprovalNotAuthenticated
    case gatewayApprovalAppCheckBlocked
    case gatewayReplayCounterExhausted
    case gatewayInvalidSealedControlPayload

    var errorDescription: String? {
        switch self {
        case .decodingFailed: return "Failed to decode cloud function response."
        case .gatewayTargetMissingRelayKey:
            // Benefit-first, jargon-free per the copy policy: messages stay
            // private, so they can only send once the Mac is ready.
            return "Update OpenBurnBar on your Mac, then reconnect Hermes. Messages here stay private to your devices, so they can only be sent once that Mac is ready."
        case .gatewayRelayKeyChanged:
            // No transport/security jargon ("relay key", "man-in-the-middle"):
            // calm, action-first copy that protects the user and names the fix.
            return "This Hermes connection looks different from when you set it up, so your message was kept on this device for your safety. Reconnect Hermes on your Mac to keep sending privately."
        case .gatewayAttachmentUnreadable:
            return "This file was shared privately with another of your devices. Reconnect Hermes on this device to open files here."
        case .gatewayApprovalNotAuthenticated:
            return "Sign in to BurnBar Cloud, then reopen Hermes Gateway and tap Connect Hermes again."
        case .gatewayApprovalAppCheckBlocked:
            return "App Check rejected this build. Reinstall from the official channel, or register and stamp the local debug token before trying Connect Hermes."
        case .gatewayReplayCounterExhausted:
            return "Reconnect Hermes on your Mac before sending more private gateway messages."
        case .gatewayInvalidSealedControlPayload:
            return "Could not prepare this private Hermes control message. Reconnect Hermes on your Mac, then try again."
        }
    }
}

// MARK: - Provider Account Device Links

extension FunctionsRepository {
    /// Adopt a provider account onto this device with the given capability.
    /// Mirrors the macOS owner-link write that happens automatically when
    /// `connectSelfHostedQuotaAccount` runs on the Mac.
    func adoptProviderAccountForDevice(
        accountID: String,
        deviceID: String,
        deviceDisplayName: String,
        capability: DeviceLinkCapability
    ) async throws {
        let callable = functions.httpsCallable("adoptProviderAccountForDevice")
        _ = try await callable.call([
            "accountID": accountID,
            "deviceID": deviceID,
            "deviceDisplayName": deviceDisplayName,
            "capability": capability.rawValue
        ])
    }

    func revokeProviderAccountDeviceLink(accountID: String, deviceID: String) async throws {
        let callable = functions.httpsCallable("revokeProviderAccountDeviceLink")
        _ = try await callable.call([
            "accountID": accountID,
            "deviceID": deviceID
        ])
    }

    func backfillProviderAccountDeviceLinks() async throws {
        let callable = functions.httpsCallable("backfillProviderAccountDeviceLinks")
        _ = try await callable.call([:])
    }
}
