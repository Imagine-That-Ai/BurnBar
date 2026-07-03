import XCTest
@testable import OpenBurnBarCore

final class LinuxLocalPeerDiscoveryTests: XCTestCase {
    func testAvahiPublishPlanUsesStablePrivacySafeMetadata() throws {
        let metadata = BurnBarLocalPeerMetadata(
            instanceName: "OpenBurnBar devbox",
            peerID: "peer-linux-123",
            port: 8317
        )

        let plan = BurnBarAvahiCommandFactory.publishPlan(for: metadata)

        XCTAssertEqual(plan.argv[0], "avahi-publish-service")
        XCTAssertEqual(plan.argv[2], "OpenBurnBar devbox")
        XCTAssertEqual(plan.argv[3], "_openburnbar._tcp")
        XCTAssertEqual(plan.argv[4], "8317")
        XCTAssertTrue(plan.argv.contains("platform=linux"))
        XCTAssertTrue(plan.argv.contains("proto=1"))
        XCTAssertTrue(plan.argv.contains("socket=unix"))
        XCTAssertTrue(plan.argv.contains("gateway=loopback"))
        XCTAssertEqual(metadata.privacyValidationIssues(), [])
        XCTAssertFalse(plan.argv.joined(separator: " ").contains("/Users/"))
        XCTAssertFalse(plan.argv.joined(separator: " ").lowercased().contains("token"))

        let browse = BurnBarAvahiCommandFactory.browsePlan()
        XCTAssertEqual(browse.argv, ["avahi-browse", "--resolve", "--parsable", "--terminate", "_openburnbar._tcp"])
    }

    func testAvahiBrowseParserConflictTeardownAndDisabledState() throws {
        let transcript = """
        +;enp4s0;IPv4;OpenBurnBar devbox;_openburnbar._tcp;local
        =;enp4s0;IPv4;OpenBurnBar devbox;_openburnbar._tcp;local;devbox.local;192.168.1.20;8317;peer=peer-linux-123;proto=1;platform=linux;caps=cast,cli,homeassistant,http,pixelclock,smarthub;socket=unix;gateway=loopback
        -;enp4s0;IPv4;OpenBurnBar devbox;_openburnbar._tcp;local
        """

        let services = BurnBarAvahiBrowseParser.parse(transcript)
        XCTAssertEqual(services.count, 3)
        let resolved = try XCTUnwrap(services.first { $0.eventKind == .resolved })
        XCTAssertEqual(resolved.instanceName, "OpenBurnBar devbox")
        XCTAssertEqual(resolved.endpoint, "192.168.1.20:8317")
        XCTAssertEqual(resolved.txtRecords["peer"], "peer-linux-123")
        XCTAssertEqual(resolved.txtRecords["socket"], "unix")

        let metadata = BurnBarLocalPeerMetadata(instanceName: "OpenBurnBar devbox", peerID: "peer-linux-123", port: 8317)
        let conflict = BurnBarAvahiRegistrationResult.evaluate(
            metadata: metadata,
            transcript: "Failed to add service: Local name collision"
        )
        XCTAssertTrue(conflict.conflictDetected)
        XCTAssertEqual(conflict.fallbackInstanceName, "OpenBurnBar devbox-peer-l")

        let lifecycle = BurnBarAvahiLifecycleEvidence(
            serviceName: "OpenBurnBar devbox",
            registerTranscript: "Established under name 'OpenBurnBar devbox'",
            browseTranscript: transcript,
            teardownTranscript: "-;enp4s0;IPv4;OpenBurnBar devbox;_openburnbar._tcp;local"
        )
        XCTAssertTrue(lifecycle.teardownObserved)

        let disabled = BurnBarAvahiDisabledState.disabled(reason: "OPENBURNBAR_LINUX_MDNS=0")
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(disabled.publishCommand, [])
        XCTAssertEqual(disabled.reason, "OPENBURNBAR_LINUX_MDNS=0")
    }

