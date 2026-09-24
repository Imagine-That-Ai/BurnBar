import Foundation

// Usage-source/provenance enums (3.2: extracted from TokenUsage so provider contracts can reference them without a UsageModels edge).

// MARK: - Usage Provenance Confidence

public enum UsageProvenanceConfidence: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case exact = "exact"
    case derivedExact = "derived_exact"
    case highConfidenceEstimate = "high_confidence_estimate"
    case lowConfidenceEstimate = "low_confidence_estimate"
    case unknown = "unknown"

    public var precedence: Int {
        switch self {
        case .exact: return 4
        case .derivedExact: return 3
        case .highConfidenceEstimate: return 2
        case .lowConfidenceEstimate: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: UsageProvenanceConfidence, rhs: UsageProvenanceConfidence) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Source

public enum UsageSource: String, Codable, Hashable, CaseIterable, Sendable {
    case providerLog = "provider_log"
    case inAppChat = "in_app_chat"
    case cursorBridge = "cursor_bridge"
    case billingAPI = "billing_api"
    case daemon = "daemon"
    case unknown = "unknown"
}

// MARK: - Execution Source

/// The product surface that executed a model request. This is intentionally
/// separate from `UsageSource`, which describes how BurnBar ingested the row.
public enum UsageExecutionSourceKind: String, Codable, Hashable, CaseIterable, Sendable {
    case ide
    case cli
    case desktopApp = "desktop_app"
    case service
    case automation
    case unknown
}
