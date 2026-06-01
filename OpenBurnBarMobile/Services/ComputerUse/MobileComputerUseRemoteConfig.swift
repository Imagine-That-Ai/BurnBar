import FirebaseRemoteConfig
import Foundation
import OpenBurnBarComputerUseCore

enum MobileComputerUseRemoteConfig {
    static func phoneControlAttestationRequired() -> Bool {
        let remoteConfig = RemoteConfig.remoteConfig()
        return remoteConfig.configValue(forKey: PhoneControlAttestationPolicy.remoteConfigKey).boolValue
    }
}