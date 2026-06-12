import Darwin
import Foundation

/// Mach service and install paths for the minimal privileged input-execution leaf (WS1).
public enum PrivilegedInputXPCConstants: Sendable {
    public static let machServiceName = "com.openburnbar.privileged-input-execution"
    public static let launchDaemonLabel = machServiceName
    public static let installPath =
        "/Library/Application Support/OpenBurnBar/RemoteUnlock/openburnbar-privileged-input-execution"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"

    /// Root-owned (0755) parent for per-user socket directories. Created by the
    /// privileged installer script. Because only root can create entries here,
    /// no other local user can pre-create ("squat") a victim's socket path —
    /// the attack that a socket in sticky-bit `/tmp` permits.
    public static let userSessionSocketDirectoryParent =
        "/Library/Application Support/OpenBurnBar/RemoteUnlock/sockets"

    /// Per-user 0700 directory holding that user's execution socket. Owned by
    /// the user (created via the installer's admin script), so the helper can
    /// safely unlink/bind inside it, and nobody else can traverse into it.
    public static func userSessionSocketDirectory(uid: uid_t = getuid()) -> String {
        "\(userSessionSocketDirectoryParent)/\(uid)"
    }

    public static func userSessionSocketPath(uid: uid_t = getuid()) -> String {
        "\(userSessionSocketDirectory(uid: uid))/input.sock"
    }
}
