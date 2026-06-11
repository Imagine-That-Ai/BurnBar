#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Darwin
import Foundation
import OSLog
import OpenBurnBarComputerUseCore

@MainActor
final class RemoteUnlockVirtualHIDBridgeInstaller: ObservableObject {
    static let shared = RemoteUnlockVirtualHIDBridgeInstaller()

    nonisolated static let log = Logger(subsystem: "com.openburnbar.app", category: "RemoteUnlockVirtualHID")

    /// User-facing status string. Always product-ready copy — never raw
    /// installer/spctl output. Exact failure detail is logged and persisted as
    /// the virtual-HID rejection reason for developer diagnostics.
    @Published private(set) var isInstalling = false
    @Published private(set) var lastError: String?

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func installOrRepair() async {
        guard !isInstalling else { return }
        isInstalling = true
        lastError = nil
        defer { isInstalling = false }

        do {
            let fileManager = self.fileManager
            try await Task.detached(priority: .userInitiated) {
                try Self.installOrRepairSynchronously(fileManager: fileManager)
            }.value
            Self.recordPolicyRejection(nil)
            await SystemPermissionMonitor.shared.refreshNow(emitting: true)
        } catch {
            // Keep the exact failure in logs for developer diagnostics; the
            // user only ever sees the product-ready displayMessage copy.
            Self.log.error("Virtual HID bridge install failed: \(String(describing: error), privacy: .public)")
            lastError = Self.displayMessage(for: error)
            if case InstallerError.bridgeRejectedByPolicy(let detail) = error {
                Self.recordPolicyRejection(detail)
            }
            await SystemPermissionMonitor.shared.refreshNow(emitting: true)
        }
    }

    nonisolated private static func installOrRepairSynchronously(fileManager: FileManager) throws {
        let bridgeSource = try resolveHelperBinary(named: "OpenBurnBarVirtualHIDBridge", fileManager: fileManager)
        let privilegedExecutionSource = try resolvePrivilegedInputExecutionSource(fileManager: fileManager)
        let stagingDirectory = URL(fileURLWithPath: "/tmp/openburnbar-virtual-hid-bridge-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingBridge = stagingDirectory.appendingPathComponent("openburnbar-virtual-hid-bridge", isDirectory: false)
        let stagingExecution = stagingDirectory.appendingPathComponent(
            privilegedExecutionSource.stagingName,
            isDirectory: privilegedExecutionSource.isDirectory
        )
        let stagingBridgePlist = stagingDirectory.appendingPathComponent("\(Self.launchDaemonLabel).plist", isDirectory: false)

        try fileManager.copyItem(at: bridgeSource, to: stagingBridge)
        try fileManager.copyItem(at: privilegedExecutionSource.source, to: stagingExecution)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingBridge.path)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: privilegedExecutionSource.executableURL(in: stagingExecution).path
        )
        try bridgeLaunchDaemonPlistData().write(to: stagingBridgePlist, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagingBridgePlist.path)

