import Foundation
import FirebaseCore
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
    let projectName: String?
    let sealedTitle: CloudVaultSealedText
    let sealedSnippet: CloudVaultSealedText
    let sealedBodyPreview: CloudVaultSealedText?
    let storagePath: String
    let bodyHash: String
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

/// One encrypted session-log manifest as returned by `queryConversations`. Facets are plaintext
/// metadata (provider/project/model/tokens/cost/timing); the conversation title and preview stay
/// sealed and are opened on-device with the vault key. Numeric facets are optional so manifests
/// written before the facet backfill still decode.
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
    let revokedAt: String?
    let createdAt: String
    let updatedAt: String
    let schemaVersion: Int

    var isActive: Bool { status == "active" }

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
            runtimeUpdatedAt: try container.decodeIfPresent(String.self, forKey: .runtimeUpdatedAt)
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
        runtimeUpdatedAt: String? = nil
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
        self.revokedAt = revokedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
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
            runtimeUpdatedAt: Self.string(data["runtimeUpdatedAt"])
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

struct HermesGatewayMessageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let kind: String
    let destinationId: String
    let threadId: String?
    let replyToEventId: String?
    let text: String?
    let attachmentIds: [String]
    let createdAt: String
    let schemaVersion: Int

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
            guard message.threadId == threadID else { return false }
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
            guard message.threadId == threadID else { return false }
            guard matchesTarget(message, targetClientId: nonEmpty(targetClientId)) else { return false }
            return message.text?.isEmpty == false || !message.attachmentIds.isEmpty
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
        self.rawValue = NSDictionary(dictionary: payload)
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
        scopes: [String]
    ) async throws -> HermesGatewayClientRecord

    func listHermesGatewayClients(includeRevoked: Bool) async throws -> [HermesGatewayClientRecord]
    func revokeHermesGatewayClient(clientId: String) async throws

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String,
        threadId: String,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String,
        threadId: String,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent
}

extension HermesGatewayRepository {
    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String? = nil
    ) async throws -> HermesGatewayClientRecord {
        try await approveHermesGatewayDeviceGrant(
            userCode: userCode,
            displayName: displayName,
            destinationId: "burnbar:home",
            scopes: [
                "hermes.gateway.read",
                "hermes.gateway.write",
                "hermes.gateway.manage"
            ]
        )
    }

    func listHermesGatewayClients() async throws -> [HermesGatewayClientRecord] {
        try await listHermesGatewayClients(includeRevoked: false)
    }

    func enqueueHermesGatewayEvent(
        text: String,
        threadId: String = "burnbar-ios-e2e",
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await enqueueHermesGatewayEvent(
            text: text,
            destinationId: "burnbar:home",
            threadId: threadId,
            targetClientId: targetClientId,
            senderDisplayName: senderDisplayName
        )
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        threadId: String = "burnbar-ios-e2e",
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await enqueueHermesGatewayModelSwitch(
            modelId: modelId,
            destinationId: "burnbar:home",
            threadId: threadId,
            targetClientId: targetClientId,
            senderDisplayName: senderDisplayName
        )
    }
}

// MARK: - Functions Repository

@MainActor
final class FunctionsRepository: HermesGatewayRepository {
    static let shared = FunctionsRepository()

    private var cachedFunctions: Functions?

