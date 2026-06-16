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

public struct BurnBarLogoFormationView: View {
    /// Names of the provider logo assets to swarm (must exist in the app bundle).
    private let providerNames: [String]
    /// The brand mark asset name.
    private let logoName: String

    public init(
        logoName: String = "AppLogo",
        providerNames: [String] = [
            "AnthropicLogo", "OpenAILogo", "GoogleLogo", "MistralLogo",
            "MetaLogo", "GrokLogo", "DeepSeekLogo", "QwenLogo",
        ]
    ) {
        self.logoName = logoName
        self.providerNames = providerNames
    }

    public var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / FormationLayout.W, geo.size.height / FormationLayout.H)
            FormationDriver(logoName: logoName, providerNames: providerNames)
                .frame(width: FormationLayout.W, height: FormationLayout.H)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel("OpenBurnBar")
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
private struct Glyph { var pos: CGPoint; var vel: CGVector; var prov: Int; var flash: Double; var formT: Double; var seed: UInt64 }

private let glyphStartT = 5.8

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
        let tx = FormationLayout.logoOX + n.x * FormationLayout.logoSize
        let ty = FormationLayout.logoOY + n.y * FormationLayout.logoSize
        let ang = rng.next() * 2 * Double.pi
        let rad = (0.35 + rng.next() * 0.75) * Double(max(FormationLayout.W, FormationLayout.H)) * 0.6
        let sx = FormationLayout.logoCX + CGFloat(cos(ang) * rad), sy = FormationLayout.logoCY + CGFloat(sin(ang) * rad)
        let delay = 0.04 + rng.next() * 0.22 + Double(n.y) * 0.06
        dots.append(Dot(target: CGPoint(x: tx, y: ty), start: CGPoint(x: sx, y: sy), r: r, g: g, b: b,
                        delay: min(delay, 0.30), driftA: CGFloat(8 + rng.next() * 22),
                        driftF: 0.5 + rng.next() * 1.3, driftP: rng.next() * 6.28, dotSize: 2.2 + rng.next() * 2.2))
    }
    return dots
}

private func sampleGlyphDots(_ name: String, grid: Int = 40, maxDots: Int = 220) -> [GDot] {
    guard let img = loadPixels(name) else { return [] }
    var pts: [GDot] = []
    for gy in 0 ..< grid { for gx in 0 ..< grid {
        let px = Int((Double(gx) + 0.5) / Double(grid) * Double(img.w))
        let py = Int((Double(gy) + 0.5) / Double(grid) * Double(img.h))
        var (r, g, b, a) = img.sample(px, py)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        if a > 0.4 && lum < 0.985 {
            let mx = max(r, max(g, b))
            if mx < 0.06 { r = 0.92; g = 0.94; b = 0.97 }
            else if mx < 0.62 { let s = 0.62 / mx; r = min(1, r * s); g = min(1, g * s); b = min(1, b * s) }
            pts.append(GDot(p: CGPoint(x: Double(gx) / Double(grid - 1) - 0.5, y: Double(gy) / Double(grid - 1) - 0.5), r: r, g: g, b: b))
        }
    }}
    if pts.count > maxDots {
        let step = Double(pts.count) / Double(maxDots)
        pts = (0 ..< maxDots).map { pts[min(Int(Double($0) * step), pts.count - 1)] }
    }
    return pts
}

private func scatterOffset(_ seed: UInt64, _ k: Int) -> CGPoint {
    var s = seed &+ (UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15)
    s ^= s >> 33; s = s &* 0xFF51_AFD7_ED55_8CCD; s ^= s >> 33
    let a = Double(s % 10000) / 10000.0 * 2 * Double.pi
    let r = 30 + Double((s >> 20) % 10000) / 10000.0 * 55
    return CGPoint(x: cos(a) * r, y: sin(a) * r)
}

/// Sampled assets, computed once on the main actor (the marks rarely change).
@MainActor private final class FormationAssets {
    let dots: [Dot]
    let providerDots: [[GDot]]
    init(logoName: String, providerNames: [String]) {
        dots = sampleDots(logoName)
        providerDots = providerNames.map { sampleGlyphDots($0) }
    }
}

// MARK: - Isometric cube geometry

