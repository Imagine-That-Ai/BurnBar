import Foundation

/// Destinations for mobile OS push and URL routing.
public enum MobileOsDestination: String, Sendable, Equatable {
    case pulse
    case burn
    case streams
    case settings
    case computerUse = "computer-use"
    case hermes
    case pi
    case assistants
    case insights
    case inbox
    case mercuryCall = "mercury-call"
    case mission
    case unknown
}

/// System notification delivery. Denied permission is never "delivered".
public enum MobileNotificationDelivery: String, Sendable, Equatable {
    case delivered
    case suppressed
}

/// Whether a tap or launch may change the visible route.
public enum MobileNavigationDecision: String, Sendable, Equatable {
    case navigate
    case ignoreStale
    case ignoreAccountMismatch
    case ignoreExpired
    case ignoreDuplicate
    case ignoreDenied
    case ignoreUnknown
}

public struct MobileOsRouteDecision: Sendable, Equatable {
    public var destination: MobileOsDestination
    public var deepLink: String?
    public var threadId: String?
    public var itemId: String?
    public var connectionId: String?
    public var missionId: String?
    public var runtime: String?
    public var slug: String?

    public init(
        destination: MobileOsDestination,
        deepLink: String? = nil,
        threadId: String? = nil,
        itemId: String? = nil,
        connectionId: String? = nil,
        missionId: String? = nil,
        runtime: String? = nil,
        slug: String? = nil
    ) {
        self.destination = destination
        self.deepLink = deepLink
        self.threadId = threadId
        self.itemId = itemId
        self.connectionId = connectionId
        self.missionId = missionId
        self.runtime = runtime
        self.slug = slug
    }
}

public struct MobilePushEnvelope: Sendable, Equatable {
    public var type: String
    public var eventId: String
    public var uid: String?
    public var expiresAtMs: Int64?
    public var threadId: String?
    public var itemId: String?
    public var connectionId: String?
    public var missionId: String?
    public var runtime: String?
    public var deepLink: String?

    public init(
        type: String,
        eventId: String,
        uid: String? = nil,
        expiresAtMs: Int64? = nil,
        threadId: String? = nil,
        itemId: String? = nil,
        connectionId: String? = nil,
        missionId: String? = nil,
        runtime: String? = nil,
        deepLink: String? = nil
    ) {
        self.type = type
        self.eventId = eventId
        self.uid = uid
        self.expiresAtMs = expiresAtMs
        self.threadId = threadId
        self.itemId = itemId
        self.connectionId = connectionId
        self.missionId = missionId
        self.runtime = runtime
        self.deepLink = deepLink
    }
}

public struct MobileWidgetPrivacyScan: Sendable, Equatable {
    public var hasRawUid: Bool
    public var hasSecret: Bool
    public var hasConversationText: Bool

    public var isPrivacySafe: Bool { !hasRawUid && !hasSecret && !hasConversationText }

    public init(hasRawUid: Bool, hasSecret: Bool, hasConversationText: Bool) {
        self.hasRawUid = hasRawUid
        self.hasSecret = hasSecret
        self.hasConversationText = hasConversationText
    }
}

/// Push, deep-link, permission, widget, and retry decisions for VAL-MOB-013.
public enum MobileOsIntegrationPolicy {
    public static let widgetRefreshCadenceSeconds: Int64 = 15 * 60
    public static let widgetAppGroup = "group.com.openburnbar.app"
    public static let maxBackgroundRetryAttempts = 3
    public static let allowlistedHosts: Set<String> = [
        "dashboard", "pulse", "burn", "quota", "streams", "search", "settings",
        "agent-watch", "agent-live", "computer-use", "chat", "hermes", "pi",
        "assistants", "insights", "inbox", "mercury", "mission"
    ]

    public static let pushTypes: [String: MobileOsDestination] = [
        "agent_reply": .assistants,
        "ai_inbox_item": .inbox,
        "quota": .burn,
        "quota_alert": .burn,
        "quota_pressure": .burn,
        "media_incoming_call": .mercuryCall,
        "mission": .mission,
        "mission_update": .mission
    ]

    public static func delivery(permissionGranted: Bool) -> MobileNotificationDelivery {
        permissionGranted ? .delivered : .suppressed
    }

    public static func mayDeliver(permissionGranted: Bool) -> Bool {
        delivery(permissionGranted: permissionGranted) == .delivered
    }

    public static func acceptedDeepLink(_ raw: String?) -> String? {
        guard let raw = firstNonEmpty(raw), let url = URL(string: raw) else { return nil }
        guard (url.scheme ?? "").lowercased() == "burnbar" else { return nil }
        guard let host = url.host?.lowercased(), allowlistedHosts.contains(host) else { return nil }
        return url.absoluteString
    }

