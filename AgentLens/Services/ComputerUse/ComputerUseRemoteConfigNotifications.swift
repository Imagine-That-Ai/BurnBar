import Foundation

extension Notification.Name {
    /// Fired when Firebase Remote Config reports
    /// `computer_use_kill_switch = true`. Live Computer Use coordinators
    /// observe this and panic-halt without needing to own Firebase.
    static let computerUseRemoteConfigKillSwitchDidFire = Notification.Name(
        "OpenBurnBarComputerUseRemoteConfigKillSwitchDidFire"
    )

    /// Fired when Remote Config or local settings changes
    /// `computer_use_phone_control_attestation_required`. Live Computer Use
    /// coordinators observe this so already-running phone-control sessions do
    /// not keep using the startup snapshot.
    static let phoneControlAttestationDidChange = Notification.Name(
        "OpenBurnBarComputerUsePhoneControlAttestationRequirementDidChange"
    )

    /// Fired when Firebase Remote Config reports `memory_extraction_enabled =
    /// false` (or a fetch error fail-closes the gate). The memory extraction
    /// chokepoint observes this and halts extraction without owning Firebase.
    static let memoryRemoteConfigKillSwitchDidFire = Notification.Name(
        "OpenBurnBarMemoryRemoteConfigKillSwitchDidFire"
    )

    /// Fired when Firebase Remote Config reports `memory_cloud_models_enabled =
    /// false` (or a fetch error finds a cached false). The daemon hand-off
    /// observes this and re-sends the memory cloud-models policy disabled.
    static let memoryCloudModelsRemoteConfigKillSwitchDidFire = Notification.Name(
        "OpenBurnBarMemoryCloudModelsRemoteConfigKillSwitchDidFire"
    )

    /// Fired whenever a Memory Pro cloud-models setting or its gate changes
    /// (`MemorySettings.propagateCloudModelsGate`). The daemon manager hands
    /// the policy to the daemon, debounced.
    static let memoryCloudModelsPolicyDidChange = Notification.Name(
        "OpenBurnBarMemoryCloudModelsPolicyDidChange"
    )

    /// Fired at the end of `MacCloudEntitlementStore.publishMembershipEntitlements()`
    /// so the daemon's membership cache can be refreshed without polling.
    static let macCloudEntitlementDidChange = Notification.Name(
        "OpenBurnBarMacCloudEntitlementDidChange"
    )
}

enum ComputerUseRemoteConfigNotificationUserInfo {
    static let phoneControlAttestationRequired = "phoneControlAttestationRequired"
}
