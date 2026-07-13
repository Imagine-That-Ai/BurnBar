#if os(Linux)
import Foundation
import OpenBurnBarCore

/// Native Linux text-expansion integration boundary.
///
/// IBus and Fcitx are input-method protocols, not global keyboard hooks.  The
/// daemon only probes their control commands and never reads evdev/uinput,
/// compositor events, clipboard contents, or surrounding text.  A packaged
/// engine still has to be registered before external expansion can be enabled;
/// this adapter intentionally reports that boundary instead of claiming an
/// integration that is not installed.
public struct BurnBarLinuxTextExpansionAdapter: Sendable {
    public enum Backend: String, Sendable {
        case ibus
        case fcitx5
        case fcitx
    }

    public enum SecureFieldDecision: Equatable, Sendable {
        case allow
        case deniedSecureField
        case deniedExcludedApplication
        case deniedUninspectable
    }

    /// Metadata supplied by a future IBus/Fcitx engine.  It contains only
    /// accessibility state and identifiers; it must never contain field text.
    public struct SecureFieldContext: Equatable, Sendable {
        public let inspectable: Bool
        public let isSecureField: Bool?
        public let applicationID: String?
        public let role: String?
        public let inputPurpose: String?

        public init(
            inspectable: Bool,
            isSecureField: Bool? = nil,
            applicationID: String? = nil,
            role: String? = nil,
            inputPurpose: String? = nil
        ) {
            self.inspectable = inspectable
            self.isSecureField = isSecureField
            self.applicationID = applicationID
            self.role = role
            self.inputPurpose = inputPurpose
        }
    }

