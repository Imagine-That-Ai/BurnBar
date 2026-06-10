import FirebaseRemoteConfig
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

enum MobileComputerUseRemoteConfig {
    static func phoneControlAttestationRequired() -> Bool {
        let remoteConfig = RemoteConfig.remoteConfig()
        return remoteConfig.configValue(forKey: PhoneControlAttestationPolicy.remoteConfigKey).boolValue
    }

    /// F2: whether this device should mint a biometry-gated Secure-Enclave
    /// phone-control signing key (default-off ramp; see
    /// `PhoneControlSecureEnclaveKeyPolicy`).
    static func phoneControlSecureEnclaveKeyEnabled() -> Bool {
        let remoteConfig = RemoteConfig.remoteConfig()
        return remoteConfig.configValue(forKey: PhoneControlSecureEnclaveKeyPolicy.remoteConfigKey).boolValue
    }

    /// F10: whether this phone establishes + seals the control lane
    /// (default-off ramp; both peers must also advertise `control_seal_v1`).
    static func controlSealEnabled() -> Bool {
        let remoteConfig = RemoteConfig.remoteConfig()
        return remoteConfig.configValue(forKey: ControlFrameSealNegotiation.remoteConfigKey).boolValue
    }

    /// F7: whether this phone wraps a media-frame-AEAD key into its mirror
    /// requests (default-off ramp; both peers must also advertise
    /// `media_frame_aead_v1`).
    static func mediaFrameAeadEnabled() -> Bool {
        let remoteConfig = RemoteConfig.remoteConfig()
        return remoteConfig.configValue(forKey: MediaFrameAeadNegotiation.remoteConfigKey).boolValue
    }
}