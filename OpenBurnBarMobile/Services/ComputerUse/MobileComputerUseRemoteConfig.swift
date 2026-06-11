import FirebaseRemoteConfig
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

enum MobileComputerUseRemoteConfig {
    static func phoneControlAttestationRequired() -> Bool {
        let remoteConfig = RemoteConfig.remoteConfig()
        return remoteConfig.configValue(forKey: PhoneControlAttestationPolicy.remoteConfigKey).boolValue
    }

    /// Default-ON protection flags (pre-launch posture: the strong protocol is
    /// the launch protocol). `.static` means no remote value AND no in-app
    /// default registered yet ⇒ ON; a fetched remote value — the operator's
    /// kill switch — always wins, in either direction.
    private static func protectionFlag(forKey key: String) -> Bool {
        let value = RemoteConfig.remoteConfig().configValue(forKey: key)
        return value.source == .static ? true : value.boolValue
    }

    /// F2: whether this device should mint a biometry-gated Secure-Enclave
    /// phone-control signing key (default ON; Remote Config is the kill switch).
    static func phoneControlSecureEnclaveKeyEnabled() -> Bool {
        protectionFlag(forKey: PhoneControlSecureEnclaveKeyPolicy.remoteConfigKey)
    }

    /// F10: whether this phone establishes + seals the control lane (default
    /// ON; both peers must also advertise `control_seal_v1`).
    static func controlSealEnabled() -> Bool {
        protectionFlag(forKey: ControlFrameSealNegotiation.remoteConfigKey)
    }

    /// F7: whether this phone wraps a media-frame-AEAD key into its mirror
    /// requests (default ON; both peers must also advertise
    /// `media_frame_aead_v1`).
    static func mediaFrameAeadEnabled() -> Bool {
        protectionFlag(forKey: MediaFrameAeadNegotiation.remoteConfigKey)
    }
}