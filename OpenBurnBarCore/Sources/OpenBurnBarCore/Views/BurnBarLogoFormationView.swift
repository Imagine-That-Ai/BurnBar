// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - BurnBarLogoFormationView
//
// The launch hero, shared across iOS / iPadOS / macOS. A swarm of dots converges
// into the BurnBar flame as a dot-glyph, morphs into the solid logo, an isometric
// glass cube settles around it, real domain-warped oil-on-water drifts across the
// glass, and a few provider glyphs (Anthropic, OpenAI, Google…) form as dot
// constellations, drift *under* the glass, and re-form into a new provider when
// two collide.
//
// Apple Liquid Glass (`glassEffect`) is used when available (iOS 26 / macOS 26)
// and falls back to a hand-built obsidian-glass cube on older OSes — so the
// component keeps the app's existing iOS 17 / macOS 14 deployment target.
//
// `Color(hex:)` comes from `OpenBurnBarCore/ThemePrimitives`.

// MARK: - Haptic events

/// Semantic haptic moments emitted by the animation. The shared Core view
/// stays UIKit-free; platform apps decide how to play these.
public enum BurnBarLogoFormationHaptic: Hashable, Sendable {
    case ignition
    case coalescing
    case logoLocked
    case glassSettled
    case providerGlyphs
    case interaction
}

private extension BurnBarLogoFormationHaptic {
    static let orderedMilestones: [BurnBarLogoFormationHaptic] = [
        .ignition,
        .coalescing,
        .logoLocked,
        .glassSettled,
        .providerGlyphs
    ]

    var triggerTime: Double {
        switch self {
        case .ignition: return 0.18
        case .coalescing: return 1.25
        case .logoLocked: return 2.95
        case .glassSettled: return 4.05
        case .providerGlyphs: return glyphStartT
        case .interaction: return 0
        }
    }
}

// MARK: - BurnBarLogoFormationView

public struct BurnBarLogoFormationView: View {
    /// Providers whose brand marks swarm beneath the glass. These form from
    /// the same canonical sampler (`SwarmGlyphSampler`) the rest of the app
    /// uses for its swarm glyphs, so the marks read identically here.
    private let providers: [AgentProvider]
    /// The brand mark asset name.
    private let logoName: String
    /// Semantic haptic moments emitted by the animation. The shared Core view
    /// stays UIKit-free; platform apps decide how to play these.
    private let onHaptic: (BurnBarLogoFormationHaptic) -> Void

    public init(
        logoName: String = "AppLogo",
        providers: [AgentProvider] = AgentProvider.swarmGlyphProviders,
        onHaptic: @escaping (BurnBarLogoFormationHaptic) -> Void = { _ in }
    ) {
        self.logoName = logoName
        self.providers = providers
        self.onHaptic = onHaptic
    }

    public var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / FormationLayout.W, geo.size.height / FormationLayout.H)
            FormationDriver(logoName: logoName, providers: providers, onHaptic: onHaptic)
                .frame(width: FormationLayout.W, height: FormationLayout.H)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("OpenBurnBar")
        .accessibilityHint("Tap to ripple the provider glyphs.")
    }
}

// MARK: - Layout (design canvas; scaled to fit)

private enum FormationLayout {
    static let W: CGFloat = 560
    static let H: CGFloat = 460
    static let logoSize: CGFloat = 150
    static let logoCX: CGFloat = 280
    static let logoCY: CGFloat = 235
    static let cubeS: CGFloat = 165
    static let cubeCX: CGFloat = 280
    static let cubeCY: CGFloat = 235
    static var logoOX: CGFloat { logoCX - logoSize / 2 }
    static var logoOY: CGFloat { logoCY - logoSize / 2 }
}

// MARK: - Math helpers (file-private)

private func smooth(_ x: Double) -> Double { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }
private func easeOut(_ x: Double) -> Double { let t = max(0, min(1, x)); return 1 - pow(1 - t, 3) }
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
private func fract(_ x: Double) -> Double { x - floor(x) }
private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

private struct RNG { var s: UInt64
    init(_ seed: UInt64) { s = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000.0 }
}

// MARK: - Real oil-on-water (domain-warped fractal noise -> image; CPU, portable)

