import Foundation

// MARK: - CLI Auth State

/// The authentication state of a CLI tool.
public enum CLIAuthState: Equatable, Sendable {
    /// OAuth session is valid, optionally with last refresh time.
    case authenticated(lastRefresh: Date?)
    /// An API key file exists (key value NOT stored — just presence check).
    case apiKeyPresent
    /// CLI is installed but not authenticated.
    case notAuthenticated
    /// CLI is not installed on this system.
    case notInstalled
}

// MARK: - CLI Auth Info

/// Non-sensitive metadata about a CLI tool's installation and auth state.
public struct CLIAuthInfo: Identifiable, Equatable, Sendable {
    public let cliType: SwitcherCLIProfileType
    public let isInstalled: Bool
    public let executablePath: String?
    public let authState: CLIAuthState
    public let configDirectory: String?
    public let accountDescription: String?

    public var id: String { cliType.rawValue }

    public init(
        cliType: SwitcherCLIProfileType,
        isInstalled: Bool,
        executablePath: String?,
        authState: CLIAuthState,
        configDirectory: String? = nil,
        accountDescription: String? = nil
    ) {
        self.cliType = cliType
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        self.authState = authState
        self.configDirectory = configDirectory
        self.accountDescription = accountDescription
    }

    public init(
        cliType: SwitcherCLIProfileType,
        authState: CLIAuthState,
        isInstalled: Bool,
        accountDescription: String?,
        configDirectory: String?,
        executablePath: String?
    ) {
        self.init(
            cliType: cliType,
            isInstalled: isInstalled,
            executablePath: executablePath,
            authState: authState,
            configDirectory: configDirectory,
            accountDescription: accountDescription
        )
    }
}

// MARK: - CLI Auth Discovery

/// Discovers CLI installation and authentication states.
///
/// Security: Only reads non-sensitive local auth metadata needed for display.
/// Raw API keys, OAuth tokens, and credentials are never stored or surfaced.
/// When token-backed auth is present, only safe identity claims like name/email
/// are extracted in-memory for UI labels.
///
/// Platform note: this enum drives the Mac-side CLI auth panel. The active
/// surface relies on Mac-only Foundation APIs (`Process`,
/// `homeDirectoryForCurrentUser`) and the Mac-only `CLILaunchAdapter`. iOS
/// builds (`OpenBurnBarMobile`) ship the type as a no-op so this file can
/// stay in the shared `OpenBurnBarCore` package.
public enum CLIAuthDiscovery {

    /// Scans all CLI types and returns their auth states.
    public static func discoverAuthStates() -> [CLIAuthInfo] {
        return SwitcherCLIProfileType.allCases.map { cliType in
            discoverAuthState(for: cliType)
        }
    }

    /// Discovers auth state for a single CLI type.
    public static func discoverAuthState(
        for cliType: SwitcherCLIProfileType,
        configDirectoryOverride: String? = nil
    ) -> CLIAuthInfo {
        #if !os(macOS)
        // iOS / non-Mac builds never run CLIs locally. Return an "unauthenticated"
        // record so the iOS app can still surface CLI provider summaries
        // without depending on AppKit-only Foundation APIs.
        return CLIAuthInfo(
            cliType: cliType,
            isInstalled: false,
            executablePath: nil,
            authState: .notInstalled,
            configDirectory: nil,
            accountDescription: nil
        )
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executablePath = CLILaunchAdapter.executablePath(for: cliType)

        switch cliType {
        case .codex:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.codex"
            )
            let authState = discoverCodexAuthState(configDirectory: configDir)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : normalizedNonEmpty(configDir),
                accountDescription: codexAccountDescription(configDirectory: configDir, authState: authState)
            )

