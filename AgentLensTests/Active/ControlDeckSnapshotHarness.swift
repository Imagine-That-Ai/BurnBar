import AppKit
import SwiftUI
import XCTest

@testable import OpenBurnBar

/// Rasterises deck chrome over a synthetic bright backdrop so the plate can be
/// *looked at*, not only measured.
///
/// The contrast maths in `BackdropLegiblePlateTests` proves the ink clears
/// 4.5:1. It cannot tell you whether the result is worth shipping. This writes
/// PNGs when `OBB_SNAPSHOT_DIR` is set and is otherwise inert, so it costs CI
/// nothing and stays available for the next person who changes the plate.
///
/// Note `liquidGlassEffect` does not composite outside a window server, so the
/// rendered plate shows substrate + wash only — i.e. it is *more* pessimistic
/// than the shipping surface, which is the right direction for a legibility
/// check.
final class ControlDeckSnapshotHarness: XCTestCase {

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["OBB_SNAPSHOT_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @MainActor
    func testRenderDeckChromeOverBrightBackdrop() throws {
        guard let outputDirectory else {
            throw XCTSkip("Set OBB_SNAPSHOT_DIR to write deck snapshots.")
        }
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        for (name, live) in [("live-backdrop", true), ("static-canvas", false)] {
            let profile = BackdropReadabilityProfile.darkCanvasFallback
            let board = DeckSnapshotBoard(live: live)
                .environment(\.dashboardLiveBackdropActive, live)
                .environment(\.backdropReadabilityProfile, profile)
                .resolvingBackdropInk(liveBackdropActive: live, profile: profile)
                .environment(\.colorScheme, .dark)
                .frame(width: 1_180, height: 420)

            let renderer = ImageRenderer(content: board)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "renderer produced no image")
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = outputDirectory.appendingPathComponent("control-deck-\(name).png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}

/// A representative slice of the deck: one band header and four tiles covering
/// the states that render differently — on, off, attention, and unavailable.
private struct DeckSnapshotBoard: View {
    let live: Bool

    @Environment(\.backdropInk) private var ink

    var body: some View {
        ZStack {
            if live {
                // Stand-in for the worst thing a kernel can paint under a tile:
                // bright, saturated, and moving. Static here, but the plate does
                // not know that.
                LinearGradient(
                    colors: [
                        Color(red: 0.58, green: 0.44, blue: 0.86),
                        Color(red: 0.96, green: 0.62, blue: 0.42),
                        Color(red: 0.42, green: 0.78, blue: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // The page scrim the dashboard paints between backdrop and route.
                .overlay(BackdropAdaptiveColors(profile: .darkCanvasFallback).scrim.opacity(0.24))
            } else {
                DesignSystem.Colors.background
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Control Deck")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(ink.primary)
                    Text("7 of 11 on · $793.60 today · daemon healthy")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(ink.subtle)
                }

                ControlDeckGroupHeader(group: .know, tileCount: 2, onCount: 1)
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    tile(.textExpansion, .on, "12 snippets · 9 enabled")
                    tile(.memoryMCP, .off, "3 clients connected")
                }

                ControlDeckGroupHeader(group: .spend, tileCount: 3, onCount: 2)
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    tile(.aiInbox, .degraded("Analyst did not run"), "2 unread · $4.12 today")
                    tile(.charts, .on, "9 of 14 charts shown")
                    tile(.alerts, .unavailable("No threshold set"), "$50.00 daily")
                }
            }
            .padding(DesignSystem.Spacing.xl)
        }
    }

    private func tile(
        _ kind: ControlKind,
        _ state: ControlTileState,
        _ headline: String
    ) -> some View {
        ControlTileShell(
            kind: kind,
            state: state,
            headline: headline,
            accessibilityHeadline: headline
        ) {
            Circle().fill(state.dotColor).frame(width: 8, height: 8)
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlStatusChip(label: "Everywhere", tint: DesignSystem.Colors.success)
                ControlStatusChip(label: "In-app")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
