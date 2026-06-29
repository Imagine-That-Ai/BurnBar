import XCTest
import SwiftUI
@testable import OpenBurnBarCore

#if canImport(AppKit)
import AppKit

/// Headless render harness: rasterizes every substrate over a synthetic
/// logo-like point cloud to PNGs so the look can be eyeballed without driving the
/// whole app. Not a CI assertion — run explicitly:
///   swift test --filter SwarmSubstratePreviewRenderTests
@MainActor
final class SwarmSubstratePreviewRenderTests: XCTestCase {

    /// Render ONE substrate (set `SUBSTRATE_PREVIEW_ID=<id>`) to dark+light PNGs,
    /// so a fixer can iterate visually:
    ///   SUBSTRATE_PREVIEW_ID=mesh.mesh-isoline swift test --filter testRenderOnePreview
    func testRenderOnePreview() throws {
        guard let id = ProcessInfo.processInfo.environment["SUBSTRATE_PREVIEW_ID"] else {
            throw XCTSkip("set SUBSTRATE_PREVIEW_ID")
        }
        guard let d = SubstrateCatalog.byID[id] ?? SubstrateCatalog.substrateList.first(where: { $0.id == id }) else {
            XCTFail("unknown substrate id \(id)")
            return
        }
        let outDir = "/tmp/substrate-previews"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let size = CGSize(width: 460, height: 320)
        let dots = Self.syntheticCloud(in: size)
        for dark in [true, false] {
            let substrate = d.make()
            let frame = Self.frame(dots: dots, size: size, dark: dark)
            let img = Self.render(size: size, dark: dark) { ctx in _ = substrate.paint(frame, into: ctx) }
            if let png = img?.pngData() {
                try png.write(to: URL(fileURLWithPath: "\(outDir)/\(id)-\(dark ? "dark" : "light").png"))
            }
        }
        print("RENDERED \(id) → \(outDir)")
    }

    /// Render every bespoke at REAL desktop density — ~900 particles spread over a
    /// full-screen canvas (sparse, ~40–96px spacing), the condition that exposes
    /// "huge piece" sizing bugs. Gated like the others.
    ///   SUBSTRATE_RENDER_PREVIEWS=1 swift test --filter testRenderRealisticDensity
    func testRenderRealisticDensity() throws {
        guard ProcessInfo.processInfo.environment["SUBSTRATE_RENDER_PREVIEWS"] == "1" else {
            throw XCTSkip("set SUBSTRATE_RENDER_PREVIEWS=1")
        }
        let outDir = "/tmp/substrate-previews-real"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // A real macOS dashboard window; 900 particles → match the screen density.
        let size = CGSize(width: 1280, height: 820)
        let dots = Self.realisticSwarmCloud(in: size, count: 760)
        var rendered = 0
        for d in SubstrateCatalog.substrateList where d.id != SubstrateCatalog.plainID {
            let substrate = d.make()
            let frame = Self.frame(dots: dots, size: size, dark: true)
            let img = Self.render(size: size, dark: true) { ctx in _ = substrate.paint(frame, into: ctx) }
            if let png = img?.pngData() {
                try png.write(to: URL(fileURLWithPath: "\(outDir)/\(d.id)-dark.png"))
                rendered += 1
            }
        }
        print("RENDERED \(rendered) realistic previews → \(outDir)")
        XCTAssertGreaterThan(rendered, 0)
    }

    /// Free-swarm field: `count` dots spread quasi-uniformly across the WHOLE
    /// canvas (blue-noise-ish), mirroring the real sparse swarm in non-shape mode.
    private static func realisticSwarmCloud(in size: CGSize, count: Int) -> [SwarmSubstrateDot] {
        var dots: [SwarmSubstrateDot] = []
        let brand = [RGBA(r: 0.80, g: 0.47, b: 0.36), RGBA(r: 0.66, g: 0.40, b: 1.0),
                     RGBA(r: 0.0, g: 0.65, b: 0.49), RGBA(r: 0.26, g: 0.92, b: 0.23),
                     RGBA(r: 0.0, g: 0.65, b: 0.89)]
        var rng = XorShift32(seed: 0xA11CE)
        for i in 0..<count {
            let x = rng.next() * Double(size.width)
            let y = rng.next() * Double(size.height)
            let col = brand[i % brand.count]
            // real particle.size is 0.8…2.3; inShape false in free swarm → radius ~0.85*size
            let sz = 0.8 + rng.next() * 1.5
            dots.append(SwarmSubstrateDot(
                x: x, y: y, vx: rng.next() * 2 - 1, vy: rng.next() * 2 - 1,
                radius: max(0.4, sz * 0.85), baseSize: sz, rgba: col, opacity: 0.85,
                inShape: false, role: nil, slotIndex: i % 5,
                colorIndex: shash(Double(i) * 1.7), flowProgress: 0))
        }
        return dots
    }

