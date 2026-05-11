import XCTest
@testable import OpenBurnBar

@MainActor
final class LocalNetworkDiscoveryTests: XCTestCase {
    func testClassCCandidatesPutPinnedHostsFirstThenCurrentSubnet() {
        let hosts = LocalNetworkDiscovery.classCCandidates(
            localIPv4Addresses: ["192.168.68.44"],
            pinnedHosts: ["192.168.68.92", "192.168.68.44"]
        )

        XCTAssertEqual(Array(hosts.prefix(3)), ["192.168.68.92", "192.168.68.44", "192.168.68.1"])
        XCTAssertTrue(hosts.contains("192.168.68.254"))
        XCTAssertEqual(hosts.filter { $0 == "192.168.68.44" }.count, 1)
    }

    func testClassCCandidatesIgnoreLoopbackAndSelfAssignedAddresses() {
        let hosts = LocalNetworkDiscovery.classCCandidates(
            localIPv4Addresses: ["127.0.0.1", "169.254.10.20", "10.0.1.7"],
            pinnedHosts: ["127.0.0.1", "169.254.10.20"]
        )

        XCTAssertFalse(hosts.contains("127.0.0.1"))
        XCTAssertFalse(hosts.contains("169.254.10.20"))
        XCTAssertTrue(hosts.contains("10.0.1.92"))
    }
}
