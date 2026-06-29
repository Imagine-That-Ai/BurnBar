import SwiftUI
import CoreGraphics
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Substrate port kit
//
// Native port of the imaginethat-llc `kit-math.ts` / `kit-draw.ts` helpers, so
// every bespoke substrate author writes against the same primitives with zero
// cross-coordination. All symbols live in `OpenBurnBarCore`; ports import nothing
// extra.

public let TAU: Double = .pi * 2

@inline(__always) public func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    v < lo ? lo : (v > hi ? hi : v)
}
@inline(__always) public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) public func frac(_ x: Double) -> Double { x - floor(x) }
@inline(__always) public func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clampD((x - e0) / (e1 - e0 == 0 ? 1 : e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Cheap, well-distributed hash → 0…1 (matches the source `hash` flavor:
/// `frac(sin(x)*43758.5453)`). Deterministic; good for per-point phase/jitter.
@inline(__always) public func shash(_ x: Double) -> Double { frac(sin(x * 91.7 + 13.13) * 43758.5453) }
@inline(__always) public func shash2(_ x: Double, _ y: Double) -> Double { frac(sin(x * 91.7 + y * 47.13 + 13.13) * 43758.5453) }

/// 0…1 "breathing" oscillator. `phase` offsets per-point; `rate` scales speed.
@inline(__always) public func breathe(_ t: Double, phase: Double = 0, rate: Double = 1) -> Double {
    0.5 + 0.5 * sin(t * rate + phase)
}

/// Tiny deterministic RNG for per-point variation that must be stable per layout.
public struct XorShift32 {
    private var s: UInt32
    public init(seed: UInt32 = 0x1234_5678) { s = seed == 0 ? 0x1234_5678 : seed }
    public mutating func nextU() -> UInt32 { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s }
    /// Next Double in 0..<1.
    public mutating func next() -> Double { Double(nextU() >> 8) / Double(1 << 24) }
    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
}

// MARK: - RGBA conveniences for ports

public extension RGBA {
    /// Bridge a SwiftUI `Color` to numeric sRGB channels (one conversion / frame,
    /// not per dot). Falls back to ember if the color can't be resolved.
    init(_ color: Color, fallback: RGBA = RGBA(r: 0.96, g: 0.31, b: 0.36)) {
        #if canImport(AppKit)
        if let ns = NSColor(color).usingColorSpace(.sRGB) {
            self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                      b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
            return
        }
        #elseif canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a)); return
        }
        #endif
        self = fallback
    }

    func withOpacity(_ o: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: clampD(o, 0, 1)) }
    /// Push toward white by `amount` (keeps alpha) — the common "hot core" move.
    func toWhite(_ amount: Double) -> RGBA { mix(with: RGBA(r: 1, g: 1, b: 1, a: a), amount: amount) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// MARK: - Shape vocabulary (mirrors kit-draw.ts drawShape)

public enum SubstrateShape: Sendable {
    case dot, bead, ring, shard, streak, ribbon, bar
}

/// Paint one primitive at (x,y) sized `sz`, oriented by velocity (vx,vy) or `rot`.
/// Matches `kit-draw.ts` semantics closely enough for faithful parity.
public func drawShape(_ ctx: inout GraphicsContext, _ shape: SubstrateShape,
                      x: Double, y: Double, sz: Double, rgba: RGBA,
                      vx: Double = 0, vy: Double = 0, rot: Double = 0) {
    let color = GraphicsContext.Shading.color(rgba.color)
    switch shape {
    case .dot:
        ctx.fill(Path(ellipseIn: CGRect(x: x - sz, y: y - sz, width: sz * 2, height: sz * 2)), with: color)
    case .bead:
        ctx.fill(Path(ellipseIn: CGRect(x: x - sz, y: y - sz, width: sz * 2, height: sz * 2)), with: color)
        let sr = sz * 0.42
        ctx.fill(Path(ellipseIn: CGRect(x: x - sz * 0.35 - sr, y: y - sz * 0.35 - sr, width: sr * 2, height: sr * 2)),
                 with: .color(.white.opacity(0.5 * rgba.a)))
    case .ring:
        let p = Path(ellipseIn: CGRect(x: x - sz, y: y - sz, width: sz * 2, height: sz * 2))
        ctx.stroke(p, with: color, lineWidth: max(0.6, sz * 0.34))
    case .shard:
        let a = rot != 0 ? rot : atan2(vy, vx)
        var p = Path()
        for i in 0..<3 {
            let ang = a + Double(i) * (TAU / 3)
            let px = x + cos(ang) * sz, py = y + sin(ang) * sz
            if i == 0 { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
        }
        p.closeSubpath()
        ctx.fill(p, with: color)
    case .streak:
        let a = rot != 0 ? rot : atan2(vy, vx)
        let dx = cos(a) * sz, dy = sin(a) * sz
        var p = Path()
        p.move(to: CGPoint(x: x - dx, y: y - dy))
        p.addLine(to: CGPoint(x: x + dx, y: y + dy))
        ctx.stroke(p, with: color, style: StrokeStyle(lineWidth: max(0.6, sz * 0.55), lineCap: .round))
    case .ribbon:
        let a = rot != 0 ? rot : atan2(vy, vx)
        let dx = cos(a) * sz * 1.6, dy = sin(a) * sz * 1.6
        var p = Path()
        p.move(to: CGPoint(x: x - dx, y: y - dy))
        p.addLine(to: CGPoint(x: x + dx, y: y + dy))
        ctx.stroke(p, with: color, style: StrokeStyle(lineWidth: max(0.8, sz * 0.9), lineCap: .round))
    case .bar:
        let a = rot
        let t = CGAffineTransform(translationX: x, y: y).rotated(by: a)
        let rect = CGRect(x: -sz, y: -sz * 0.42, width: sz * 2, height: sz * 0.84)
        let p = Path(roundedRect: rect, cornerRadius: sz * 0.2).applying(t)
        ctx.fill(p, with: color)
        _ = t
    }
}

// MARK: - Sprite cache (cached radial sprites; never re-bake per frame)

/// Per-instance cache of small radial sprites (white glow, frost, spark, ember…).
/// Built once via CoreGraphics, keyed by (diameter, stops). Each substrate owns
/// one; ports `resolve` the returned `Image` once per frame then draw it many.
public final class SpriteCache {
    private var cache: [Int: Image] = [:]
    public init() {}

    /// A radial-gradient sprite. `stops` are (location 0…1, color).
    public func radial(diameter: Int = 64, stops: [(loc: Double, rgba: RGBA)]) -> Image {
        var h = Hasher(); h.combine(diameter)
        for s in stops { h.combine(Int(s.loc * 1000)); h.combine(s.rgba.bucketKey) }
        let key = h.finalize()
        if let img = cache[key] { return img }
        let img = Self.makeRadial(diameter: max(2, diameter), stops: stops)
        cache[key] = img
        return img
    }

    /// The canonical additive white glow (matches starfire's 64px sprite).
    public func whiteGlow(diameter: Int = 64) -> Image {
        radial(diameter: diameter, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.22, RGBA(r: 1, g: 1, b: 1, a: 0.55)),
            (0.5, RGBA(r: 1, g: 1, b: 1, a: 0.14)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ])
    }

    /// A tinted soft glow (for colored bloom halos).
    public func tintedGlow(_ rgba: RGBA, diameter: Int = 64) -> Image {
        radial(diameter: diameter, stops: [
            (0.0, rgba.withOpacity(0.9)),
            (0.35, rgba.withOpacity(0.32)),
            (1.0, rgba.withOpacity(0.0))
        ])
    }

    private static func makeRadial(diameter: Int, stops: [(loc: Double, rgba: RGBA)]) -> Image {
        let s = diameter
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // jsdom-equivalent fallback: a 1px transparent image.
            return Image(systemName: "circle.fill")
        }
        let colors = stops.map { $0.rgba.cgColor } as CFArray
        let locs = stops.map { CGFloat($0.loc) }
        let c = CGFloat(s) / 2
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs) {
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: c, y: c), startRadius: 0,
                                   endCenter: CGPoint(x: c, y: c), endRadius: c, options: [])
        }
        if let cg = ctx.makeImage() {
            return Image(decorative: cg, scale: 1)
        }
        return Image(systemName: "circle.fill")
    }
}

