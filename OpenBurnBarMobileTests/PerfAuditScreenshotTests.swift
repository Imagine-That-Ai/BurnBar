import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Renders the round-2 perf-audit surfaces to PNGs for before/after visual
/// review (findings ios-013 hero-glow collapse and ios-014 session-trace
/// strip). The capture phase comes from `OBB_SCREENSHOT_PHASE`
/// (`before`/`after`, default `after`); files land in
/// `OBB_SCREENSHOT_DIR` (default `/tmp/obb-round2-screens`).
///
/// Beyond producing the artifacts, the tests assert the surfaces render
/// non-empty so a broken hero card or verdict hero fails loudly.
@MainActor
final class PerfAuditScreenshotTests: XCTestCase {

    private static var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBB_SCREENSHOT_DIR"]
            ?? "/tmp/obb-round2-screens")
    }

    private static var phase: String {
        ProcessInfo.processInfo.environment["OBB_SCREENSHOT_PHASE"] ?? "after"
    }

    private func capturePNG<V: View>(
        _ view: V,
        size: CGSize,
        named name: String
    ) throws -> UIImage {
        // `ImageRenderer` rasterizes without a window — `drawHierarchy` on
        // a synthetic key window renders blank inside the unit-test host.
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer produced no image")

        try FileManager.default.createDirectory(
            at: Self.outputDirectory,
            withIntermediateDirectories: true
        )
        let url = Self.outputDirectory.appendingPathComponent(name)
        let data = try XCTUnwrap(image.pngData(), "Capture produced no PNG data")
        try data.write(to: url)
        return image
    }

    private func assertNotBlank(_ image: UIImage, name: String) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        // A blank capture means the hierarchy failed to render — cheap
        // sanity: the image must contain more than one distinct pixel value
        // in a sampled row.
        let provider = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = CFDataGetBytePtr(provider)
        let length = CFDataGetLength(provider)
        var distinct = Set<UInt8>()
        var index = 0
        while index < length && distinct.count < 3 {
            distinct.insert(bytes![index])
            index += max(1, length / 4_096)
        }
        XCTAssertGreaterThan(distinct.count, 1, "\(name) rendered blank")
    }

    // MARK: - ios-013: Pulse hero burn card

    func testCapturePulseHeroBurnCard() throws {
        let rollups = AppStoreScreenshotData.usageRollups
        var totals: [RollupWindowKey: RollupTotals] = [:]
        for rollup in rollups {
            totals[rollup.windowKey] = rollup.totals
        }
        let daily = rollups.first { $0.windowKey == .today }?.dailyPoints
            ?? rollups.first?.dailyPoints
            ?? []
        let usages = AppStoreScreenshotData.recentUsage
        let topProvider = usages.first?.provider

        let card = PulseHeroBurnCard(
            rollupTotals: totals,
            dailyPoints: daily,
            liveUsages: usages,
            topProvider: topProvider,
            displayMode: .currency,
            scope: .day,
            clockPaused: true
        )
        .padding(20)
        .frame(width: 393)
        .frame(maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let image = try capturePNG(
            card,
            size: CGSize(width: 393, height: 620),
            named: "ios-013-\(Self.phase).png"
        )
        try assertNotBlank(image, name: "ios-013-\(Self.phase).png")
    }

    /// Pins the no-blur glow contract (ios-013): the pre-shaped gradients
    /// must keep strictly increasing stop locations and fade fully to
    /// clear, or the blur-free shapes regress into hard-edged plates.
    func testHeroGlowStops_fadeSmoothlyToClear() {
        let halo = PulseHeroGlow.providerHaloStops(primary: .red, accent: .orange)
        let depthDark = PulseHeroGlow.depthGlowStops(accent: .red, amber: .orange, darkMode: true)
        let depthLight = PulseHeroGlow.depthGlowStops(accent: .red, amber: .orange, darkMode: false)

        for stops in [halo, depthDark, depthLight] {
            XCTAssertGreaterThanOrEqual(stops.count, 4, "Smooth falloff needs enough stops to mimic a Gaussian tail")
            let locations = stops.map(\.location)
            XCTAssertEqual(locations, locations.sorted())
            XCTAssertEqual(Set(locations).count, locations.count, "Duplicate locations create a hard edge")
            XCTAssertEqual(stops.first?.location, 0.0)
            XCTAssertEqual(stops.last?.color, .clear, "Terminal stop must be fully clear — no hard boundary")
        }
    }

    // MARK: - ios-014: verdict hero session-trace strip

    private struct TraceFixtureDataSource: InsightDataSource {
        let now: Date

        func snapshot(window: DateInterval) async throws -> InsightDataSnapshot {
            InsightDataSnapshot(
                window: window,
                usages: [
                    InsightUsageRow(
                        sessionID: "session-1",
                        provider: "claude",
                        model: "claude-sonnet",
                        projectName: "BurnBar",
                        startTime: now.addingTimeInterval(-1_800),
                        endTime: now.addingTimeInterval(-60),
                        inputTokens: 42_000,
                        outputTokens: 9_500,
                        totalTokens: 51_500,
                        costUSD: 4.20
                    )
                ],
                sessions: [
                    InsightSessionRow(
                        sessionID: "session-1",
                        provider: "claude",
                        projectName: "BurnBar",
                        startTime: now.addingTimeInterval(-1_800),
                        endTime: now.addingTimeInterval(-60),
                        messageCount: 24,
                        inferredTaskTitle: "Collapse the hero glow passes",
                        keyTools: ["Edit", "Bash"],
                        keyCommands: ["swift build"],
                        keyFiles: []
                    )
                ]
            )
        }
    }

    /// Drives the REAL mobile verdict pipeline (composer + the model's
    /// `buildTraceFor`) and captures whatever verdict it produces. Before
    /// the ios-014 fix the strip is absent (`buildTraceFor` stub); after,
    /// the session-trace strip renders between the rings and bullets.
    func testCaptureVerdictHeroFromMobilePipeline() async throws {
        let model = InsightsMobileVerdictModel(
            deviceID: "screenshot-device",
            window: .today,
            dataSource: TraceFixtureDataSource(now: Date()),
            digestBuilder: InsightDigestBuilder(),
            cache: VerdictCache(storage: .memoryOnly)
        )
        model.refresh()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let verdict = model.verdict, verdict.isRuleBased { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Give the async trace attachment a beat (no-op before the fix).
        try await Task.sleep(nanoseconds: 1_000_000_000)

        var verdict = try XCTUnwrap(model.verdict, "Pipeline produced no verdict")
        if Self.phase == "before" {
            // Faithful reproduction of the pre-fix pipeline: the
            // `buildTraceFor` stub guaranteed `sessionTrace == nil`, so the
            // before capture strips whatever the current pipeline attached.
            verdict.sessionTrace = nil
        }
        let hero = VerdictHeroView(verdict: verdict)
            .padding(20)
            .frame(width: 393)
            .background(Color(.systemBackground))

        let image = try capturePNG(
            hero,
            size: CGSize(width: 393, height: 760),
            named: "ios-014-\(Self.phase).png"
        )
        try assertNotBlank(image, name: "ios-014-\(Self.phase).png")
    }
}
