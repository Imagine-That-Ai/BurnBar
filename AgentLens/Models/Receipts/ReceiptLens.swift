import Foundation

// MARK: - Receipt Lens

/// Defines the switchable visual perspectives for a receipt.
public enum ReceiptLens: String, CaseIterable, Identifiable, Codable, Sendable {
    case thermal
    case efficiency
    case audit
    case transcript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thermal:
            return "Thermal Slip"
        case .efficiency:
            return "Efficiency"
        case .audit:
            return "Audit & Proof"
        case .transcript:
            return "Chat"
        }
    }

    /// Compact picker label — four long titles will not fit the slip inspector.
    public var pickerTitle: String {
        switch self {
        case .thermal: return "Slip"
        case .efficiency: return "Burn"
        case .audit: return "Proof"
        case .transcript: return "Chat"
        }
    }

    public var iconName: String {
        switch self {
        case .thermal:
            return "doc.text.fill"
        case .efficiency:
            return "bolt.fill"
        case .audit:
            return "checkmark.seal.fill"
        case .transcript:
            return "text.bubble.fill"
        }
    }

    /// Token used in `openburnbar://receipts/{id}?lens=` so a flyout can
    /// land on Chat tape without inventing a second host.
    public var deepLinkToken: String {
        switch self {
        case .thermal: return "slip"
        case .efficiency: return "burn"
        case .audit: return "proof"
        case .transcript: return "chat"
        }
    }

    public static func fromDeepLinkToken(_ raw: String?) -> ReceiptLens? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "slip", "thermal": return .thermal
        case "burn", "efficiency": return .efficiency
        case "proof", "audit": return .audit
        case "chat", "transcript": return .transcript
        default: return nil
        }
    }

    public var subtitle: String {
        switch self {
        case .thermal:
            return "Itemized cost & token breakdown"
        case .efficiency:
            return "Cache savings & throughput metrics"
        case .audit:
            return "Durable SHA-256 signature & Git trace"
        case .transcript:
            return "Chat summary, transcript, and session links"
        }
    }
}