private func hash21(_ x: Double, _ y: Double) -> Double {
    var px = fract(x * 123.34), py = fract(y * 233.53)
    let dv = px * (px + 23.234) + py * (py + 23.234)
    px += dv; py += dv
    return fract(px * py)
}
private func vnoise(_ x: Double, _ y: Double) -> Double {
    let ix = floor(x), iy = floor(y), fx = x - ix, fy = y - iy
    let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
    let a = hash21(ix, iy), b = hash21(ix + 1, iy), c = hash21(ix, iy + 1), d = hash21(ix + 1, iy + 1)
    let ab = a + (b - a) * ux, cd = c + (d - c) * ux
    return ab + (cd - ab) * uy
}
private func fbm2(_ x0: Double, _ y0: Double) -> Double {
    var x = x0, y = y0, v = 0.0, amp = 0.5
    for _ in 0 ..< 5 { v += amp * vnoise(x, y); let nx = 1.6 * x + 1.2 * y, ny = -1.2 * x + 1.6 * y; x = nx; y = ny; amp *= 0.5 }
    return v
}
private func oilImage(_ t: Double, n: Int = 68) -> CGImage? {
    var buf = [UInt8](repeating: 0, count: n * n * 4)
    for yy in 0 ..< n { for xx in 0 ..< n {
        let ux = (Double(xx) + 0.5) / Double(n), uy = (Double(yy) + 0.5) / Double(n)
        let px = ux * 3.2, py = uy * 3.2
        let qx = fbm2(px + 0.15 * t, py + 0.15 * t)
        let qy = fbm2(px + 5.2 + 0.12 * t, py + 1.3 + 0.12 * t)
        let rx = fbm2(px + 2 * qx + 1.7 + 0.10 * t, py + 2 * qy + 9.2 + 0.10 * t)
        let ry = fbm2(px + 2 * qx + 8.3 - 0.13 * t, py + 2 * qy + 2.8 - 0.13 * t)
        let f = fbm2(px + 2 * rx, py + 2 * ry)
        let ph = f * 1.7 + 0.08 * t + (rx * rx + ry * ry).squareRoot() * 0.8
        func pal(_ o: Double) -> Double { pow(clamp01(0.5 + 0.5 * cos(2 * Double.pi * (ph + o))), 1.25) }
        let cr = pal(0.0), cg = pal(0.33), cb = pal(0.67)
        let wander = smooth((fbm2(ux * 1.3, uy * 1.3 - 0.05 * t) - 0.30) / 0.65)
        let patches = smooth((f - 0.52) / 0.40)
        let dxc = ux - 0.5, dyc = uy - 0.5
        let edge = 1 - smooth(((dxc * dxc + dyc * dyc).squareRoot() * 1.45 - 0.62) / 0.46)
        let m = max(0, patches * wander * edge) * 0.9
        let idx = (yy * n + xx) * 4
        buf[idx + 0] = UInt8(min(255, cr * m * 255)); buf[idx + 1] = UInt8(min(255, cg * m * 255))
        buf[idx + 2] = UInt8(min(255, cb * m * 255)); buf[idx + 3] = UInt8(min(255, m * 255))
    }}
    return buf.withUnsafeMutableBytes { ptr -> CGImage? in
        guard let ctx = CGContext(data: ptr.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - Cross-platform image pixel loading

private func cgImageNamed(_ name: String) -> CGImage? {
    #if canImport(UIKit)
    return UIImage(named: name)?.cgImage
    #elseif canImport(AppKit)
    guard let img = NSImage(named: name) else { return nil }
    var rect = CGRect(origin: .zero, size: img.size)
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    #else
    return nil
    #endif
}

/// Top-left-origin RGBA pixel buffer for a named asset.
private struct PixelImage { let px: [UInt8]; let w: Int; let h: Int
    func sample(_ gx: Int, _ gy: Int) -> (Double, Double, Double, Double) {
        let i = (min(gy, h - 1) * w + min(gx, w - 1)) * 4
        let a = Double(px[i + 3]) / 255
        var r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
        if a > 0.001 { r /= a; g /= a; b /= a } // un-premultiply
        return (min(1, r), min(1, g), min(1, b), a)
    }
}
private func loadPixels(_ name: String) -> PixelImage? {
    guard let cg = cgImageNamed(name) else { return nil }
    let w = cg.width, h = cg.height
    guard w > 0, h > 0 else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok: Bool = px.withUnsafeMutableBytes { ptr in
        guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) // top-left origin
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? PixelImage(px: px, w: w, h: h) : nil
}

// MARK: - Model

private struct Dot { let target: CGPoint; let start: CGPoint; let r: Double; let g: Double; let b: Double; let delay: Double; let driftA: CGFloat; let driftF: Double; let driftP: Double; let dotSize: Double }
private struct GDot { let p: CGPoint; let r: Double; let g: Double; let b: Double }
private struct Glyph { var pos: CGPoint; var vel: CGVector; var prov: Int; var baseProv: Int; var flash: Double; var formT: Double; var seed: UInt64; var lastSwapT: Double }

private let glyphStartT = 3.35

private func sampleDots(_ logoName: String) -> [Dot] {
    guard let img = loadPixels(logoName) else { return [] }
    let grid = 62
    var raw: [(CGPoint, Double, Double, Double)] = []
    for gy in 0 ..< grid { for gx in 0 ..< grid {
        let px = Int((Double(gx) + 0.5) / Double(grid) * Double(img.w))
        let py = Int((Double(gy) + 0.5) / Double(grid) * Double(img.h))
        let (r, g, b, a) = img.sample(px, py)
        if a < 0.45 { continue }
        let nx = (Double(gx) + 0.5) / Double(grid), ny = (Double(gy) + 0.5) / Double(grid)
        raw.append((CGPoint(x: nx, y: ny), r, g, b))
    }}
    var rng = RNG(42)
    var dots: [Dot] = []
    for item in raw {
        let (n, r, g, b) = item
        let visualY = 1 - n.y
        let cell = FormationLayout.logoSize / CGFloat(grid)
        let tx = FormationLayout.logoOX + n.x * FormationLayout.logoSize + CGFloat(rng.next() - 0.5) * cell * 0.8
        let ty = FormationLayout.logoOY + visualY * FormationLayout.logoSize + CGFloat(rng.next() - 0.5) * cell * 0.8
        let sx: CGFloat
        let sy: CGFloat
        // Keep the ignition swarm out of the hero box at rest. The particles
        // should enter from screen edges and corners, never bloom from a
        // rectangular field around the logo.
        switch Int(rng.next() * 8) {
        case 0:
            sx = CGFloat(-96 - rng.next() * 190)
            sy = CGFloat(rng.next()) * FormationLayout.H
        case 1:
            sx = FormationLayout.W + CGFloat(96 + rng.next() * 190)
            sy = CGFloat(rng.next()) * FormationLayout.H
        case 2:
            sx = CGFloat(rng.next()) * FormationLayout.W
            sy = CGFloat(-96 - rng.next() * 180)
        case 3:
            sx = CGFloat(rng.next()) * FormationLayout.W
            sy = FormationLayout.H + CGFloat(96 + rng.next() * 180)
        case 4:
            sx = CGFloat(-108 - rng.next() * 170)
            sy = CGFloat(-108 - rng.next() * 150)
        case 5:
            sx = FormationLayout.W + CGFloat(108 + rng.next() * 170)
            sy = CGFloat(-108 - rng.next() * 150)
        case 6:
            sx = CGFloat(-108 - rng.next() * 170)
            sy = FormationLayout.H + CGFloat(108 + rng.next() * 150)
        default:
            sx = FormationLayout.W + CGFloat(108 + rng.next() * 170)
            sy = FormationLayout.H + CGFloat(108 + rng.next() * 150)
        }
        let targetAngle = atan2(Double(ty - FormationLayout.logoCY), Double(tx - FormationLayout.logoCX))
        let radialBias = 0.04 + 0.08 * abs(sin(targetAngle))
        let delay = radialBias + rng.next() * 0.36
        dots.append(Dot(target: CGPoint(x: tx, y: ty), start: CGPoint(x: sx, y: sy), r: r, g: g, b: b,
                        delay: min(delay, 0.30), driftA: CGFloat(8 + rng.next() * 22),
                        driftF: 0.5 + rng.next() * 1.3, driftP: rng.next() * 6.28, dotSize: 2.2 + rng.next() * 2.2))
    }
    return dots
}

private func sampleGlyphDots(_ name: String, maxDots: Int = 96) -> [GDot] {
    guard let img = loadPixels(name) else { return [] }
    let grid = 28
    var dots: [GDot] = []
    for gy in 0 ..< grid {
        for gx in 0 ..< grid {
            let px = Int((Double(gx) + 0.5) / Double(grid) * Double(img.w))
            let py = Int((Double(gy) + 0.5) / Double(grid) * Double(img.h))
            let (r, g, b, a) = img.sample(px, py)
            guard a >= 0.45 else { continue }
            let (br, bg, bb) = brightenedBrandColor(RGBA(r: r, g: g, b: b, a: a))
            let nx = (Double(gx) + 0.5) / Double(grid) - 0.5
            let ny = 0.5 - (Double(gy) + 0.5) / Double(grid)
            dots.append(GDot(p: CGPoint(x: nx, y: ny), r: br, g: bg, b: bb))
        }
    }
    guard dots.count > maxDots else { return dots }
    let step = Double(dots.count) / Double(maxDots)
    return (0 ..< maxDots).map { dots[min(Int(Double($0) * step), dots.count - 1)] }
}

/// Lifts a sampled brand color so monochrome or dark marks (OpenAI, GitHub,
/// Anthropic…) stay legible on the dark splash, where the constellation draws
/// with `.plusLighter`. `nil` brand colors (vector / initials fallbacks)
/// resolve to a warm white. Mirrors the brightening the splash always applied
/// to sampled logos, now fed by the canonical glyph sampler.
private func brightenedBrandColor(_ rgba: RGBA?) -> (Double, Double, Double) {
    guard let rgba else { return (0.96, 0.97, 1.0) }
    var r = rgba.r, g = rgba.g, b = rgba.b
    let mx = max(r, max(g, b))
    if mx < 0.06 { return (0.96, 0.97, 1.0) }
    if mx < 0.68 {
        let s = 0.68 / mx
        r = min(1, r * s); g = min(1, g * s); b = min(1, b * s)
    }
    let avg = (r + g + b) / 3
    r = clamp01(avg + (r - avg) * 1.12)
    g = clamp01(avg + (g - avg) * 1.12)
    b = clamp01(avg + (b - avg) * 1.12)
    return (r, g, b)
}

private func scatterOffset(_ seed: UInt64, _ k: Int) -> CGPoint {
    var s = seed &+ (UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15)
    s ^= s >> 33; s = s &* 0xFF51_AFD7_ED55_8CCD; s ^= s >> 33
    let a = Double(s % 10000) / 10000.0 * 2 * Double.pi
    let r = 12 + Double((s >> 20) % 10000) / 10000.0 * 24
    return CGPoint(x: cos(a) * r, y: sin(a) * r)
}

/// Sampled assets, computed once on the main actor (the marks rarely change).
@MainActor private final class FormationAssets {
    let dots: [Dot]
    let providerDots: [[GDot]]
    init(logoName: String, providers: [AgentProvider]) {
        dots = sampleDots(logoName)
        providerDots = providers.map { providerGlyphDots(for: $0) }
    }
}

/// Provider brand mark as constellation dots, sourced from the canonical
/// `SwarmGlyphSampler` so the splash forms the exact same recognizable glyphs
/// the rest of the app does. Uses the *filled* sampler (not the outline one):
/// at hero scale a hollow ring is unreadable, a solid dot-logo reads as the
/// real mark. Canonical glyph space is ~[-1, 1] on the long axis (y down); the
/// constellation layer multiplies by 84, so we halve to keep marks at the
/// on-canvas size this scene is tuned for.
@MainActor
private func providerGlyphDots(for provider: AgentProvider, maxDots: Int = 240) -> [GDot] {
    SwarmGlyphSampler.filledGlyphPoints(for: provider, maxPoints: maxDots).map { point in
        let (r, g, b) = brightenedBrandColor(point.brandColor)
        return GDot(p: CGPoint(x: point.position.x * 0.5, y: point.position.y * 0.5), r: r, g: g, b: b)
    }
}

// MARK: - Isometric cube geometry

private struct CubePts {
    let topBackLeft: CGPoint
    let topBackRight: CGPoint
    let topFrontRight: CGPoint
    let topFrontLeft: CGPoint
    let bottomBackRight: CGPoint
    let bottomFrontRight: CGPoint
    let bottomFrontLeft: CGPoint
}

private func cubePoints() -> CubePts {
    let cx = FormationLayout.cubeCX, cy = FormationLayout.cubeCY, s = FormationLayout.cubeS
    func point(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: cx + (x - y) * 0.866 * s, y: cy + ((x + y) * 0.5 - z) * s)
    }
    return CubePts(
        topBackLeft: point(0, 0, 1),
        topBackRight: point(1, 0, 1),
        topFrontRight: point(1, 1, 1),
        topFrontLeft: point(0, 1, 1),
        bottomBackRight: point(1, 0, 0),
        bottomFrontRight: point(1, 1, 0),
        bottomFrontLeft: point(0, 1, 0)
    )
}
private func roundedPoly(_ pts: [CGPoint], _ rad: CGFloat) -> Path {
    var path = Path(); let n = pts.count
    for i in 0 ..< n {
        let prev = pts[(i - 1 + n) % n], cur = pts[i], nxt = pts[(i + 1) % n]
        let v1 = CGVector(dx: cur.x - prev.x, dy: cur.y - prev.y), v2 = CGVector(dx: nxt.x - cur.x, dy: nxt.y - cur.y)
        let l1 = max(hypot(v1.dx, v1.dy), 0.001), l2 = max(hypot(v2.dx, v2.dy), 0.001)
        let r = min(rad, l1 / 2, l2 / 2)
        let p1 = CGPoint(x: cur.x - v1.dx / l1 * r, y: cur.y - v1.dy / l1 * r)
        let p2 = CGPoint(x: cur.x + v2.dx / l2 * r, y: cur.y + v2.dy / l2 * r)
        if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
        path.addQuadCurve(to: p2, control: cur)
    }
    path.closeSubpath(); return path
}
private struct CubeSil: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.topBackLeft, p.topBackRight, p.bottomBackRight, p.bottomFrontRight, p.bottomFrontLeft, p.topFrontLeft], FormationLayout.cubeS * 0.09) } }
private struct CubeTopF: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.topBackLeft, p.topBackRight, p.topFrontRight, p.topFrontLeft], FormationLayout.cubeS * 0.05) } }
private struct CubeLeftF: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.topFrontLeft, p.topFrontRight, p.bottomFrontRight, p.bottomFrontLeft], FormationLayout.cubeS * 0.05) } }
private struct CubeRightF: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.topBackRight, p.bottomBackRight, p.bottomFrontRight, p.topFrontRight], FormationLayout.cubeS * 0.05) } }
private struct CubeTopEdge: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); var pa = Path(); pa.move(to: p.topFrontLeft); pa.addLine(to: p.topFrontRight); pa.addLine(to: p.topBackRight); return pa } }
private struct CubeFrontEdge: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); var pa = Path(); pa.move(to: p.topFrontRight); pa.addLine(to: p.bottomFrontRight); return pa } }