    public typealias EnvironmentReader = @Sendable (_ name: String) -> String?
    public typealias ExecutableResolver = @Sendable (_ name: String) -> String?
    public typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) throws -> CommandResult

    public struct CommandResult: Equatable, Sendable {
        public let exitCode: Int32

        public init(exitCode: Int32) {
            self.exitCode = exitCode
        }
    }

    /// Default resolver used by the daemon. It only searches PATH for the
    /// named input-method control utility.
    public static func defaultExecutablePath(_ name: String) -> String? {
        which(name)
    }

    /// Default bounded control probe. Output is drained and discarded.
    public static func defaultCommandRunner(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
        try runProcess(executablePath: executablePath, arguments: arguments)
    }

    private let environment: EnvironmentReader
    private let resolveExecutable: ExecutableResolver
    private let runCommand: CommandRunner
    private let excludedApplicationIDs: Set<String>

    public init(
        environment: @escaping EnvironmentReader = { ProcessInfo.processInfo.environment[$0] },
        resolveExecutable: @escaping ExecutableResolver = BurnBarLinuxTextExpansionAdapter.defaultExecutablePath,
        runCommand: @escaping CommandRunner = BurnBarLinuxTextExpansionAdapter.defaultCommandRunner,
        excludedApplicationIDs: Set<String> = []
    ) {
        self.environment = environment
        self.resolveExecutable = resolveExecutable
        self.runCommand = runCommand
        self.excludedApplicationIDs = Set(excludedApplicationIDs.map(Self.normalizeIdentifier))
    }

    /// Returns a capability snapshot suitable for the existing daemon text
    /// expansion response.  Health checks never include command output.
    public func status() -> BurnBarTextExpansionNativeStatus {
        let session = sessionType()
        let configured = configuredBackend()
        let candidates = candidateBackends(preferred: configured)
        var discoveredPath: String?
        var discoveredBackend: Backend?
        var sawExecutable = false
        var failureDetail: String?

        for backend in candidates {
            guard let path = commandPath(for: backend) else { continue }
            sawExecutable = true
            let result: CommandResult
            do {
                result = try runCommand(path, commandArguments(for: backend))
            } catch {
                failureDetail = "\(backend.rawValue) control probe failed."
                continue
            }
            guard result.exitCode == 0 else {
                failureDetail = "\(backend.rawValue) control probe is not running."
                continue
            }
            discoveredBackend = backend
            discoveredPath = path
            break
        }

        guard let backend = discoveredBackend else {
            let detail: String
            if sawExecutable {
                detail = failureDetail ?? "An installed input method did not report a running session."
            } else {
                detail = "No IBus or Fcitx control executable is available in PATH."
            }
            return makeStatus(
                status: "blocked",
                backend: configured?.rawValue,
                backendPath: nil,
                sessionType: session,
                detail: detail
            )
        }

        guard session != "unknown" else {
            return makeStatus(
                status: "blocked",
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                detail: "Input method is running, but the desktop session type is not provable."
            )
        }

        return makeStatus(
            status: "degraded",
            backend: backend.rawValue,
            backendPath: discoveredPath,
            sessionType: session,
            detail: "\(backend.rawValue) is reachable, but the BurnBar input-method engine is not registered; external expansion remains disabled."
        )
    }

    /// Apply the native engine's secure-field signal without inspecting field
    /// text. Unknown or uninspectable contexts are denied by default.
    public func secureFieldDecision(for context: SecureFieldContext) -> SecureFieldDecision {
        if let applicationID = context.applicationID,
           excludedApplicationIDs.contains(Self.normalizeIdentifier(applicationID)) {
            return .deniedExcludedApplication
        }
        guard context.inspectable else { return .deniedUninspectable }
        if context.isSecureField == true || Self.looksSecure(role: context.role, purpose: context.inputPurpose) {
            return .deniedSecureField
        }
        guard context.isSecureField == false else { return .deniedUninspectable }
        return .allow
    }

    private func makeStatus(
        status: String,
        backend: String?,
        backendPath: String?,
        sessionType: String,
        detail: String
    ) -> BurnBarTextExpansionNativeStatus {
        BurnBarTextExpansionNativeStatus(
            status: status,
            backend: backend,
            backendPath: backendPath,
            sessionType: sessionType,
            registration: "engine_not_registered",
            supportsExternalExpansion: false,
            secureFieldPolicy: "deny-unless-inspectable-and-explicitly-nonsecure",
            noGlobalCapture: true,
            detail: detail,
            checkedAt: Self.isoNow()
        )
    }

    private func sessionType() -> String {
        if let session = Self.nonEmpty(environment("XDG_SESSION_TYPE"))?.lowercased(),
           session == "wayland" || session == "x11" {
            return session
        }
        if Self.nonEmpty(environment("WAYLAND_DISPLAY")) != nil { return "wayland" }
        if Self.nonEmpty(environment("DISPLAY")) != nil { return "x11" }
        return "unknown"
    }

    private func configuredBackend() -> Backend? {
        let values = ["GTK_IM_MODULE", "QT_IM_MODULE", "SDL_IM_MODULE", "CLUTTER_IM_MODULE", "XMODIFIERS"]
            .compactMap { Self.nonEmpty(environment($0))?.lowercased() }
        if values.contains(where: { $0.contains("fcitx5") }) { return .fcitx5 }
        if values.contains(where: { $0.contains("fcitx") }) { return .fcitx }
        if values.contains(where: { $0.contains("ibus") }) { return .ibus }
        return nil
    }

    private func candidateBackends(preferred: Backend?) -> [Backend] {
        let all: [Backend] = [.fcitx5, .fcitx, .ibus]
        guard let preferred else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    private func commandPath(for backend: Backend) -> String? {
        switch backend {
        case .ibus:
            return resolveExecutable("ibus")
        case .fcitx5:
            return resolveExecutable("fcitx5-remote")
        case .fcitx:
            return resolveExecutable("fcitx-remote")
        }
    }

    private func commandArguments(for backend: Backend) -> [String] {
        switch backend {
        case .ibus:
            // `ibus engine` reads the active engine and does not mutate input
            // state or retrieve surrounding/field text.
            return ["engine"]
        case .fcitx5, .fcitx:
            return ["--check"]
        }
    }

    private static func looksSecure(role: String?, purpose: String?) -> Bool {
        let words = [role, purpose]
            .compactMap { nonEmpty($0)?.lowercased() }
            .joined(separator: " ")
        return [
            "password", "passcode", "pin", "credential", "secret", "private",
            "secure", "protected", "authentication", "authorization", "polkit",
            "keyring", "kwallet", "login"
        ].contains { words.contains($0) }
    }

    private static func normalizeIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func which(_ name: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return pathValue.split(separator: ":").map(String.init)
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            _ = error.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(exitCode: 124)
        }
        // Drain both pipes but intentionally discard their contents. Input
        // method commands must never make field text part of diagnostics.
        _ = output.fileHandleForReading.readDataToEndOfFile()
        _ = error.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(exitCode: process.terminationStatus)
    }
}
#endif
