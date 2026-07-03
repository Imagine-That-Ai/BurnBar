#if !canImport(LibSignalClient)
import XCTest
import OpenBurnBarSignalSessionTransport

final class OBBSignalSessionTransportUnavailableTests: XCTestCase {
    func testLinuxContractImportReportsMissingLibSignalImplementation() {
        XCTAssertFalse(OpenBurnBarSignalSessionTransportAvailability.isLibSignalBacked)
    }
}
#endif
