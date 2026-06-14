import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

/// Internal (not `private`) since the per-domain API splits of
/// `FunctionsRepository` (tech-debt finding-67) call it from their own files.
struct FirebaseCallablePayload: @unchecked Sendable {
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

/// Single source of truth for the primitive coercions that the untyped
/// `[String: Any]` Firebase boundary needs all over this file.
///
/// Before this existed the same `string(_:)` switch was hand-copied into four
/// model parsers and the `gatewayDate(from:)` ISO-8601 decode was copied into
/// three more — each `gatewayDate` call also allocated two fresh
/// `ISO8601DateFormatter`s. The formatters are expensive to build, so they are
/// cached here once. The per-type `string`/`gatewayDate` helpers now forward to
/// these so there is one behaviour to reason about and one place to fix.
///
/// Internal (not `private`) since the per-domain API splits of
/// `FunctionsRepository` (tech-debt finding-67) parse with it from their
/// own files.
enum ParsePrimitives {
    /// Reused across every gateway-date parse. `ISO8601DateFormatter` is
    /// thread-safe for `date(from:)`, so a single shared instance is safe even
    /// though this file spans `@MainActor` and `Sendable` types.
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601 = ISO8601DateFormatter()

    /// Coerce a JSON-bridged value into a non-empty `String`, tolerating the
    /// `NSString`/`NSNumber` forms that Firebase callable payloads surface.
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

    /// Decode a gateway ISO-8601 timestamp, preferring fractional seconds and
    /// falling back to whole-second form.
    static func gatewayDate(from raw: String) -> Date? {
        if let date = fractionalISO8601.date(from: raw) { return date }
        return plainISO8601.date(from: raw)
    }
}

/// Internal (not `private`) since the per-domain API splits of
/// `FunctionsRepository` (tech-debt finding-67) call it from their own files.
final class FirebaseCallableExecutor: @unchecked Sendable {
    private let callable: HTTPSCallable

    init(_ callable: HTTPSCallable) {
        self.callable = callable
    }

    func call(_ payload: FirebaseCallablePayload) async throws -> HTTPSCallableResult {
        try await callable.call(payload.rawValue)
    }

    /// Typed callable invocation that keeps the request `Encodable` and decodes
    /// the response `Decodable` while preserving the failure context that a bare
    /// `try? JSONDecoder().decode(...)` throws away.
    ///
    /// On a malformed response this surfaces the underlying `DecodingError`
    /// (key path, type mismatch) through ``FunctionsError/responseDecodingFailed``
    /// instead of collapsing it into an opaque ``FunctionsError/decodingFailed``.
    func call<Req: Encodable, Res: Decodable>(_ request: Req) async throws -> Res {
        let requestObject = try Self.encodeToJSONObject(request)
        let result = try await call(FirebaseCallablePayload(requestObject))
        return try Self.decodeResponse(Res.self, from: result.data)
    }

    /// Build the callable for `name`, then make the typed request above. Mirrors
    /// the `functionsClient().httpsCallable(name)` + `.call(...)` boilerplate that
    /// is repeated for every endpoint in this file.
    static func call<Req: Encodable, Res: Decodable>(
        _ name: String,
        _ request: Req,
        using functions: Functions
    ) async throws -> Res {
        try await FirebaseCallableExecutor(functions.httpsCallable(name)).call(request)
    }

