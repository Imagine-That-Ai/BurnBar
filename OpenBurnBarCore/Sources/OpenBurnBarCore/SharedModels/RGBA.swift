import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - RGBA (lightweight, Canvas-friendly)

/// Raw RGBA components for use in Canvas drawing contexts where SwiftUI `Color`
/// cannot be used directly. Components are in `[0, 1]`.
///
/// This is a Foundation-only primitive so it stays available to the pure engine
/// on non-Apple platforms. The SwiftUI `color` bridge is compiled in only where
/// SwiftUI is available (`#if canImport(SwiftUI)`), which is every Apple
/// platform — so macOS/iOS see the exact same symbol as before this extraction.
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

    #if canImport(SwiftUI)
    public var color: Color {
        Color(red: r, green: g, blue: b).opacity(a)
    }
    #endif

    /// Quantized 8-bit-per-channel bucket key. Two RGBA values that round to the
    /// same byte triple share a bucket, which makes Canvas fill batching stable
    /// across micro-jitter in floating-point math and keeps draw counts bounded
    /// even when the colour driver wiggles intensities continuously.
    public var bucketKey: UInt32 {
        let r8 = UInt32((r.clamped(to: 0...1) * 255.0).rounded()) & 0xFF
        let g8 = UInt32((g.clamped(to: 0...1) * 255.0).rounded()) & 0xFF
        let b8 = UInt32((b.clamped(to: 0...1) * 255.0).rounded()) & 0xFF
        let a8 = UInt32((a.clamped(to: 0...1) * 255.0).rounded()) & 0xFF
        return (r8 << 24) | (g8 << 16) | (b8 << 8) | a8
    }
}

// MARK: - Color math helpers

extension RGBA {
    func mix(with other: RGBA, amount: Double) -> RGBA {
        let t = amount.clamped(to: 0...1)
        return RGBA(
            r: (r * (1 - t) + other.r * t).clamped(to: 0...1),
            g: (g * (1 - t) + other.g * t).clamped(to: 0...1),
            b: (b * (1 - t) + other.b * t).clamped(to: 0...1),
            a: (a * (1 - t) + other.a * t).clamped(to: 0...1)
        )
    }

    func lightened(by amount: Double) -> RGBA {
        mix(with: RGBA(r: 1, g: 1, b: 1, a: a), amount: amount)
    }

    func darkened(by amount: Double) -> RGBA {
        mix(with: RGBA(r: 0, g: 0, b: 0, a: a), amount: amount)
    }
}

// MARK: - Clamped helper

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
