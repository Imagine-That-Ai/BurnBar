import FirebaseRemoteConfig
import Foundation
import OpenBurnBarComputerUseCore

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
}