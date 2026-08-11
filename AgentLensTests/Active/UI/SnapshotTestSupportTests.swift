import AppKit
import SwiftUI
import XCTest
import OpenBurnBarCore

@MainActor
final class SnapshotTestSupportTests: XCTestCase {
    func test_renderViewSnapshotUsesCanonicalBackingScale() throws {
        let logicalSize = CGSize(width: 37, height: 23)

        let image = renderViewSnapshot(
            Color.red,
            size: logicalSize,
            colorScheme: .dark
        )

        let bitmap = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        )
        XCTAssertEqual(image.size, logicalSize)
        XCTAssertEqual(bitmap.size, logicalSize)
        XCTAssertEqual(bitmap.pixelsWide, 74)
        XCTAssertEqual(bitmap.pixelsHigh, 46)
        XCTAssertEqual(
            bitmap.colorSpace.iccProfileData,
            NSColorSpace.sRGB.iccProfileData
        )
        XCTAssertEqual(
            CGFloat(bitmap.pixelsWide) / bitmap.size.width,
            openBurnBarSnapshotBackingScale
        )
        XCTAssertEqual(
            CGFloat(bitmap.pixelsHigh) / bitmap.size.height,
            openBurnBarSnapshotBackingScale
        )
    }

    func test_renderViewSnapshotDefaultsToAuroraAndRestoresCallerSkin() {
        withCallerSkin(.editorial) {
            let image = renderViewSnapshot(
                SnapshotSkinProbe(),
                size: CGSize(width: 8, height: 8),
                colorScheme: .light
            )

            XCTAssertEqual(AppSkin.current, .editorial)
            assertCenterPixel(of: image, isDominatedBy: .red)
        }
    }

    func test_renderViewSnapshotSupportsExplicitEditorialSkinAndRestoresCallerSkin() {
        withCallerSkin(.aurora) {
            let image = renderViewSnapshot(
                SnapshotSkinProbe(),
                size: CGSize(width: 8, height: 8),
                colorScheme: .light,
                skin: .editorial
            )

            XCTAssertEqual(AppSkin.current, .aurora)
            assertCenterPixel(of: image, isDominatedBy: .blue)
        }
    }

    func test_snapshotRecordModePrefersCanonicalEnvironment() {
        XCTAssertEqual(
            openBurnBarSnapshotRecordMode(
                environment: [
                    "SNAPSHOT_TESTING_RECORD": "failed",
                    "TEST_RUNNER_SNAPSHOT_TESTING_RECORD": "missing"
                ],
                bundleInfo: [openBurnBarSnapshotRecordModeInfoKey: "all"]
            ),
            .failed
        )
    }

    func test_snapshotRecordModeSupportsXcodeRunnerAlias() {
        XCTAssertEqual(
            openBurnBarSnapshotRecordMode(
                environment: ["TEST_RUNNER_SNAPSHOT_TESTING_RECORD": "all"],
                bundleInfo: [:]
            ),
            .all
        )
    }

    func test_snapshotRecordModeFallsBackToValidatedBundleInfo() {
        XCTAssertEqual(
            openBurnBarSnapshotRecordMode(
                environment: [:],
                bundleInfo: [openBurnBarSnapshotRecordModeInfoKey: " failed\n"]
            ),
            .failed
        )

        XCTAssertNil(
            openBurnBarSnapshotRecordMode(
                environment: [:],
                bundleInfo: [openBurnBarSnapshotRecordModeInfoKey: "invalid"]
            )
        )
    }

    func test_snapshotRecordModeIsStampedIntoTestBundle() throws {
        let bundle = Bundle(for: SnapshotTestSupportTests.self)
        let value = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: openBurnBarSnapshotRecordModeInfoKey) as? String
        )
        XCTAssertTrue(
            ["all", "failed", "missing", "never"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    func test_snapshotReferenceDirectoryRequiresAFileBackedURL() {
        let fileURL = URL(fileURLWithPath: "/tmp/../tmp/openburnbar-snapshots", isDirectory: true)
        XCTAssertEqual(
            openBurnBarSnapshotReferenceDirectory(resourceURL: fileURL),
            "/tmp/openburnbar-snapshots"
        )
        XCTAssertNil(
            openBurnBarSnapshotReferenceDirectory(
                resourceURL: URL(string: "https://example.com/snapshots")
            )
        )
        XCTAssertNil(openBurnBarSnapshotReferenceDirectory(resourceURL: nil))
    }

    private func withCallerSkin(
        _ skin: AppSkin,
        operation: () -> Void
    ) {
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

        operation()
    }

    private func assertCenterPixel(
        of image: NSImage,
        isDominatedBy expectedComponent: DominantColorComponent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            XCTFail("Snapshot image has no bitmap representation", file: file, line: line)
            return
        }
        guard let actualColor = bitmap.colorAt(
            x: bitmap.pixelsWide / 2,
            y: bitmap.pixelsHigh / 2
        )?.usingColorSpace(.sRGB) else {
            XCTFail("Could not resolve the snapshot color in sRGB", file: file, line: line)
            return
        }

        switch expectedComponent {
        case .red:
            XCTAssertGreaterThan(actualColor.redComponent, 0.8, file: file, line: line)
            XCTAssertGreaterThan(
                actualColor.redComponent - max(actualColor.greenComponent, actualColor.blueComponent),
                0.5,
                file: file,
                line: line
            )
        case .blue:
            XCTAssertGreaterThan(actualColor.blueComponent, 0.8, file: file, line: line)
            XCTAssertGreaterThan(
                actualColor.blueComponent - max(actualColor.redComponent, actualColor.greenComponent),
                0.25,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actualColor.alphaComponent, 1, accuracy: 0.01, file: file, line: line)
    }
}

private enum DominantColorComponent {
    case red
    case blue
}

private struct SnapshotSkinProbe: View {
    var body: some View {
        AppSkin.current == .aurora ? Color.red : Color.blue
    }
}
