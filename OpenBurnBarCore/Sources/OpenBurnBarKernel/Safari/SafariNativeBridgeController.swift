import Foundation

/// Closed, injectable daemon transport used by the Safari native bridge.
///
/// The live transport first attempts the ordinary newline-delimited daemon
/// request. If and only if the socket client proves that the fully encoded
/// request exceeds its 60 KiB safety ceiling, the params value is written once
/// to the trusted App Group and replaced by the authenticated payload marker.
/// No provider credentials or arbitrary RPC method strings cross this seam.
public struct BurnBarSafariDaemonRPCTransport: Sendable {
    public typealias Sender = @Sendable (
        _ method: BurnBarRPCMethod,
        _ id: String,
        _ params: BurnBarJSONValue
    ) throws -> BurnBarJSONValue

    private let sender: Sender

    public init(sender: @escaping Sender) {
        self.sender = sender
    }

    public func send(
        method: BurnBarRPCMethod,
        id: String = UUID().uuidString,
        params: BurnBarJSONValue
    ) throws -> BurnBarJSONValue {
        try sender(method, id, params)
    }

    public static func live(
        socketClient: BurnBarSafariDaemonSocketClient,
        payloadStore: BurnBarSafariAppGroupPayloadStore
    ) -> Self {
        externalizing(payloadStore: payloadStore) { method, id, params in
            try socketClient.send(method: method, id: id, params: params)
        }
    }

    /// Public construction seam for deterministic transport and payload-store
    /// tests. The primary sender must apply the daemon's exact request bound and
    /// throw ``BurnBarSafariDaemonSocketError/requestTooLarge`` before I/O.
    public static func externalizing(
        payloadStore: BurnBarSafariAppGroupPayloadStore,
        primarySender: @escaping Sender
    ) -> Self {
        Self { method, id, params in
            do {
                return try primarySender(method, id, params)
            } catch BurnBarSafariDaemonSocketError.requestTooLarge {
                let encodedParams = try JSONEncoder().encode(params)
                let reference = try payloadStore.store(encodedParams)
                do {
                    return try primarySender(method, id, reference.markerValue)
                } catch {
                    payloadStore.discard(reference)
                    throw error
                }
            }
        }
    }
}

public struct BurnBarSafariPopupActionResult: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let requestId: String?
    public let state: BurnBarJSONValue?
    public let output: BurnBarJSONValue?

    public init(
        accepted: Bool,
        requestId: String? = nil,
        state: BurnBarJSONValue? = nil,
        output: BurnBarJSONValue? = nil
    ) {
        self.accepted = accepted
        self.requestId = requestId
        self.state = state
        self.output = output
    }
}

// AUDIT: The controller is immutable after initialization; mutable transfer
// state is owned by the chunk store's lock-protected storage.
// sendable-allowlist: internal-lock-snapshot-store
/// Synchronous, deterministic core of `SafariWebExtensionHandler`.
///
/// The extension process is short-lived and Safari may invoke several handler
/// instances concurrently. This controller therefore keeps no in-memory
/// session authority: the daemon owns sessions, while chunk state is persisted
/// under the App Group by ``BurnBarSafariBridgeChunkStore``.
public final class BurnBarSafariNativeBridgeController: @unchecked Sendable {
    private enum PopupAction: String, CaseIterable {
        case bootstrap
        case catalog
        case uiSnapshot = "ui.snapshot"
        case ask
        case agentic
        case approval
        case abort
        case trustKillSwitch = "trust.killSwitch"
        case trustUpdate = "trust.update"
    }

    private struct BridgePageContext: Codable, Hashable, Sendable {
        let pageState: BurnBarSafariPageState
        let viewport: BurnBarJSONValue
        let markdown: String
        let snapshot: String
        let nodes: [BurnBarJSONValue]
        let truncated: Bool
        let sensitive: Bool
        let capturedAt: Date
    }

    private struct BridgeScreenshot: Codable, Hashable, Sendable {
        let dataUrl: String
        let mediaType: String
        let width: Int
        let height: Int
        let byteLength: Int
        let source: String
        let truncated: Bool
    }

