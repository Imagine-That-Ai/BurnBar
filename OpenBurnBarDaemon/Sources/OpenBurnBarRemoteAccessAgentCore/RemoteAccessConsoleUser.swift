import Foundation

/// The interactive GUI login user that the remote-access agent serves.
///
/// On macOS the remote-access agent runs as `root` (a LaunchDaemon) but must act on behalf of
/// the logged-in user: it chowns its control socket to that user and only accepts requests from
/// that user's processes. The agent therefore needs a reliable way to discover *who* is logged
/// into the GUI — even while the screen is locked, which is precisely when Remote Unlock runs.
public struct RemoteAccessConsoleUser: Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32

    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }
}

/// Pure policy for resolving the logged-in GUI user from the system signals available to a
/// root daemon. Kept free of system calls so the decision logic can be unit-tested directly.
///
/// Two signals are combined:
/// 1. `SCDynamicStoreCopyConsoleUser` — the canonical console user. It keeps reporting the
///    logged-in account (e.g. uid 501) *through a screen lock*, because the GUI session is still
///    alive; it only reports `"loginwindow"`/uid 0 once the user has actually logged out or
///    switched to the login window.
/// 2. The owner of `/dev/console` — a legacy fallback. This flips to `root` (uid 0) when the
///    screen is locked, so it must never be trusted over a real console user, but it is a useful
///    backstop if SystemConfiguration is momentarily unavailable.
///
/// The resolver returns `nil` (rather than a sentinel root user) when no real interactive user is
/// present, so callers can keep the daemon alive and simply decline work instead of crashing.
public enum RemoteAccessConsoleUserResolver {
    /// The lowest uid macOS assigns to an interactive login account. Standard user accounts start
    /// at 501; system/service accounts and `root` are below this. The login window itself is
    /// reported with uid 0, so anything below this threshold is "not a real GUI user".
    public static let minimumInteractiveUID: UInt32 = 500

    /// Reserved console-user names that indicate *no* interactive user is logged in.
    public static let nonInteractiveConsoleUserNames: Set<String> = ["loginwindow", "root", ""]

    /// Resolve the logged-in GUI user from the two system signals.
    ///
    /// - Parameters:
    ///   - dynamicStoreUser: Result of `SCDynamicStoreCopyConsoleUser` — the console user name and
    ///     its uid/gid. Pass `nil` when SystemConfiguration returns no user.
    ///   - consoleDeviceOwner: Owner uid/gid of `/dev/console`. Pass `nil` when it cannot be read.
    /// - Returns: The interactive GUI user, or `nil` when only the login window / root is present.
    public static func resolve(
        dynamicStoreUser: (name: String?, uid: UInt32, gid: UInt32)?,
        consoleDeviceOwner: (uid: UInt32, gid: UInt32)?
    ) -> RemoteAccessConsoleUser? {
        if let store = dynamicStoreUser,
           isInteractive(name: store.name, uid: store.uid) {
            return RemoteAccessConsoleUser(uid: store.uid, gid: store.gid)
        }
        if let device = consoleDeviceOwner,
           isInteractive(name: nil, uid: device.uid) {
            return RemoteAccessConsoleUser(uid: device.uid, gid: device.gid)
        }
        return nil
    }

    /// Whether a (name, uid) pair represents a real interactive GUI login user.
    public static func isInteractive(name: String?, uid: UInt32) -> Bool {
        guard uid >= minimumInteractiveUID else { return false }
        if let name {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if nonInteractiveConsoleUserNames.contains(normalized) { return false }
        }
        return true
    }
}
