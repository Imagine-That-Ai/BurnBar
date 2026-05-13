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
            localIPv4Addresses: ["127.0.0.1", "169.254.10.20", "100.89.162.125", "10.0.1.7"],
            pinnedHosts: ["127.0.0.1", "169.254.10.20", "100.89.162.125"]
        )

        XCTAssertFalse(hosts.contains("127.0.0.1"))
        XCTAssertFalse(hosts.contains("169.254.10.20"))
        XCTAssertFalse(hosts.contains("100.89.162.125"))
        XCTAssertFalse(hosts.contains("100.89.162.92"))
        XCTAssertTrue(hosts.contains("10.0.1.92"))
    }

    func testSubnetCandidatesCoverFullLocalNetmask() {
        let hosts = LocalNetworkDiscovery.subnetCandidates(
            localIPv4Interfaces: [(address: "192.168.68.93", netmask: "255.255.252.0")],
            pinnedHosts: ["192.168.68.92"]
        )

        XCTAssertEqual(hosts.first, "192.168.68.92")
        XCTAssertTrue(hosts.contains("192.168.68.1"))
        XCTAssertTrue(hosts.contains("192.168.69.1"))
        XCTAssertTrue(hosts.contains("192.168.70.254"))
        XCTAssertTrue(hosts.contains("192.168.71.254"))
        XCTAssertFalse(hosts.contains("192.168.72.1"))
    }

    func testSubnetCandidatesIgnoreTailscaleCarrierGradeNatOverlay() {
        let hosts = LocalNetworkDiscovery.subnetCandidates(
            localIPv4Interfaces: [
                (address: "100.89.162.125", netmask: "255.255.255.0"),
                (address: "192.168.68.89", netmask: "255.255.252.0")
            ],
            pinnedHosts: ["100.89.162.92", "192.168.68.92"]
        )

        XCTAssertEqual(hosts.first, "192.168.68.92")
        XCTAssertFalse(hosts.contains("100.89.162.92"))
        XCTAssertFalse(hosts.contains("100.89.162.1"))
        XCTAssertTrue(hosts.contains("192.168.68.1"))
        XCTAssertTrue(hosts.contains("192.168.71.254"))
    }
}
