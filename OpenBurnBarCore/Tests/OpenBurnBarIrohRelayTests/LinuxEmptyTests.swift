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

    func testProductionBackendMatchesShippingLibraryConfiguration() {
        let libraryDirectory = ProcessInfo.processInfo.environment[
            "OPENBURNBAR_LINUX_IROH_LIBRARY_DIR"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let libraryDirectory, libraryDirectory.isEmpty == false {
            XCTAssertNotNil(
                OpenBurnBarIrohFFIBackendFactory.make(),
                "shipping Linux builds must compile the production iroh backend"
            )
        } else {
            XCTAssertNil(
                OpenBurnBarIrohFFIBackendFactory.make(),
                "development builds without the native runtime must remain fail-closed"
            )
        }
    }
}
