import AppKit
import Metal
import SwiftUI
import XCTest

@testable import OpenBurnBar

// MARK: - Glass proof harness
//
// The material is judged by eye, so it has to be *seen*. Contrast maths
// (`BackdropLegiblePlateTests`) proves the ink is readable; nothing in the suite says
// whether the plate reads as glass. This rasterises plates over a deliberately hostile
// backdrop — hard 45° edges, saturated hue blocks, a conic colour wheel — and writes
// PNGs a human (or an agent that can look at images) can open.
//
// Why that backdrop: refraction is a *displacement* and dispersion is a *per-channel*
// displacement. Both are invisible over a smooth ground and unmistakable over a hard
// edge, because the edge lands in a different place per channel and the fringe is the
// proof. A colour wheel adds a continuous hue sweep so scatter and internal reflection
// have something to carry.
//
// The three boards answer one question each:
//
//   01  the shipping composition — `content.background(substrate).modifier(lens)`.
//   02  the same optics with the backdrop *inside* the lensed layer.
//   03  the spec ladder, both compositions, five personalities, one frame.
//
// `layerEffect` samples only the layer it is attached to. In 01 that layer is
// `substrate + text`; in 02 it is `backdrop`. If 01 and 02 differ, the difference is
// what the substrate costs.
//
// 00 is the control: the bare backdrop. Board 02 is diffed against it inside the test,
// because "the lens does nothing" and "the renderer never ran the lens" produce the
// same flat picture and must not be confused. If the diff is ~0 the shader did not
// execute and every visual conclusion drawn from these files is void — so the test
// says so out loud rather than letting someone read a rendering limitation as a
// design finding.

@MainActor
final class GlassProofSnapshots: XCTestCase {

    // MARK: - Geometry

    private static let cardSize = CGSize(width: 520, height: 320)
    private static let cardPlate = CGRect(x: 40, y: 40, width: 440, height: 240)
    /// The shipping default (`DesignSystem.Radius.lg`), so 02 is geometrically identical
    /// to 01 and the only variable is where the lens gets its pixels.
    private static let plateRadius = DesignSystem.Radius.lg

    private static let ladderSpecs: [(String, GlassSpec)] = [
        ("ledger", .ledger),
        ("cockpit", .cockpit),
        ("focus", .focus),
        ("bento", .bento),
        ("canvas", .canvas)
    ]

    // MARK: - The proof

    func test_writeGlassProofBoards() throws {
        // A headless box with no Metal device resolves to `.flat`, which renders a
        // substrate-only plate that looks exactly like the bug under investigation. Pin
        // the tier so a missing GPU shows up in the log rather than posing as evidence.
        setenv("OPENBURNBAR_FORCE_MATERIAL_TIER", "shader", 1)
        defer { unsetenv("OPENBURNBAR_FORCE_MATERIAL_TIER") }

        let directory = try Self.outputDirectory()
        print("[glass-proof] tier=\(MaterialTier.resolved) metal=\(MTLCreateSystemDefaultDevice() != nil)")
        print("[glass-proof] directory=\(directory.path)")

        // 00 — control. Also the reference the shader-executed check is made against.
        let backdrop = try render(
            GlassProofBackdrop().frame(width: Self.cardSize.width, height: Self.cardSize.height)
        )
        try write(backdrop, named: "00-backdrop.png", into: directory)

        // 01 — the material exactly as it ships.
        let shipping = try render(
            ProofBoard(
                canvas: Self.cardSize,
                radius: Self.plateRadius,
                plates: [
                    ProofPlate(
                        rect: Self.cardPlate,
                        spec: .canvas,
                        style: .shipping,
                        caption: "SHIPPING · substrate under the lens",
                        value: "$128.40"
                    )
                ]
            )
        )
        try write(shipping, named: "01-current-architecture.png", into: directory)

        // 02 — the same optics, same spec, same geometry, backdrop inside the layer.
        let lensed = try render(
            ProofBoard(
                canvas: Self.cardSize,
                radius: Self.plateRadius,
                plates: [
                    ProofPlate(
                        rect: Self.cardPlate,
                        spec: .canvas,
                        style: .lensed,
                        caption: "LENSED · backdrop inside the layer",
                        value: "$128.40"
                    )
                ]
            )
        )
        try write(lensed, named: "02-lens-over-backdrop.png", into: directory)

        // 03 — five personalities × both compositions.
        try write(try render(Self.ladderBoard()), named: "03-spec-ladder.png", into: directory)

        // MARK: Numeric receipts
        //
        // Printed rather than asserted: this file exists to produce evidence, and a
        // threshold on "how much did the picture change" would be a guess wearing an
        // assertion's clothes. The one thing that *is* asserted is that the renderer
        // executed the shader at all, because every visual reading depends on it.
        let lensDelta = Self.meanAbsoluteDifference(lensed, backdrop)
        let shippingDelta = Self.meanAbsoluteDifference(shipping, backdrop)
        let plateOnly = Self.plateRegionInPixels(scale: 2)
        let lensDeltaInPlate = Self.meanAbsoluteDifference(lensed, backdrop, region: plateOnly)
        print(String(
            format: "[glass-proof] mean |Δ| vs bare backdrop — lensed %.2f/255 (plate only %.2f), shipping %.2f/255",
            lensDelta, lensDeltaInPlate, shippingDelta
        ))
        print(String(
            format: "[glass-proof] interior structure (std-dev of luma inside the plate) — backdrop %.2f, shipping %.2f, lensed %.2f",
            Self.lumaStandardDeviation(backdrop, region: plateOnly),
            Self.lumaStandardDeviation(shipping, region: plateOnly),
            Self.lumaStandardDeviation(lensed, region: plateOnly)
        ))

        XCTAssertGreaterThan(
            lensDeltaInPlate, 0.5,
            """
            `burnBarGlassLens` left the backdrop bit-identical inside the plate. \
            That means this renderer did not execute the layer effect, so these PNGs \
            show the renderer's limits, not the material's — do not read them as design \
            evidence until this passes.
            """
        )
    }

