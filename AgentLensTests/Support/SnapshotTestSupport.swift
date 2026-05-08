import SwiftUI
import SnapshotTesting
import XCTest
@testable import OpenBurnBar

func openBurnBarIsGitHubActionsRunner() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["CI"] == "true"
        || environment["GITHUB_ACTIONS"] == "true"
        || environment["RUNNER_OS"] != nil
}

// MARK: - Visual Regression Support

/// Renders a SwiftUI view into an NSImage at a fixed size and color scheme,
/// disabling animations for deterministic snapshot capture.
@MainActor
func renderViewSnapshot<V: View>(
    _ view: V,
    size: CGSize,
    colorScheme: ColorScheme
) -> NSImage {
    let wrapped = view
        .environment(\.colorScheme, colorScheme)
        .transaction { $0.disablesAnimations = true }
        .frame(width: size.width, height: size.height)

    let hostingView = NSHostingView(rootView: wrapped)
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.setNeedsDisplay(hostingView.bounds)
    hostingView.displayIfNeeded()

    // Force layout so AutoLayout / SwiftUI sizing resolves before capture.
    hostingView.layoutSubtreeIfNeeded()

    guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        XCTFail("Failed to create bitmap rep for snapshot")
        return NSImage(size: size)
    }

    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

    let image = NSImage(size: size)
    image.addRepresentation(bitmapRep)
    return image
}

/// Asserts a visual snapshot of a SwiftUI view in both light and dark modes.
@MainActor
func assertAdaptiveSnapshot<V: View>(
    of view: V,
    size: CGSize,
    named: String,
    precision: Float = 0.95,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    if openBurnBarIsGitHubActionsRunner() {
        _ = renderViewSnapshot(view, size: size, colorScheme: .light)
        return
    }

    for scheme in [ColorScheme.dark, ColorScheme.light] {
        let image = renderViewSnapshot(view, size: size, colorScheme: scheme)
        let suffix = scheme == .dark ? "dark" : "light"
        assertSnapshot(
            of: image,
            as: .image(precision: precision),
            named: "\(named).\(suffix)",
            file: file,
            testName: testName,
            line: line
        )
    }
}

/// Asserts a single-scheme snapshot of a SwiftUI view.
@MainActor
func assertViewSnapshot<V: View>(
    of view: V,
    size: CGSize,
    colorScheme: ColorScheme,
    named: String,
    precision: Float = 0.95,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    if openBurnBarIsGitHubActionsRunner() {
        _ = renderViewSnapshot(view, size: size, colorScheme: colorScheme)
        return
    }

    let image = renderViewSnapshot(view, size: size, colorScheme: colorScheme)
    assertSnapshot(
        of: image,
        as: .image(precision: precision),
        named: named,
        file: file,
        testName: testName,
        line: line
    )
}

// MARK: - Snapshot Naming

enum SnapshotName {
    static let hermesToolCardRunning = "hermesToolCard.running"
    static let hermesToolCardCompleted = "hermesToolCard.completed"
    static let hermesToolCardExpanded = "hermesToolCard.expanded"
    static let hermesThinkingView = "hermesThinkingView"
    static let chatMessageHermes = "chatMessage.hermes"
    static let chatMessageUser = "chatMessage.user"
    static let chatMessageAssistant = "chatMessage.assistant"
    static let chatMessageStreaming = "chatMessage.streaming"
    static let colorSwatches = "adaptiveColors.swatches"
    static let providerColors = "adaptiveColors.providers"
    static let insightBriefCard = "insightBriefCard"
    static let narrativeCard = "narrativeCard"
    static let dashboardOverview = "dashboardOverview"
    static let dashboardNavStrip = "dashboardNavStrip"
    static let miniSparklineFlat = "miniSparkline.flat"
    static let miniSparklineRising = "miniSparkline.rising"
    static let miniSparklineFalling = "miniSparkline.falling"
    static let onboardingProviderPill = "onboardingProviderPill"
    static let onboardingComplete = "onboardingComplete"
    static let chatFAB = "chatFAB"
}
