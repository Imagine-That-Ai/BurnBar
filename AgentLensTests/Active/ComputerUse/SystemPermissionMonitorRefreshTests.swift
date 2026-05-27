#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
@testable import OpenBurnBar

final class SystemPermissionMonitorRefreshTests: XCTestCase {
    @MainActor
    func testRefreshNowSeedsCurrentMacPermissionSnapshots() async {
        let monitor = SystemPermissionMonitor()

        await monitor.refreshNow(emitting: false)

        XCTAssertNotNil(monitor.snapshots["camera|"])
        XCTAssertNotNil(monitor.snapshots["microphone|"])
        XCTAssertNotNil(monitor.snapshots["screenRecording|"])
        XCTAssertNotNil(monitor.snapshots["accessibility|"])
        XCTAssertNotNil(monitor.snapshots["fullDiskAccess|"])
    }

    func testOnboardingWizardForcesLivePermissionRefreshBeforeReadingSnapshots() throws {
        let sourceURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Views")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingSystemPermissionsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("await SystemPermissionMonitor.shared.refreshNow(emitting: true)\n                self?.refreshSnapshots()"))
        XCTAssertTrue(source.contains("await SystemPermissionMonitor.shared.refreshNow(emitting: true)\n        refreshSnapshots()"))
    }

    func testOnboardingAutomationActionSendsRealTargetedAppleEventProbe() throws {
        let sourceURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Views")
            .appendingPathComponent("Onboarding")
            .appendingPathComponent("OnboardingSystemPermissionsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("case .automation: return \"Request Access\""))
        XCTAssertTrue(source.contains("AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, true)"))
        XCTAssertTrue(source.contains("runAutomationProbe(bundleId: bundleId)"))
        XCTAssertTrue(source.contains("tell application id"))
        XCTAssertTrue(source.contains("Target(bundleId: \"com.todesktop.230313mzl4w4u92\", displayName: \"Cursor\")"))
        XCTAssertTrue(source.contains("Target(bundleId: \"com.apple.Safari\", displayName: \"Safari\")"))
        XCTAssertTrue(source.contains("Target(bundleId: \"com.google.Chrome\", displayName: \"Google Chrome\")"))
        XCTAssertTrue(source.contains("Target(bundleId: \"com.apple.finder\", displayName: \"Finder\")"))
    }

    func testMacAppDeclaresAppleEventsUsageDescription() throws {
        let plistURL = repoRoot()
            .appendingPathComponent("AgentLens")
            .appendingPathComponent("Resources")
            .appendingPathComponent("OpenBurnBar-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let usage = try XCTUnwrap(plist["NSAppleEventsUsageDescription"] as? String)

        XCTAssertTrue(usage.contains("Cursor"))
        XCTAssertTrue(usage.contains("Safari"))
        XCTAssertTrue(usage.contains("Chrome"))
        XCTAssertTrue(usage.contains("Finder"))
    }

    private func repoRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
#endif
