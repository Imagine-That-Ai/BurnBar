import SwiftUI
import SnapshotTesting
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

let openBurnBarSnapshotRecordModeInfoKey = "OpenBurnBarSnapshotRecordMode"

private final class OpenBurnBarSnapshotBundleLocator: NSObject {}

func openBurnBarIsGitHubActionsRunner(sourceFile: StaticString = #filePath) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    let sourcePath = String(describing: sourceFile)
    let currentDirectory = FileManager.default.currentDirectoryPath

    return environment["CI"] == "true"
        || environment["GITHUB_ACTIONS"] == "true"
        || environment["RUNNER_OS"] != nil
        || environment["TEST_RUNNER_CI"] == "true"
        || environment["TEST_RUNNER_GITHUB_ACTIONS"] == "true"
        || environment["TEST_RUNNER_RUNNER_OS"] != nil
        || sourcePath.contains("/Users/runner/work/")
        || currentDirectory.contains("/Users/runner/work/")
}

func openBurnBarShouldSkipVisualSnapshots(sourceFile: StaticString = #filePath) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    let mainBundlePath = Bundle.main.bundlePath

    return environment["TEST_RUNNER_OPENBURNBAR_SKIP_SNAPSHOTS"] == "true"
        || mainBundlePath.contains("/openburnbar-app-tests/")
        || openBurnBarIsGitHubActionsRunner(sourceFile: sourceFile)
}

// MARK: - Visual Regression Support

let openBurnBarSnapshotBackingScale: CGFloat = 2

/// Renders a SwiftUI view into an NSImage at a fixed size and color scheme,
/// disabling animations and pinning the skin and backing scale for deterministic capture.
@MainActor
func renderViewSnapshot<V: View>(
    _ view: V,
    size: CGSize,
    colorScheme: ColorScheme,
    skin: AppSkin = .aurora
) -> NSImage {
    return withSnapshotSkin(skin) {
        let appearance = NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        )

        var image = NSImage(size: size)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                image = renderViewSnapshotBody(view, size: size, colorScheme: colorScheme, appearance: appearance)
            }
            return image
        }

        return renderViewSnapshotBody(view, size: size, colorScheme: colorScheme, appearance: nil)
    }
}

@MainActor
private func withSnapshotSkin<Result>(
    _ skin: AppSkin,
    operation: () -> Result
) -> Result {
    let defaults = UserDefaults.standard
    let previousValue = defaults.object(forKey: AppSkin.storageKey)
    defaults.set(skin.rawValue, forKey: AppSkin.storageKey)
    defer {
        if let previousValue {
            defaults.set(previousValue, forKey: AppSkin.storageKey)
        } else {
            defaults.removeObject(forKey: AppSkin.storageKey)
        }
    }

    return operation()
}

@MainActor
private func renderViewSnapshotBody<V: View>(
    _ view: V,
    size: CGSize,
    colorScheme: ColorScheme,
    appearance: NSAppearance?
) -> NSImage {
    let wrapped = view
        .environment(\.colorScheme, colorScheme)
        .transaction { $0.disablesAnimations = true }
        .frame(width: size.width, height: size.height)

    let hostingView = NSHostingView(rootView: wrapped)
    hostingView.appearance = appearance
    hostingView.frame = CGRect(origin: .zero, size: size)
    hostingView.setNeedsDisplay(hostingView.bounds)
    hostingView.displayIfNeeded()

    // Force layout so AutoLayout / SwiftUI sizing resolves before capture.
    hostingView.layoutSubtreeIfNeeded()

    let pixelWidth = max(1, Int((size.width * openBurnBarSnapshotBackingScale).rounded(.up)))
    let pixelHeight = max(1, Int((size.height * openBurnBarSnapshotBackingScale).rounded(.up)))
    guard let sourceBitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        XCTFail("Failed to create bitmap rep for snapshot")
        return NSImage(size: size)
    }
    sourceBitmap.size = size

    hostingView.cacheDisplay(in: hostingView.bounds, to: sourceBitmap)

    guard let bitmapRep = sourceBitmap.converting(to: .sRGB, renderingIntent: .default) else {
        XCTFail("Failed to convert snapshot bitmap to sRGB")
        return NSImage(size: size)
    }
    bitmapRep.size = size

    let image = NSImage(size: size)
    image.addRepresentation(bitmapRep)
    return image
}

