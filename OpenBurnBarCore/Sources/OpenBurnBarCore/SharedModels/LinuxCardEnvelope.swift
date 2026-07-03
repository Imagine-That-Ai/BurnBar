// Windows joins Linux on the non-Apple path: the real `CardEnvelope` lives in
// `Views/Cards/CardEnvelope.swift`, which the manifest excludes off-Apple (the
// `Views` folder). This minimal stub keeps `SubscriptionTopic.swift` and other
// SharedModels consumers (compiled on every platform) resolvable in the Engine
// subset on Linux and Windows. On Apple the guard is false and the real type wins.
#if os(Linux) || os(Windows)
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