    // MARK: - Boards

    private static func ladderBoard() -> some View {
        let columns = ladderSpecs.count
        let plateSize = CGSize(width: 200, height: 230)
        let gutter: CGFloat = 24
        let margin: CGFloat = 32
        let headerHeight: CGFloat = 34
        let rowGap: CGFloat = 30

        let canvas = CGSize(
            width: margin * 2 + CGFloat(columns) * plateSize.width + CGFloat(columns - 1) * gutter,
            height: margin * 2 + headerHeight + plateSize.height * 2 + rowGap + headerHeight
        )

        func rect(column: Int, row: Int) -> CGRect {
            CGRect(
                x: margin + CGFloat(column) * (plateSize.width + gutter),
                y: margin + headerHeight + CGFloat(row) * (plateSize.height + rowGap + headerHeight),
                width: plateSize.width,
                height: plateSize.height
            )
        }

        var plates: [ProofPlate] = []
        for (column, entry) in ladderSpecs.enumerated() {
            plates.append(
                ProofPlate(
                    rect: rect(column: column, row: 0),
                    spec: entry.1,
                    style: .shipping,
                    caption: entry.0.uppercased(),
                    value: "$128.40"
                )
            )
            plates.append(
                ProofPlate(
                    rect: rect(column: column, row: 1),
                    spec: entry.1,
                    style: .lensed,
                    caption: entry.0.uppercased(),
                    value: "$128.40"
                )
            )
        }

        return ProofBoard(
            canvas: canvas,
            radius: plateRadius,
            plates: plates,
            rowTitles: [
                RowTitle(text: "SHIPPING — lens over opaque substrate", y: margin),
                RowTitle(
                    text: "LENSED BACKDROP — lens over the field, content on top",
                    y: margin + headerHeight + plateSize.height + rowGap
                )
            ]
        )
        .frame(width: canvas.width, height: canvas.height)
    }

