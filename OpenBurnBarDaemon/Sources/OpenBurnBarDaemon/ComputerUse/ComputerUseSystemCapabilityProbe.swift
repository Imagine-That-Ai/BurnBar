import Foundation
import OpenBurnBarCore

/// Read-only capability probe used by the pending-approval RPC.  Session
/// start and input dispatch remain owned by the existing Computer Use service;
/// this seam only reports whether the Linux prerequisites are present.
protocol ComputerUseSystemCapabilityProvider: Sendable {
    func capability() async -> ComputerUseSystemCapabilitySnapshot
}

#if os(Linux)
import OpenBurnBarMedia

actor LinuxComputerUseSystemCapabilityProbe: ComputerUseSystemCapabilityProvider {
    typealias MediaProbe = @Sendable () -> MercuryLinuxMediaCapabilities
    typealias PortalProbe = @Sendable () -> Bool
    typealias KillSwitchProbe = @Sendable () -> Bool

    private let inputAdapter: LinuxComputerUseInputAdapter
    private let mediaProbe: MediaProbe
    private let portalProbe: PortalProbe
    private let killSwitchProbe: KillSwitchProbe

    init(
        inputAdapter: LinuxComputerUseInputAdapter = LinuxComputerUseInputAdapter(),
        mediaProbe: @escaping MediaProbe = MercuryLinuxCaptureEngine.mediaCapabilities,
        portalProbe: @escaping PortalProbe = {
            ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        },
        killSwitchProbe: @escaping KillSwitchProbe = {
            LinuxPrivilegedInputKillFlag.isActive()
                || LinuxPrivilegedInputKillFlag.environmentKillSwitchActive()
        }
    ) {
        self.inputAdapter = inputAdapter
        self.mediaProbe = mediaProbe
        self.portalProbe = portalProbe
        self.killSwitchProbe = killSwitchProbe
    }

    func capability() -> ComputerUseSystemCapabilitySnapshot {
        let media = mediaProbe()
        let portalReady = portalProbe()
        let killSwitchActive = killSwitchProbe()
        let inputReady = inputAdapter.isAvailableForSystemInput() && !killSwitchActive
        let captureReady = portalReady
            && media.capabilitiesKnown
            && media.pipeWireSource
            && media.vp9Encode
        let available = captureReady && inputReady
        let reason: String
        if killSwitchActive {
            reason = "computer_use_kill_switch_active"
        } else if !portalReady {
            reason = "desktop_portal_session_bus_unavailable"
        } else if !media.capabilitiesKnown || !media.pipeWireSource || !media.vp9Encode {
            reason = "pipewire_vp9_capture_unavailable"
        } else if !inputReady {
            reason = "linux_input_adapter_unavailable"
        } else {
            reason = "capture_and_input_ready"
        }
        return ComputerUseSystemCapabilitySnapshot(
            available: available,
            captureReady: captureReady,
            inputReady: inputReady,
            active: false,
            reason: reason
        )
    }
}
#endif