    func testRenderAllSubstratePreviews() throws {
        // Dev artifact, not a CI assertion — gated so normal test runs skip it.
        guard ProcessInfo.processInfo.environment["SUBSTRATE_RENDER_PREVIEWS"] == "1" else {
            throw XCTSkip("set SUBSTRATE_RENDER_PREVIEWS=1 to render the preview contact sheet")
        }
        let outDir = "/tmp/substrate-previews"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let size = CGSize(width: 460, height: 320)
        let dots = Self.syntheticCloud(in: size)

        // one bespoke per family + the shared plain, both polarities
        var rendered = 0
        for d in SubstrateCatalog.substrateList where d.id != SubstrateCatalog.plainID {
            for dark in [true, false] {
                let substrate = d.make()
                let frame = Self.frame(dots: dots, size: size, dark: dark)
                let img = Self.render(size: size, dark: dark) { ctx in
                    _ = substrate.paint(frame, into: ctx)
                }
                let name = "\(d.id)-\(dark ? "dark" : "light").png"
                if let png = img?.pngData() {
                    try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
                    rendered += 1
                }
            }
        }
        print("RENDERED \(rendered) previews → \(outDir)")
        XCTAssertGreaterThan(rendered, 0)
    }

    // MARK: - synthetic field (a dense rounded glyph blob with internal structure)

    private static func syntheticCloud(in size: CGSize) -> [SwarmSubstrateDot] {
        // Uniform-density fill of a recognizable 5-point star silhouette — mirrors
        // how the real swarm fills a provider mark (no ring-density artifacts).
        var dots: [SwarmSubstrateDot] = []
        let cx = Double(size.width) * 0.5, cy = Double(size.height) * 0.5
        let radius = Double(min(size.width, size.height)) * 0.44
        let brand = [RGBA(r: 0.80, g: 0.47, b: 0.36), RGBA(r: 0.66, g: 0.40, b: 1.0),
                     RGBA(r: 0.0, g: 0.65, b: 0.49), RGBA(r: 0.26, g: 0.92, b: 0.23),
                     RGBA(r: 0.0, g: 0.65, b: 0.89)]
        // Smoothed 5-point star radius as a function of angle.
        func starR(_ ang: Double) -> Double {
            let spike = abs(cos(ang * 2.5))          // 5 lobes
            return radius * (0.46 + 0.54 * pow(spike, 0.7))
        }
        var rng = XorShift32(seed: 0x5757_BEEF)
        var i = 0
        var tries = 0
        while dots.count < 820 && tries < 400_000 {
            tries += 1
            let x = (rng.next() * 2 - 1) * radius
            let y = (rng.next() * 2 - 1) * radius
            let r = (x * x + y * y).squareRoot()
            let ang = atan2(y, x)
            guard r <= starR(ang) else { continue }
            // spatially-coherent color (by angular sector) so flow/streamline reads.
            let sector = Int((ang + .pi) / (2 * .pi) * 5) % 5
            let col = brand[sector]
            dots.append(SwarmSubstrateDot(
                x: cx + x, y: cy + y, vx: -sin(ang), vy: cos(ang),
                radius: 1.7, baseSize: 1.55, rgba: col, opacity: 0.92,
                inShape: true, role: nil, slotIndex: sector,
                colorIndex: shash(Double(i) * 1.7), flowProgress: 0))
            i += 1
        }
        return dots
    }

    private static func frame(dots: [SwarmSubstrateDot], size: CGSize, dark: Bool) -> SwarmSubstrateFrame {
        var sumX = 0.0, sumY = 0.0
        for d in dots { sumX += d.x; sumY += d.y }
        let n = Double(max(1, dots.count))
        let cx = sumX / n, cy = sumY / n
        var dsum = 0.0
        for d in dots { dsum += hypot(d.x - cx, d.y - cy) }
        let accent = RGBA(r: 0.96, g: 0.31, b: 0.36)
        let stage = SubstrateStage(
            accent: accent,
            accent2: RGBA(r: 0.55, g: 0.78, b: 1.0),
            ink: dark ? RGBA(r: 0.9, g: 0.93, b: 1.0) : RGBA(r: 0.1, g: 0.1, b: 0.14),
            dark: dark)
        return SwarmSubstrateFrame(
            size: size, dark: dark, reduced: false, batteryThrottled: false,
            uiMode: .standard, isShapeMode: true, formed: true, settleProgress: 1.0,
            t: 12.34, dt: 1.0, stage: stage, backdrop: nil, dots: dots,
            cx: cx, cy: cy, cloudRadius: dsum / n, sizePx: 1.7,
            structure: SubstrateStructureProvider())
    }

    private static func render(size: CGSize, dark: Bool, _ draw: @escaping (inout GraphicsContext) -> Void) -> NSImage? {
        let scale: CGFloat = 2
        let view = ZStack {
            (dark ? Color(red: 0.02, green: 0.02, blue: 0.03) : Color(red: 0.95, green: 0.94, blue: 0.91))
            Canvas { ctx, _ in
                var c = ctx
                draw(&c)
            }
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.nsImage
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