    public static func envelope(from payload: [String: String]) -> MobilePushEnvelope {
        let expiresRaw = firstNonEmpty(payload["expires_at_millis"], payload["expiresAtMs"])
        let expires = expiresRaw.flatMap { Int64($0) }
        return MobilePushEnvelope(
            type: payload["type"] ?? "",
            eventId: firstNonEmpty(payload["event_id"], payload["eventId"]) ?? "",
            uid: firstNonEmpty(payload["uid"], payload["account_uid"], payload["accountUid"]),
            expiresAtMs: expires,
            threadId: firstNonEmpty(payload["thread_id"], payload["threadId"]),
            itemId: firstNonEmpty(payload["item_id"], payload["itemId"]),
            connectionId: firstNonEmpty(payload["connection_id"], payload["connectionId"]),
            missionId: firstNonEmpty(payload["mission_id"], payload["missionId"]),
            runtime: firstNonEmpty(payload["runtime"]),
            deepLink: firstNonEmpty(payload["deep_link"], payload["deepLink"])
        )
    }

    public static func route(payload: [String: String]) -> MobileOsRouteDecision {
        route(envelope: envelope(from: payload))
    }

    public static func route(envelope: MobilePushEnvelope) -> MobileOsRouteDecision {
        let destination = pushTypes[envelope.type] ?? .unknown
        switch destination {
        case .assistants:
            let runtime = firstNonEmpty(envelope.runtime) ?? "hermes"
            let thread = envelope.threadId ?? ""
            let link = acceptedDeepLink(envelope.deepLink)
                ?? "burnbar://assistants/\(runtime)?threadId=\(thread)"
            return MobileOsRouteDecision(
                destination: .assistants,
                deepLink: link,
                threadId: envelope.threadId,
                runtime: runtime
            )
        case .inbox:
            let item = envelope.itemId
            let link = acceptedDeepLink(envelope.deepLink)
                ?? (item.map { "burnbar://inbox/\($0)" } ?? "burnbar://inbox")
            return MobileOsRouteDecision(destination: .inbox, deepLink: link, itemId: item)
        case .burn:
            return MobileOsRouteDecision(
                destination: .burn,
                deepLink: acceptedDeepLink(envelope.deepLink) ?? "burnbar://quota"
            )
        case .mercuryCall:
            let connection = envelope.connectionId ?? ""
            let link = acceptedDeepLink(envelope.deepLink) ?? "burnbar://mercury/call/\(connection)"
            return MobileOsRouteDecision(
                destination: .mercuryCall,
                deepLink: link,
                connectionId: envelope.connectionId
            )
        case .mission:
            let mission = envelope.missionId ?? ""
            let link = acceptedDeepLink(envelope.deepLink) ?? "burnbar://mission/\(mission)"
            return MobileOsRouteDecision(
                destination: .mission,
                deepLink: link,
                missionId: envelope.missionId
            )
        default:
            return MobileOsRouteDecision(destination: .unknown)
        }
    }

    public static func route(url: URL) -> MobileOsRouteDecision {
        guard (url.scheme ?? "").lowercased() == "burnbar" else {
            return MobileOsRouteDecision(destination: .unknown)
        }
        let host = (url.host ?? "").lowercased()
        let pathParts = url.path.split(separator: "/").map(String.init)
        let first = pathParts.first
        let firstLower = first?.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let thread = query(components, names: ["threadId", "threadID", "thread_id"])
        let runtimeQuery = query(components, names: ["runtime"])

        switch host {
        case "dashboard", "pulse":
            return MobileOsRouteDecision(destination: .pulse, deepLink: url.absoluteString)
        case "burn", "quota":
            return MobileOsRouteDecision(destination: .burn, deepLink: url.absoluteString)
        case "streams", "search":
            return MobileOsRouteDecision(destination: .streams, deepLink: url.absoluteString)
        case "settings":
            return MobileOsRouteDecision(destination: .settings, deepLink: url.absoluteString)
        case "agent-watch", "agent-live", "computer-use":
            return MobileOsRouteDecision(destination: .computerUse, deepLink: url.absoluteString)
        case "chat", "hermes":
            return MobileOsRouteDecision(
                destination: .hermes,
                deepLink: url.absoluteString,
                threadId: thread,
                runtime: "hermes"
            )
        case "pi":
            return MobileOsRouteDecision(
                destination: .pi,
                deepLink: url.absoluteString,
                threadId: thread,
                runtime: "pi"
            )
        case "assistants":
            let runtime = runtimeQuery ?? firstLower ?? "hermes"
            return MobileOsRouteDecision(
                destination: .assistants,
                deepLink: url.absoluteString,
                threadId: thread,
                runtime: runtime
            )
        case "insights":
            return MobileOsRouteDecision(
                destination: .insights,
                deepLink: url.absoluteString,
                slug: first
            )
        case "inbox":
            return MobileOsRouteDecision(
                destination: .inbox,
                deepLink: url.absoluteString,
                itemId: first
            )
        case "mercury":
            if firstLower == "call" {
                return MobileOsRouteDecision(
                    destination: .mercuryCall,
                    deepLink: url.absoluteString,
                    connectionId: pathParts.dropFirst().first
                )
            }
            return MobileOsRouteDecision(destination: .unknown)
        case "mission":
            return MobileOsRouteDecision(
                destination: .mission,
                deepLink: url.absoluteString,
                missionId: first
            )
        default:
            return MobileOsRouteDecision(destination: .unknown)
        }
    }