// MARK: - Structure provider (NN order + kNN, cached by topology signature)

/// Lazily-built point-cloud structure for lattice / stroke / sketch idioms:
/// a single-stroke nearest-neighbor walk (`order`), per-point k-NN lists
/// (`neighbors`), and segment-break flags for polylines (`breaks`). Rebuilds only
/// when the topology signature changes, so it's free for styles that ignore it.
public final class SubstrateStructureProvider {
    public struct Structure: Sendable {
        public let order: [Int]
        public let neighbors: [[Int]]
        public let breaks: [Bool]
        public init(order: [Int], neighbors: [[Int]], breaks: [Bool]) {
            self.order = order; self.neighbors = neighbors; self.breaks = breaks
        }
    }

    private var cached: Structure?
    private var sig: UInt64 = .max
    private var cachedK: Int = -1
    public init() {}

    public func structure(for dots: [SwarmSubstrateDot], k: Int = 6) -> Structure {
        let s = Self.signature(dots)
        if let c = cached, s == sig, cachedK == k { return c }
        let built = Self.build(dots, k: k)
        cached = built; sig = s; cachedK = k
        return built
    }

    /// Cheap topology fingerprint: count + coarse centroid + a strided position hash.
    private static func signature(_ dots: [SwarmSubstrateDot]) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        @inline(__always) func mix(_ v: Int) { h = (h ^ UInt64(bitPattern: Int64(v))) &* 1099511628211 }
        mix(dots.count)
        let stride = max(1, dots.count / 64)
        var i = 0
        while i < dots.count {
            let d = dots[i]
            mix(Int((d.x * 0.5).rounded()))
            mix(Int((d.y * 0.5).rounded()))
            i += stride
        }
        return h
    }

    private static func build(_ dots: [SwarmSubstrateDot], k: Int) -> Structure {
        let n = dots.count
        guard n > 1 else {
            return Structure(order: Array(0..<n), neighbors: Array(repeating: [], count: n), breaks: Array(repeating: false, count: n))
        }
        // Uniform grid over the bounding box for O(n) neighbor queries.
        var minX = dots[0].x, minY = dots[0].y, maxX = dots[0].x, maxY = dots[0].y
        for d in dots { minX = min(minX, d.x); minY = min(minY, d.y); maxX = max(maxX, d.x); maxY = max(maxY, d.y) }
        let w = max(1, maxX - minX), hgt = max(1, maxY - minY)
        let cell = max(4.0, sqrt(w * hgt / Double(n)))   // ~1 point per cell
        let cols = max(1, Int(w / cell) + 1), rows = max(1, Int(hgt / cell) + 1)
        @inline(__always) func cellOf(_ d: SwarmSubstrateDot) -> (Int, Int) {
            (min(cols - 1, max(0, Int((d.x - minX) / cell))), min(rows - 1, max(0, Int((d.y - minY) / cell))))
        }
        var grid = [[Int]](repeating: [], count: cols * rows)
        for i in 0..<n { let (cx, cy) = cellOf(dots[i]); grid[cy * cols + cx].append(i) }

        @inline(__always) func candidates(_ i: Int, ring: Int) -> [Int] {
            let (gx, gy) = cellOf(dots[i])
            var out: [Int] = []
            for yy in max(0, gy - ring)...min(rows - 1, gy + ring) {
                for xx in max(0, gx - ring)...min(cols - 1, gx + ring) {
                    out.append(contentsOf: grid[yy * cols + xx])
                }
            }
            return out
        }

        // kNN per point (expand ring until enough candidates).
        var neighbors = [[Int]](repeating: [], count: n)
        var nnDist = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var ring = 1
            var cand = candidates(i, ring: ring)
            while cand.count < k + 1 && ring < max(cols, rows) { ring += 1; cand = candidates(i, ring: ring) }
            let xi = dots[i].x, yi = dots[i].y
            let sorted = cand.filter { $0 != i }
                .map { (j: $0, d: (dots[$0].x - xi) * (dots[$0].x - xi) + (dots[$0].y - yi) * (dots[$0].y - yi)) }
                .sorted { $0.d < $1.d }
            neighbors[i] = sorted.prefix(k).map { $0.j }
            nnDist[i] = sorted.first.map { sqrt($0.d) } ?? cell
        }

        // Median nearest-neighbor distance → polyline break threshold.
        let medianNN = nnDist.sorted()[n / 2]
        let breakThresh = max(cell, medianNN * 3.0)

        // Greedy nearest-neighbor walk for a single stroke order. Start nearest centroid.
        var cxs = 0.0, cys = 0.0
        for d in dots { cxs += d.x; cys += d.y }
        cxs /= Double(n); cys /= Double(n)
        var start = 0, bestD = Double.infinity
        for i in 0..<n {
            let dd = (dots[i].x - cxs) * (dots[i].x - cxs) + (dots[i].y - cys) * (dots[i].y - cys)
            if dd < bestD { bestD = dd; start = i }
        }
        var visited = [Bool](repeating: false, count: n)
        var order = [Int](); order.reserveCapacity(n)
        var breaks = [Bool](); breaks.reserveCapacity(n)
        var cur = start
        visited[cur] = true; order.append(cur)
        for _ in 1..<n {
            // search expanding rings for nearest unvisited
            var ring = 1, picked = -1, pickedD = Double.infinity
            while picked == -1 && ring <= max(cols, rows) {
                for j in candidates(cur, ring: ring) where !visited[j] {
                    let dd = (dots[j].x - dots[cur].x) * (dots[j].x - dots[cur].x) + (dots[j].y - dots[cur].y) * (dots[j].y - dots[cur].y)
                    if dd < pickedD { pickedD = dd; picked = j }
                }
                ring += 1
            }
            if picked == -1 { // fallback linear scan (disconnected remainder)
                for j in 0..<n where !visited[j] {
                    let dd = (dots[j].x - dots[cur].x) * (dots[j].x - dots[cur].x) + (dots[j].y - dots[cur].y) * (dots[j].y - dots[cur].y)
                    if dd < pickedD { pickedD = dd; picked = j }
                }
            }
            guard picked >= 0 else { break }
            breaks.append(sqrt(pickedD) > breakThresh)
            visited[picked] = true; order.append(picked); cur = picked
        }
        // breaks has order.count-1 entries; pad to align with order indices.
        breaks.append(false)
        return Structure(order: order, neighbors: neighbors, breaks: breaks)
    }
}

// MARK: - Color ramps (iris jewel ramp + altitude ramps), ported from kit

public enum SubstrateRamp {
    /// 6-stop iris jewel ramp used by the mesh/moire families.
    public static let iris: [RGBA] = [
        RGBA(r: 0.42, g: 0.36, b: 1.0),   // iris
        RGBA(r: 0.30, g: 0.72, b: 0.96),  // cyan
        RGBA(r: 0.36, g: 0.95, b: 0.78),  // mint
        RGBA(r: 1.0, g: 0.82, b: 0.36),  // gold
        RGBA(r: 1.0, g: 0.45, b: 0.62),  // rose
        RGBA(r: 0.67, g: 0.40, b: 1.0)   // violet
    ]

    /// Sample a ramp at 0…1 with linear interpolation (wraps).
    public static func sample(_ ramp: [RGBA], _ t: Double) -> RGBA {
        guard ramp.count > 1 else { return ramp.first ?? RGBA(r: 1, g: 1, b: 1) }
        let x = frac(t) * Double(ramp.count - 1)
        let i = Int(floor(x)), f = x - Double(i)
        let a = ramp[i], b = ramp[min(ramp.count - 1, i + 1)]
        return a.mix(with: b, amount: f)
    }
}
