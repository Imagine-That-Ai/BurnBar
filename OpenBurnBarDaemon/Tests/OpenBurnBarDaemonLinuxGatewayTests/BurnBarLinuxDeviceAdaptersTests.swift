#if os(Linux)
import Foundation
import Glibc
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarLinuxDeviceAdaptersTests: XCTestCase {
    func testAvahiBrowseReadsConcurrentOutputAndCapsTranscript() throws {
        let executable = try makeExecutable(
            "#!/bin/sh\nprintf '%s' \"$(head -c 256 /dev/zero | tr '\\0' 'x')\"\n"
        )
        defer { try? FileManager.default.removeItem(at: executable) }

        let result = BurnBarLinuxDeviceAdapters.testingRunAvahiBrowse(
            executablePath: executable.path,
            timeoutSeconds: 2,
            maxBytes: 64
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertLessThanOrEqual(result.transcript.count, 128)
        XCTAssertTrue(result.transcript.contains("<avahi-output-truncated>"))
    }

    func testAvahiBrowseTerminatesAStalledProcessWithinBoundedTimeout() throws {
        let executable = try makeExecutable("#!/bin/sh\nexec /bin/sleep 5\n")
        defer { try? FileManager.default.removeItem(at: executable) }
        let startedAt = Date()

        let result = BurnBarLinuxDeviceAdapters.testingRunAvahiBrowse(
            executablePath: executable.path,
            timeoutSeconds: 0.1,
            maxBytes: 256
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.transcript.contains("<avahi-timeout>"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testAvahiBrowseReportsLaunchFailureWithoutLeakingExecutablePath() {
        let result = BurnBarLinuxDeviceAdapters.testingRunAvahiBrowse(
            executablePath: "/tmp/openburnbar-missing-avahi-(UUID().uuidString)",
            timeoutSeconds: 1,
            maxBytes: 256
        )

        XCTAssertEqual(result.error, "launch_failed")
        XCTAssertEqual(result.transcript, "")
    }

    func testParityLedgerEvaluatesSmartHubStatusOnce() {
        var statusCalls = 0

        let rows = BurnBarLinuxDeviceAdapters.testingParityLedger(
            avahiAvailable: true,
            homeAssistantConfigured: true,
            smartHubStatusProvider: {
                statusCalls += 1
                return ["status": "bridge_control_ok"]
            }
        )

        XCTAssertEqual(statusCalls, 1)
        let smartHub = rows.first { $0.adapter == "smart_hub_bridge" }
        XCTAssertEqual(smartHub?.status, "control_ready")
        XCTAssertNil(smartHub?.blocker)
    }

    func testParityLedgerKeepsSmartHubBlockerWhenControlProbeFails() {
        let rows = BurnBarLinuxDeviceAdapters.testingParityLedger(
            smartHubStatusProvider: { ["status": "bridge_reachable_control_blocked"] }
        )

        let smartHub = rows.first { $0.adapter == "smart_hub_bridge" }
        XCTAssertEqual(smartHub?.status, "blocked_until_bridge_health_reachable")
        XCTAssertEqual(smartHub?.blocker, "Start Linux SmartHub bridge and rerun CLI status for live control proof.")
    }

    func testDiscoveredEndpointURLBracketsIPv6Literal() {
        XCTAssertEqual(
            BurnBarLinuxDeviceAdapters.testingServiceEndpointURL(address: "192.0.2.10", port: 8787),
            "http://192.0.2.10:8787"
        )
        XCTAssertEqual(
            BurnBarLinuxDeviceAdapters.testingServiceEndpointURL(address: "fe80::1234", port: 8787),
            "http://[fe80::1234]:8787"
        )
        XCTAssertEqual(
            BurnBarLinuxDeviceAdapters.testingServiceEndpointURL(address: "[fe80::1234]", port: 8787),
            "http://[fe80::1234]:8787"
        )
    }

    private func makeExecutable(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-avahi-test-(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }
}
#endif
