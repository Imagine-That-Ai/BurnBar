#if os(Linux)
import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarLinuxLocalPeerDiscoveryTests: XCTestCase {
    func testSanitizedTXTExcludesSecretsAndPaths() {
        let txt = BurnBarLinuxLocalPeerDiscovery.sanitizedTXT(
            daemonVersion: "1.0.27",
            protocolVersion: "1"
        )
        XCTAssertEqual(txt["platform"], "linux")
        XCTAssertEqual(txt["pairing"], "mdns")
        XCTAssertNil(txt["socket"])
        XCTAssertNil(txt["token"])
        XCTAssertNil(txt["auth"])
        for value in txt.values {
            XCTAssertFalse(value.contains("/home/"))
            XCTAssertFalse(value.contains("/run/"))
        }
    }

    func testIsDiscoveryDisabledHonorsEnvironment() {
        XCTAssertFalse(
            BurnBarLinuxLocalPeerDiscovery.isDiscoveryDisabled(
                environment: ["OPENBURNBAR_DISABLE_LOCAL_DISCOVERY": "0"]
            )
        )
        XCTAssertTrue(
            BurnBarLinuxLocalPeerDiscovery.isDiscoveryDisabled(
                environment: ["OPENBURNBAR_DISABLE_LOCAL_DISCOVERY": "1"]
            )
        )
    }

    func testParsesRealAvahiQuotedTXTFixture() {
        let fixture = """
        =;lo;IPv4;OpenBurnBar\\032validator;_openburnbar-peer._tcp;local;host.local;127.0.0.1;8317;"socket=unix" "proto=1" "platform=linux" "peer=peer-linux-validator" "gateway=loopback" "caps=cast,cli"
        """
        let peers = BurnBarLinuxLocalPeerDiscovery.testing_parseBrowseOutput(fixture)
        XCTAssertEqual(peers.count, 1)
        let peer = try XCTUnwrap(peers.first)
        XCTAssertEqual(peer.instanceName, "OpenBurnBar validator")
        XCTAssertEqual(peer.hostName, "host.local")
        XCTAssertEqual(peer.port, 8317)
        XCTAssertEqual(peer.txt["socket"], "unix")
        XCTAssertEqual(peer.txt["proto"], "1")
        XCTAssertEqual(peer.txt["platform"], "linux")
        XCTAssertEqual(peer.txt["peer"], "peer-linux-validator")
        XCTAssertEqual(peer.txt["gateway"], "loopback")
        XCTAssertEqual(peer.txt["caps"], "cast,cli")
    }
}
#endif