    // MARK: - Rasterising

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
    }

    private func write(_ image: CGImage, named name: String, into directory: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        print("[glass-proof] wrote \(url.path) (\(image.width)×\(image.height)px)")
    }

    /// Where the PNGs land.
    ///
    /// `OBB_GLASS_PROOF_DIR` wins so the harness can be pointed somewhere writable; the
    /// default is the repo's gitignored `.derived-data/glass-proofs`, resolved from this
    /// file's own path rather than a working directory the test host does not control.
    /// An app-hosted XCTest can lack the terminal's Documents-folder TCC grant, so a
    /// failed write falls back to a temporary directory and prints the path instead of
    /// failing — a permissions problem is not a material problem.
    private static func outputDirectory() throws -> URL {
        let preferred: URL = ProcessInfo.processInfo.environment["OBB_GLASS_PROOF_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath)          // …/AgentLensTests/Active/<this file>
            .deletingLastPathComponent()                // …/AgentLensTests/Active
            .deletingLastPathComponent()                // …/AgentLensTests
            .deletingLastPathComponent()                // repo root
            .appendingPathComponent(".derived-data/glass-proofs", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)
            let probe = preferred.appendingPathComponent(".writable")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return preferred
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("glass-proofs", isDirectory: true)
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            print("[glass-proof] \(preferred.path) unwritable (\(error.localizedDescription)); using \(fallback.path)")
            return fallback
        }
    }

    // MARK: - Measuring

    /// The plate footprint in device pixels, so the interior can be measured without the
    /// surrounding un-plated backdrop diluting every number toward zero.
    private static func plateRegionInPixels(scale: CGFloat) -> CGRect {
        CGRect(
            x: cardPlate.minX * scale,
            y: cardPlate.minY * scale,
            width: cardPlate.width * scale,
            height: cardPlate.height * scale
        )
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }

    private static func meanAbsoluteDifference(
        _ lhs: CGImage,
        _ rhs: CGImage,
        region: CGRect? = nil
    ) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .nan }
        let a = rgba(lhs)
        let b = rgba(rhs)
        var total = 0.0
        var count = 0
        forEachPixel(width: lhs.width, height: lhs.height, region: region) { index in
            for channel in 0..<3 {
                total += abs(Double(a[index + channel]) - Double(b[index + channel]))
                count += 1
            }
        }
        return count == 0 ? .nan : total / Double(count)
    }

    /// How much *structure* survives inside the plate. A flat frost collapses this toward
    /// zero however bright it is; a lens that is genuinely carrying the backdrop keeps it
    /// within reach of the backdrop's own figure.
    private static func lumaStandardDeviation(_ image: CGImage, region: CGRect?) -> Double {
        let pixels = rgba(image)
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        forEachPixel(width: image.width, height: image.height, region: region) { index in
            let luma = 0.2126 * Double(pixels[index])
                + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
            sum += luma
            sumSquares += luma * luma
            count += 1
        }
        guard count > 0 else { return .nan }
        let mean = sum / Double(count)
        return (sumSquares / Double(count) - mean * mean).squareRoot()
    }

    private static func forEachPixel(
        width: Int,
        height: Int,
        region: CGRect?,
        _ body: (Int) -> Void
    ) {
        let clip = region ?? CGRect(x: 0, y: 0, width: width, height: height)
        let minX = max(0, Int(clip.minX)), maxX = min(width, Int(clip.maxX))
        let minY = max(0, Int(clip.minY)), maxY = min(height, Int(clip.maxY))
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX {
                body((y * width + x) * 4)
            }
        }
    }
}

// MARK: - The backdrop

/// Deliberately hostile ground: hard 45° edges, saturated hue blocks, a conic wheel and
/// a crosshair.
///
/// Every term in `BurnBarGlass.metal` needs a different feature to be visible. Refraction
/// needs an edge to displace. Dispersion needs that edge to be achromatic *and* the
/// neighbourhood chromatic, so a red-shifted and a blue-shifted copy of it land apart.
/// Magnification needs a straight line through the centre — the crosshair — because a
/// bent straight line is the one cue the eye cannot rationalise away. Scatter needs
/// saturated colour to bleed.
struct GlassProofBackdrop: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            paintHueBlocks(&context, size)
            paintDiagonalStripes(&context, size)
            paintColourWheel(&context, size)
            paintCrosshair(&context, size)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.09))
    }

    /// A 6×3 grid of fully saturated hues, so no part of a plate sits over neutral ground.
    private func paintHueBlocks(_ context: inout GraphicsContext, _ size: CGSize) {
        let columns = 6
        let rows = 3
        let cell = CGSize(width: size.width / CGFloat(columns), height: size.height / CGFloat(rows))
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let hue = Double(index) / Double(columns * rows)
                let rect = CGRect(
                    x: CGFloat(column) * cell.width,
                    y: CGFloat(row) * cell.height,
                    width: cell.width,
                    height: cell.height
                )
                context.fill(
                    Path(rect),
                    with: .color(Color(hue: hue, saturation: 0.95, brightness: row == 1 ? 0.95 : 0.72))
                )
            }
        }
    }

    /// Hard 45° bands at partial alpha: the edges stay razor-sharp (that is what refraction
    /// displaces and dispersion splits) while the hue underneath still reads through.
    private func paintDiagonalStripes(_ context: inout GraphicsContext, _ size: CGSize) {
        let stripe: CGFloat = 16
        var offset = -size.height
        var light = true
        while offset < size.width {
            var path = Path()
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset + stripe, y: 0))
            path.addLine(to: CGPoint(x: offset + stripe + size.height, y: size.height))
            path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(light ? Color.white.opacity(0.62) : Color.black.opacity(0.66)))
            offset += stripe
            light.toggle()
        }
    }

    /// A continuous hue sweep in the middle of the plate — the reference for chromatic
    /// aberration, which shows up as the wheel's spokes shearing colour at the rim.
    private func paintColourWheel(_ context: inout GraphicsContext, _ size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let diameter = min(size.width, size.height) * 0.52
        let circle = Path(
            ellipseIn: CGRect(
                x: centre.x - diameter / 2,
                y: centre.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        )
        context.fill(
            circle,
            with: .conicGradient(
                Gradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }),
                center: centre
            )
        )
        context.stroke(circle, with: .color(Color.black), lineWidth: 3)
    }

    /// Two straight lines through the middle. A lens bends them; a frost does not.
    private func paintCrosshair(_ context: inout GraphicsContext, _ size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        path.move(to: CGPoint(x: size.width / 2, y: 0))
        path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
        context.stroke(path, with: .color(Color.white.opacity(0.95)), lineWidth: 2)
    }
}