    /// Encode an `Encodable` request into the JSON-object dictionary that the
    /// callable payload bridge expects.
    static func encodeToJSONObject<Req: Encodable>(_ request: Req) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FunctionsError.responseDecodingFailed(
                "Request \(Req.self) did not encode to a JSON object."
            )
        }
        return object
    }

    /// Decode a callable's `result.data` into `Res`, surfacing `DecodingError`
    /// context (rather than swallowing it) when the cloud response is malformed.
    static func decodeResponse<Res: Decodable>(_ type: Res.Type, from raw: Any?) throws -> Res {
        guard let object = raw as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(object) as? [String: Any] else {
            throw FunctionsError.responseDecodingFailed(
                "Cloud response for \(Res.self) was not a JSON object."
            )
        }
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: sanitized)
        } catch {
            throw FunctionsError.responseDecodingFailed(
                "Cloud response for \(Res.self) was not serializable: \(error)"
            )
        }
        do {
            return try JSONDecoder().decode(Res.self, from: jsonData)
        } catch let decodingError as DecodingError {
            throw FunctionsError.responseDecodingFailed(
                Self.describe(decodingError, for: Res.self)
            )
        } catch {
            throw FunctionsError.responseDecodingFailed(
                "Failed to decode \(Res.self): \(error)"
            )
        }
    }

    /// Render a `DecodingError` into a stable, log-safe sentence that names the
    /// failing key path and reason without leaking the decoded payload.
    private static func describe<Res>(_ error: DecodingError, for type: Res.Type) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "Decoding \(Res.self) failed: missing key '\(key.stringValue)' at \(path(context))."
        case let .typeMismatch(expected, context):
            return "Decoding \(Res.self) failed: type mismatch (expected \(expected)) at \(path(context))."
        case let .valueNotFound(expected, context):
            return "Decoding \(Res.self) failed: missing value (expected \(expected)) at \(path(context))."
        case let .dataCorrupted(context):
            return "Decoding \(Res.self) failed: corrupted data at \(path(context)) — \(context.debugDescription)"
        @unknown default:
            return "Decoding \(Res.self) failed: \(error)"
        }
    }
}

// MARK: - Functions Client Provider

/// Lazily builds and caches the shared `Functions` client exactly the way
/// `FunctionsRepository.functionsClient()` always did, so every per-domain
/// API split out of the repository (tech-debt finding-67) keeps the same
/// single-lazy-client + fail-before-Firebase-configures behavior.
@MainActor
final class FunctionsClientProvider {
    private var cachedFunctions: Functions?

    func client() throws -> Functions {
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
}

// MARK: - Functions Repository

/// Facade over the Firebase callable surface. The provider-account,
/// StoreKit-entitlement, Pi-pairing, conversation-search, and Hermes Gateway
/// domains live in their own API objects (`ProviderAccountsAPI`,
/// `EntitlementsAPI`, `PiPairingAPI`, `ConversationSearchAPI`,
/// `HermesGatewayAPI` — tech-debt finding-67); this type forwards to them so
/// every existing call site keeps compiling unchanged. The privacy plaintext
/// scanner (scripts/privacy/scan-chat-cloud-plaintext.mjs) pins its gateway
/// and conversation-search rules to the per-domain files now, and keeps a
/// defense-in-depth no-projectName rule on the forwarders below: keep the
/// conversation-query forwarder and its static decode forwarder in that order
/// (the scanner anchors the rule between their signatures, matched by first
/// occurrence — never repeat those signature strings above the forwarders).
/// The Hermes host-pairing callables delegate to `HermesGatewayAPI` with the
/// rest of the Hermes domain.
@MainActor
final class FunctionsRepository: HermesGatewayRepository {
    static let shared = FunctionsRepository()

    private let clientProvider: FunctionsClientProvider

    /// Per-domain callable APIs. New call sites may depend on these (or their
    /// protocols) directly instead of the whole repository.
    let providerAccounts: ProviderAccountsAPI
    let entitlements: EntitlementsAPI
    let piPairing: PiPairingAPI
    let conversationSearch: ConversationSearchAPI
    let hermesGateway: HermesGatewayAPI

    init() {
        let clientProvider = FunctionsClientProvider()
        self.clientProvider = clientProvider
        self.providerAccounts = ProviderAccountsAPI(client: clientProvider)
        self.entitlements = EntitlementsAPI(client: clientProvider)
        self.piPairing = PiPairingAPI(client: clientProvider)
        self.conversationSearch = ConversationSearchAPI(client: clientProvider)
        self.hermesGateway = HermesGatewayAPI(client: clientProvider)
    }

    // MARK: Provider accounts (delegates to ProviderAccountsAPI)

    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc {
        try await providerAccounts.connectProviderCredential(provider: provider, credential: credential, kind: kind)
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
        try await providerAccounts.connectProviderAccount(
            providerID: providerID,
            credential: credential,
            kind: kind,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName,
            metadata: metadata
        )
    }

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        try await providerAccounts.connectHostedQuotaAccount(
            providerID: providerID,
            credential: credential,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName
        )
    }

