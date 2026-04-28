import Foundation

/// Cross-process notification names for daemon → app handoff (no subprocesses).
public enum OpenBurnBarDistributedNotifications {
    public static let daemonLocalNotificationName = Notification.Name("com.openburnbar.daemon.localNotification")
    public static let titleKey = "title"
    public static let bodyKey = "body"
}

public extension Notification.Name {
    static let openBurnBarAppCheckValidationFailed = Notification.Name("openBurnBarAppCheckValidationFailed")
}
