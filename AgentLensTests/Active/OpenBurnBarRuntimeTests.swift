import XCTest
import CoreGraphics
import AppKit
@testable import OpenBurnBar

final class OpenBurnBarRuntimeTests: XCTestCase {
    func test_isRunningTests_detectsXCTestEnvironment() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/OpenBurnBarTests.xctestconfiguration"],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: []
        ))
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: ["TEST_RUNNER_CI": "true"],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: []
        ))
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: ["__XPC_DYLD_LIBRARY_PATH": "/tmp/OpenBurnBarTests.xctest/Contents/MacOS"],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: []
        ))
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: ["/tmp/OpenBurnBarTests.xctestconfiguration"],
            parentProcessPath: nil,
            loadedBundlePaths: []
        ))
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: [],
            parentProcessPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
            loadedBundlePaths: []
        ))
    }

    func test_isRunningTests_detectsLoadedXCTestBundle() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: ["/tmp/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarTests.xctest"],
            loadedImagePaths: []
        ))
    }

    func test_isRunningTests_detectsInjectedXCTestDylibImage() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: ["/tmp/OpenBurnBar.app"],
            loadedImagePaths: ["/Applications/Xcode.app/Contents/Developer/usr/lib/libXCTestBundleInject.dylib"]
        ))
    }

    func test_isRunningTests_doesNotFlagCopiedAppBundleWithEmbeddedXCTestPlugin() {
        XCTAssertFalse(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: ["/tmp/OpenBurnBar.app"],
            loadedImagePaths: []
        ))
    }

    func test_isRunningTests_detectsInjectedXCTestFrameworkBeforeBundleLoads() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: ["/tmp/OpenBurnBar.app"],
            loadedImagePaths: [],
            xCTestFrameworkLoaded: true
        ))
    }

    func test_isRunningTests_doesNotFlagPlainAppProcess() {
        XCTAssertFalse(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            arguments: [],
            parentProcessPath: nil,
            loadedBundlePaths: ["/tmp/OpenBurnBar.app"],
            loadedImagePaths: []
        ))
    }

    func test_shouldUseTestStubScene_honorsForceLiveSceneOverride() {
        XCTAssertTrue(OpenBurnBarRuntime.shouldUseTestStubScene(
            isRunningTests: true,
            forceLiveScene: false
        ))
        XCTAssertFalse(OpenBurnBarRuntime.shouldUseTestStubScene(
            isRunningTests: true,
            forceLiveScene: true
        ))
    }

    func test_shouldDisableAutomaticTerminationForHarness_honorsE2EEnvironment() {
        XCTAssertTrue(OpenBurnBarRuntime.shouldDisableAutomaticTerminationForHarness(
            environment: ["OPENBURNBAR_FORCE_LIVE_SCENE": "1"]
        ))
        XCTAssertTrue(OpenBurnBarRuntime.shouldDisableAutomaticTerminationForHarness(
            environment: ["OPENBURNBAR_E2E_HOLD_OPEN": "1"]
        ))
        XCTAssertFalse(OpenBurnBarRuntime.shouldDisableAutomaticTerminationForHarness(environment: [:]))
    }

    func test_statusItemClickPolicy_opensOnMouseDownAndIgnoresMouseUp() {
        XCTAssertEqual(OpenBurnBarStatusItemClick.actionMask, [.leftMouseDown, .rightMouseDown])
        XCTAssertEqual(OpenBurnBarStatusItemClick.action(for: .leftMouseDown), .togglePopover)
        XCTAssertEqual(OpenBurnBarStatusItemClick.action(for: .rightMouseDown), .showSecondaryMenu)
        XCTAssertEqual(OpenBurnBarStatusItemClick.action(for: .leftMouseUp), .ignore)
        XCTAssertEqual(OpenBurnBarStatusItemClick.action(for: .rightMouseUp), .ignore)
        XCTAssertEqual(OpenBurnBarStatusItemClick.action(for: nil), .togglePopover)
    }

    func test_menuExtraClickFallback_usesSmallHitSlopAroundStatusItemFrame() {
        let frame = CGRect(x: 3044, y: 3, width: 36, height: 24)

        XCTAssertTrue(OpenBurnBarMenuExtraClickFallback.click(CGPoint(x: 3062, y: 15), hits: frame))
        XCTAssertTrue(OpenBurnBarMenuExtraClickFallback.click(CGPoint(x: 3041, y: 1), hits: frame))
        XCTAssertFalse(OpenBurnBarMenuExtraClickFallback.click(CGPoint(x: 3020, y: 15), hits: frame))
        XCTAssertFalse(OpenBurnBarMenuExtraClickFallback.click(CGPoint(x: 3062, y: 45), hits: frame))
    }

    func test_menuExtraClickFallback_matchesAnyObservedStatusItemFrame() {
        let axMirroredMenuExtra = CGRect(x: 3181, y: 3, width: 28, height: 24)
        let controlCenterMenuExtra = CGRect(x: 1256, y: 0, width: 42, height: 33)

        XCTAssertEqual(
            OpenBurnBarMenuExtraClickFallback.hitFrame(
                for: CGPoint(x: 1277, y: 16),
                in: [axMirroredMenuExtra, controlCenterMenuExtra]
            ),
            controlCenterMenuExtra
        )
        XCTAssertEqual(
            OpenBurnBarMenuExtraClickFallback.hitFrame(
                for: CGPoint(x: 3195, y: 15),
                in: [axMirroredMenuExtra, controlCenterMenuExtra]
            ),
            axMirroredMenuExtra
        )
        XCTAssertNil(OpenBurnBarMenuExtraClickFallback.hitFrame(
            for: CGPoint(x: 1230, y: 16),
            in: [axMirroredMenuExtra, controlCenterMenuExtra]
        ))
    }

    func test_menuExtraClickFallback_matchesAnonymousMirroredStatusItemFrame() {
        let explicitAppFrame = CGRect(x: 1198, y: 0, width: 34, height: 33)
        let anonymousMirrorFrame = CGRect(x: 3116, y: 0, width: 34, height: 30)
        let unrelatedAnonymousFrame = CGRect(x: 3306, y: 0, width: 38, height: 30)
        let displayBounds = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117),
            CGRect(x: 1728, y: 0, width: 1920, height: 1080),
        ]

        let mirroredFrames = OpenBurnBarMenuExtraClickFallback.mirroredFrames(
            for: [explicitAppFrame],
            anonymousFrames: [anonymousMirrorFrame, unrelatedAnonymousFrame],
            displayBounds: displayBounds
        )

        XCTAssertEqual(mirroredFrames, [anonymousMirrorFrame])
        XCTAssertEqual(
            OpenBurnBarMenuExtraClickFallback.hitFrame(
                for: CGPoint(x: 3133, y: 15),
                in: [explicitAppFrame] + mirroredFrames
            ),
            anonymousMirrorFrame
        )
    }

    func test_popoverClickRegion_keepsPopoverAndStatusItemInteractive() {
        let statusItemFrame = CGRect(x: 3044, y: 3, width: 36, height: 24)
        let popoverFrame = CGRect(x: 2800, y: 30, width: 407, height: 760)

        XCTAssertTrue(OpenBurnBarPopoverClickRegion.isInsideInteractiveRegion(
            CGPoint(x: 3000, y: 240),
            statusItemFrame: statusItemFrame,
            popoverFrame: popoverFrame
        ))
        XCTAssertTrue(OpenBurnBarPopoverClickRegion.isInsideInteractiveRegion(
            CGPoint(x: 3041, y: 1),
            statusItemFrame: statusItemFrame,
            popoverFrame: popoverFrame
        ))
        XCTAssertFalse(OpenBurnBarPopoverClickRegion.isInsideInteractiveRegion(
            CGPoint(x: 2500, y: 240),
            statusItemFrame: statusItemFrame,
            popoverFrame: popoverFrame
        ))
    }
}
