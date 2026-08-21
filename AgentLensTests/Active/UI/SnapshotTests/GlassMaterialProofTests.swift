import AppKit
import OpenBurnBarCore
import SnapshotTesting
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// Proof renders for the glass material.
///
/// Not a regression suite — a **microscope**. The material was tuned for several rounds
/// without anyone looking at a pixel of it, and the result was a lens that was
/// mathematically correct and visually inert. These write PNGs to
/// `.derived-data/glass-proofs/` so the optics can be judged on evidence.
///
/// The backdrop is deliberately hostile: hard diagonal stripes and saturated blocks.
/// Refraction, magnification and spectral separation are all *displacements of an edge*,
/// so they are invisible over a smooth gradient and unmissable over a hard one. If the
/// stripes do not bend under the plate, the plate is not glass.
@MainActor
final class GlassMaterialProofTests: XCTestCase {

    /// Derived from `#filePath`, not the working directory: the xctest host runs with
    /// cwd `/`, so a relative path resolves to the read-only root volume.
    private static var proofDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/AgentLensTests/Active/UI/SnapshotTests/<file>
            .deletingLastPathComponent()          // SnapshotTests
            .deletingLastPathComponent()          // UI
            .deletingLastPathComponent()          // Active
            .deletingLastPathComponent()          // AgentLensTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent(".derived-data/glass-proofs", isDirectory: true)
    }

    // MARK: - The test backdrop

    /// Hard edges in several orientations plus saturated colour, so every optical term
    /// has something to act on.
    private var structuredBackdrop: some View {
        ZStack {
            Color.black
            // Diagonal stripes: the reference for bending.
            Canvas { context, size in
                let step: CGFloat = 26
                var offset: CGFloat = -size.height
                while offset < size.width + size.height {
                    var bar = Path()
                    bar.move(to: CGPoint(x: offset, y: 0))
                    bar.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                    bar.addLine(to: CGPoint(x: offset + size.height + step / 2, y: size.height))
                    bar.addLine(to: CGPoint(x: offset + step / 2, y: 0))
                    bar.closeSubpath()
                    context.fill(bar, with: .color(.white.opacity(0.92)))
                    offset += step
                }
            }
            // Saturated blocks: the reference for dispersion and tinting.
            HStack(spacing: 0) {
                ForEach(
                    [Color.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                    id: \.self
                ) { color in
                    color.opacity(0.85)
                }
            }
            .blendMode(.multiply)
        }
    }

    // MARK: - Proofs

    /// The material exactly as it ships. If the diagnosis is right — that the opaque
    /// substrate leaves the lens nothing to refract — the stripes under this plate will
    /// be perfectly straight and the plate will read as a flat card.
    func test_proof_materialAsShipped() throws {
        try renderProof("01-material-as-shipped") {
            ZStack {
                structuredBackdrop
                Text("BURNBAR")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 300, height: 170)
                    .burnBarGlass(.canvas, role: .chrome, tint: .orange)
            }
        }
    }

    /// The same plate at `.content`, which is what every `DashboardSection` uses — the
    /// role the user is actually looking at on screen.
    func test_proof_contentRole() throws {
        try renderProof("02-content-role") {
            ZStack {
                structuredBackdrop
                Text("SECTION")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 300, height: 170)
                    .burnBarGlass(.canvas, role: .content, tint: .orange)
            }
        }
    }

    /// The lens applied straight to the backdrop with no substrate between them — the
    /// upper bound of what the optics can do. If 01 is flat and this one bends, the
    /// substrate is proven to be the thing killing the effect.
    func test_proof_lensDirectlyOnBackdrop() throws {
        try renderProof("03-lens-on-backdrop") {
            structuredBackdrop
                .visualEffect { effect, proxy in
                    effect.layerEffect(
                        ShaderLibrary.default.burnBarGlassLens(
                            .float2(proxy.size.width, proxy.size.height),
                            .float(28),
                            .float(0.70),   // lensing
                            .float(0.42),   // dispersion
                            .float(0.58),   // specular
                            .float(0.85),   // thickness
                            .float(0.80),   // scatter
                            .float2(proxy.size.width * 0.25, -proxy.size.height * 0.3),
                            .float(0.8)     // energy
                        ),
                        maxSampleOffset: CGSize(width: 96, height: 96)
                    )
                }
        }
    }

    /// The seven personalities over one backdrop. "Seven distinct materials" is a claim
    /// until you can see the difference in one frame.
    func test_proof_specLadder() throws {
        let specs: [(String, GlassSpec)] = [
            ("LEDGER", .ledger), ("COCKPIT", .cockpit), ("FOCUS", .focus),
            ("BENTO", .bento), ("CANVAS", .canvas)
        ]
        try renderProof("04-spec-ladder", size: CGSize(width: 900, height: 260)) {
            ZStack {
                structuredBackdrop
                HStack(spacing: 14) {
                    ForEach(specs, id: \.0) { name, spec in
                        Text(name)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 150, height: 150)
                            .burnBarGlass(spec, role: .chrome, tint: .orange)
                    }
                }
            }
        }
    }

    // MARK: - Harness

    private func renderProof(
        _ name: String,
        size: CGSize = CGSize(width: 520, height: 320),
        @ViewBuilder _ view: () -> some View
    ) throws {
        try FileManager.default.createDirectory(
            at: Self.proofDirectory, withIntermediateDirectories: true
        )
        let image = renderViewSnapshot(view(), size: size, colorScheme: .dark)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("Could not encode \(name)")
            return
        }
        let url = Self.proofDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        // Printed so the path is recoverable from the test log.
        print("GLASS PROOF: \(url.path)")
    }
}