    private struct AgenticPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let prompt: String
        let agentId: String
        let pageContext: BridgePageContext
        let screenshot: BridgeScreenshot
        let tabId: Int
        let url: String
        let learningOptedIn: Bool
    }


    private struct ApprovalPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let approvalId: String
        let decision: String
    }

    private struct AbortPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let activeRunId: String?
        let reason: String
    }

    private struct BootstrapPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let sessionId: String?
    }

    private struct UISnapshotPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let computerUseSessionId: String?
        let runId: String?
    }

    private struct TrustKillSwitchPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let enabled: Bool?
        let globalKillSwitch: Bool?
        let killSwitchEnabled: Bool?

        var resolvedValue: Bool? {
            let values = [enabled, globalKillSwitch, killSwitchEnabled].compactMap { $0 }
            guard let first = values.first,
                  values.dropFirst().allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }
    }

    private struct TrustCompatibilityPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let origin: String?
        let allowed: Bool?
        let sensitiveOverride: Bool?
        let onlyCurrentTab: Bool?
        let globalKillSwitch: Bool?
    }

    private struct CanonicalTrustPayload: Codable, Hashable, Sendable {
        let safariSessionId: String
        let origin: String
        let decision: BurnBarSafariTrustDecision
        let trustMode: String
        let actionBudget: Int?
        let expiresAt: Date?
        let killSwitchEnabled: Bool?
    }








    private let daemon: BurnBarSafariDaemonRPCTransport
    private let chunkStore: BurnBarSafariBridgeChunkStore

    public init(
        daemon: BurnBarSafariDaemonRPCTransport,
        chunkStore: BurnBarSafariBridgeChunkStore
    ) {
        self.daemon = daemon
        self.chunkStore = chunkStore
    }

    public static func live(
        profileIdentifier: String = Bundle.main.bundleIdentifier
            ?? "com.openburnbar.app.safari-extension",
        fileManager: FileManager = .default
    ) throws -> BurnBarSafariNativeBridgeController {
        let payloadStore = try BurnBarSafariAppGroupPayloadStore.live(fileManager: fileManager)
        let chunkStore = try BurnBarSafariBridgeChunkStore.live(
            profileIdentifier: profileIdentifier,
            fileManager: fileManager
        )
        return BurnBarSafariNativeBridgeController(
            daemon: .live(
                socketClient: try .live(
                    fileManager: fileManager,
                    sharedContainerRoot: payloadStore.trustedRoot
                ),
                payloadStore: payloadStore
            ),
            chunkStore: chunkStore
        )
    }

    /// Always returns a JSON-compatible property-list response. Expected
    /// protocol, validation, transport, and daemon errors are converted into a
    /// bounded structured error without leaking tokens, file paths, page
    /// payloads, or daemon internals.
    public func handle(propertyList: Any) -> Any {
        let fallbackID = Self.safeRequestIdentifier(from: propertyList)
        do {
            let request = try BurnBarSafariNativeBridgeCodec.decodeRequest(from: propertyList)
            let result = try execute(request)
            return try BurnBarSafariNativeBridgeCodec.encodeResponseObject(
                .success(id: request.id, result: result)
            )
        } catch {
            let response = BurnBarSafariNativeResponseEnvelope.failure(
                id: fallbackID,
                error: Self.sanitizedError(error)
            )
            return (try? BurnBarSafariNativeBridgeCodec.encodeResponseObject(response))
                ?? Self.lastResortFailureObject(id: fallbackID)
        }
    }

    private func execute(_ request: BurnBarSafariNativeRequestEnvelope) throws -> BurnBarJSONValue {
        switch request.method {
        case .hello:
            let attachRequest = try BurnBarSafariNativeBridgeCodec.decodeWebParams(
                BurnBarSafariSessionAttachRequest.self,
                from: request.params
            )
            let bootstrap: BurnBarSafariBootstrapResponse = try sendTyped(
                method: .safariBootstrap,
                request: BurnBarSafariBootstrapRequest(),
                response: BurnBarSafariBootstrapResponse.self
            )
            guard attachRequest.supportedProtocolVersions.contains(bootstrap.protocolVersion),
                  bootstrap.protocolVersion == BurnBarSafariProtocol.currentVersion else {
                throw BurnBarSafariBridgeFailure(
                    code: "protocol_mismatch",
                    message: "The Safari extension and OpenBurnBar daemon use incompatible protocols."
                )
            }
            let attached: BurnBarSafariSessionAttachResponse = try sendTyped(
                method: .safariSessionAttach,
                request: attachRequest,
                response: BurnBarSafariSessionAttachResponse.self
            )
            return try BurnBarSafariNativeBridgeCodec.encodeWebValue(attached)

        case .poll:
            let pollRequest = try BurnBarSafariNativeBridgeCodec.decodeWebParams(
                BurnBarSafariCommandPollRequest.self,
                from: request.params
            )
            let response: BurnBarSafariCommandPollResponse = try sendTyped(
                method: .safariCommandPoll,
                request: pollRequest,
                response: BurnBarSafariCommandPollResponse.self
            )
            return try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)

        case .complete:
            let completion = try BurnBarSafariNativeBridgeCodec.decodeWebParams(
                BurnBarSafariCommandCompletionRequest.self,
                from: request.params
            )
            let response: BurnBarSafariCommandCompletionResponse = try sendTyped(
                method: .safariCommandComplete,
                request: completion,
                response: BurnBarSafariCommandCompletionResponse.self
            )
            return try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)

        case .popupAction:
            return try executePopupAction(request)

        case .chunkBegin:
            let transferID = try requiredString(request.params, key: "transferId")
            let originalMethodRaw = try requiredString(request.params, key: "originalMethod")
            guard let originalMethod = BurnBarSafariBridgeMethod(rawValue: originalMethodRaw),
                  !originalMethod.isChunkMethod else {
                throw BurnBarSafariChunkStoreError.invalidMetadata
            }
            try chunkStore.begin(
                transferID: transferID,
                originalMethod: originalMethod,
                byteLength: try requiredInteger(request.params, key: "byteLength"),
                chunkCount: try requiredInteger(request.params, key: "chunkCount"),
                sha256: try requiredString(request.params, key: "sha256")
            )
            return .object(["accepted": .bool(true)])

        case .chunkAppend:
            try chunkStore.append(
                transferID: try requiredString(request.params, key: "transferId"),
                index: try requiredInteger(request.params, key: "index"),
                base64Data: try requiredString(request.params, key: "data")
            )
            return .object(["accepted": .bool(true)])

        case .chunkCommit:
            let committed = try chunkStore.commit(
                transferID: try requiredString(request.params, key: "transferId")
            )
            let original = try BurnBarSafariNativeBridgeCodec.decodeRequest(
                from: committed.payload,
                maximumBytes: BurnBarSafariBridgeWire.maximumChunkedPayloadBytes
            )
            guard original.method == committed.originalMethod,
                  !original.method.isChunkMethod else {
                throw BurnBarSafariBridgeFailure(
                    code: "chunk_method_mismatch",
                    message: "Safari chunk metadata does not match its committed request."
                )
            }
            return try execute(original)
        }
    }

    private func executePopupAction(
        _ request: BurnBarSafariNativeRequestEnvelope
    ) throws -> BurnBarJSONValue {
        let sessionID = try requiredString(request.params, key: "sessionId")
        let actionRaw = try requiredString(request.params, key: "action")
        guard let action = PopupAction(rawValue: actionRaw) else {
            throw BurnBarSafariBridgeFailure(
                code: "unsupported_popup_action",
                message: "This Safari popup action is not supported by the installed OpenBurnBar version."
            )
        }
        guard case .object(let payload)? = request.params["payload"] else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_bridge_schema",
                message: "Safari popup action payload must be an object."
            )
        }
        guard case .string(let payloadSessionID)? = payload["safariSessionId"],
              payloadSessionID == sessionID else {
            throw BurnBarSafariBridgeFailure(
                code: "safari_session_mismatch",
                message: "Safari popup action session binding is invalid."
            )
        }

        let output: BurnBarJSONValue
        switch action {
        case .bootstrap:
            let decoded: BootstrapPayload = try decodeExactWebPayload(
                payload,
                required: ["safariSessionId"],
                allowed: ["safariSessionId", "sessionId"]
            )
            if let explicit = decoded.sessionId, explicit != sessionID {
                throw sessionMismatch()
            }
            let response: BurnBarSafariBootstrapResponse = try sendTyped(
                method: .safariBootstrap,
                request: BurnBarSafariBootstrapRequest(sessionId: sessionID),
                response: BurnBarSafariBootstrapResponse.self
            )
            output = try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)

        case .catalog:
            try validateExactKeys(
                payload,
                required: ["safariSessionId"],
                allowed: ["safariSessionId"],
                label: "catalog payload"
            )
            let response: BurnBarCatalogResponse = try sendTyped(
                method: .catalog,
                request: BurnBarCatalogRequest(),
                response: BurnBarCatalogResponse.self
            )
            output = try BurnBarSafariNativeBridgeCodec.encodeWebValue(response.catalog)

        case .uiSnapshot:
            let decoded: UISnapshotPayload = try decodeExactWebPayload(
                payload,
                required: ["safariSessionId"],
                allowed: ["safariSessionId", "computerUseSessionId", "runId"]
            )
            let response: BurnBarSafariUISnapshotResponse = try sendTyped(
                method: .safariUISnapshot,
                request: BurnBarSafariUISnapshotRequest(
                    safariSessionId: decoded.safariSessionId,
                    computerUseSessionId: decoded.computerUseSessionId,
                    runId: decoded.runId
                ),
                response: BurnBarSafariUISnapshotResponse.self
            )
            output = try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)

        case .ask:
            // Ask mode goes directly from the background worker to the daemon's
            // loopback OpenAI/Anthropic gateway using the scoped bootstrap
            // credential. There is intentionally no arbitrary native RPC
            // passthrough and no provider key ever enters the extension.
            throw BurnBarSafariBridgeFailure(
                code: "native_ask_unsupported",
                message: "Ask mode must use OpenBurnBar's loopback model gateway."
            )

        case .agentic:
            try validatePageTurnPayload(payload)
            let decoded: AgenticPayload = try decodeExactWebPayload(
                payload,
                required: [
                    "safariSessionId", "prompt", "agentId", "pageContext",
                    "screenshot", "tabId", "url", "learningOptedIn"
                ],
                allowed: [
                    "safariSessionId", "prompt", "agentId", "pageContext",
                    "screenshot", "tabId", "url", "learningOptedIn"
                ]
            )
            try validatePageTurn(decoded)
            let runRequest = try makeRunCreateRequest(decoded)
            let response: BurnBarRunCreateResponse = try sendTyped(
                method: .runCreate,
                request: runRequest,
                response: BurnBarRunCreateResponse.self
            )
            output = .object([
                "activeRunId": .string(response.runID.rawValue),
                "runId": .string(response.runID.rawValue),
                "phase": .string(response.phase.rawValue),
                "running": .bool(true)
            ])

        case .approval:
            let decoded: ApprovalPayload = try decodeExactWebPayload(
                payload,
                required: ["safariSessionId", "approvalId", "decision"],
                allowed: ["safariSessionId", "approvalId", "decision"]
            )
            guard let decision = BurnBarSafariApprovalDecision(
                rawValue: decoded.decision
            ) else {
                throw BurnBarSafariBridgeFailure(
                    code: "invalid_approval_decision",
                    message: "Safari approval decision is invalid."
                )
            }
            let response: BurnBarSafariApprovalRespondResponse = try sendTyped(
                method: .safariApprovalRespond,
                request: BurnBarSafariApprovalRespondRequest(
                    safariSessionId: decoded.safariSessionId,
                    approvalId: decoded.approvalId,
                    decision: decision
                ),
                response: BurnBarSafariApprovalRespondResponse.self
            )
            output = try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)

        case .abort:
            let decoded: AbortPayload = try decodeExactWebPayload(
                payload,
                required: ["safariSessionId", "reason"],
                allowed: ["safariSessionId", "activeRunId", "reason"]
            )
            guard decoded.reason == "user_stop" else {
                throw BurnBarSafariBridgeFailure(
                    code: "invalid_abort_reason",
                    message: "Safari abort reason is invalid."
                )
            }
            let response: BurnBarSafariToolResponse = try sendTyped(
                method: .safariAbort,
                request: BurnBarSafariToolRequest(
                    safariSessionId: decoded.safariSessionId,
                    runId: decoded.activeRunId,
                    arguments: .object(["reason": .string(decoded.reason)])
                ),
                response: BurnBarSafariToolResponse.self
            )
            output = try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)

        case .trustKillSwitch:
            let decoded: TrustKillSwitchPayload = try decodeExactWebPayload(
                payload,
                required: ["safariSessionId"],
                allowed: [
                    "safariSessionId", "enabled", "globalKillSwitch",
                    "killSwitchEnabled"
                ]
            )
            guard let enabled = decoded.resolvedValue else {
                throw BurnBarSafariBridgeFailure(
                    code: "invalid_trust_update",
                    message: "Safari kill-switch update is ambiguous or missing."
                )
            }
            output = try updateTrust(
                BurnBarSafariTrustUpdateRequest(
                    safariSessionId: decoded.safariSessionId,
                    origin: "*",
                    decision: .remove,
                    trustMode: "manual",
                    killSwitchEnabled: enabled
                )
            )

        case .trustUpdate:
            output = try executeTrustUpdate(payload)
        }

        return try BurnBarSafariNativeBridgeCodec.encodeWebValue(
            BurnBarSafariPopupActionResult(
                accepted: true,
                requestId: request.id,
                output: output
            )
        )
    }

    private func executeTrustUpdate(
        _ payload: [String: BurnBarJSONValue]
    ) throws -> BurnBarJSONValue {
        let canonicalKeys: Set<String> = [
            "safariSessionId", "origin", "decision", "trustMode",
            "actionBudget", "expiresAt", "killSwitchEnabled"
        ]
        if payload["decision"] != nil || payload["trustMode"] != nil {
            let decoded: CanonicalTrustPayload = try decodeExactWebPayload(
                payload,
                required: ["safariSessionId", "origin", "decision", "trustMode"],
                allowed: canonicalKeys
            )
            return try updateTrust(
                BurnBarSafariTrustUpdateRequest(
                    safariSessionId: decoded.safariSessionId,
                    origin: decoded.origin,
                    decision: decoded.decision,
                    trustMode: decoded.trustMode,
                    actionBudget: decoded.actionBudget,
                    expiresAt: decoded.expiresAt,
                    killSwitchEnabled: decoded.killSwitchEnabled
                )
            )
        }

        let decoded: TrustCompatibilityPayload = try decodeExactWebPayload(
            payload,
            required: ["safariSessionId"],
            allowed: [
                "safariSessionId", "origin", "allowed", "sensitiveOverride",
                "onlyCurrentTab", "globalKillSwitch"
            ]
        )
        if let globalKillSwitch = decoded.globalKillSwitch {
            guard decoded.origin == nil,
                  decoded.allowed == nil,
                  decoded.sensitiveOverride == nil,
                  decoded.onlyCurrentTab == nil else {
                throw BurnBarSafariBridgeFailure(
                    code: "invalid_trust_update",
                    message: "Global and per-site trust changes must be separate requests."
                )
            }
            return try updateTrust(
                BurnBarSafariTrustUpdateRequest(
                    safariSessionId: decoded.safariSessionId,
                    origin: "*",
                    decision: .remove,
                    trustMode: "manual",
                    killSwitchEnabled: globalKillSwitch
                )
            )
        }
        guard let origin = decoded.origin,
              let allowed = decoded.allowed else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_trust_update",
                message: "Per-site trust updates require an origin and decision."
            )
        }
        // Sensitive-site overrides remain daemon-owned policy. The legacy web
        // boolean is accepted only as an explicit user signal and never widens
        // the native bridge's RPC authority.
        _ = decoded.sensitiveOverride
        return try updateTrust(
            BurnBarSafariTrustUpdateRequest(
                safariSessionId: decoded.safariSessionId,
                origin: origin,
                decision: allowed ? .allow : .deny,
                trustMode: decoded.onlyCurrentTab == false ? "step" : "manual"
            )
        )
    }

    private func updateTrust(
        _ update: BurnBarSafariTrustUpdateRequest
    ) throws -> BurnBarJSONValue {
        guard update.origin == "*" || Self.validSafariTrustOrigin(update.origin) else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_trust_origin",
                message: "Safari trust updates require an exact HTTPS origin or an exact HTTP loopback origin."
            )
        }
        guard ["manual", "step", "trusted"].contains(update.trustMode) else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_trust_mode",
                message: "Safari trust mode is invalid."
            )
        }
        if let budget = update.actionBudget, !(1...10_000).contains(budget) {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_action_budget",
                message: "Safari action budget is outside the supported range."
            )
        }
        let response: BurnBarSafariTrustUpdateResponse = try sendTyped(
            method: .safariTrustUpdate,
            request: update,
            response: BurnBarSafariTrustUpdateResponse.self
        )
        return try BurnBarSafariNativeBridgeCodec.encodeWebValue(response)
    }

    private func makeRunCreateRequest(_ payload: AgenticPayload) throws -> BurnBarRunCreateRequest {
        var metadata = BurnBarRunCreateMetadata()
        metadata[.surface] = .string("safari_extension")
        metadata[.safariSessionId] = .string(payload.safariSessionId)
        metadata[.safariTabId] = .number(Double(payload.tabId))
        metadata[.safariURL] = .string(payload.url)
        metadata[.safariPageContext] = try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
            payload.pageContext
        )
        metadata[.safariScreenshot] = try BurnBarSafariNativeBridgeCodec.daemonJSONValue(
            payload.screenshot
        )
        return BurnBarRunCreateRequest(
            clientID: BurnBarClientID(
                rawValue: "safari-extension:\(payload.safariSessionId)"
            ),
            sessionID: BurnBarSessionID(rawValue: payload.safariSessionId),
            prompt: payload.prompt,
            modelID: payload.agentId,
            metadata: metadata
        )
    }

    private func validatePageTurn(_ payload: AgenticPayload) throws {
        try validateTurnCommon(
            safariSessionID: payload.safariSessionId,
            prompt: payload.prompt,
            agentID: payload.agentId,
            pageContext: payload.pageContext,
            screenshot: payload.screenshot,
            tabID: payload.tabId
        )
        guard payload.url == payload.pageContext.pageState.url else {
            throw BurnBarSafariBridgeFailure(
                code: "page_state_mismatch",
                message: "Safari page URL changed while preparing the agentic turn."
            )
        }
    }


    private func validateTurnCommon(
        safariSessionID: String,
        prompt: String,
        agentID: String,
        pageContext: BridgePageContext,
        screenshot: BridgeScreenshot,
        tabID: Int
    ) throws {
        guard Self.validIdentifier(safariSessionID),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 256 * 1024,
              !agentID.isEmpty,
              agentID.utf8.count <= 512,
              tabID >= 0,
              pageContext.pageState.tabId == tabID,
              pageContext.pageState.isActive,
              pageContext.pageState.isTopFrame,
              Self.validWebURL(pageContext.pageState.url) else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_page_turn",
                message: "Safari page turn context is invalid or stale."
            )
        }
        guard pageContext.markdown.utf8.count <= 4 * 1024 * 1024,
              pageContext.snapshot.utf8.count <= 4 * 1024 * 1024,
              pageContext.nodes.count <= 8_192 else {
            throw BurnBarSafariBridgeFailure(
                code: "page_context_too_large",
                message: "Safari page context exceeds the supported limits."
            )
        }
        guard screenshot.mediaType == "image/jpeg",
              screenshot.source == "viewport" || screenshot.source == "full-page",
              screenshot.width > 0,
              screenshot.height > 0,
              screenshot.width <= 16_384,
              screenshot.height <= 16_384,
              screenshot.byteLength > 0,
              screenshot.byteLength <= 8 * 1024 * 1024,
              let comma = screenshot.dataUrl.firstIndex(of: ","),
              screenshot.dataUrl[..<comma] == "data:image/jpeg;base64",
              let bytes = Data(
                  base64Encoded: String(screenshot.dataUrl[screenshot.dataUrl.index(after: comma)...]),
                  options: []
              ),
              bytes.count == screenshot.byteLength else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_screenshot",
                message: "Safari screenshot metadata or encoding is invalid."
            )
        }
    }

    private func validatePageTurnPayload(
        _ payload: [String: BurnBarJSONValue]
    ) throws {
        guard case .object(let context)? = payload["pageContext"],
              case .object(let pageState)? = context["pageState"],
              case .object(let viewport)? = context["viewport"],
              case .array(let nodes)? = context["nodes"],
              case .object(let screenshot)? = payload["screenshot"] else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_bridge_schema",
                message: "Safari page turn contains malformed context."
            )
        }
        try validateExactKeys(
            context,
            required: [
                "pageState", "viewport", "markdown", "snapshot", "nodes",
                "truncated", "sensitive", "capturedAt"
            ],
            allowed: [
                "pageState", "viewport", "markdown", "snapshot", "nodes",
                "truncated", "sensitive", "capturedAt"
            ],
            label: "pageContext"
        )
        try validateExactKeys(
            pageState,
            required: [
                "tabId", "url", "title", "navigationEpoch", "isActive",
                "isTopFrame", "capturedAt"
            ],
            allowed: [
                "tabId", "windowId", "url", "title", "navigationEpoch",
                "isActive", "isTopFrame", "capturedAt"
            ],
            label: "pageContext.pageState"
        )
        try validateExactKeys(
            viewport,
            required: [
                "width", "height", "scrollX", "scrollY", "pageWidth",
                "pageHeight", "devicePixelRatio", "visualViewportOffsetLeft",
                "visualViewportOffsetTop", "visualViewportScale"
            ],
            allowed: [
                "width", "height", "scrollX", "scrollY", "pageWidth",
                "pageHeight", "devicePixelRatio", "visualViewportOffsetLeft",
                "visualViewportOffsetTop", "visualViewportScale"
            ],
            label: "pageContext.viewport"
        )
        try validateExactKeys(
            screenshot,
            required: [
                "dataUrl", "mediaType", "width", "height", "byteLength",
                "source", "truncated"
            ],
            allowed: [
                "dataUrl", "mediaType", "width", "height", "byteLength",
                "source", "truncated"
            ],
            label: "screenshot"
        )
        let nodeKeys: Set<String> = [
            "ref", "role", "name", "selector", "box", "description", "value",
            "checked", "disabled", "expanded", "focused", "selected", "sensitive"
        ]
        for (index, node) in nodes.enumerated() {
            guard case .object(let object) = node else {
                throw BurnBarSafariBridgeFailure(
                    code: "invalid_bridge_schema",
                    message: "Safari page node \(index) is invalid."
                )
            }
            try validateExactKeys(
                object,
                required: ["ref", "role", "name", "selector"],
                allowed: nodeKeys,
                label: "pageContext.nodes[\(index)]"
            )
        }
    }

    private static func screenshotJPEGData(
        _ screenshot: BridgeScreenshot
    ) throws -> Data {
        guard let comma = screenshot.dataUrl.firstIndex(of: ","),
              screenshot.dataUrl[..<comma] == "data:image/jpeg;base64",
              let data = Data(
                  base64Encoded: String(
                      screenshot.dataUrl[screenshot.dataUrl.index(after: comma)...]
                  ),
                  options: []
              ),
              data.count == screenshot.byteLength else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_screenshot",
                message: "Safari screenshot metadata or encoding is invalid."
            )
        }
        return data
    }

    private func sendTyped<Request: Encodable & Sendable, Response: Decodable>(
        method: BurnBarRPCMethod,
        request: Request,
        response: Response.Type
    ) throws -> Response {
        let params = try BurnBarSafariNativeBridgeCodec.daemonJSONValue(request)
        let raw = try daemon.send(method: method, params: params)
        return try BurnBarSafariNativeBridgeCodec.decodeDaemonValue(response, from: raw)
    }

    private func requireAttachedLearningSession(
        _ safariSessionID: String
    ) throws -> BurnBarSafariSessionStatusResponse {
        guard Self.validIdentifier(safariSessionID) else {
            throw sessionMismatch()
        }
        let response: BurnBarSafariSessionStatusResponse = try sendTyped(
            method: .safariSessionStatus,
            request: BurnBarSafariSessionStatusRequest(
                sessionId: safariSessionID
            ),
            response: BurnBarSafariSessionStatusResponse.self
        )
        guard response.sessionId == safariSessionID, response.attached else {
            throw sessionMismatch()
        }
        return response
    }

    private func decodeExactWebPayload<Value: Decodable>(
        _ payload: [String: BurnBarJSONValue],
        required: Set<String>,
        allowed: Set<String>
    ) throws -> Value {
        try validateExactKeys(
            payload,
            required: required,
            allowed: allowed,
            label: "popup payload"
        )
        return try BurnBarSafariNativeBridgeCodec.decodeWebValue(
            Value.self,
            from: .object(payload)
        )
    }

    private func validateExactKeys(
        _ object: [String: BurnBarJSONValue],
        required: Set<String>,
        allowed: Set<String>,
        label: String
    ) throws {
        guard required.isSubset(of: Set(object.keys)) else {
            let missing = required.subtracting(object.keys).sorted().joined(separator: ", ")
            throw BurnBarSafariBridgeFailure(
                code: "invalid_bridge_schema",
                message: "\(label) is missing required field(s): \(missing)."
            )
        }
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_bridge_schema",
                message: "\(label) contains unknown field \"\(unknown)\"."
            )
        }
    }

    private func requiredString(
        _ object: [String: BurnBarJSONValue],
        key: String
    ) throws -> String {
        guard case .string(let value)? = object[key],
              !value.isEmpty,
              value.utf8.count <= BurnBarSafariBridgeWire.maximumInlineMessageBytes else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_bridge_schema",
                message: "Safari bridge field \(key) must be a bounded string."
            )
        }
        return value
    }

    private func requiredInteger(
        _ object: [String: BurnBarJSONValue],
        key: String
    ) throws -> Int {
        guard case .number(let value)? = object[key],
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else {
            throw BurnBarSafariBridgeFailure(
                code: "invalid_bridge_schema",
                message: "Safari bridge field \(key) must be an integer."
            )
        }
        return Int(value)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= BurnBarSafariBridgeWire.maximumIdentifierLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validLearningIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "-"
                || $0 == "_"
                || $0 == ":"
        }
    }

    private static func validWebURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }

    private static func validSafariTrustOrigin(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        if scheme == "https" {
            return true
        }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private func sessionMismatch() -> BurnBarSafariBridgeFailure {
        BurnBarSafariBridgeFailure(
            code: "safari_session_mismatch",
            message: "Safari popup action session binding is invalid."
        )
    }

    private static func safeRequestIdentifier(from propertyList: Any) -> String {
        guard let object = propertyList as? [String: Any],
              let id = object["id"] as? String,
              validIdentifier(id) else {
            return "unknown"
        }
        return id
    }

    private static func sanitizedError(_ error: Error) -> BurnBarSafariBridgeErrorPayload {
        if let bridge = error as? BurnBarSafariBridgeFailure {
            return bridge.payload
        }
        if let socket = error as? BurnBarSafariDaemonSocketError {
            switch socket {
            case .timedOut:
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_timeout",
                    message: "OpenBurnBar took too long to answer the Safari extension.",
                    retryable: true
                )
            case .connectionFailed, .readFailed, .writeFailed, .emptyResponse:
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_unavailable",
                    message: "The OpenBurnBar daemon is unavailable.",
                    retryable: true
                )
            case .daemonError(let code, _):
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_rejected",
                    message: "OpenBurnBar rejected the Safari request.",
                    details: .object(["daemonCode": .number(Double(code))])
                )
            case .requestTooLarge:
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_request_too_large",
                    message: "Safari request exceeds the supported daemon envelope."
                )
            case .responseTooLarge:
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_response_too_large",
                    message: "OpenBurnBar returned more Safari data than can be handled safely."
                )
            case .socketPathTooLong:
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_socket_path_too_long",
                    message: "The OpenBurnBar daemon socket path exceeds the platform limit."
                )
            case .platformUnavailable, .malformedResponse,
                 .responseIdentifierMismatch, .protocolMismatch:
                return BurnBarSafariBridgeErrorPayload(
                    code: "daemon_protocol_error",
                    message: "OpenBurnBar returned an invalid Safari bridge response."
                )
            }
        }
        if error is BurnBarSafariDaemonTokenError {
            return BurnBarSafariBridgeErrorPayload(
                code: "daemon_auth_unavailable",
                message: "OpenBurnBar daemon authentication is unavailable.",
                retryable: true
            )
        }
        if error is BurnBarSafariChunkStoreError {
            return BurnBarSafariBridgeErrorPayload(
                code: "invalid_chunk_transfer",
                message: "Safari chunk transfer failed integrity or lifecycle validation."
            )
        }
        if error is BurnBarSafariAppGroupPayloadError {
            return BurnBarSafariBridgeErrorPayload(
                code: "shared_payload_unavailable",
                message: "Safari shared payload storage is unavailable or invalid."
            )
        }
        if error is DecodingError || error is EncodingError {
            return BurnBarSafariBridgeErrorPayload(
                code: "invalid_bridge_schema",
                message: "Safari bridge data does not match the supported schema."
            )
        }
        return BurnBarSafariBridgeErrorPayload(
            code: "native_bridge_failure",
            message: "The OpenBurnBar Safari bridge could not complete the request."
        )
    }

    private static func lastResortFailureObject(id: String) -> [String: Any] {
        [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": id,
            "error": [
                "code": "native_bridge_failure",
                "message": "The OpenBurnBar Safari bridge could not encode its response.",
                "retryable": false
            ]
        ]
    }
}
