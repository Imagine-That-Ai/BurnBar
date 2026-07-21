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
            supportsSealedMediaFrames: media.capabilitiesKnown,
            supportsCallAudioCapture: media.capabilitiesKnown && media.opusEncode && media.pipeWireSource,
            supportsCallVideoCapture: media.capabilitiesKnown && media.vp9Encode && media.pipeWireSource,
            callRequiresMediaSeal: true,
            source: "COpenBurnBarMediaCapture.media_capability_probe",
            detail: media.capabilitiesKnown
                ? "Daemon-owned capture and inbound playback use the media C FFI. "
                    + "Outbound calls require a call-bound MediaFrameAEAD seal before PipeWire "
                    + "audio/video capture starts; inbound Opus frames require an available native "
                    + "audio sink before they are acknowledged as rendered. PipeWire fds must be "
                    + "opened by the daemon through xdg-desktop-portal."
                : "Linux media capture crate is not linked or its GStreamer backend is unavailable; "
                    + "codec availability is unknown."
        )
    }
}
#endif
