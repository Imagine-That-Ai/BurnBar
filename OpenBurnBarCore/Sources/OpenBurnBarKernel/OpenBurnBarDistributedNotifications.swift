import Foundation

/// Cross-process notification names for daemon → app handoff (no subprocesses).
public enum OpenBurnBarDistributedNotifications {
    public static let daemonLocalNotificationName = Notification.Name("com.openburnbar.daemon.localNotification")
    public static let titleKey = "title"
    public static let bodyKey = "body"
    /// Optional `openburnbar://` deep link, so tapping the notification lands on
    /// the thing it is about rather than just raising the app.
    public static let deepLinkKey = "deepLink"
    /// Optional producer tag. The app routes on this: agent-completion
    /// notifications honour the Pixel Clock settings, while other kinds (the AI
    /// Inbox) must not be silently suppressed by an unrelated toggle.
    public static let categoryKey = "category"

    /// Well-known `categoryKey` values.
    public enum Category {
        public static let agentCompletion = "agent_completion"
        public static let aiInbox = "ai_inbox"
    }
}

public extension Notification.Name {
    static let openBurnBarAppCheckValidationFailed = Notification.Name("openBurnBarAppCheckValidationFailed")
}