        let adminScript = """
        set -e
        mkdir -p '\(installDirectory)'
        launchctl bootout system/\(executionLaunchLabel) >/dev/null 2>&1 || true
        launchctl bootout system '\(executionLaunchDaemonPlistPath)' >/dev/null 2>&1 || true
        rm -f '\(executionLaunchDaemonPlistPath)'
        rm -rf '\(RemoteUnlockSetupProbe.legacyPrivilegedInputExecutionInstallPath)'
        rm -rf '\(RemoteUnlockSetupProbe.privilegedInputExecutionBundleInstallPath)'
        cp -R '\(stagingExecution.path)' '\(privilegedExecutionSource.installedContainerPath)'
        chown -R root:wheel '\(privilegedExecutionSource.installedContainerPath)'
        chmod -R go-w '\(privilegedExecutionSource.installedContainerPath)'
        chmod 755 '\(privilegedExecutionSource.installedExecutablePath)'

        cp '\(stagingBridge.path)' '\(installedBinaryPath)'
        chown root:wheel '\(installedBinaryPath)'
        chmod 755 '\(installedBinaryPath)'
        cp '\(stagingBridgePlist.path)' '\(launchDaemonPlistPath)'
        chown root:wheel '\(launchDaemonPlistPath)'
        chmod 644 '\(launchDaemonPlistPath)'
        launchctl bootout system '\(launchDaemonPlistPath)' >/dev/null 2>&1 || true
        rm -f '\(RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath)'
        launchctl bootstrap system '\(launchDaemonPlistPath)'
        launchctl enable system/\(launchDaemonLabel)
        launchctl kickstart -k system/\(launchDaemonLabel)
        """
        try runAdministratorScript(adminScript)
        try startExecutionUserHelper(
            executablePath: privilegedExecutionSource.installedExecutablePath,
            fileManager: fileManager
        )
        try awaitHealthy()
    }

    nonisolated private static func resolveHelperBinary(named name: String, fileManager: FileManager) throws -> URL {
        let appBundleURL = Bundle.main.bundleURL
        let candidates = [
            appBundleURL.appendingPathComponent("Contents/Helpers/\(name)", isDirectory: false),
            appBundleURL.appendingPathComponent("Contents/MacOS/\(name)", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("OpenBurnBarDaemon/.build/arm64-apple-macosx/release/\(name)")
        ]
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        throw InstallerError.bridgeBinaryMissing(candidates.map(\.path))
    }

    nonisolated private static func resolvePrivilegedInputExecutionSource(
        fileManager: FileManager
    ) throws -> PrivilegedInputExecutionSource {
        let appBundleURL = Bundle.main.bundleURL
        let executableRelativePath = "Contents/MacOS/OpenBurnBarPrivilegedInputExecution"
        let appCandidates = [
            appBundleURL.appendingPathComponent(
                "Contents/Helpers/OpenBurnBarPrivilegedInputExecution.app",
                isDirectory: true
            ),
            appBundleURL.appendingPathComponent(
                "Contents/MacOS/OpenBurnBarPrivilegedInputExecution.app",
                isDirectory: true
            ),
            appBundleURL.deletingLastPathComponent().appendingPathComponent(
                "OpenBurnBarPrivilegedInputExecution.app",
                isDirectory: true
            )
        ]
        if let app = appCandidates.first(where: {
            isDirectory($0, fileManager: fileManager)
                && fileManager.isExecutableFile(atPath: $0.appendingPathComponent(executableRelativePath).path)
        }) {
            return PrivilegedInputExecutionSource(
                source: app,
                stagingName: "OpenBurnBarPrivilegedInputExecution.app",
                installedContainerPath: RemoteUnlockSetupProbe.privilegedInputExecutionBundleInstallPath,
                installedExecutablePath: RemoteUnlockSetupProbe.privilegedInputExecutionInstallPath,
                executableRelativePath: executableRelativePath,
                isDirectory: true
            )
        }

        let binary = try resolveHelperBinary(named: "OpenBurnBarPrivilegedInputExecution", fileManager: fileManager)
        return PrivilegedInputExecutionSource(
            source: binary,
            stagingName: "openburnbar-privileged-input-execution",
            installedContainerPath: RemoteUnlockSetupProbe.legacyPrivilegedInputExecutionInstallPath,
            installedExecutablePath: RemoteUnlockSetupProbe.legacyPrivilegedInputExecutionInstallPath,
            executableRelativePath: nil,
            isDirectory: false
        )
    }

    nonisolated private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    nonisolated private static func startExecutionUserHelper(
        executablePath: String,
        fileManager: FileManager
    ) throws {
        let logsDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/OpenBurnBar", isDirectory: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let plistURL = URL(fileURLWithPath: executionLaunchAgentPlistPath)
        let domain = "gui/\(getuid())"
        _ = runProcess(executablePath: "/bin/launchctl", arguments: ["bootout", "\(domain)/\(executionLaunchLabel)"])
        _ = runProcess(executablePath: "/bin/launchctl", arguments: ["bootout", domain, plistURL.path])
        try? fileManager.removeItem(at: plistURL)

        _ = runProcess(executablePath: "/usr/bin/pkill", arguments: ["-f", executablePath])
        try launchDetachedExecutionHelper(
            executablePath: executablePath,
            stdoutPath: logsDirectory
                .appendingPathComponent("openburnbar-privileged-input-execution.log", isDirectory: false)
                .path,
            stderrPath: logsDirectory
                .appendingPathComponent("openburnbar-privileged-input-execution.err.log", isDirectory: false)
                .path
        )
    }

    nonisolated private static func launchDetachedExecutionHelper(
        executablePath: String,
        stdoutPath: String,
        stderrPath: String
    ) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: stdoutPath) {
            fileManager.createFile(atPath: stdoutPath, contents: nil)
        }
        if !fileManager.fileExists(atPath: stderrPath) {
            fileManager.createFile(atPath: stderrPath, contents: nil)
        }

        let stdout = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        try stdout.seekToEnd()
        try stderr.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
    }

    nonisolated private static func bridgeLaunchDaemonPlistData() throws -> Data {
        let plist: [String: Any] = [
            "Label": launchDaemonLabel,
            "ProgramArguments": [
                installedBinaryPath,
                "--socket",
                RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/var/log/openburnbar-virtual-hid-bridge.log",
            "StandardErrorPath": "/var/log/openburnbar-virtual-hid-bridge.err.log",
            "ProcessType": "Interactive"
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    nonisolated private static func runAdministratorScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptLiteral(script)) with administrator privileges"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallerError.administratorScriptFailed(stderr.isEmpty ? stdout : stderr)
        }
    }

    nonisolated private static func awaitHealthy() throws {
        let deadline = Date().addingTimeInterval(8)
        repeat {
            let healthy: Bool
            do {
                healthy = try RemoteUnlockVirtualHIDInputHealthProbe.health()
            } catch {
                healthy = false
            }
            if FileManager.default.fileExists(atPath: RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath),
               healthy {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        try diagnoseInstalledBridgeFailure()
        throw InstallerError.bridgeDidNotBecomeHealthy
    }

    nonisolated private static func diagnoseInstalledBridgeFailure() throws {
        guard FileManager.default.fileExists(atPath: installedBinaryPath) else { return }

        let spctl = runProcess(
            executablePath: "/usr/sbin/spctl",
            arguments: ["-a", "-vvv", "-t", "execute", installedBinaryPath]
        )
        if spctl.status != 0,
           spctl.combinedOutput.localizedCaseInsensitiveContains("rejected") {
            throw InstallerError.bridgeRejectedByPolicy(spctl.combinedOutput)
        }

        let launchctl = runProcess(
            executablePath: "/bin/launchctl",
            arguments: ["print", "system/\(launchDaemonLabel)"]
        )
        if launchctl.combinedOutput.contains("OS_REASON_EXEC") ||
            launchctl.combinedOutput.localizedCaseInsensitiveContains("exec") {
            throw InstallerError.bridgeRejectedByPolicy(launchctl.combinedOutput)
        }

        if FileManager.default.fileExists(atPath: RemoteUnlockSetupProbe.privilegedInputExecutionBundleInstallPath) {
            let executionSpctl = runProcess(
                executablePath: "/usr/sbin/spctl",
                arguments: [
                    "-a",
                    "-vvv",
                    "-t",
                    "execute",
                    RemoteUnlockSetupProbe.privilegedInputExecutionBundleInstallPath
                ]
            )
            if executionSpctl.status != 0,
               executionSpctl.combinedOutput.localizedCaseInsensitiveContains("rejected") {
                throw InstallerError.bridgeRejectedByPolicy(executionSpctl.combinedOutput)
            }
        }
    }

    nonisolated private static func runProcess(
        executablePath: String,
        arguments: [String]
    ) -> (status: Int32, combinedOutput: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, String(describing: error))
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, [stdout, stderr].joined(separator: "\n"))
    }

    nonisolated private static func recordPolicyRejection(_ detail: String?) {
        let defaults = UserDefaults.standard
        if let detail {
            defaults.set(true, forKey: RemoteUnlockSetupProbe.virtualHIDPolicyRejectedKey)
            defaults.set(
                trimmedInstallerDetail(detail),
                forKey: RemoteUnlockSetupProbe.virtualHIDPolicyRejectionReasonKey
            )
        } else {
            defaults.set(false, forKey: RemoteUnlockSetupProbe.virtualHIDPolicyRejectedKey)
            defaults.removeObject(forKey: RemoteUnlockSetupProbe.virtualHIDPolicyRejectionReasonKey)
        }
    }

    nonisolated private static func trimmedInstallerDetail(_ detail: String) -> String {
        let collapsed = detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 260 else { return collapsed }
        return String(collapsed.prefix(257)) + "..."
    }

    nonisolated private static func appleScriptLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Product-ready, action-oriented status for the user. Never names virtual
    /// HID/DriverKit, entitlements, signing, or Apple approval, and never frames
    /// the blocker as the user's fault. Raw failure detail goes to logs /
    /// the persisted rejection reason instead (see `installOrRepair`).
    nonisolated private static func displayMessage(for error: Swift.Error) -> String {
        switch error {
        case InstallerError.bridgeBinaryMissing:
            return "Locked-screen input couldn't be set up on this Mac. Update OpenBurnBar, then choose Set Up Input again."
        case InstallerError.bridgeDidNotBecomeHealthy:
            return "Locked-screen input installed but hasn't turned on yet. Open Privacy & Security, approve OpenBurnBar if prompted, then choose Set Up Input again."
        case InstallerError.bridgeRejectedByPolicy:
            return "Locked-screen input needs one more approval to turn on. Open Privacy & Security on your Mac, approve OpenBurnBar, then choose Set Up Input again."
        case InstallerError.administratorScriptFailed:
            return "macOS didn't finish setting up locked-screen input. Choose Set Up Input again and approve the administrator prompt when it appears."
        default:
            return "Locked-screen input couldn't finish setting up. Choose Set Up Input again to retry."
        }
    }

    nonisolated private static let launchDaemonLabel = "com.openburnbar.virtual-hid-bridge"
    nonisolated private static let executionLaunchLabel =
        RemoteUnlockSetupProbe.privilegedInputExecutionMachService
    nonisolated private static let installDirectory = "/Library/Application Support/OpenBurnBar/RemoteUnlock"
    nonisolated private static let installedBinaryPath = RemoteUnlockSetupProbe.virtualHIDBridgeInstallPath
    nonisolated private static let installedExecutionPath = RemoteUnlockSetupProbe.privilegedInputExecutionInstallPath
    nonisolated private static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"
    nonisolated private static let executionLaunchDaemonPlistPath =
        "/Library/LaunchDaemons/\(executionLaunchLabel).plist"
    nonisolated private static var executionLaunchAgentPlistPath: String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(executionLaunchLabel).plist")
            .path
    }
}