/// Asserts a visual snapshot of a SwiftUI view in both light and dark modes.
@MainActor
func XCTAssertAdaptiveSnapshot<V: View>(
    of view: V,
    size: CGSize,
    named: String,
    skin: AppSkin = .aurora,
    precision: Float = 0.95,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    if openBurnBarShouldSkipVisualSnapshots() {
        return
    }

    for scheme in [ColorScheme.dark, ColorScheme.light] {
        let image = renderViewSnapshot(view, size: size, colorScheme: scheme, skin: skin)
        let suffix = scheme == .dark ? "dark" : "light"
        assertOpenBurnBarSnapshot(
            of: image,
            named: "\(named).\(suffix)",
            precision: precision,
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
    skin: AppSkin = .aurora,
    precision: Float = 0.95,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    if openBurnBarShouldSkipVisualSnapshots() {
        return
    }

    let image = renderViewSnapshot(view, size: size, colorScheme: colorScheme, skin: skin)
    assertOpenBurnBarSnapshot(
        of: image,
        named: named,
        precision: precision,
        file: file,
        testName: testName,
        line: line
    )
}

@MainActor
private func assertOpenBurnBarSnapshot(
    of image: NSImage,
    named name: String,
    precision: Float,
    file: StaticString,
    testName: String,
    line: UInt
) {
    let bundle = Bundle(for: OpenBurnBarSnapshotBundleLocator.self)
    guard let snapshotDirectory = openBurnBarSnapshotReferenceDirectory(
        resourceURL: bundle.resourceURL
    ) else {
        XCTFail(
            "OpenBurnBarTests has no file-backed resource directory for snapshot references",
            file: file,
            line: line
        )
        return
    }

    if let failure = verifySnapshot(
        of: image,
        as: .image(precision: precision),
        named: name,
        record: snapshotRecordMode(bundleInfo: bundle.infoDictionary ?? [:]),
        snapshotDirectory: snapshotDirectory,
        file: file,
        testName: testName,
        line: line
    ) {
        XCTFail(failure, file: file, line: line)
    }
}

func openBurnBarSnapshotReferenceDirectory(resourceURL: URL?) -> String? {
    guard let resourceURL, resourceURL.isFileURL else {
        return nil
    }
    return resourceURL.standardizedFileURL.path
}

private func snapshotRecordMode(
    bundleInfo: [String: Any]
) -> SnapshotTestingConfiguration.Record? {
    return openBurnBarSnapshotRecordMode(
        environment: ProcessInfo.processInfo.environment,
        bundleInfo: bundleInfo
    )
}

func openBurnBarSnapshotRecordMode(
    environment: [String: String],
    bundleInfo: [String: Any]
) -> SnapshotTestingConfiguration.Record? {
    if let mode = environment["SNAPSHOT_TESTING_RECORD"]
        .flatMap(SnapshotTestingConfiguration.Record.init(rawValue:))
        ?? environment["TEST_RUNNER_SNAPSHOT_TESTING_RECORD"]
        .flatMap(SnapshotTestingConfiguration.Record.init(rawValue:))
    {
        return mode
    }

    guard let configuredValue = bundleInfo[openBurnBarSnapshotRecordModeInfoKey] as? String else {
        return nil
    }
    let rawValue = configuredValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return SnapshotTestingConfiguration.Record(rawValue: rawValue)
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
    static let castleGreatHall = "castleGreatHall"
    static let miniSparklineFlat = "miniSparkline.flat"
    static let miniSparklineRising = "miniSparkline.rising"
    static let miniSparklineFalling = "miniSparkline.falling"
    static let onboardingProviderPill = "onboardingProviderPill"
    static let onboardingComplete = "onboardingComplete"
    static let chatFAB = "chatFAB"
}