    public static func navigation(
        envelope: MobilePushEnvelope,
        activeUid: String?,
        nowMs: Int64,
        lastConsumedEventId: String?,
        permissionGranted: Bool
    ) -> MobileNavigationDecision {
        if !permissionGranted { return .ignoreDenied }
        if route(envelope: envelope).destination == .unknown { return .ignoreUnknown }
        guard let uid = firstNonEmpty(envelope.uid) else { return .ignoreStale }
        let active = firstNonEmpty(activeUid)
        if active == nil || uid != active { return .ignoreAccountMismatch }
        guard let expires = envelope.expiresAtMs else { return .ignoreStale }
        if nowMs > expires { return .ignoreExpired }
        if let last = lastConsumedEventId, !envelope.eventId.isEmpty, last == envelope.eventId {
            return .ignoreDuplicate
        }
        return .navigate
    }

    public static func shouldConsumeTap(eventId: String, lastConsumedEventId: String?) -> Bool {
        let clean = eventId.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return false }
        return lastConsumedEventId != clean
    }

    public static func scanWidgetFields(_ fields: [String: String]) -> MobileWidgetPrivacyScan {
        var hasUid = false
        var hasSecret = false
        var hasConversation = false
        for (rawKey, rawValue) in fields {
            let key = rawKey.lowercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if uidKeys.contains(key) || looksLikeFirebaseUid(value) {
                hasUid = true
            }
            if secretKeys.contains(key) || looksLikeSecret(value) {
                hasSecret = true
            }
            if conversationKeys.contains(key) || looksLikeConversation(value) {
                hasConversation = true
            }
        }
        return MobileWidgetPrivacyScan(
            hasRawUid: hasUid,
            hasSecret: hasSecret,
            hasConversationText: hasConversation
        )
    }

    public static func widgetSnapshotIsPrivacySafe(
        heroTotalCost: Double,
        heroTotalTokens: Int,
        topProviders: [String],
        extraFields: [String: String] = [:]
    ) -> Bool {
        var fields = extraFields
        fields["heroTotalCost"] = String(heroTotalCost)
        fields["heroTotalTokens"] = String(heroTotalTokens)
        for (index, provider) in topProviders.enumerated() {
            fields["topProvider.\(index)"] = provider
        }
        return scanWidgetFields(fields).isPrivacySafe
    }

    public static func shouldRetryBackground(attempt: Int, cancelled: Bool) -> Bool {
        if cancelled { return false }
        return attempt >= 0 && attempt < maxBackgroundRetryAttempts
    }

    /// Foreground same-thread agent replies stay local — they must not post a
    /// second banner for the conversation already on screen.
    public static func shouldSuppressForegroundSameThread(
        foreground: Bool,
        activeRuntime: String?,
        activeThreadId: String?,
        payloadRuntime: String?,
        payloadThreadId: String?
    ) -> Bool {
        guard foreground else { return false }
        let activeThread = firstNonEmpty(activeThreadId) ?? ""
        let payloadThread = firstNonEmpty(payloadThreadId) ?? ""
        guard !activeThread.isEmpty, activeThread == payloadThread else { return false }
        let activeRuntimeValue = firstNonEmpty(activeRuntime)
        let payloadRuntimeValue = firstNonEmpty(payloadRuntime)
        if let activeRuntimeValue, let payloadRuntimeValue {
            return activeRuntimeValue == payloadRuntimeValue
        }
        return true
    }

    private static let uidKeys: Set<String> = [
        "uid", "userid", "user_id", "accountuid", "account_uid", "firebaseuid"
    ]

    private static let secretKeys: Set<String> = [
        "secret", "apikey", "api_key", "token", "fcm_token", "password", "privatekey"
    ]

    private static let conversationKeys: Set<String> = [
        "conversation", "conversationtext", "messagebody", "replytext", "preview"
    ]

    private static func looksLikeFirebaseUid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9]{28}$"#, options: .regularExpression) != nil
    }

    private static func looksLikeSecret(_ value: String) -> Bool {
        value.hasPrefix("sk-") || value.hasPrefix("AIza") || value.count >= 40 && value.allSatisfy {
            $0.isHexDigit
        }
    }

    private static func looksLikeConversation(_ value: String) -> Bool {
        value.contains(" ") && value.count > 40
    }

    private static func query(_ components: URLComponents?, names: [String]) -> String? {
        let items = components?.queryItems ?? []
        for name in names {
            if let value = items.first(where: { $0.name == name })?.value {
                return firstNonEmpty(value)
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
