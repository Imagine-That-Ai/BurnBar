import XCTest
@testable import OpenBurnBar

final class OpenBurnBarRuntimeTests: XCTestCase {
    func test_isRunningTests_detectsXCTestEnvironment() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: ["XCTestConfigurationFilePath": "/tmp/OpenBurnBarTests.xctestconfiguration"],
            loadedBundlePaths: [],
            mainBundleContainsXCTestPlugin: false
        ))
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: ["TEST_RUNNER_CI": "true"],
            loadedBundlePaths: [],
            mainBundleContainsXCTestPlugin: false
        ))
    }

    func test_isRunningTests_detectsLoadedXCTestBundle() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            loadedBundlePaths: ["/tmp/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarTests.xctest"],
            mainBundleContainsXCTestPlugin: false
        ))
    }

    func test_isRunningTests_detectsEmbeddedXCTestPlugin() {
        XCTAssertTrue(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            loadedBundlePaths: ["/tmp/OpenBurnBar.app"],
            mainBundleContainsXCTestPlugin: true
        ))
    }

    func test_isRunningTests_doesNotFlagPlainAppProcess() {
        XCTAssertFalse(OpenBurnBarRuntime.isRunningTests(
            environment: [:],
            loadedBundlePaths: ["/tmp/OpenBurnBar.app"],
            mainBundleContainsXCTestPlugin: false
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
}
