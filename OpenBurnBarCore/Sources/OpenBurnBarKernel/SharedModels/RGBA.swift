import Foundation

// MARK: - RGBA (lightweight, Canvas-friendly)

/// Raw RGBA components for use in Canvas drawing contexts where SwiftUI `Color`
/// cannot be used directly. Components are in `[0, 1]`.
///
/// The value type is a Foundation-only primitive so it stays available to the pure
/// engine on non-Apple platforms and to every `OpenBurnBarKernel` consumer
/// (e.g. `SubstrateFamily` / `FamilyAccent`) on all platforms. The richer color
/// math (`bucketKey`, `mix`/`lightened`/`darkened`) and the SwiftUI `color` bridge
/// live in the SwiftUI-carrying layer (Core's `SharedModels/RGBA.swift` today,
/// `OpenBurnBarUI` after the K4 split) as retroactive extensions, so macOS/iOS
/// see the exact same API as before this Kernel extraction while the Kernel itself
/// stays SwiftUI/AppKit-free (Core-decomposition purity invariant).
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
