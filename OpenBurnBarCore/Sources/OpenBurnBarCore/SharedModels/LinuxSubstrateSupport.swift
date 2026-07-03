#if os(Linux)
import Foundation

// `RGBA` is now provided cross-platform by `SharedModels/RGBA.swift` (Foundation
// core), so the Linux fallback stub was removed to avoid a duplicate definition.

public enum SubstrateCatalog {
    public static let plainID = "plain"
    public static let byID: [String: Bool] = [plainID: true]
}
#endif