    private func functionsClient() throws -> Functions {
        if let cachedFunctions {
            return cachedFunctions
        }
        guard FirebaseApp.app() != nil else {
            throw FunctionsError.firebaseUnavailable
        }
        let functions = Functions.functions()
        cachedFunctions = functions
        return functions
    }

    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc {
        let callable = try functionsClient().httpsCallable("connectProviderCredential")
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
        let callable = try functionsClient().httpsCallable("refreshProviderAccountQuota")
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

    func rebuildUsageRollups() async throws {
        let callable = try functionsClient().httpsCallable("rebuildUsageRollups")
        _ = try await callable.call([:])
    }

    func searchStreams(query: String, limit: Int = 25) async throws -> [StreamSearchHit] {
        let callable = try functionsClient().httpsCallable("searchStreams")
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
        let callable = try functionsClient().httpsCallable("searchEncryptedConversationIndex")
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
    /// All filtering and sorting happen on plaintext facets server-side; the returned rows carry
    /// only sealed envelopes for title/preview, which the caller opens with the on-device vault
    /// key. Pass `cursorDocId` from a prior `nextCursor` to page; request aggregates only on the
    /// first page (`includeAggregates`) since they cover the whole filtered set.
    func queryConversations(
        providers: [String] = [],
        models: [String] = [],
        projectName: String? = nil,
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
        let callable = try functionsClient().httpsCallable("queryConversations")
        var payload: [String: Any] = [
            "sort": sort,
            "direction": direction,
            "limit": max(1, min(limit, 100)),
            "includeAggregates": includeAggregates
        ]
        if !providers.isEmpty { payload["providers"] = Array(providers.prefix(20)) }
        if !models.isEmpty { payload["models"] = Array(models.prefix(20)) }
        if let projectName, !projectName.isEmpty { payload["projectName"] = projectName }
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
        let callable = try functionsClient().httpsCallable("getEncryptedSessionBlobDownloadUrl")
        let result = try await callable.call(["storagePath": storagePath])
        guard let dict = result.data as? [String: Any],
              let raw = dict["downloadURL"] as? String,
              let url = URL(string: raw) else {
            throw FunctionsError.decodingFailed
        }
        return url
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

    // MARK: Hermes host pairing

    func createHermesPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> HermesPairingSessionRecord {
        let callable = try functionsClient().httpsCallable("createHermesPairing")
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
        let callable = try functionsClient().httpsCallable("completeHermesPairing")
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
        let callable = try functionsClient().httpsCallable("listHermesConnections")
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
        let callable = try functionsClient().httpsCallable("revokeHermesConnection")
        _ = try await callable.call(["connectionId": connectionId])
    }

    func revokeRemoteMcpClient(clientID: String) async throws {
        let callable = try functionsClient().httpsCallable("revokeRemoteMcpClient")
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
        ]
    ) async throws -> HermesGatewayClientRecord {
        let callable = try functionsClient().httpsCallable("approveHermesGatewayDeviceGrant")
        var payload: [String: Any] = [
            "userCode": userCode,
            "destinationId": destinationId,
            "scopes": scopes
        ]
        if let displayName, !displayName.isEmpty {
            payload["displayName"] = displayName
        }

        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try Self.decodeHermesGatewayValue(HermesGatewayApprovalResponse.self, from: result.data).client
    }

    func listHermesGatewayClients(includeRevoked: Bool = false) async throws -> [HermesGatewayClientRecord] {
        let callable = try functionsClient().httpsCallable("listHermesGatewayClients")
        let result = try await callable.call(["includeRevoked": includeRevoked])
        return try Self.decodeHermesGatewayValue(HermesGatewayClientsResponse.self, from: result.data).clients
    }

    func revokeHermesGatewayClient(clientId: String) async throws {
        let callable = try functionsClient().httpsCallable("revokeHermesGatewayClient")
        _ = try await callable.call(["clientId": clientId])
    }

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        let callable = try functionsClient().httpsCallable("enqueueHermesGatewayEvent")
        var payload: [String: Any] = [
            "destinationId": destinationId,
            "threadId": threadId,
            "senderId": "burnbar-ios",
            "senderDisplayName": senderDisplayName,
            "text": text
        ]
        if let targetClientId = targetClientId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetClientId.isEmpty {
            payload["targetClientId"] = targetClientId
        }
        let result = try await callable.call(payload)
        return try Self.decodeHermesGatewayValue(HermesGatewayQueuedEvent.self, from: result.data)
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        let callable = try functionsClient().httpsCallable("enqueueHermesGatewayEvent")
        var payload: [String: Any] = [
            "destinationId": destinationId,
            "threadId": threadId,
            "senderId": "burnbar-ios",
            "senderDisplayName": senderDisplayName,
            "eventKind": "model_switch",
            "modelId": modelId,
            "text": "/model \(modelId)"
        ]
        if let targetClientId = targetClientId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetClientId.isEmpty {
            payload["targetClientId"] = targetClientId
        }
        let result = try await callable.call(payload)
        return try Self.decodeHermesGatewayValue(HermesGatewayQueuedEvent.self, from: result.data)
    }

    // MARK: Pi Agent host pairing

    func createPiAgentPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> PiPairingSessionRecord {
        let callable = try functionsClient().httpsCallable("createPiAgentPairing")
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
        let callable = try functionsClient().httpsCallable("completePiAgentPairing")
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
        let callable = try functionsClient().httpsCallable("listPiAgentConnections")
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
        let callable = try functionsClient().httpsCallable("revokePiAgentConnection")
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
        let callable = try functionsClient().httpsCallable("updatePiAgentConnectionStatus")
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
    case firebaseUnavailable

    var errorDescription: String? {
        switch self {
        case .decodingFailed: return "Failed to decode cloud function response."
        case .firebaseUnavailable:
            return "Firebase is not configured. Add GoogleService-Info.plist to the app bundle."
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
