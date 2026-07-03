#if os(Linux)
import Foundation

public struct RGBA: Hashable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

public enum SubstrateCatalog {
    public static let plainID = "plain"
    public static let byID: [String: Bool] = [plainID: true]
}
#endif
