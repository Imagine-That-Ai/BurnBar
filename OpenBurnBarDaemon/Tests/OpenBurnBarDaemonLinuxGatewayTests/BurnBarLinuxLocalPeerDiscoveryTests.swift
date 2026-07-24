#if os(Linux)
import Foundation
import Glibc
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarLinuxLocalPeerDiscoveryTests: XCTestCase {
    func testBrowsePeersTerminatesAStalledAvahiProcessWithinTimeout() throws {
        let fixture = try makeAvahiBrowseFixture(script: "#!/bin/sh\nexec /bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let startedAt = Date()

        XCTAssertThrowsError(
            try BurnBarLinuxLocalPeerDiscovery.browsePeers(
                timeoutSeconds: 0.1,
                environment: ["PATH": fixture.directory.path]
            )
        ) { error in
            guard case BurnBarLinuxLocalPeerDiscovery.DiscoveryError.browseFailed(let detail) = error else {
                return XCTFail("Expected a typed browse failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testBrowsePeersReportsNonZeroAvahiExit() throws {
        let fixture = try makeAvahiBrowseFixture(script: "#!/bin/sh\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertThrowsError(
            try BurnBarLinuxLocalPeerDiscovery.browsePeers(
                timeoutSeconds: 1,
                environment: ["PATH": fixture.directory.path]
            )
        ) { error in
            guard case BurnBarLinuxLocalPeerDiscovery.DiscoveryError.browseFailed(let detail) = error else {
                return XCTFail("Expected a typed browse failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("status 7"))
        }
    }

    func testBrowsePeersParsesSuccessfulAvahiOutput() throws {
        let fixture = try makeAvahiBrowseFixture(
            script: """
            #!/bin/sh
            printf '%s\\n' '=;eth0;IPv4;OpenBurnBar-Test;_openburnbar-peer._tcp;local;host.local;192.168.1.2;5959;"daemon_version=1.0" "platform=linux"'
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let peers = try BurnBarLinuxLocalPeerDiscovery.browsePeers(
            timeoutSeconds: 1,
            environment: ["PATH": fixture.directory.path]
        )

        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.instanceName, "OpenBurnBar-Test")
        XCTAssertEqual(peers.first?.hostName, "host.local")
        XCTAssertEqual(peers.first?.port, 5959)
        XCTAssertEqual(peers.first?.txt["daemon_version"], "1.0")
        XCTAssertEqual(peers.first?.txt["platform"], "linux")
    }

    private func makeAvahiBrowseFixture(script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-peer-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("avahi-browse", isDirectory: false)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        return (directory, executable)
    }
}
#endif