private struct CubePts { let A, B, C, D, E, F, G: CGPoint }
private func cubePoints() -> CubePts {
    let cx = FormationLayout.cubeCX, cy = FormationLayout.cubeCY, s = FormationLayout.cubeS
    func P(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: cx + (x - y) * 0.866 * s, y: cy + ((x + y) * 0.5 - z) * s)
    }
    return CubePts(A: P(0, 0, 1), B: P(1, 0, 1), C: P(1, 1, 1), D: P(0, 1, 1), E: P(1, 0, 0), F: P(1, 1, 0), G: P(0, 1, 0))
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
private struct CubeSil: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.A, p.B, p.E, p.F, p.G, p.D], FormationLayout.cubeS * 0.09) } }
private struct CubeTopF: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.A, p.B, p.C, p.D], FormationLayout.cubeS * 0.05) } }
private struct CubeLeftF: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.D, p.C, p.F, p.G], FormationLayout.cubeS * 0.05) } }
private struct CubeRightF: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); return roundedPoly([p.B, p.E, p.F, p.C], FormationLayout.cubeS * 0.05) } }
private struct CubeTopEdge: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); var pa = Path(); pa.move(to: p.D); pa.addLine(to: p.C); pa.addLine(to: p.B); return pa } }
private struct CubeFrontEdge: Shape { func path(in _: CGRect) -> Path { let p = cubePoints(); var pa = Path(); pa.move(to: p.C); pa.addLine(to: p.F); return pa } }

// MARK: - Glyph physics

@MainActor private final class FormationSim: ObservableObject {
    @Published var t: Double = 0
    @Published var glyphs: [Glyph] = []
    private var timer: Timer?
    private let dt = 1.0 / 45.0
    private let providerCount: Int

    init(providerCount: Int) { self.providerCount = max(1, providerCount) }

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

    private func seed() {
        let n = providerCount
        let W = FormationLayout.W
        glyphs = (0 ..< 3).map { i in
            Glyph(pos: CGPoint(x: .random(in: 120 ... (W - 120)), y: .random(in: 115 ... 345)),
                  vel: CGVector(dx: .random(in: -14 ... 14), dy: .random(in: -14 ... 14)),
                  prov: (i * 3) % n, flash: 0, formT: 0, seed: .random(in: 0 ... UInt64.max))
        }
    }
    private func step() {
        t += dt
        guard t > glyphStartT else { return }
        let r: CGFloat = 44, n = providerCount, W = FormationLayout.W
        for i in glyphs.indices {
            glyphs[i].pos.x += glyphs[i].vel.dx * CGFloat(dt)
            glyphs[i].pos.y += glyphs[i].vel.dy * CGFloat(dt)
            if glyphs[i].pos.x < 85 { glyphs[i].pos.x = 85; glyphs[i].vel.dx = abs(glyphs[i].vel.dx) }
            if glyphs[i].pos.x > W - 85 { glyphs[i].pos.x = W - 85; glyphs[i].vel.dx = -abs(glyphs[i].vel.dx) }
            if glyphs[i].pos.y < 100 { glyphs[i].pos.y = 100; glyphs[i].vel.dy = abs(glyphs[i].vel.dy) }
            if glyphs[i].pos.y > 360 { glyphs[i].pos.y = 360; glyphs[i].vel.dy = -abs(glyphs[i].vel.dy) }
            if glyphs[i].flash > 0 { glyphs[i].flash = max(0, glyphs[i].flash - dt * 2.2) }
            if glyphs[i].formT < 1 { glyphs[i].formT = min(1, glyphs[i].formT + dt / 1.6) }
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
                    if n > 1 {
                        glyphs[i].prov = (glyphs[i].prov + Int.random(in: 1 ..< n)) % n
                        glyphs[j].prov = (glyphs[j].prov + Int.random(in: 1 ..< n)) % n
                    }
                    glyphs[i].formT = 0; glyphs[i].seed = .random(in: 0 ... UInt64.max)
                    glyphs[j].formT = 0; glyphs[j].seed = .random(in: 0 ... UInt64.max)
                    glyphs[i].flash = 1; glyphs[j].flash = 1
                }
            }
        }
    }
}

// MARK: - Driver

private struct FormationDriver: View {
    let logoName: String
    let providerNames: [String]
    @StateObject private var sim: FormationSim
    @State private var assets: FormationAssets?