    func connectSelfHostedQuotaAccount(
        providerID: ProviderID,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        try await providerAccounts.connectSelfHostedQuotaAccount(
            providerID: providerID,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName
        )
    }

    func deleteProviderCredential(provider: String) async throws {
        try await providerAccounts.deleteProviderCredential(provider: provider)
    }

    func refreshProviderQuota(provider: String) async throws {
        try await providerAccounts.refreshProviderQuota(provider: provider)
    }

    func refreshProviderAccountQuota(accountID: String) async throws -> ProviderQuotaSnapshot {
        try await providerAccounts.refreshProviderAccountQuota(accountID: accountID)
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
        try await providerAccounts.connectHostedQuotaAccount(
            providerID: providerID,
            credential: credential,
            kind: kind,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName
        )
    }

    func deleteHostedQuotaCredentials(accountID: String = "codex_default") async throws {
        try await providerAccounts.deleteHostedQuotaCredentials(accountID: accountID)
    }

    func updateProviderAccount(accountID: String, label: String? = nil, isDefault: Bool? = nil, disabled: Bool? = nil) async throws -> ProviderAccountDoc {
        try await providerAccounts.updateProviderAccount(accountID: accountID, label: label, isDefault: isDefault, disabled: disabled)
    }

    func deleteProviderAccount(accountID: String) async throws {
        try await providerAccounts.deleteProviderAccount(accountID: accountID)
    }

    func rebuildUsageRollups(force: Bool = false) async throws {
        try await providerAccounts.rebuildUsageRollups(force: force)
    }

    // MARK: Conversation search (delegates to ConversationSearchAPI)

    func searchStreams(query: String, limit: Int = 25) async throws -> [StreamSearchHit] {
        try await conversationSearch.searchStreams(query: query, limit: limit)
    }

    func searchEncryptedConversationIndex(
        tokenHashes: [String],
        semanticHashes: [String] = [],
        limit: Int = 25
    ) async throws -> [CloudConversationSearchHit] {
        try await conversationSearch.searchEncryptedConversationIndex(
            tokenHashes: tokenHashes,
            semanticHashes: semanticHashes,
            limit: limit
        )
    }

