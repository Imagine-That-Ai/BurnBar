import Foundation

/// Mach service and install paths for the minimal privileged input-execution leaf (WS1).
public enum PrivilegedInputXPCConstants: Sendable {
    public static let machServiceName = "com.openburnbar.privileged-input-execution"
    public static let launchDaemonLabel = machServiceName
    public static let installPath =
        "/Library/Application Support/OpenBurnBar/RemoteUnlock/openburnbar-privileged-input-execution"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"
}
