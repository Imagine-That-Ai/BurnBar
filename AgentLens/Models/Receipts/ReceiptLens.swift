import Foundation

// MARK: - Receipt Lens

/// Defines the switchable visual perspectives for a receipt.
public enum ReceiptLens: String, CaseIterable, Identifiable, Codable, Sendable {
    case thermal
    case efficiency
    case audit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thermal:
            return "Thermal Slip"
        case .efficiency:
            return "Efficiency"
        case .audit:
            return "Audit & Proof"
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
        }
    }
}
