// Windows joins Linux on the non-Apple path: the real `SubstrateCatalog` lives in
// `Views/Substrate/SubstrateCatalog.swift`, which the manifest excludes off-Apple
// (the `Views` folder). This stub supplies the two members `SubstrateFamily.swift`
// (compiled on every platform) references, so the Engine subset resolves on Linux
// and Windows alike. On Apple the guard is false and the real catalog compiles.
#if os(Linux) || os(Windows)
import Foundation

// `RGBA` is now provided cross-platform by `SharedModels/RGBA.swift` (Foundation
// core), so the Linux fallback stub was removed to avoid a duplicate definition.

public enum SubstrateCatalog {
    public static let plainID = "plain"
    public static let byID: [String: Bool] = [plainID: true]
}
#endif
