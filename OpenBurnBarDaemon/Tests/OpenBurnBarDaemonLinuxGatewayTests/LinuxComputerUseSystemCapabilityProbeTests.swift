#if os(Linux)
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxComputerUseSystemCapabilityProbeTests: XCTestCase {
    func testRequiresPortalAndCaptureBeforeAdvertisingAvailability() async {
        let probe = makeProbe(portalReady: false)

        let capability = await probe.capability()

        XCTAssertFalse(capability.available)
        XCTAssertFalse(capability.captureReady)
        XCTAssertTrue(capability.inputReady)
        XCTAssertEqual(capability.reason, "desktop_portal_session_bus_unavailable")
    }

    func testAdvertisesReadyWhenCaptureAndInputPrerequisitesAreLive() async {
        let probe = makeProbe(portalReady: true)

        let capability = await probe.capability()

        XCTAssertTrue(capability.available)
        XCTAssertTrue(capability.captureReady)
        XCTAssertTrue(capability.inputReady)
        XCTAssertFalse(capability.active)
        XCTAssertEqual(capability.reason, "capture_and_input_ready")
        XCTAssertEqual(capability.source, "linux-system-runtime")
    }

    func testKillSwitchFailsClosed() async {
        let probe = makeProbe(portalReady: true, killSwitchActive: true)

        let capability = await probe.capability()

        XCTAssertFalse(capability.available)
        XCTAssertFalse(capability.inputReady)
        XCTAssertEqual(capability.reason, "computer_use_kill_switch_active")
    }

    private func makeProbe(
        portalReady: Bool,
        killSwitchActive: Bool = false
    ) -> LinuxComputerUseSystemCapabilityProbe {
        let input = LinuxComputerUseInputAdapter(
            environment: { name in
                name == "DISPLAY" ? ":1" : nil
            },
            resolveExecutable: { name in
                name == "xdotool" ? "/usr/bin/xdotool" : nil
            },
            runCommand: { _, _ in
                LinuxComputerUseInputAdapter.CommandResult(exitCode: 0)
            }
        )
        return LinuxComputerUseSystemCapabilityProbe(
            inputAdapter: input,
            mediaProbe: {
                MercuryLinuxMediaCapabilities(
                    capabilitiesKnown: true,
                    vp9Encode: true,
                    vp9Decode: true,
                    av1Encode: false,
                    av1Decode: false,
                    opusEncode: true,
                    opusDecode: true,
                    pipeWireSource: true
                )
            },
            portalProbe: { portalReady },
            killSwitchProbe: { killSwitchActive }
        )
    }
}
#endif
