import Foundation
import OpenBurnBarCore

/// Phase 14 — Domain status mirror of
/// `HermesRealtimeRelaySystemPermissionStatusKind`.
public enum SystemPermissionStatus: String, CaseIterable, Hashable, Sendable, Codable {
    case needsAccess
    case requesting
    case granted
    case denied
    case timeout
    case unknown

    public init(wire: HermesRealtimeRelaySystemPermissionStatusKind) {
        switch wire {
        case .needsAccess: self = .needsAccess
        case .requesting:  self = .requesting
        case .granted:     self = .granted
        case .denied:      self = .denied
        case .timeout:     self = .timeout
        case .unknown:     self = .unknown
        }
    }

    public var wire: HermesRealtimeRelaySystemPermissionStatusKind {
        switch self {
        case .needsAccess: return .needsAccess
        case .requesting:  return .requesting
        case .granted:     return .granted
        case .denied:      return .denied
        case .timeout:     return .timeout
        case .unknown:     return .unknown
        }
    }

    /// Whether the chat surface should show progress UI for this state.
    public var isInflight: Bool {
        self == .requesting
    }

    /// Whether the failed tool call should be retried automatically.
    public var unblocksRetry: Bool {
        self == .granted
    }

    /// Whether the chat surface should keep offering the grant CTA.
    public var allowsRetap: Bool {
        switch self {
        case .needsAccess, .denied, .timeout, .unknown: return true
        case .requesting, .granted: return false
        }
    }
}

/// One row in the chat-side inbox of pending macOS permissions.
public struct SystemPermissionItem: Hashable, Sendable, Identifiable, Codable {
    public let id: String
    public let kind: SystemPermissionKind
    public let bundleId: String?
    public let originatingToolCallId: String?
    public let originatingToolName: String?
    public let threadId: String
    public var status: SystemPermissionStatus
    public var deepLink: String?
    public var instructions: String?
    public var failureCategory: String?
    public var lastChangedAt: Date
    /// Set by the inbox store when this item was synthesised by the iOS
    /// text classifier rather than emitted by the Mac. Mac-side items
    /// always win over heuristic items for the same (thread, kind).
    public let source: Source

    public enum Source: String, Hashable, Sendable, Codable {
        case macStructured
        case iosHeuristic
    }

    public init(
        id: String = UUID().uuidString,
        kind: SystemPermissionKind,
        bundleId: String? = nil,
        originatingToolCallId: String? = nil,
        originatingToolName: String? = nil,
        threadId: String,
        status: SystemPermissionStatus = .needsAccess,
        deepLink: String? = nil,
        instructions: String? = nil,
        failureCategory: String? = nil,
        lastChangedAt: Date = Date(),
        source: Source
    ) {
        self.id = id
        self.kind = kind
        self.bundleId = bundleId
        self.originatingToolCallId = originatingToolCallId
        self.originatingToolName = originatingToolName
        self.threadId = threadId
        self.status = status
        self.deepLink = deepLink ?? kind.systemSettingsDeepLink
        self.instructions = instructions
        self.failureCategory = failureCategory
        self.lastChangedAt = lastChangedAt
        self.source = source
    }

    /// Inbox dedupe key — items sharing this key collapse to the most
    /// recently updated row. Mac-structured rows supersede iOS
    /// heuristic rows that share the same key.
    public var dedupeKey: String {
        "\(threadId)|\(kind.rawValue)|\(bundleId ?? "")"
    }

    public func wireStatus() -> HermesRealtimeRelaySystemPermissionStatus {
        HermesRealtimeRelaySystemPermissionStatus(
            kind: kind.wire,
            bundleId: bundleId,
            status: status.wire,
            originatingToolCallId: originatingToolCallId,
            originatingToolName: originatingToolName,
            deepLink: deepLink ?? kind.systemSettingsDeepLink,
            instructions: instructions,
            failureCategory: failureCategory,
            lastChangedAt: lastChangedAt
        )
    }

    public static func make(
        wire: HermesRealtimeRelaySystemPermissionStatus,
        threadId: String
    ) -> SystemPermissionItem {
        SystemPermissionItem(
            kind: SystemPermissionKind(wire: wire.kind),
            bundleId: wire.bundleId,
            originatingToolCallId: wire.originatingToolCallId,
            originatingToolName: wire.originatingToolName,
            threadId: threadId,
            status: SystemPermissionStatus(wire: wire.status),
            deepLink: wire.deepLink,
            instructions: wire.instructions,
            failureCategory: wire.failureCategory,
            lastChangedAt: wire.lastChangedAt,
            source: .macStructured
        )
    }
}
