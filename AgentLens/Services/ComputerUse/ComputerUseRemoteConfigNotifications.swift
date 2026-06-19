import Foundation

extension Notification.Name {
    /// Fired when Firebase Remote Config reports
    /// `computer_use_kill_switch = true`. Live Computer Use coordinators
    /// observe this and panic-halt without needing to own Firebase.
    static let computerUseRemoteConfigKillSwitchDidFire = Notification.Name(
        "OpenBurnBarComputerUseRemoteConfigKillSwitchDidFire"
    )

    /// Fired when Firebase Remote Config reports `memory_extraction_enabled =
    /// false` (or a fetch error fail-closes the gate). The memory extraction
    /// chokepoint observes this and halts extraction without owning Firebase.
    static let memoryRemoteConfigKillSwitchDidFire = Notification.Name(
        "OpenBurnBarMemoryRemoteConfigKillSwitchDidFire"
    )
}
