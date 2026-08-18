import Foundation
import OpenBurnBarKernel

/// The AI Inbox half of the push-notification plane.
///
/// ## What a P1 push contains
///
/// The mirrored inbox document at `users/{uid}/ai_inbox_items/{itemId}` is
/// sealed with the Cloud Vault, so the Cloud Function that fires the push
/// (`functions/src/aiInboxNotifications.ts`) cannot read the item's title or
/// summary and therefore cannot put them in the payload. What arrives is an
/// opaque `item_id` plus two bounded enums — `kind` and `priority`.
///
/// This type deliberately exposes no `preview`/`summary` field: the alert body
/// is a fixed local string, and the real content is decrypted from Firestore
/// once the tap lands. A future server-supplied string rendered as content would
/// quietly convert the alert into a plaintext channel.
struct AIInboxNotificationPayload: Equatable, Sendable {
    /// The mirror document id. Opaque to the notification layer.
    let itemID: String
    /// A `BurnBarInboxItemKind` raw value, already narrowed to a known case.
    let kind: BurnBarInboxItemKind
    let priority: BurnBarInboxPriority
    /// The durable `agent_notification_events` id, for delivery correlation.
    let eventID: String
    let uid: String?
    let expiresAtMs: Int64?

    /// Kind label shown as the notification title. Local, never server text.
    var title: String { Self.title(forKind: kind) }

    /// Body copy. Fixed: there is nothing readable to summarize.
    var body: String { "Open OpenBurnBar to see what needs you." }

    /// Main-actor because `AIInboxDeepLink` owns a type-level stash. The payload
    /// itself stays non-isolated so it can be decoded inside the `nonisolated`
    /// `UNUserNotificationCenterDelegate` hops.
    @MainActor
    var deepLink: URL? { AIInboxDeepLink.url(itemID: itemID) }

    init?(userInfo: [AnyHashable: Any]) {
        guard Self.string(userInfo["type"]) == AIInboxDeepLink.pushType else { return nil }
        guard let raw = Self.string(userInfo["item_id"]),
              let itemID = AIInboxDeepLink.sanitizedItemID(raw) else {
            return nil
        }
        self.itemID = itemID
        // An unrecognized kind means a newer Mac published a case this build
        // does not know. Degrading to `.system` keeps the alert deliverable
        // instead of dropping a real P1 on a schema bump.
        if let rawKind = Self.string(userInfo["kind"]), let known = BurnBarInboxItemKind(rawValue: rawKind) {
            kind = known
        } else {
            kind = .system
        }
        priority = BurnBarInboxPriority(clamping: Int(Self.string(userInfo["priority"]) ?? "") ?? 1)
        eventID = Self.string(userInfo["event_id"]) ?? itemID
        uid = Self.string(userInfo["uid"]) ?? Self.string(userInfo["account_uid"])
        expiresAtMs = Self.string(userInfo["expires_at_millis"]).flatMap { Int64($0) }
    }

    static func title(forKind kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "Wasted CI"
        case .promisedNotLanded: return "Promised, not landed"
        case .uncommittedWork: return "Uncommitted work"
        case .costAnomaly: return "Cost anomaly"
        case .stuckPR: return "Stuck pull request"
        case .indexHealth: return "Index health"
        case .brief: return "Brief"
        case .budget: return "Budget"
        case .system: return "OpenBurnBar"
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

/// `burnbar://inbox` routing, shared by the push tap and the URL handler.
///
/// Follows `HermesGatewayPairingDeepLink`: the tap and the app launch race each
/// other, so the request is stashed and posted, and whichever surface is alive
/// claims it. `consumePendingItemID` clears as it reads so a re-render cannot
/// re-navigate away from wherever the user has since gone.
///
/// `@MainActor` for that type-level stash, matching the precedent. Every caller
/// (URL handler, banner tap, notification-response hop) is already isolated.
@MainActor
enum AIInboxDeepLink {
    // Constants and pure parsing stay `nonisolated`: `AIInboxNotificationPayload
    // .init(userInfo:)` decodes inside a `nonisolated`
    // `UNUserNotificationCenterDelegate` hop, so anything it touches must be
    // reachable without hopping to the main actor first.
    nonisolated static let notificationName = Notification.Name("ShowAIInboxItem")
    nonisolated static let itemIDUserInfoKey = "itemID"
    nonisolated static let host = "inbox"
    nonisolated static let pushType = "ai_inbox_item"

    /// Bounds an id before it becomes a URL path or a lookup key.
    nonisolated private static let maxItemIDLength = 160

    private static var pendingItemID: String?

    static func open(itemID: String?) {
        let sanitized = itemID.flatMap(sanitizedItemID)
        pendingItemID = sanitized
        var userInfo: [AnyHashable: Any] = [:]
        if let sanitized { userInfo[itemIDUserInfoKey] = sanitized }
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }

    nonisolated static func itemID(from notification: Notification) -> String? {
        (notification.userInfo?[itemIDUserInfoKey] as? String).flatMap(sanitizedItemID)
    }

    static func consumePendingItemID() -> String? {
        let itemID = pendingItemID
        pendingItemID = nil
        return itemID
    }

    /// `burnbar://inbox/<itemId>`, or the bare list link when there is no item.
    nonisolated static func url(itemID: String?) -> URL? {
        guard let sanitized = itemID.flatMap(sanitizedItemID) else {
            return URL(string: "burnbar://\(host)")
        }
        let encoded = sanitized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sanitized
        return URL(string: "burnbar://\(host)/\(encoded)")
    }

    /// Extracts the item id from a `burnbar://inbox[/<itemId>]` URL.
    nonisolated static func itemID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "burnbar", url.host?.lowercased() == host else { return nil }
        return url.pathComponents.dropFirst().first.flatMap(sanitizedItemID)
    }

    /// Rejects ids that are empty, oversized, or carry control/bidi characters —
    /// the last of which would let a hostile payload spoof rendered text.
    nonisolated static func sanitizedItemID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxItemIDLength else { return nil }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !(0x202A...0x202E).contains($0.value) }) else { return nil }
        return trimmed
    }

    /// Test seam: the type-level stash must not leak between test cases.
    static func resetPendingItemID() {
        pendingItemID = nil
    }
}