private struct PrivilegedInputExecutionSource {
    var source: URL
    var stagingName: String
    var installedContainerPath: String
    var installedExecutablePath: String
    var executableRelativePath: String?
    var isDirectory: Bool

    func executableURL(in container: URL) -> URL {
        guard let executableRelativePath else { return container }
        return container.appendingPathComponent(executableRelativePath, isDirectory: false)
    }
}

private enum InstallerError: Error, Equatable {
    case administratorScriptFailed(String)
    case bridgeBinaryMissing([String])
    case bridgeDidNotBecomeHealthy
    case bridgeRejectedByPolicy(String)
}

private enum RemoteUnlockVirtualHIDInputHealthProbe {
    static func health() throws -> Bool {
        let request = PrivilegedInputDispatchRequest(operation: "health")
        let envelope = PrivilegedInputDispatchEnvelope(request: request)
        if (try? PrivilegedInputXPCClient(requestTimeout: .seconds(1)).perform(envelope).ok) == true {
            return true
        }
        return try RemoteUnlockVirtualHIDInputRawClient.send(operation: "health")
    }
}

private enum RemoteUnlockVirtualHIDInputRawClient {
    static func send(operation: String) throws -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { return }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let request = #"{"operation":"\#(operation)"}"# + "\n"
        _ = request.withCString { Darwin.write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0 else { return false }
        return String(bytes: buffer.prefix(count), encoding: .utf8)?.contains(#""ok":true"#) == true
    }
}
#endif
