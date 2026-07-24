import Foundation
@testable import OpenBurnBarDaemon
import XCTest

final class OpenBurnBarPlaywrightBridgeResourceTests: XCTestCase {
    func testPackagedLinuxPathWinsOverAppImageAndSystemPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-playwright-resource-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packaged = root.appendingPathComponent("package/bridge.js")
        let appDirectory = root.appendingPathComponent("appdir", isDirectory: true)

        let resolved = OpenBurnBarPlaywrightBridgeResource.installedLinuxURL(
            environment: [
                OpenBurnBarPlaywrightBridgeResource.packagedEnvironmentKey: packaged.path,
                "APPDIR": appDirectory.path
            ],
            fileManager: .default,
            systemRoot: root
        )

        XCTAssertEqual(resolved, packaged.standardizedFileURL)
    }

    func testAppImagePathUsesTheImmutableInstalledRelativePath() throws {
        let appDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-appdir-\(UUID().uuidString)", isDirectory: true)
        let resolved = OpenBurnBarPlaywrightBridgeResource.installedLinuxURL(
            environment: ["APPDIR": appDirectory.path],
            fileManager: .default
        )
        XCTAssertEqual(
            resolved,
            appDirectory.appendingPathComponent(
                OpenBurnBarPlaywrightBridgeResource.installedRelativePath,
                isDirectory: false
            ).standardizedFileURL
        )
    }

    func testRelativeOverridesAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-playwright-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent(
            OpenBurnBarPlaywrightBridgeResource.installedRelativePath,
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("bridge".utf8).write(to: installed)

        let resolved = OpenBurnBarPlaywrightBridgeResource.installedLinuxURL(
            environment: [
                OpenBurnBarPlaywrightBridgeResource.packagedEnvironmentKey: "relative/bridge.js",
                "APPDIR": "relative/appdir"
            ],
            fileManager: .default,
            systemRoot: root
        )
        XCTAssertEqual(resolved, installed.standardizedFileURL)
    }
}
