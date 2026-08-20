import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

// MARK: - Hermes Gateway client records
//
// Split out of `HermesGatewayAPI.swift` (audit wave 4, item 14 structural
// decomposition). Pure move — no behavior change.

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
    let agentSupportsSignalEnvelope: Bool?
    let agentSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc?
    let phoneRatchetIdentityPublicKey: String?
    let phoneRatchetSigningPublicKey: String?
    let phoneRatchetSignedPreKeyPublicKey: String?
    let phoneRatchetSignedPreKeyId: String?
    let phoneRatchetSignedPreKeySignature: String?
    let phoneSupportsRatchetV1: Bool?
    let phoneSupportsSignalEnvelope: Bool?
    let phoneSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc?
    let supportsRatchetV1: Bool
    let supportsSignalEnvelope: Bool
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

    var canSignalToAgent: Bool {
        supportsSignalEnvelope
            && agentSupportsSignalEnvelope != false
            && agentSignalPrekeyBundle != nil
            && phoneSignalPrekeyBundle != nil
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

    static func == (lhs: HermesGatewayClientRecord, rhs: HermesGatewayClientRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
        case agentSupportsSignalEnvelope
        case agentSignalPrekeyBundle
        case phoneRatchetIdentityPublicKey
        case phoneRatchetSigningPublicKey
        case phoneRatchetSignedPreKeyPublicKey
        case phoneRatchetSignedPreKeyId
        case phoneRatchetSignedPreKeySignature
        case phoneSupportsRatchetV1
        case phoneSupportsSignalEnvelope
        case phoneSignalPrekeyBundle
        case supportsRatchetV1
        case supportsSignalEnvelope
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
            agentSupportsSignalEnvelope: try container.decodeIfPresent(Bool.self, forKey: .agentSupportsSignalEnvelope),
            agentSignalPrekeyBundle: try container.decodeIfPresent(FirestoreHermesGatewaySignalPrekeyBundleDoc.self, forKey: .agentSignalPrekeyBundle),
            phoneRatchetIdentityPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetIdentityPublicKey),
            phoneRatchetSigningPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSigningPublicKey),
            phoneRatchetSignedPreKeyPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeyPublicKey),
            phoneRatchetSignedPreKeyId: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeyId),
            phoneRatchetSignedPreKeySignature: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeySignature),
            phoneSupportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .phoneSupportsRatchetV1),
            phoneSupportsSignalEnvelope: try container.decodeIfPresent(Bool.self, forKey: .phoneSupportsSignalEnvelope),
            phoneSignalPrekeyBundle: try container.decodeIfPresent(FirestoreHermesGatewaySignalPrekeyBundleDoc.self, forKey: .phoneSignalPrekeyBundle),
            supportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .supportsRatchetV1) ?? false,
            supportsSignalEnvelope: try container.decodeIfPresent(Bool.self, forKey: .supportsSignalEnvelope) ?? false
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
        agentSupportsSignalEnvelope: Bool? = nil,
        agentSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc? = nil,
        phoneRatchetIdentityPublicKey: String? = nil,
        phoneRatchetSigningPublicKey: String? = nil,
        phoneRatchetSignedPreKeyPublicKey: String? = nil,
        phoneRatchetSignedPreKeyId: String? = nil,
        phoneRatchetSignedPreKeySignature: String? = nil,
        phoneSupportsRatchetV1: Bool? = nil,
        phoneSupportsSignalEnvelope: Bool? = nil,
        phoneSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc? = nil,
        supportsRatchetV1: Bool = false,
        supportsSignalEnvelope: Bool = false
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
        self.agentSupportsSignalEnvelope = agentSupportsSignalEnvelope
        self.agentSignalPrekeyBundle = agentSignalPrekeyBundle
        self.phoneRatchetIdentityPublicKey = phoneRatchetIdentityPublicKey
        self.phoneRatchetSigningPublicKey = phoneRatchetSigningPublicKey
        self.phoneRatchetSignedPreKeyPublicKey = phoneRatchetSignedPreKeyPublicKey
        self.phoneRatchetSignedPreKeyId = phoneRatchetSignedPreKeyId
        self.phoneRatchetSignedPreKeySignature = phoneRatchetSignedPreKeySignature
        self.phoneSupportsRatchetV1 = phoneSupportsRatchetV1
        self.phoneSupportsSignalEnvelope = phoneSupportsSignalEnvelope
        self.phoneSignalPrekeyBundle = phoneSignalPrekeyBundle
        self.supportsRatchetV1 = supportsRatchetV1
        self.supportsSignalEnvelope = supportsSignalEnvelope
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
            agentSupportsSignalEnvelope: data["agentSupportsSignalEnvelope"] as? Bool,
            agentSignalPrekeyBundle: Self.signalPrekeyBundle(data["agentSignalPrekeyBundle"]),
            phoneRatchetIdentityPublicKey: Self.string(data["phoneRatchetIdentityPublicKey"]),
            phoneRatchetSigningPublicKey: Self.string(data["phoneRatchetSigningPublicKey"]),
            phoneRatchetSignedPreKeyPublicKey: Self.string(data["phoneRatchetSignedPreKeyPublicKey"]),
            phoneRatchetSignedPreKeyId: Self.string(data["phoneRatchetSignedPreKeyId"]),
            phoneRatchetSignedPreKeySignature: Self.string(data["phoneRatchetSignedPreKeySignature"]),
            phoneSupportsRatchetV1: data["phoneSupportsRatchetV1"] as? Bool,
            phoneSupportsSignalEnvelope: data["phoneSupportsSignalEnvelope"] as? Bool,
            phoneSignalPrekeyBundle: Self.signalPrekeyBundle(data["phoneSignalPrekeyBundle"]),
            supportsRatchetV1: (data["supportsRatchetV1"] as? Bool) ?? false,
            supportsSignalEnvelope: (data["supportsSignalEnvelope"] as? Bool) ?? false
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
        ParsePrimitives.gatewayDate(from: raw)
    }

    private static func string(_ raw: Any?) -> String? {
        ParsePrimitives.string(raw)
    }

    private static func signalPrekeyBundle(_ raw: Any?) -> FirestoreHermesGatewaySignalPrekeyBundleDoc? {
        guard let map = raw as? NSDictionary,
              JSONSerialization.isValidJSONObject(map),
              let data = try? JSONSerialization.data(withJSONObject: map),
              let bundle = try? JSONDecoder().decode(FirestoreHermesGatewaySignalPrekeyBundleDoc.self, from: data)
        else { return nil }
        return bundle
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
        ParsePrimitives.string(raw)
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
