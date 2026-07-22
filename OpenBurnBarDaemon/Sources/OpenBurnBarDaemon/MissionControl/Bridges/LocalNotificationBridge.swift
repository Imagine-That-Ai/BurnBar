import Foundation
import OpenBurnBarCore

#if os(Linux)
/// Linux's native notification bridge is deliberately small and explicit. The daemon does not
/// search `PATH`, invoke a shell, or attach actions/deep links to a notification. `notify-send`
/// talks to the user's freedesktop notification service through D-Bus.
struct LinuxLocalNotificationAdapter: Sendable {
    static let notifySendPath = "/usr/bin/notify-send"
    static let maximumTitleUTF8Bytes = 120
    static let maximumBodyUTF8Bytes = 2_048

    struct CommandResult: Sendable, Equatable {
        let exitCode: Int32
        let stderr: String

        init(exitCode: Int32, stderr: String = "") {
            self.exitCode = exitCode
            self.stderr = stderr
        }
    }

    enum Availability: Sendable, Equatable {
        case available
        case unavailable
    }

    enum AdapterError: LocalizedError, Equatable, Sendable {
        case unavailable(path: String)
        case emptyTitle
        case emptyBody
        case titleTooLong(maximumBytes: Int)
        case bodyTooLong(maximumBytes: Int)
        case titleContainsControlCharacter
        case bodyContainsControlCharacter
        case launchFailed(String)
        case commandFailed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let path):
                return "Linux local notifications are unavailable: " + path + " is not installed or executable."
            case .emptyTitle:
                return "Linux local notification title must not be empty."
            case .emptyBody:
                return "Linux local notification body must not be empty."
            case .titleTooLong(let maximumBytes):
                return "Linux local notification title exceeds the " + String(maximumBytes) + "-byte limit."
            case .bodyTooLong(let maximumBytes):
                return "Linux local notification body exceeds the " + String(maximumBytes) + "-byte limit."
            case .titleContainsControlCharacter:
                return "Linux local notification title contains an unsupported control character."
            case .bodyContainsControlCharacter:
                return "Linux local notification body contains an unsupported control character."
            case .launchFailed(let detail):
                return "Linux local notification launch failed: " + detail
            case .commandFailed(let exitCode, let stderr):
                let suffix = stderr.isEmpty ? "" : " (" + stderr + ")"
                return "Linux local notification service rejected the notification (exit " + String(exitCode) + ")" + suffix + "."
            }
        }
    }

    typealias ExecutableAvailability = @Sendable (_ path: String) -> Bool
    typealias CommandRunner = @Sendable (_ path: String, _ arguments: [String]) throws -> CommandResult

    private let executablePath: String
    private let executableAvailability: ExecutableAvailability
    private let runCommand: CommandRunner

    /// The path and runner are injectable for deterministic Linux tests. The live bridge always
    /// uses the fixed `/usr/bin/notify-send` default above.
    init(
        executablePath: String = LinuxLocalNotificationAdapter.notifySendPath,
        executableAvailability: @escaping ExecutableAvailability = { path in
            FileManager.default.isExecutableFile(atPath: path)
        },
        runCommand: @escaping CommandRunner = LinuxLocalNotificationAdapter.runProcess
    ) {
        self.executablePath = executablePath
        self.executableAvailability = executableAvailability
        self.runCommand = runCommand
    }

    func availability() -> Availability {
        executableAvailability(executablePath) ? .available : .unavailable
    }

    func deliver(title: String, body: String) throws {
        try validate(title: title, body: body)
        guard executableAvailability(executablePath) else {
            throw AdapterError.unavailable(path: executablePath)
        }

        let arguments = [
            "--app-name=OpenBurnBar",
            "--urgency=normal",
            "--",
            title,
            body
        ]
        let result: CommandResult
        do {
            result = try runCommand(executablePath, arguments)
        } catch {
            let detail = String(error.localizedDescription.prefix(512))
            throw AdapterError.launchFailed(detail)
        }
        guard result.exitCode == 0 else {
            throw AdapterError.commandFailed(
                exitCode: result.exitCode,
                stderr: String(result.stderr.prefix(512))
            )
        }
    }

    private func validate(title: String, body: String) throws {
        try validate(
            title,
            emptyError: .emptyTitle,
            tooLong: .titleTooLong(maximumBytes: Self.maximumTitleUTF8Bytes),
            controlCharacter: .titleContainsControlCharacter,
            maximumBytes: Self.maximumTitleUTF8Bytes,
            allowsLineFeed: false
        )
        try validate(
            body,
            emptyError: .emptyBody,
            tooLong: .bodyTooLong(maximumBytes: Self.maximumBodyUTF8Bytes),
            controlCharacter: .bodyContainsControlCharacter,
            maximumBytes: Self.maximumBodyUTF8Bytes,
            allowsLineFeed: true
        )
    }

    private func validate(
        _ value: String,
        emptyError: AdapterError,
        tooLong: AdapterError,
        controlCharacter: AdapterError,
        maximumBytes: Int,
        allowsLineFeed: Bool
    ) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw emptyError
        }
        guard value.utf8.count <= maximumBytes else {
            throw tooLong
        }
        for scalar in value.unicodeScalars {
            let isLineFeed = scalar.value == 0x0A
            let isControlCharacter = CharacterSet.controlCharacters.contains(scalar)
            guard isControlCharacter == false || (allowsLineFeed && isLineFeed) else {
                throw controlCharacter
            }
        }
    }

    private static func runProcess(path: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stderr = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stderr: stderr)
    }
}
#endif

/// Delivers controller nudges by broadcasting to the OpenBurnBar app. The app posts a real
/// `UserNotifications` banner (same as the previous `osascript display notification` behavior,
/// without spawning `/usr/bin/osascript` or touching `UNUserNotificationCenter` from the helper).
actor BurnBarLocalNotificationBridge {
    static let shared = BurnBarLocalNotificationBridge()

#if os(Linux)
    private let linuxAdapter: LinuxLocalNotificationAdapter

    init(linuxAdapter: LinuxLocalNotificationAdapter = LinuxLocalNotificationAdapter()) {
        self.linuxAdapter = linuxAdapter
    }
#else
    init() {}
#endif

    func deliver(title: String, body: String) async throws {
        #if canImport(Darwin)
        let userInfo: [String: String] = [
            OpenBurnBarDistributedNotifications.titleKey: title,
            OpenBurnBarDistributedNotifications.bodyKey: body
        ]
        DistributedNotificationCenter.default().postNotificationName(
            OpenBurnBarDistributedNotifications.daemonLocalNotificationName,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
        #elseif os(Linux)
        try linuxAdapter.deliver(title: title, body: body)
        #else
        throw NSError(
            domain: "BurnBarLocalNotificationBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local notifications are unavailable on this platform."]
        )
        #endif
    }
}