    func testPixelClockAdapterBuildsControlPlansAndDoesNotSilentlyDemoteFirmwareFlashing() throws {
        let transcript = """
        =;wlp0s20f3;IPv4;awtrix_clock_01;_http._tcp;local;awtrix-clock.local;192.168.1.42;80;model=AWTRIX3;id=pixel-01
        """
        let services = BurnBarAvahiBrowseParser.parse(transcript)
        let report = BurnBarPixelClockLinuxAdapter.evaluate(services: services)

        XCTAssertEqual(report.discoveredServices.count, 1)
        XCTAssertEqual(report.controlPlans.map(\.url), [
            "http://192.168.1.42:80/api/stats",
            "http://192.168.1.42:80/api/custom?name=openburnbar",
            "http://192.168.1.42:80/api/notify"
        ])
        XCTAssertEqual(report.parityRows.first?.contractID, "VAL-DEVICE-001")
        XCTAssertEqual(report.parityRows.first?.status, .ready)

        let blockedFirmware = BurnBarPixelClockLinuxAdapter.evaluateFirmwareLane(
            prerequisites: BurnBarPixelClockFirmwarePrerequisites(
                networkManagerDBusAvailable: false,
                libUdevAvailable: false,
                serialDevices: [],
                firmwareImagePath: nil
            )
        )
        XCTAssertEqual(blockedFirmware.status, .blocked)
        XCTAssertTrue(blockedFirmware.attemptedCommands.contains("busctl introspect org.freedesktop.NetworkManager /org/freedesktop/NetworkManager"))
        XCTAssertTrue(blockedFirmware.attemptedCommands.contains("udevadm info --export-db"))
        XCTAssertTrue(blockedFirmware.blocker?.contains("NetworkManager DBus service") == true)
        XCTAssertTrue(blockedFirmware.blocker?.contains("libudev") == true)
        XCTAssertTrue(blockedFirmware.blocker?.contains("serial device") == true)
        XCTAssertTrue(blockedFirmware.blocker?.contains("firmware image") == true)

        let attemptedFirmware = BurnBarPixelClockLinuxAdapter.evaluateFirmwareLane(
            prerequisites: BurnBarPixelClockFirmwarePrerequisites(
                networkManagerDBusAvailable: true,
                libUdevAvailable: true,
                serialDevices: ["/dev/ttyUSB0"],
                firmwareImagePath: "/opt/openburnbar/pixelclock.bin"
            )
        )
        XCTAssertEqual(attemptedFirmware.status, .attempted)
        XCTAssertTrue(attemptedFirmware.attemptedCommands.contains("udevadm info --query=property --name=/dev/ttyUSB0"))
        XCTAssertTrue(attemptedFirmware.attemptedCommands.contains("python3 -m esptool --chip esp32 --port /dev/ttyUSB0 write_flash 0x0 /opt/openburnbar/pixelclock.bin"))
    }

    func testSmartHubCastAndHomeAssistantAdaptersConsumeResolvedAvahiServices() throws {
        let transcript = """
        =;enp4s0;IPv4;OpenBurnBar devbox;_openburnbar._tcp;local;devbox.local;192.168.1.20;8317;peer=peer-linux-123;proto=1;platform=linux;caps=cli,http,smarthub;socket=unix
        =;wlp0s20f3;IPv4;Living Room TV;_googlecast._tcp;local;living-room-tv.local;192.168.1.51;8009;fn=Living Room TV;md=Chromecast
        =;enp4s0;IPv4;homeassistant;_home-assistant._tcp;local;ha.local;192.168.1.60;8123;version=2026.7.0
        """
        let services = BurnBarAvahiBrowseParser.parse(transcript)
        let reports = BurnBarLinuxIoTAdapterSuite.evaluate(services: services)
        let rows = reports.flatMap(\.parityRows)

        XCTAssertEqual(Set(reports.map(\.adapter)), Set(["SmartHub", "Cast", "HomeAssistant"]))
        XCTAssertTrue(reports.flatMap(\.controlPlans).contains { $0.url == "http://192.168.1.20:8317/local-peer/status" })
        XCTAssertTrue(reports.flatMap(\.controlPlans).contains { $0.url == "http://192.168.1.51:8009/setup/eureka_info?options=detail" })
        XCTAssertTrue(reports.flatMap(\.controlPlans).contains { $0.url == "http://192.168.1.60:8123/api/" })
        XCTAssertEqual(Set(rows.map(\.contractID)), Set(["VAL-IOT-001"]))
        XCTAssertTrue(rows.allSatisfy { $0.status == .ready })

        let absentReports = BurnBarLinuxIoTAdapterSuite.evaluate(services: [])
        XCTAssertTrue(absentReports.flatMap(\.parityRows).allSatisfy { $0.status == .blocked })
        XCTAssertTrue(absentReports.flatMap(\.parityRows).allSatisfy { $0.blocker?.contains("no resolved Avahi service") == true || $0.blocker?.contains("fixture") == true })
    }
}