    /// Forwards to `ConversationSearchAPI.queryConversations`. PRIVACY:
    /// server-side filters stay operational facets only — the privacy
    /// plaintext scanner pins a no-`projectName` rule to both this forwarder
    /// and the `ConversationSearchAPI` implementation; project/path/title/body
    /// search must use `searchEncryptedConversationIndex` with client-keyed
    /// hashes.
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
        try await conversationSearch.queryConversations(
            providers: providers,
            models: models,
            deviceId: deviceId,
            sourceType: sourceType,
            dateFrom: dateFrom,
            dateTo: dateTo,
            sort: sort,
            direction: direction,
            limit: limit,
            cursorDocId: cursorDocId,
            includeAggregates: includeAggregates
        )
    }

    static func decodeConversationQueryResponse(_ raw: Any?) throws -> ConversationQueryResponse {
        try ConversationSearchAPI.decodeConversationQueryResponse(raw)
    }

    func encryptedSessionBlobDownloadURL(storagePath: String) async throws -> URL {
        try await conversationSearch.encryptedSessionBlobDownloadURL(storagePath: storagePath)
    }

    func uploadProviderQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot) async throws -> ProviderQuotaSnapshot {
        try await providerAccounts.uploadProviderQuotaSnapshot(snapshot)
    }

    // MARK: Hermes host pairing (delegates to HermesGatewayAPI)

    func createHermesPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> HermesPairingSessionRecord {
        try await hermesGateway.createHermesPairing(
            deviceId: deviceId,
            platform: platform,
            displayName: displayName
        )
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
        try await hermesGateway.completeHermesPairing(
            pairingId: pairingId,
            code: code,
            connectionId: connectionId,
            displayName: displayName,
            endpointURL: endpointURL,
            advertisedModel: advertisedModel,
            capabilities: capabilities
        )
    }

    func listHermesConnections() async throws -> [HermesConnectionRecord] {
        try await hermesGateway.listHermesConnections()
    }

    func revokeHermesConnection(connectionId: String) async throws {
        try await hermesGateway.revokeHermesConnection(connectionId: connectionId)
    }

    func revokeRemoteMcpClient(clientID: String) async throws {
        try await hermesGateway.revokeRemoteMcpClient(clientID: clientID)
    }

    // MARK: Hermes Gateway platform adapter (delegates to HermesGatewayAPI)

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
        try await hermesGateway.approveHermesGatewayDeviceGrant(
            userCode: userCode,
            displayName: displayName,
            destinationId: destinationId,
            scopes: scopes,
            phoneRelayPublicKey: phoneRelayPublicKey,
            phoneRelayKeyVersion: phoneRelayKeyVersion,
            phoneRelayEncryption: phoneRelayEncryption,
            phoneRatchetPrekeyBundle: phoneRatchetPrekeyBundle
        )
    }

    func listHermesGatewayClients(includeRevoked: Bool = false) async throws -> [HermesGatewayClientRecord] {
        try await hermesGateway.listHermesGatewayClients(includeRevoked: includeRevoked)
    }

    func revokeHermesGatewayClient(clientId: String) async throws {
        try await hermesGateway.revokeHermesGatewayClient(clientId: clientId)
    }

    func hermesGatewayAttachmentDownloadURL(
        attachmentId: String,
        clientId: String,
        destinationId: String?
    ) async throws -> URL {
        try await hermesGateway.hermesGatewayAttachmentDownloadURL(
            attachmentId: attachmentId,
            clientId: clientId,
            destinationId: destinationId
        )
    }

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await hermesGateway.enqueueHermesGatewayEvent(
            text: text,
            destinationId: destinationId,
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId,
            senderDisplayName: senderDisplayName
        )
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await hermesGateway.enqueueHermesGatewayModelSwitch(
            modelId: modelId,
            destinationId: destinationId,
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId,
            senderDisplayName: senderDisplayName
        )
    }

    /// Test-visible entry point preserved in place; the implementation moved
    /// to `GatewayEventSealer.sealGatewayEventPayload` (mechanical extraction,
    /// tech-debt finding-67). Signature, defaults, and behavior are unchanged.
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
        try GatewayEventSealer.sealGatewayEventPayload(
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

    func setHermesGatewayOversightMode(clientId: String, mode: String, targetClient: HermesGatewayClientRecord?) async throws {
        try await hermesGateway.setHermesGatewayOversightMode(
            clientId: clientId,
            mode: mode,
            targetClient: targetClient
        )
    }

    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        try await hermesGateway.respondHermesGatewayApproval(
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
        try await hermesGateway.enqueueHermesGatewayApprovalDecision(
            approvalId: approvalId,
            approve: approve,
            targetClient: targetClient,
            targetClientId: targetClientId
        )
    }

    // MARK: Pi Agent host pairing (delegates to PiPairingAPI)

    func createPiAgentPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> PiPairingSessionRecord {
        try await piPairing.createPiAgentPairing(
            deviceId: deviceId,
            platform: platform,
            displayName: displayName
        )
    }

    func completePiAgentPairing(_ request: PiAgentPairingCompletionRequest) async throws -> PiConnectionRecord {
        try await piPairing.completePiAgentPairing(request)
    }

    func listPiAgentConnections(includeRevoked: Bool = false) async throws -> [PiConnectionRecord] {
        try await piPairing.listPiAgentConnections(includeRevoked: includeRevoked)
    }

    func revokePiAgentConnection(connectionId: String, deviceId: String? = nil) async throws {
        try await piPairing.revokePiAgentConnection(connectionId: connectionId, deviceId: deviceId)
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
        try await piPairing.updatePiAgentConnectionStatus(
            connectionId: connectionId,
            status: status,
            advertisedModel: advertisedModel,
            selectedInstanceID: selectedInstanceID,
            capabilities: capabilities,
            instances: instances,
            models: models,
            deviceId: deviceId
        )
    }

    #if DEBUG
    /// Test-visible entry point preserved in place; the implementation moved
    /// to `HermesGatewayAPI` with the rest of the gateway domain (tech-debt
    /// finding-67). Behavior is unchanged.
    nonisolated static func decodeHermesGatewayApprovalClientForTesting(_ raw: Any) throws -> HermesGatewayClientRecord {
        try HermesGatewayAPI.decodeHermesGatewayApprovalClientForTesting(raw)
    }
    #endif

    // MARK: Apple-verified hosted quota entitlement (delegates to EntitlementsAPI)

    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String? = nil
    ) async throws -> String {
        try await entitlements.beginEntitlementBinding(
            productID: productID,
            clientPlatform: clientPlatform
        )
    }

    @discardableResult
    func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        signedRenewalInfoJWS: String? = nil,
        productID: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        try await entitlements.verifyHostedQuotaEntitlement(
            signedTransactionJWS: signedTransactionJWS,
            signedRenewalInfoJWS: signedRenewalInfoJWS,
            productID: productID
        )
    }

    @discardableResult
    func restoreHostedQuotaEntitlement(
        productID: String? = nil,
        signedTransactionJWS: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        try await entitlements.restoreHostedQuotaEntitlement(
            productID: productID,
            signedTransactionJWS: signedTransactionJWS
        )
    }

    @discardableResult
    func verifyCloudProTopUp(
        signedTransactionJWS: String,
        productID: String
    ) async throws -> CloudProTopUpCreditResponse {
        try await entitlements.verifyCloudProTopUp(
            signedTransactionJWS: signedTransactionJWS,
            productID: productID
        )
    }
}

