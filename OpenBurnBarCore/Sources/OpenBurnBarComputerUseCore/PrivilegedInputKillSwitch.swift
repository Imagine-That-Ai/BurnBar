import Foundation

/// Leaf-reaching panic kill flag shared between the Mac app and privileged input daemons.
///
/// When any panic source fires, the app sets this flag; Virtual HID and related leaves check it on
/// every dispatch so input synthesis stops even if the app process crashes afterward.
public enum PrivilegedInputKillSwitch: Sendable {
    public static let productionFlagPath = "/var/run/openburnbar-privileged-input-kill"

    /// Override for unit tests (`OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH`).
    public static var flagPath: String {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH"],
           !override.isEmpty {
            return override
        }
        return productionFlagPath
    }

    public static var isActive: Bool {
        FileManager.default.fileExists(atPath: flagPath)
    }

    public static func activate(reason: String? = nil) {
        let payload = reason ?? "panic"
        do {
            try payload.write(toFile: flagPath, atomically: true, encoding: .utf8)
        } catch {
            fputs("PrivilegedInputKillSwitch.activate failed: \(error)\n", stderr)
        }
    }

    public static func clear() {
        do {
            if FileManager.default.fileExists(atPath: flagPath) {
                try FileManager.default.removeItem(atPath: flagPath)
            }
        } catch {
            fputs("PrivilegedInputKillSwitch.clear failed: \(error)\n", stderr)
        }
    }

    public static func assertNotActive() throws {
        guard !isActive else {
            throw KillSwitchActive()
        }
    }

    public struct KillSwitchActive: Error, Equatable, Sendable {}
}