        case .claude:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.claude"
            )
            let statusJSONData = claudeAuthStatusJSON(
                executablePath: executablePath,
                configDirectory: configDir
            )
            let authState = claudeAuthState(
                configDirectory: configDir,
                statusJSONData: statusJSONData
            )
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : normalizedNonEmpty(configDir),
                accountDescription: claudeAccountDescription(
                    statusJSONData: statusJSONData,
                    authState: authState
                )
            )

        case .opencode:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.config/opencode"
            )
            let dataDir = "\(home)/.local/share/opencode"
            let authState = discoverOpenCodeAuthState(dataDirectory: dataDir, configDirectory: configDir)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: executablePath == nil ? .notInstalled : authState,
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : normalizedNonEmpty(configDir),
                accountDescription: openCodeAccountDescription(dataDirectory: dataDir, authState: authState)
            )
        }
        #endif
    }

    // MARK: - Codex Auth Detection

    /// Checks Codex auth.json for key presence (value not read).
    private static func discoverCodexAuthState(configDirectory: String) -> CLIAuthState {
        let authPath = "\(configDirectory)/auth.json"
        let fm = FileManager.default

        guard fm.fileExists(atPath: authPath),
              let data = fm.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No auth file — check if installed
            return fm.fileExists(atPath: configDirectory) ? .notAuthenticated : .notInstalled
        }

        // Check for OPENAI_API_KEY presence (boolean only — never read the value)
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return .apiKeyPresent
        }

        // Check for tokens object presence
        if let tokens = json["tokens"] as? [String: Any], !tokens.isEmpty {
            let lastRefresh = parseDate(from: json["last_refresh"])
            return .authenticated(lastRefresh: lastRefresh)
        }

        return .notAuthenticated
    }

    // MARK: - Claude Code Auth Detection

    /// Checks Claude Code directory for session/auth state.
    private static func discoverClaudeAuthState(configDirectory: String) -> CLIAuthState {
        let fm = FileManager.default
        let claudeDir = configDirectory

        guard fm.fileExists(atPath: claudeDir) else {
            return .notInstalled
        }

        // Check for settings.json (indicates configuration)
        let settingsPath = "\(claudeDir)/settings.json"
        let hasSettings = fm.fileExists(atPath: settingsPath)

        // Check for sessions directory (indicates active usage)
        let sessionsPath = "\(claudeDir)/sessions"
        let hasSessions = fm.fileExists(atPath: sessionsPath)

        // Check for chrome subdirectory (OAuth credentials from browser auth)
        let chromePath = "\(claudeDir)/chrome"
        let hasChromeAuth = fm.fileExists(atPath: chromePath)

        if hasChromeAuth || hasSessions {
            return .authenticated(lastRefresh: nil)
        }

        if hasSettings {
            return .notAuthenticated
        }

        return .notAuthenticated
    }

    private static func discoverOpenCodeAuthState(dataDirectory: String, configDirectory: String) -> CLIAuthState {
        let fm = FileManager.default
        let authPath = "\(dataDirectory)/auth.json"
        guard fm.fileExists(atPath: authPath),
              let data = fm.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            return (fm.fileExists(atPath: dataDirectory) || fm.fileExists(atPath: configDirectory))
                ? .notAuthenticated
                : .notInstalled
        }
        return .authenticated(lastRefresh: nil)
    }

    /// Returns the parsed auth status JSON from `claude auth status --json`, if available.
    private static func claudeAuthStatusJSON(executablePath: String?, configDirectory: String) -> Data? {
        guard let executablePath else { return nil }

        return runCommand(
            executablePath: executablePath,
            arguments: ["auth", "status", "--json"],
            environment: ["CLAUDE_CONFIG_PATH": configDirectory],
            timeout: 3.5
        )
    }

    /// Prefers explicit CLI-reported auth state, then falls back to filesystem heuristics.
    private static func claudeAuthState(configDirectory: String, statusJSONData: Data?) -> CLIAuthState {
        if let statusJSONData,
           let statusPayload = parseClaudeStatusJSON(statusJSONData) {
            if let loggedIn = statusPayload.loggedIn {
                return loggedIn ? .authenticated(lastRefresh: nil) : .notAuthenticated
            }

            if statusPayload.email != nil || statusPayload.name != nil || statusPayload.orgName != nil {
                return .authenticated(lastRefresh: nil)
            }
        }

        return discoverClaudeAuthState(configDirectory: configDirectory)
    }

    // MARK: - Account Identity Helpers

    static func codexAccountDescription(configDirectory: String, authState: CLIAuthState) -> String? {
        guard case .authenticated = authState else { return nil }

        let authPath = "\(configDirectory)/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath) else {
            return nil
        }

        return extractCodexAccountDescription(fromAuthJSONData: data)
    }

    static func extractCodexAccountDescription(fromAuthJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else {
            return nil
        }

        if let idToken = tokens["id_token"] as? String,
           let claims = parseJWTClaims(from: idToken) {
            let name = claims["name"] as? String
            let email = claims["email"] as? String
            if let formatted = formattedAccountDescription(name: name, email: email) {
                return formatted
            }
        }

        if let accessToken = tokens["access_token"] as? String,
           let claims = parseJWTClaims(from: accessToken),
           let profile = claims["https://api.openai.com/profile"] as? [String: Any] {
            let email = profile["email"] as? String
            return formattedAccountDescription(name: nil, email: email)
        }

        return nil
    }

    private struct ClaudeStatusPayload {
        let loggedIn: Bool?
        let email: String?
        let name: String?
        let orgName: String?
    }

    private static func parseClaudeStatusJSON(_ data: Data) -> ClaudeStatusPayload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let account = json["account"] as? [String: Any]
        let user = json["user"] as? [String: Any]

        let loggedIn = (json["loggedIn"] as? Bool)
            ?? (json["isLoggedIn"] as? Bool)
            ?? (account?["loggedIn"] as? Bool)
            ?? (user?["loggedIn"] as? Bool)

        let email = normalizedNonEmpty(
            (json["email"] as? String)
                ?? (account?["email"] as? String)
                ?? (user?["email"] as? String)
        )

        let name = normalizedNonEmpty(
            (json["name"] as? String)
                ?? (json["displayName"] as? String)
                ?? (account?["name"] as? String)
                ?? (account?["displayName"] as? String)
                ?? (user?["name"] as? String)
                ?? (user?["displayName"] as? String)
        )

        let orgName = normalizedNonEmpty(
            (json["orgName"] as? String)
                ?? (account?["orgName"] as? String)
                ?? (user?["orgName"] as? String)
                ?? (json["organization"] as? String)
        )

        return ClaudeStatusPayload(
            loggedIn: loggedIn,
            email: email,
            name: name,
            orgName: orgName
        )
    }

    static func claudeAccountDescription(
        statusJSONData: Data?,
        authState: CLIAuthState
    ) -> String? {
        guard case .authenticated = authState,
              let statusJSONData else {
            return nil
        }

        return extractClaudeAccountDescription(fromStatusJSONData: statusJSONData)
    }

    static func extractClaudeAccountDescription(fromStatusJSONData data: Data) -> String? {
        guard let statusPayload = parseClaudeStatusJSON(data) else {
            return nil
        }

        if let email = normalizedNonEmpty(statusPayload.email) {
            if let name = normalizedNonEmpty(statusPayload.name) {
                return formattedAccountDescription(name: name, email: email)
            }
            return email
        }

        if let name = normalizedNonEmpty(statusPayload.name) {
            return name
        }

        return normalizedNonEmpty(statusPayload.orgName)
    }

    static func openCodeAccountDescription(dataDirectory: String, authState: CLIAuthState) -> String? {
        guard case .authenticated = authState else { return nil }
        let authPath = "\(dataDirectory)/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !json.isEmpty else {
            return nil
        }
        let providers = json.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !providers.isEmpty else { return nil }
        return "Signed in: \(providers.joined(separator: ", "))"
    }

    static func formattedAccountDescription(name: String?, email: String?) -> String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedName, !trimmedName.isEmpty,
           let trimmedEmail, !trimmedEmail.isEmpty {
            return "\(trimmedName) • \(trimmedEmail)"
        }

        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }

        return nil
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedConfigDirectory(_ override: String?, fallback: String) -> String {
        normalizedNonEmpty(override) ?? fallback
    }

    static func parseJWTClaims(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private static func runCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval
    ) -> Data? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { (_: Process) in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        return stdout.fileHandleForReading.readDataToEndOfFile()
        #else
        // iOS / non-Mac targets do not run local CLIs.
        return nil
        #endif
    }

    // MARK: - Date Parsing

    private static func parseDate(from value: Any?) -> Date? {
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: str)
        }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        return nil
    }
}