// MARK: - Functions Error

enum FunctionsError: Error, LocalizedError, Equatable {
    case decodingFailed
    /// A typed callable response could not be decoded. The associated string
    /// carries the underlying `DecodingError` context (failing key path / type)
    /// so failures are diagnosable instead of being collapsed by `try?`.
    case responseDecodingFailed(String)
    case firebaseUnavailable
    case gatewayTargetMissingRelayKey
    case gatewayRelayKeyChanged
    case gatewayAttachmentUnreadable
    case gatewayApprovalNotAuthenticated
    case gatewayApprovalAppCheckBlocked
    case gatewayReplayCounterExhausted
    case gatewayInvalidSealedControlPayload
    /// T-CRY-01 — the envelope version that would be sealed (or that arrived on a
    /// reply) is below the v3 high-water this device already observed for the
    /// peer. A downgrade is refused fail-closed; the operator must re-pair.
    case gatewayEnvelopeVersionDowngrade

    var errorDescription: String? {
        switch self {
        case .decodingFailed: return "Failed to decode cloud function response."
        case .responseDecodingFailed: return "Failed to decode cloud function response."
        case .firebaseUnavailable:
            return "BurnBar Cloud is still starting. Try again after sign-in finishes."
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
        case .gatewayEnvelopeVersionDowngrade:
            // Same calm, action-first copy as a key change: a downgrade looks
            // different from when the connection was set up, so the message is
            // kept on-device until the operator re-pairs.
            return "This Hermes connection looks different from when you set it up, so your message was kept on this device for your safety. Reconnect Hermes on your Mac to keep sending privately."
        }
    }
}

// MARK: - Provider Account Device Links (delegates to ProviderAccountsAPI)

extension FunctionsRepository {
    func adoptProviderAccountForDevice(
        accountID: String,
        deviceID: String,
        deviceDisplayName: String,
        capability: DeviceLinkCapability
    ) async throws {
        try await providerAccounts.adoptProviderAccountForDevice(
            accountID: accountID,
            deviceID: deviceID,
            deviceDisplayName: deviceDisplayName,
            capability: capability
        )
    }

    func revokeProviderAccountDeviceLink(accountID: String, deviceID: String) async throws {
        try await providerAccounts.revokeProviderAccountDeviceLink(accountID: accountID, deviceID: deviceID)
    }

    func backfillProviderAccountDeviceLinks() async throws {
        try await providerAccounts.backfillProviderAccountDeviceLinks()
    }
}