// MARK: - Spend chart

/// Proof renders for the Home spend chart.
///
/// Same discipline as the glass proofs above: the breakdown was built to be *seen*, so
/// it gets looked at rather than asserted about. `HomeSpendSeriesTests` pins the numbers;
/// these prove the numbers reach the screen as distinguishable coloured bands with
/// working controls, in both colour schemes.
@MainActor
final class HomeSpendChartProofTests: XCTestCase {

    private static var proofDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".derived-data/glass-proofs", isDirectory: true)
    }

    /// A day that actually looks like a day: several harnesses, several models each,
    /// bursty rather than uniform. A flat synthetic ramp would prove nothing — every
    /// band would be the same shape and the stack would read as one gradient.
    private var day: [TokenUsage] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recipe: [(AgentProvider, String, Double)] = [
            (.claudeCode, "claude-opus-4", 1.0),
            (.claudeCode, "claude-sonnet-4", 0.45),
            (.codex, "gpt-5", 0.7),
            (.cursor, "gemini-3-pro", 0.3),
            (.deepSeek, "deepseek-v3", 0.16),
            (.kimi, "kimi-k2", 0.08),
            (.ollama, "llama-4", 0.05)
        ]
        var rows: [TokenUsage] = []
        for (index, entry) in recipe.enumerated() {
            for step in 0..<40 {
                let hoursAgo = 23.5 - Double(step) * 0.58
                // A deterministic burst shape, phase-shifted per series.
                let wave = 0.35 + abs(sin(Double(step) * 0.41 + Double(index)))
                rows.append(
                    TokenUsage(
                        provider: entry.0,
                        sessionId: "\(entry.1)-\(step)",
                        projectName: "BurnBar",
                        model: entry.1,
                        inputTokens: 900,
                        outputTokens: 400,
                        costUSD: entry.2 * wave,
                        startTime: now.addingTimeInterval(-hoursAgo * 3600 - 120),
                        endTime: now.addingTimeInterval(-hoursAgo * 3600)
                    )
                )
            }
        }
        return rows
    }

    /// The chart reads its breakdown from `UserDefaults`, and the xctest host *is* the
    /// app — so a proof that flips the mode would otherwise rewrite the real
    /// preference. Saved and restored around every render.
    private static let breakdownKey = "home.spend.breakdown"
    private static let hiddenKey = "home.spend.hidden"
    private var savedBreakdown: Any?
    private var savedHidden: Any?

    override func setUp() {
        super.setUp()
        savedBreakdown = UserDefaults.standard.object(forKey: Self.breakdownKey)
        savedHidden = UserDefaults.standard.object(forKey: Self.hiddenKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedBreakdown, forKey: Self.breakdownKey)
        UserDefaults.standard.set(savedHidden, forKey: Self.hiddenKey)
        super.tearDown()
    }

    func test_proof_chartBreakdownDark() throws {
        try renderProof("05-spend-chart-dark", scheme: .dark)
    }

    func test_proof_chartBreakdownLight() throws {
        try renderProof("06-spend-chart-light", scheme: .light)
    }

    /// The model cut, where the same-family colour separation has to do its work:
    /// Opus and Sonnet both resolve to Anthropic ochre before it runs.
    func test_proof_chartByModel() throws {
        UserDefaults.standard.set(HomeSpendBreakdown.model.rawValue, forKey: Self.breakdownKey)
        try renderProof("07-spend-chart-by-model", scheme: .dark)
    }

    /// One harness switched off from the legend, so the proof shows the control doing
    /// something rather than merely existing.
    func test_proof_chartWithASeriesHidden() throws {
        UserDefaults.standard.set(HomeSpendBreakdown.harness.rawValue, forKey: Self.breakdownKey)
        UserDefaults.standard.set(
            "\(HomeSpendBreakdown.harness.rawValue)\t\(AgentProvider.codex.rawValue)",
            forKey: Self.hiddenKey
        )
        try renderProof("08-spend-chart-series-hidden", scheme: .dark)
    }

    private func renderProof(_ name: String, scheme: ColorScheme) throws {
        try FileManager.default.createDirectory(
            at: Self.proofDirectory, withIntermediateDirectories: true
        )
        let cube = HomeSpendSeries.cube(day, now: Date(timeIntervalSince1970: 1_700_000_000))
        let size = CGSize(width: 980, height: 232)
        let chart = HomeSpendChart(
            cube: cube,
            ink: BackdropInk.resolveForPlate(skin: AppSkin.current, colorScheme: scheme)
        )
        .padding(DesignSystem.Spacing.md)
        .background(scheme == .dark ? Color.black : Color.white)

        let image = renderViewSnapshot(chart, size: size, colorScheme: scheme)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("Could not encode \(name)")
            return
        }
        let url = Self.proofDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("CHART PROOF: \(url.path)")
    }
}

