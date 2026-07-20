#if os(Linux)
import Foundation
import OpenBurnBarEngine

public enum MercuryLinuxCapabilityProbe {
    public static func snapshot(
        mediaSocketPath: String? = MercuryLinuxMediaChannel.defaultSocketPath
    ) -> DaemonMediaCapabilityResponse {
        let media = MercuryLinuxCaptureEngine.mediaCapabilities()
        return DaemonMediaCapabilityResponse(
            platform: "linux",
            available: true,
            mediaSocketPath: mediaSocketPath,
            supportsDaemonToShellFrames: true,
            supportsShellToDaemonControl: false,
            codecsKnown: media.capabilitiesKnown,
            codecs: media.daemonCodecMap,
            source: "COpenBurnBarMediaCapture.media_capability_probe",
            detail: media.capabilitiesKnown
                ? "Daemon-owned capture uses the media C FFI. The shell media socket is daemon-to-shell only; PipeWire fds must be opened by the daemon through xdg-desktop-portal."
                : "Linux media capture crate is not linked or its GStreamer backend is unavailable; codec availability is unknown."
        )
    }
}
#endif
