#if os(Linux)
import Foundation
import OpenBurnBarCore

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
            codecsKnown: true,
            codecs: media.daemonCodecMap,
            source: "COpenBurnBarMediaCapture.media_capability_probe",
            detail: "Daemon-owned capture uses the media C FFI. The shell media socket is daemon-to-shell only; PipeWire fds must be opened by the daemon or transferred with SCM_RIGHTS."
        )
    }
}
#endif
