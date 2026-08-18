import Foundation
@testable import OpenBurnBarIrohRelay
import XCTest

final class OpenBurnBarIrohRelayLinuxEmptyTests: XCTestCase {
    func testLinuxTargetLinks() {
        XCTAssertTrue(true, "Linux target compiles and loads XCTest")
    }

    func testProcessEnvironmentReadable() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment)
    }

    func testProductionBackendMatchesCompiledLibraryConfiguration() {
        #if canImport(OpenBurnBarIrohFFI)
        XCTAssertNotNil(
            OpenBurnBarIrohFFIBackendFactory.make(),
            "builds linked with the native runtime must construct the production iroh backend"
        )
        #else
        XCTAssertNil(
            OpenBurnBarIrohFFIBackendFactory.make(),
            "builds without the native runtime must remain fail-closed"
        )
        #endif
    }
}