// MARK: - Liquid Glass Cube

/// The isometric brand cube: a warm, luminous glass shell that wraps the flame.
/// On iOS 26 / macOS 26 it uses native Liquid Glass; on earlier OSes it falls
/// back to a hand-tuned translucent obsidian plate with specular highlights,
/// rim lighting, and a slow mercury shimmer.
private struct GlassCubeAssembly: View {
    let time: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let cubeS = FormationLayout.cubeS
    private let cubeCX = FormationLayout.cubeCX
    private let cubeCY = FormationLayout.cubeCY
    private let width = FormationLayout.W
    private let height = FormationLayout.H

    var body: some View {
        let pts = cubePoints()
        ZStack {
            // Grounded shadow
            Ellipse()
                .fill(Color.black.opacity(0.55))
                .frame(width: cubeS * 1.75, height: cubeS * 0.5)
                .blur(radius: cubeS * 0.22)
                .position(x: cubeCX, y: pts.bottomFrontRight.y + cubeS * 0.08)

            // Inner ember glow — warm light that appears to live inside the cube.
            RadialGradient(
                colors: [
                    Color(hex: "F25205").opacity(0.30),
                    Color(hex: "FF6A2A").opacity(0.10),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: cubeS * 0.85
            )
            .frame(width: cubeS * 1.55, height: cubeS * 1.55)
            .position(x: cubeCX, y: cubeCY + cubeS * 0.10)
            .blur(radius: 10)
            .blendMode(.plusLighter)
            .clipShape(CubeSil())

            // Pre-Liquid-Glass fallback faces. More translucent than before so
            // the highlights and glyphs read through the "glass" rather than
            // sitting on a dark solid block.
            if #unavailable(iOS 26.0, macOS 26.0) {
                fallbackGlassFaces
            }

            // Native Liquid Glass on iOS 26 / macOS 26. A faint warm tint makes
            // the cube feel on-brand; `.interactive()` gives it a subtle living
            // response as the device moves.
            if #available(iOS 26.0, macOS 26.0, *) {
                Color.clear
                    .frame(width: width, height: height)
                    .glassEffect(
                        .regular
                            .tint(Color(hex: "FF6A2A").opacity(colorScheme == .dark ? 0.10 : 0.06))
                            .interactive(),
                        in: CubeSil()
                    )
            }

            // Specular highlights, caustics, and animated shimmer.
            glassHighlights

            // Rim edges that catch the light.
            glassEdges
        }
        .frame(width: width, height: height)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var fallbackGlassFaces: some View {
        ZStack {
            CubeRightF().fill(
                LinearGradient(
                    colors: [
                        Color(hex: "1A1C26").opacity(0.70),
                        Color(hex: "0E1018").opacity(0.78)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            CubeLeftF().fill(
                LinearGradient(
                    colors: [
                        Color(hex: "232533").opacity(0.66),
                        Color(hex: "14161F").opacity(0.74)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            CubeTopF().fill(
                LinearGradient(
                    colors: [
                        Color(hex: "4A4D5C").opacity(0.58),
                        Color(hex: "2E303C").opacity(0.66)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipShape(CubeSil())
    }

    @ViewBuilder
    private var glassHighlights: some View {
        ZStack {
            // Top-face specular hotspot — the brightest reflection on the cube.
            CubeTopF().fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.26 : 0.38),
                        Color.white.opacity(0.08),
                        .clear
                    ],
                    center: UnitPoint(x: 0.35, y: 0.18),
                    startRadius: 0,
                    endRadius: cubeS
                )
            )
            .blendMode(.plusLighter)

            // Warm caustic glow rising from the lower interior.
            RadialGradient(
                colors: [
                    Color(hex: "FF6A2A").opacity(0.20),
                    Color(hex: "F25205").opacity(0.07),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: cubeS * 0.78
            )
            .frame(width: cubeS * 1.55, height: cubeS * 1.55)
            .position(x: cubeCX, y: cubeCY + cubeS * 0.18)
            .blendMode(.plusLighter)
            .clipShape(CubeSil())

            // Slow mercury shimmer across the glass surface.
            if !reduceTransparency {
                GlassCubeShimmer()
                    .clipShape(CubeSil())
            }
        }
        .clipShape(CubeSil())
    }

    @ViewBuilder
    private var glassEdges: some View {
        ZStack {
            CubeTopEdge().stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.55),
                        Color(hex: "FF6A2A").opacity(0.35),
                        Color(hex: "6E7180").opacity(0.65)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: max(1.2, cubeS * 0.014)
            )
            CubeTopEdge().stroke(
                Color.white.opacity(0.18),
                lineWidth: max(0.5, cubeS * 0.004)
            )
            CubeFrontEdge().stroke(
                LinearGradient(
                    colors: [
                        Color(hex: "5C5E6C").opacity(0.9),
                        Color(hex: "FF6A2A").opacity(0.28),
                        Color(hex: "23242C").opacity(0.8)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: max(1.2, cubeS * 0.014)
            )
        }
        .clipShape(CubeSil())
    }
}

// MARK: - Glass cube shimmer

/// A slow diagonal shimmer band that traverses the cube, giving the surface
/// a living, refractive quality. Disabled under Reduce Motion.
private struct GlassCubeShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { _ in
            shimmerGradient
                .mask(shimmerMask)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    private var shimmerGradient: some View {
        LinearGradient(
            colors: [
                .clear,
                Color.white.opacity(0.06),
                Color.white.opacity(0.18),
                Color.white.opacity(0.06),
                .clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shimmerMask: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .rotationEffect(.degrees(18))
            .offset(x: -FormationLayout.cubeS * 1.6 + phase * FormationLayout.cubeS * 3.4)
            .blur(radius: 6)
    }
}

// MARK: - Provider glyph constellation

/// Provider marks live as a full-canvas field, not as a cube texture. They form
/// around and beyond the glass, then respond to taps with a re-scatter pulse.
private struct ProviderGlyphConstellationLayer: View {
    let time: Double
    let glyphs: [Glyph]
    let providerDots: [[GDot]]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width = FormationLayout.W
    private let height = FormationLayout.H

    var body: some View {
        let appear = smooth((time - glyphStartT) / 0.72)
        if appear > 0.001, !providerDots.isEmpty {
            Canvas { ctx, _ in
                let scale: CGFloat = 84
                let isLight = colorScheme == .light
                if isLight {
                    ctx.addFilter(.shadow(color: Color.black.opacity(0.13), radius: 2.4, x: 0, y: 0.8))
                } else {
                    ctx.addFilter(.shadow(color: Color(hex: "FF6A2A").opacity(0.18), radius: 4, x: 0, y: 0))
                }

                for gl in glyphs {
                    guard providerDots.indices.contains(gl.prov) else { continue }
                    let points = providerDots[gl.prov]
                    let form = easeOut(gl.formT)
                    let breathe = reduceMotion ? 0 : sin(time * 0.7 + Double(gl.seed % 997) * 0.01) * 1.2

                    for (index, dot) in points.enumerated() {
                        let targetX = gl.pos.x + dot.p.x * scale
                        let targetY = gl.pos.y + dot.p.y * scale
                        let off = scatterOffset(gl.seed, index)
                        let startX = gl.pos.x + off.x * 1.25
                        let startY = gl.pos.y + off.y * 1.25
                        let x = startX + (targetX - startX) * CGFloat(form)
                        let y = startY + (targetY - startY) * CGFloat(form) + CGFloat(breathe)
                        let alpha = min(0.72, appear * (0.18 + 0.70 * form) * (0.82 + 0.20 * gl.flash))
                        guard alpha >= 0.018 else { continue }

                        // Filled dot-logos read solid only when dots roughly
                        // meet at this density; smaller and the mark stipples
                        // into an unreadable scatter.
                        let size: CGFloat = isLight ? 4.5 + 0.9 * gl.flash : 4.2 + 0.8 * gl.flash
                        let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
                        if isLight {
                            ctx.opacity = alpha * 0.16
                            ctx.fill(Path(ellipseIn: rect.insetBy(dx: -0.7, dy: -0.7)), with: .color(Color.black))
                        }
                        ctx.opacity = alpha
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .color(Color(.sRGB, red: dot.r, green: dot.g, blue: dot.b, opacity: 1))
                        )
                    }
                }
            }
            .frame(width: width, height: height)
            .blendMode(colorScheme == .dark ? .plusLighter : .normal)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Glyph physics

@MainActor private final class FormationSim: ObservableObject {
    @Published var t: Double = 0
    @Published var glyphs: [Glyph] = []
    @Published var interactionNonce: Int = 0
    private var timer: Timer?
    private let dt = 1.0 / 45.0
    private let swapCooldown = 1.15
    private var providerCount: Int
    private var providerCursor: Int = 0

    init(providerCount: Int) { self.providerCount = max(1, providerCount) }

    func configureProviderCount(_ count: Int) {
        let resolved = max(1, count)
        guard providerCount != resolved else { return }
        providerCount = resolved
        seed()
    }

    func start() {
        guard timer == nil else { return }
        seed()
        let tm = Timer(timeInterval: dt, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }
    func stop() { timer?.invalidate(); timer = nil }

    func pulse(at point: CGPoint) {
        if t < glyphStartT { t = glyphStartT }
        for i in glyphs.indices {
            let dx = glyphs[i].pos.x - point.x
            let dy = glyphs[i].pos.y - point.y
            let d = max(hypot(dx, dy), 1)
            let impulse = CGFloat(12 + Double(i) * 2)
            glyphs[i].vel.dx = dx / d * impulse + .random(in: -2 ... 2)
            glyphs[i].vel.dy = dy / d * impulse + .random(in: -2 ... 2)
            advanceProvider(at: i, flash: 1)
        }
    }

    private func seed() {
        let n = providerCount
        let visibleCount = max(1, min(n, 5))
        providerCursor = visibleCount % max(n, 1)
        glyphs = (0 ..< visibleCount).map { i in
            let base = i % n
            let position = orbitPoint(index: i, count: visibleCount)
            let angle = Double(i) / Double(max(visibleCount, 1)) * 2 * Double.pi
            return Glyph(
                pos: position,
                vel: CGVector(dx: CGFloat(cos(angle + .pi / 2) * 0.8), dy: CGFloat(sin(angle + .pi / 2) * 0.6)),
                prov: base,
                baseProv: base,
                flash: 0,
                formT: 0,
                seed: .random(in: 0 ... UInt64.max),
                lastSwapT: 0
            )
        }
    }

    private func orbitPoint(index: Int, count: Int) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) / Double(max(count, 1)) * 2 * Double.pi
        let x = FormationLayout.logoCX + CGFloat(cos(angle)) * 205
        let y = FormationLayout.logoCY + CGFloat(sin(angle)) * 142
        return CGPoint(
            x: min(max(x, 58), FormationLayout.W - 58),
            y: min(max(y, 50), FormationLayout.H - 50)
        )
    }

    private func advanceProvider(at index: Int, flash: Double) {
        guard providerCount > 1, glyphs.indices.contains(index) else {
            if glyphs.indices.contains(index) { glyphs[index].flash = max(glyphs[index].flash, flash) }
            return
        }
        let next = providerCursor % providerCount
        providerCursor = (providerCursor + 1) % providerCount
        glyphs[index].prov = next
        glyphs[index].baseProv = next
        glyphs[index].formT = 0
        glyphs[index].flash = max(glyphs[index].flash, flash)
        glyphs[index].seed = .random(in: 0 ... UInt64.max)
        glyphs[index].lastSwapT = t
    }

    private func step() {
        t += dt
        guard t > glyphStartT else { return }
        let r: CGFloat = 40, width = FormationLayout.W, height = FormationLayout.H
        for i in glyphs.indices {
            glyphs[i].pos.x += glyphs[i].vel.dx * CGFloat(dt)
            glyphs[i].pos.y += glyphs[i].vel.dy * CGFloat(dt)
            glyphs[i].vel.dx *= 0.996
            glyphs[i].vel.dy *= 0.996
            if glyphs[i].pos.x < 58 { glyphs[i].pos.x = 58; glyphs[i].vel.dx = abs(glyphs[i].vel.dx) }
            if glyphs[i].pos.x > width - 58 { glyphs[i].pos.x = width - 58; glyphs[i].vel.dx = -abs(glyphs[i].vel.dx) }
            if glyphs[i].pos.y < 48 { glyphs[i].pos.y = 48; glyphs[i].vel.dy = abs(glyphs[i].vel.dy) }
            if glyphs[i].pos.y > height - 48 { glyphs[i].pos.y = height - 48; glyphs[i].vel.dy = -abs(glyphs[i].vel.dy) }
            if glyphs[i].flash > 0 { glyphs[i].flash = max(0, glyphs[i].flash - dt * 2.2) }
            if glyphs[i].formT < 1 { glyphs[i].formT = min(1, glyphs[i].formT + dt / 2.8) }
        }
        guard glyphs.count >= 2 else { return }
        for i in 0 ..< (glyphs.count - 1) {
            for j in (i + 1) ..< glyphs.count {
                let dx = glyphs[j].pos.x - glyphs[i].pos.x, dy = glyphs[j].pos.y - glyphs[i].pos.y
                let d = hypot(dx, dy)
                if d < r * 2, d > 0.001 {
                    let nx = dx / d, ny = dy / d, overlap = (r * 2 - d) / 2
                    glyphs[i].pos.x -= nx * overlap; glyphs[i].pos.y -= ny * overlap
                    glyphs[j].pos.x += nx * overlap; glyphs[j].pos.y += ny * overlap
                    let pi = glyphs[i].vel.dx * nx + glyphs[i].vel.dy * ny
                    let pj = glyphs[j].vel.dx * nx + glyphs[j].vel.dy * ny
                    glyphs[i].vel.dx += (pj - pi) * nx; glyphs[i].vel.dy += (pj - pi) * ny
                    glyphs[j].vel.dx += (pi - pj) * nx; glyphs[j].vel.dy += (pi - pj) * ny
                    var didAdvance = false
                    if t - glyphs[i].lastSwapT >= swapCooldown {
                        advanceProvider(at: i, flash: 0.9)
                        didAdvance = true
                    } else {
                        glyphs[i].flash = max(glyphs[i].flash, 0.45)
                    }
                    if t - glyphs[j].lastSwapT >= swapCooldown {
                        advanceProvider(at: j, flash: 0.9)
                        didAdvance = true
                    } else {
                        glyphs[j].flash = max(glyphs[j].flash, 0.45)
                    }
                    if didAdvance { interactionNonce &+= 1 }
                }
            }
        }
    }
}

// MARK: - Driver

private struct FormationDriver: View {
    let logoName: String
    let providers: [AgentProvider]
    let onHaptic: (BurnBarLogoFormationHaptic) -> Void
    @StateObject private var sim: FormationSim
    @State private var assets: FormationAssets?
    @State private var emittedHaptics: Set<BurnBarLogoFormationHaptic> = []

    init(logoName: String, providers: [AgentProvider], onHaptic: @escaping (BurnBarLogoFormationHaptic) -> Void) {
        self.logoName = logoName
        self.providers = providers
        self.onHaptic = onHaptic
        _sim = StateObject(wrappedValue: FormationSim(providerCount: providers.count))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { _ in
            FormationHero(p: min(sim.t / 5.0, 1.0), time: sim.t, glyphs: sim.glyphs,
                          logoName: logoName, providerDots: assets?.providerDots ?? [], dots: assets?.dots ?? [])
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    sim.pulse(at: value.location)
                    onHaptic(.interaction)
                }
        )
        .onAppear {
            if assets == nil {
                let loadedAssets = FormationAssets(logoName: logoName, providers: providers)
                assets = loadedAssets
                sim.configureProviderCount(loadedAssets.providerDots.count)
            } else {
                sim.configureProviderCount(assets?.providerDots.count ?? providers.count)
            }
            emittedHaptics.removeAll()
            sim.start()
        }
        .onChange(of: sim.t) { _, newValue in
            emitMilestoneHaptics(at: newValue)
        }
        .onChange(of: sim.interactionNonce) { _, _ in
            onHaptic(.interaction)
        }
        .onDisappear { sim.stop() }
    }

    private func emitMilestoneHaptics(at time: Double) {
        for event in BurnBarLogoFormationHaptic.orderedMilestones
        where time >= event.triggerTime && !emittedHaptics.contains(event) {
            emittedHaptics.insert(event)
            onHaptic(event)
        }
    }
}

// MARK: - Hero (no chrome — the app supplies the wordmark/buttons)

private struct FormationHero: View {
    let p: Double
    let time: Double
    let glyphs: [Glyph]
    let logoName: String
    let providerDots: [[GDot]]
    let dots: [Dot]

    private var solidFade: Double { smooth((p - 0.60) / 0.20) }
    private var glass: Double { smooth((p - 0.80) / 0.20) }
    private let width = FormationLayout.W
    private let height = FormationLayout.H
    private let cubeS = FormationLayout.cubeS, cubeCX = FormationLayout.cubeCX, cubeCY = FormationLayout.cubeCY
    private let logoCX = FormationLayout.logoCX, logoCY = FormationLayout.logoCY, logoSize = FormationLayout.logoSize

    private func oilSheen() -> some View {
        Group {
            if let cg = oilImage(time, n: 68) {
                Image(decorative: cg, scale: 1).resizable().interpolation(.high)
                    .frame(width: cubeS * 2, height: cubeS * 2)
                    .position(x: cubeCX, y: cubeCY)
                    .blur(radius: 2.5).blendMode(.plusLighter).opacity(0.95)
            }
        }
        .frame(width: width, height: height)
        .clipShape(CubeSil())
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: "F25205").opacity(0.18 * solidFade + 0.05), .clear], center: UnitPoint(x: logoCX / width, y: logoCY / height), startRadius: 0, endRadius: 240)
                .blendMode(.plusLighter)

            Canvas { ctx, _ in
                let conv = p - 0.10
                for d in dots {
                    let local = easeOut((conv - d.delay) / 0.42)
                    let drift = sin(Double(d.driftP) + p * 6.28 * d.driftF) * (p < 0.30 ? 1 : (1 - local))
                    let fx = d.start.x + d.driftA * CGFloat(drift)
                    let fy = d.start.y + d.driftA * CGFloat(cos(Double(d.driftP) + p * 5.0 * d.driftF)) * (p < 0.30 ? 1 : CGFloat(1 - local))
                    let x = lerp(fx, d.target.x, local), y = lerp(fy, d.target.y, local)
                    let appear = smooth(p / 0.12)
                    let alpha = appear * (1 - solidFade * 0.92) * (0.45 + 0.55 * local)
                    if alpha <= 0.01 { continue }
                    let warm = local
                    let cr = 0.55 + (d.r - 0.55) * warm, cg = 0.40 + (d.g - 0.40) * warm, cb = 0.45 + (d.b - 0.45) * warm
                    let ds = d.dotSize * (1 + 0.7 * (1 - local))
                    ctx.opacity = alpha
                    ctx.fill(Path(ellipseIn: CGRect(x: x - ds / 2, y: y - ds / 2, width: ds, height: ds)), with: .color(Color(.sRGB, red: cr, green: cg, blue: cb, opacity: 1)))
                }
            }
            .frame(width: width, height: height)

            if glass > 0.001 {
                GlassCubeAssembly(time: time)
                    .opacity(glass)
            }

            ProviderGlyphConstellationLayer(time: time, glyphs: glyphs, providerDots: providerDots)

            if solidFade > 0.001 {
                Image(logoName).resizable().scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .position(x: logoCX, y: logoCY)
                    .opacity(solidFade)
                    .scaleEffect(0.92 + 0.08 * solidFade)
                    .shadow(color: Color(hex: "FF6A2A").opacity(0.5 * solidFade), radius: 18)
            }

            if glass > 0.001 {
                ZStack {
                    oilSheen()
                    CubeSil().stroke(Color.black.opacity(0.5), lineWidth: max(0.6, cubeS * 0.006))
                    CubeSil().stroke(LinearGradient(colors: [Color.white.opacity(0.3), .clear, Color.black.opacity(0.3)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.8, cubeS * 0.006))
                }.frame(width: width, height: height).opacity(glass)
            }
        }
        .frame(width: width, height: height)
    }
}