// MARK: - Does the lens see the field?

/// The decisive experiment behind "those are not reflecting the beautiful kernels".
///
/// `BurnBarKernelField.swift` states the diagnosis in its own header: a `WKWebView` is a
/// sealed rectangle in the compositor, so every glass plate in the app "floats above a
/// field it cannot see." These renders test the other half of that claim — that once the
/// field is ordinary SwiftUI content, a `layerEffect` at a common ancestor *can* sample
/// and bend it.
///
/// Two proofs, in order:
///   09 — the native field alone. If this is blank, nothing downstream matters.
///   10 — the same field with the lens applied at the ancestor. If the field bends,
///        real refraction of the live kernel is available and the only work left is
///        generalising the shader from one rect to N plates.
@MainActor
final class KernelLensProofTests: XCTestCase {

    private static var proofDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".derived-data/glass-proofs", isDirectory: true)
    }

    /// A busy fleet, so the field has several distinct provider ribbons — refraction is
    /// a displacement of an edge, and a single-hue field would hide it.
    private var driver: SwarmColorDriver {
        SwarmColorDriver(
            mode: .active,
            providers: [
                .init(provider: .claudeCode, weight: 0.42, quotaPressure: 0.1),
                .init(provider: .codex, weight: 0.28, quotaPressure: 0.55),
                .init(provider: .cursor, weight: 0.18, quotaPressure: 0.86),
                .init(provider: .deepSeek, weight: 0.12, quotaPressure: 0.2)
            ],
            totalBurnRateUSD: 84
        )
    }

    func test_proof_nativeFieldRenders() throws {
        try renderProof("09-kernel-field-native") {
            BurnBarKernelField(driver: driver)
        }
    }

    func test_proof_lensBendsTheNativeField() throws {
        try renderProof("10-kernel-field-through-lens") {
            BurnBarKernelField(driver: driver)
                .visualEffect { effect, proxy in
                    effect.layerEffect(
                        ShaderLibrary.default.burnBarGlassLens(
                            .float2(proxy.size.width, proxy.size.height),
                            .float(120),    // radius — a big soft plate, so the rim is obvious
                            .float(0.85),   // lensing
                            .float(0.55),   // dispersion
                            .float(0.62),   // specular
                            .float(0.90),   // thickness
                            .float(0.80),   // scatter
                            .float2(proxy.size.width * 0.25, -proxy.size.height * 0.3),
                            .float(0.85)    // energy
                        ),
                        maxSampleOffset: CGSize(width: 120, height: 120)
                    )
                }
        }
    }

    private func renderProof(_ name: String, @ViewBuilder _ view: () -> some View) throws {
        try FileManager.default.createDirectory(
            at: Self.proofDirectory, withIntermediateDirectories: true
        )
        let image = renderViewSnapshot(
            view(), size: CGSize(width: 900, height: 380), colorScheme: .dark
        )
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("Could not encode \(name)")
            return
        }
        try png.write(to: Self.proofDirectory.appendingPathComponent("\(name).png"))
        print("KERNEL PROOF: \(name)")
    }
}
