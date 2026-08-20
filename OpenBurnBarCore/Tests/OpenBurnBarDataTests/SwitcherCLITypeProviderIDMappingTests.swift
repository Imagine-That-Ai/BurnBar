import XCTest
@testable import OpenBurnBarData

final class SwitcherCLITypeProviderIDMappingTests: XCTestCase {
    func test_providerIDForSwitcherCLIType_mapsJuniePrimeAgentAndFx() {
        XCTAssertEqual(OpenBurnBarDatabase.providerIDForSwitcherCLIType("junie"), "junie")
        XCTAssertEqual(OpenBurnBarDatabase.providerIDForSwitcherCLIType("prime-agent"), "prime-agent")
        XCTAssertEqual(OpenBurnBarDatabase.providerIDForSwitcherCLIType("fx"), "fx")
        XCTAssertNil(OpenBurnBarDatabase.providerIDForSwitcherCLIType("unknown-cli"))
    }
}