// MARK: - Plates

private enum PlateStyle {
    /// `content.background(substrate).modifier(LensModifier)` — what ships.
    case shipping
    /// `ZStack { backdrop.lensed; content }` — the lens with something to bend.
    case lensed
}

private struct ProofPlate: Identifiable {
    let id = UUID()
    let rect: CGRect
    let spec: GlassSpec
    let style: PlateStyle
    let caption: String
    let value: String
}

private struct RowTitle: Identifiable {
    let id = UUID()
    let text: String
    let y: CGFloat
}

/// One backdrop, N plates at absolute positions.
///
/// Absolute rects rather than a stack, because a lensed plate has to know where it sits
/// on the backdrop: the copy of the field inside the plate is offset so it continues the
/// field outside it. Get that wrong and the plate shows a *different* piece of backdrop,
/// which looks like refraction and is not.
private struct ProofBoard: View {
    let canvas: CGSize
    let radius: CGFloat
    let plates: [ProofPlate]
    var rowTitles: [RowTitle] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassProofBackdrop()
                .frame(width: canvas.width, height: canvas.height)

            ForEach(rowTitles) { title in
                Text(title.text)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .offset(x: 32, y: title.y)
            }

            ForEach(plates) { plate in
                Group {
                    switch plate.style {
                    case .shipping: shippingPlate(plate)
                    case .lensed:   lensedPlate(plate)
                    }
                }
                .frame(width: plate.rect.width, height: plate.rect.height)
                .offset(x: plate.rect.minX, y: plate.rect.minY)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Shipping composition

    private func shippingPlate(_ plate: ProofPlate) -> some View {
        plateContent(plate)
            .frame(width: plate.rect.width, height: plate.rect.height)
            .burnBarGlass(plate.spec, role: .chrome)
    }

    // MARK: Lensed-backdrop composition

    private func lensedPlate(_ plate: ProofPlate) -> some View {
        let spec = plate.spec
        let radius = radius
        // The same resting light `LensModifier` uses when the pointer is outside: off the
        // top-leading corner. A snapshot has no cursor, so this is the honest default.
        let light = CGPoint(x: plate.rect.width * 0.22, y: -plate.rect.height * 0.35)
        let energy = BurnBarAmbient.neutral.energy

        return ZStack {
            Color.clear
                .frame(width: plate.rect.width, height: plate.rect.height)
                .overlay {
                    // The same field, positioned so the piece inside the plate continues
                    // the piece outside it.
                    GlassProofBackdrop()
                        .frame(width: canvas.width, height: canvas.height)
                        .offset(
                            x: canvas.width / 2 - plate.rect.midX,
                            y: canvas.height / 2 - plate.rect.midY
                        )
                }
                .clipped()
                .compositingGroup()
                .visualEffect { [spec, radius, light, energy] effect, proxy in
                    effect.layerEffect(
                        ShaderLibrary.default.burnBarGlassLens(
                            .float2(proxy.size.width, proxy.size.height),
                            .float(radius),
                            .float(spec.lensing),
                            .float(spec.dispersion),
                            .float(spec.specular),
                            .float(spec.thickness),
                            .float(spec.scatter),
                            .float2(light.x, light.y),
                            .float(energy)
                        ),
                        maxSampleOffset: CGSize(width: 96, height: 96)
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

            plateContent(plate)
        }
    }

    // MARK: Content

    /// Chrome-shaped content: a label, a number, a supporting line. Identical in both
    /// compositions so the only difference between boards is the optics.
    private func plateContent(_ plate: ProofPlate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plate.caption)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(0.75))
            Text(plate.value)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
            Text("Claude Code · 62%")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
    }
}
