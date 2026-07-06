#if os(Linux)
import Foundation
import OpenBurnBarCore

public enum MercuryLinuxCapabilityProbe {
    public static func snapshot(
        mediaSocketPath: String? = MercuryLinuxMediaChannel.defaultSocketPath
    ) -> DaemonMediaCapabilityResponse {
        DaemonMediaCapabilityResponse(
            platform: "linux",
            available: true,
            mediaSocketPath: mediaSocketPath,
            supportsDaemonToShellFrames: true,
            supportsShellToDaemonControl: true,
            codecsKnown: false,
            codecs: [
                "vp9": false,
                "opus": false,
                "h264": false,
                "av1": false
            ],
            source: "MercuryLinuxCapabilityProbe.stub",
            detail: "Conservative stub: codec availability is unknown until the media crate C-FFI probe is linked; the AF_UNIX media socket is bidirectional."
        )
    }
}
#endif
