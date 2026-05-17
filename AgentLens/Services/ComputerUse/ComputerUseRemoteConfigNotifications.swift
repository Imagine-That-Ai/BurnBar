import Foundation

extension Notification.Name {
    /// Fired when Firebase Remote Config reports
    /// `computer_use_kill_switch = true`. Live Computer Use coordinators
    /// observe this and panic-halt without needing to own Firebase.
    static let computerUseRemoteConfigKillSwitchDidFire = Notification.Name(
        "OpenBurnBarComputerUseRemoteConfigKillSwitchDidFire"
    )
}

