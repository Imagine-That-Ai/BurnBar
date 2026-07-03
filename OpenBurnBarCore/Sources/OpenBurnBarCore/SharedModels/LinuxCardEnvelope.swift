#if os(Linux)
import Foundation

public enum CardEnvelope: Codable, Sendable, Hashable, Identifiable {
    case unknown(String)

    public var kind: String { "unknown" }

    public var id: String {
        switch self {
        case .unknown(let label):
            return "unknown#\(label)"
        }
    }
}
#endif
