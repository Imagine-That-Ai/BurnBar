import Foundation
import OpenBurnBarKernel

#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - RGBA color math + SwiftUI Color bridge
//
// The `RGBA` value type itself is a Foundation-only primitive that lives in
// `OpenBurnBarKernel/SharedModels/RGBA.swift` so the pure engine and every Kernel
// consumer can use it on all platforms (including off-Apple). The richer color
// math and the SwiftUI bridge stay in the SwiftUI-carrying layer (Core today,
// `OpenBurnBarUI` after the K4 split) — the bridge behind `#if canImport(SwiftUI)`
// — keeping the Kernel SwiftUI/AppKit-free while macOS/iOS see the exact same API
// (`.bucketKey`, `.mix`, `.lightened`, `.darkened`, `.color`) as before the extraction.

extension RGBA {
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

    #if canImport(SwiftUI)
    public var color: Color {
        // Single-initializer form: `Color(...).opacity(a)` layers an extra
        // wrapper Color per call, and substrates convert thousands of RGBA
        // values per frame on the main thread. Rendering is identical.
        Color(red: r, green: g, blue: b, opacity: a)
    }
    #endif
}

// MARK: - Color math helpers

extension RGBA {
    // `public` (was module-internal in Core): after the K4 split these color-math
    // helpers live in OpenBurnBarUI, but Core consumers that stay above the UI
    // layer (e.g. `SharedModels/SwarmColorDriver.swift`, `Views/SwarmCanvasView+*`)
    // reach them across the module boundary via Core's `@_exported import
    // OpenBurnBarUI`, so they must be public. Behavior is unchanged — access
    // widening only. macOS/iOS keep the exact same `.mix`/`.lightened`/`.darkened`
    // API as before the extraction.
    public func mix(with other: RGBA, amount: Double) -> RGBA {
        let t = amount.clamped(to: 0...1)
        return RGBA(
            r: (r * (1 - t) + other.r * t).clamped(to: 0...1),
            g: (g * (1 - t) + other.g * t).clamped(to: 0...1),
            b: (b * (1 - t) + other.b * t).clamped(to: 0...1),
            a: (a * (1 - t) + other.a * t).clamped(to: 0...1)
        )
    }

    public func lightened(by amount: Double) -> RGBA {
        mix(with: RGBA(r: 1, g: 1, b: 1, a: a), amount: amount)
    }

    public func darkened(by amount: Double) -> RGBA {
        mix(with: RGBA(r: 0, g: 0, b: 0, a: a), amount: amount)
    }
}

// MARK: - Clamped helper

extension Double {
    // `public` for the same cross-module reason as the RGBA color-math above:
    // `SwarmColorDriver` (Core) calls `Double.clamped` and now reaches it through
    // the re-exported OpenBurnBarUI. Single definition in the whole graph (no
    // ambiguity); access widening only, behavior unchanged.
    public func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
