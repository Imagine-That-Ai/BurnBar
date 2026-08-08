import XCTest
@testable import OpenBurnBarData

final class SwitcherCLITypeProviderIDMappingTests: XCTestCase {
    func test_providerIDForSwitcherCLIType_mapsJunieAndPrimeAgent() {
        XCTAssertEqual(OpenBurnBarDatabase.providerIDForSwitcherCLIType("junie"), "junie")
        XCTAssertEqual(OpenBurnBarDatabase.providerIDForSwitcherCLIType("prime-agent"), "prime-agent")
        XCTAssertNil(OpenBurnBarDatabase.providerIDForSwitcherCLIType("unknown-cli"))
    }
}