    init(logoName: String, providerNames: [String]) {
        self.logoName = logoName
        self.providerNames = providerNames
        _sim = StateObject(wrappedValue: FormationSim(providerCount: providerNames.count))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { _ in
            FormationHero(p: min(sim.t / 5.0, 1.0), time: sim.t, glyphs: sim.glyphs,
                          logoName: logoName, providerDots: assets?.providerDots ?? [], dots: assets?.dots ?? [])
        }
        .onAppear {
            if assets == nil { assets = FormationAssets(logoName: logoName, providerNames: providerNames) }
            sim.start()
        }
        .onDisappear { sim.stop() }
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
    private let W = FormationLayout.W, H = FormationLayout.H
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
        .frame(width: W, height: H)
        .clipShape(CubeSil())
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: "F25205").opacity(0.18 * solidFade + 0.05), .clear], center: UnitPoint(x: logoCX / W, y: logoCY / H), startRadius: 0, endRadius: 240)
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
            .frame(width: W, height: H)

            if glass > 0.001 {
                let pts = cubePoints()
                ZStack {
                    Ellipse().fill(Color.black.opacity(0.5))
                        .frame(width: cubeS * 1.7, height: cubeS * 0.46).blur(radius: cubeS * 0.18)
                        .position(x: cubeCX, y: pts.F.y + cubeS * 0.1)
                    ZStack {
                        CubeRightF().fill(LinearGradient(colors: [Color(hex: "171924"), Color(hex: "0C0D14")], startPoint: .top, endPoint: .bottom))
                        CubeLeftF().fill(LinearGradient(colors: [Color(hex: "21232F"), Color(hex: "15161F")], startPoint: .top, endPoint: .bottom))
                        CubeTopF().fill(LinearGradient(colors: [Color(hex: "3B3D49"), Color(hex: "2C2E38")], startPoint: .top, endPoint: .bottom))
                    }.clipShape(CubeSil())

                    let glyphAppear = smooth((time - glyphStartT) / 1.2)
                    if glyphAppear > 0.001, !providerDots.isEmpty {
                        Canvas { ctx, _ in
                            let scale: CGFloat = 98
                            for gl in glyphs {
                                guard providerDots.indices.contains(gl.prov) else { continue }
                                let gd = providerDots[gl.prov]
                                let f = easeOut(gl.formT)
                                for (k, d) in gd.enumerated() {
                                    let tx = gl.pos.x + d.p.x * scale, ty = gl.pos.y + d.p.y * scale
                                    let off = scatterOffset(gl.seed, k)
                                    let sx = gl.pos.x + off.x * 1.5, sy = gl.pos.y + off.y * 1.5
                                    let x = sx + (tx - sx) * CGFloat(f), y = sy + (ty - sy) * CGFloat(f)
                                    let alpha = min(1.0, glyphAppear * (0.22 + 0.78 * f) * (0.92 + 0.5 * gl.flash))
                                    if alpha < 0.02 { continue }
                                    ctx.opacity = alpha
                                    let ds: CGFloat = 3.1 + 1.8 * gl.flash
                                    ctx.fill(Path(ellipseIn: CGRect(x: x - ds / 2, y: y - ds / 2, width: ds, height: ds)), with: .color(Color(.sRGB, red: d.r, green: d.g, blue: d.b, opacity: 1)))
                                }
                            }
                        }
                        .frame(width: W, height: H).blendMode(.plusLighter).allowsHitTesting(false)
                    }

                    if #available(iOS 26.0, macOS 26.0, *) {
                        Color.clear.frame(width: W, height: H).glassEffect(.regular, in: CubeSil())
                    }

                    ZStack {
                        CubeTopF().fill(RadialGradient(colors: [Color.white.opacity(0.18), .clear], center: UnitPoint(x: 0.38, y: 0.18), startRadius: 0, endRadius: cubeS)).blendMode(.plusLighter)
                        RadialGradient(colors: [Color(hex: "F25205").opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: cubeS * 0.66)
                            .frame(width: cubeS * 1.6, height: cubeS * 1.6).position(x: cubeCX, y: cubeCY + cubeS * 0.18).blendMode(.plusLighter)
                    }.clipShape(CubeSil())

                    ZStack {
                        CubeTopEdge().stroke(Color(hex: "6E7180").opacity(0.85), lineWidth: max(1, cubeS * 0.012))
                        CubeTopEdge().stroke(Color.white.opacity(0.16), lineWidth: max(0.5, cubeS * 0.004))
                        CubeFrontEdge().stroke(LinearGradient(colors: [Color(hex: "5C5E6C"), Color(hex: "23242C")], startPoint: .top, endPoint: .bottom), lineWidth: max(1, cubeS * 0.012))
                    }.clipShape(CubeSil())
                }.frame(width: W, height: H).opacity(glass)
            }

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
                }.frame(width: W, height: H).opacity(glass)
            }
        }
        .frame(width: W, height: H)
    }
}
