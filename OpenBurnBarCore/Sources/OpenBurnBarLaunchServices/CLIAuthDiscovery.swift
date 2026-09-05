import Foundation
import OpenBurnBarKernel

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

    nonisolated(unsafe) static var environmentProvider: () -> [String: String] = {
        ProcessInfo.processInfo.environment
    }

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
        case .droid:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.factory"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Factory Droid local profile" : nil
            )
        case .forge:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.forge"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Forge local profile" : nil
            )
        case .antigravity:
            let geminiConfigDir = "\(home)/.gemini/antigravity"
            let primaryConfigDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: FileManager.default.fileExists(atPath: geminiConfigDir) ? geminiConfigDir : "\(home)/.antigravity"
            )
            let legacyConfigDir = "\(home)/.gemini/antigravity-cli"
            let exists = FileManager.default.fileExists(atPath: primaryConfigDir)
                || FileManager.default.fileExists(atPath: geminiConfigDir)
                || FileManager.default.fileExists(atPath: legacyConfigDir)
            let configDir = FileManager.default.fileExists(atPath: primaryConfigDir)
                ? primaryConfigDir
                : (FileManager.default.fileExists(atPath: geminiConfigDir) ? geminiConfigDir : legacyConfigDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(primaryConfigDir),
                accountDescription: exists ? "Antigravity local profile" : nil
            )
        case .cursorAgent:
            let primaryConfigDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.cursor"
            )
            let dataDir = "\(home)/.local/share/cursor-agent"
            let legacyConfigDir = "\(home)/.cursor-agent"
            let exists = FileManager.default.fileExists(atPath: primaryConfigDir)
                || FileManager.default.fileExists(atPath: dataDir)
                || FileManager.default.fileExists(atPath: legacyConfigDir)
            let configDir = FileManager.default.fileExists(atPath: primaryConfigDir)
                ? primaryConfigDir
                : (FileManager.default.fileExists(atPath: dataDir) ? dataDir : legacyConfigDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Cursor Agent local profile" : nil
            )
        case .omp:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.omp"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "OMP local profile" : nil
            )
        case .gemini:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.gemini"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Gemini CLI local profile" : nil
            )
        case .kimi:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.kimi"
            )
            let altConfigDir = "\(home)/.config/kimi"
            let exists = FileManager.default.fileExists(atPath: configDir)
                || FileManager.default.fileExists(atPath: altConfigDir)
            let resolvedDir = FileManager.default.fileExists(atPath: configDir) ? configDir : altConfigDir
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? resolvedDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Kimi local profile" : nil
            )
        case .pi:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.pi"
            )
            let altConfigDir = "\(home)/.config/pi"
            let exists = FileManager.default.fileExists(atPath: configDir)
                || FileManager.default.fileExists(atPath: altConfigDir)
            let resolvedDir = FileManager.default.fileExists(atPath: configDir) ? configDir : altConfigDir
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? resolvedDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Pi local profile" : nil
            )
        case .grok:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.grok"
            )
            let sessionsDir = "\(configDir)/sessions"
            let hasConfig = FileManager.default.fileExists(atPath: configDir)
            let hasSessions = FileManager.default.fileExists(atPath: sessionsDir)
            let hasAPIKey = !(ProcessInfo.processInfo.environment["XAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let authState: CLIAuthState = {
                if executablePath == nil { return .notInstalled }
                if hasAPIKey { return .apiKeyPresent }
                if hasConfig || hasSessions { return .authenticated(lastRefresh: nil) }
                return .notAuthenticated
            }()
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: hasConfig ? configDir : normalizedNonEmpty(configDir),
                accountDescription: hasSessions ? "Grok Build local sessions" : nil
            )
        case .junie:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.junie"
            )
            let sessionsDir = "\(configDir)/sessions"
            let hasConfig = FileManager.default.fileExists(atPath: configDir)
            let hasRecordedSessions = directoryContainsAnyEntry(atPath: sessionsDir)
            let hasAPIKey = !(ProcessInfo.processInfo.environment["JUNIE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            // `~/.junie` is created on first launch even before sign-in and
            // credentials live in the macOS Keychain, so only treat recorded
            // sessions (or an explicit API key) as evidence of a usable login.
            let authState: CLIAuthState = {
                if executablePath == nil { return .notInstalled }
                if hasAPIKey { return .apiKeyPresent }
                if hasRecordedSessions { return .authenticated(lastRefresh: nil) }
                return .notAuthenticated
            }()
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: hasConfig ? configDir : normalizedNonEmpty(configDir),
                accountDescription: hasRecordedSessions ? "Junie local sessions" : nil
            )
        case .primeAgent:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.prime"
            )
            let sessionsDir = "\(configDir)/agent/sessions"
            let hasConfig = FileManager.default.fileExists(atPath: configDir)
            let hasRecordedSessions = directoryContainsAnyEntry(atPath: sessionsDir)
            let hasAPIKey = hasConfig // auth.json holds backend keys router-agnostic
            let authState: CLIAuthState = {
                if executablePath == nil { return .notInstalled }
                if hasRecordedSessions { return .authenticated(lastRefresh: nil) }
                if hasAPIKey { return .authenticated(lastRefresh: nil) }
                return .notAuthenticated
            }()
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: hasConfig ? configDir : normalizedNonEmpty(configDir),
                accountDescription: hasRecordedSessions ? "Prime Agent local sessions" : nil
            )
        case .fx:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.fx"
            )
            let sessionsDir = "\(configDir)/sessions"
            let hasConfig = FileManager.default.fileExists(atPath: configDir)
            let hasRecordedSessions = directoryContainsAnyEntry(atPath: sessionsDir)
            let fileCredential = fxFileCredentialState(configDirectory: configDir)
            let environment = environmentProvider()
            let hasEnvironmentKey = normalizedNonEmpty(environment["AI_GATEWAY_API_KEY"]) != nil
            // Current fx keeps OAuth in auth.json/chatgpt-auth.json (or the
            // FX_OAUTH_SESSION_V1 Keychain item after migration) and API keys
            // in `api-key`, AI_GATEWAY_API_KEY, or FX_AI_GATEWAY_API_KEY in
            // Keychain. Merely launching fx creates ~/.fx, and old sessions
            // survive logout, so neither is authentication evidence.
            let keychainCredential = configDirectoryOverride == nil
                ? fxKeychainCredentialState()
                : nil
            let authState: CLIAuthState = {
                if executablePath == nil { return .notInstalled }
                if fileCredential == .authenticated(lastRefresh: nil)
                    || keychainCredential == .authenticated(lastRefresh: nil) {
                    return .authenticated(lastRefresh: nil)
                }
                if fileCredential == .apiKeyPresent
                    || keychainCredential == .apiKeyPresent
                    || hasEnvironmentKey {
                    return .apiKeyPresent
                }
                return .notAuthenticated
            }()
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: hasConfig ? configDir : normalizedNonEmpty(configDir),
                accountDescription: hasRecordedSessions ? "fx local sessions" : nil
            )

        case .muse:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.config/muse"
            )
            // XDG-style layout (verified on Muse Code 1.0.2): auth and
            // settings live in ~/.config/muse (auth.json, settings.json,
            // trust.json); envelope session logs live in
            // ~/.local/share/muse/sessions/YYYY/MM/DD/<id>/session.jsonl.
            // The config dir is created on first launch even before sign-in
            // and credentials live outside it (browser-linked device flow),
            // so only recorded sessions count as usable-login evidence.
            let sessionsDir = "\(home)/.local/share/muse/sessions"
            let hasConfig = FileManager.default.fileExists(atPath: configDir)
            let hasRecordedSessions = directoryContainsAnyEntry(atPath: sessionsDir)
            let authState: CLIAuthState = {
                if executablePath == nil { return .notInstalled }
                if hasRecordedSessions { return .authenticated(lastRefresh: nil) }
                return .notAuthenticated
            }()
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: hasConfig ? configDir : normalizedNonEmpty(configDir),
                accountDescription: hasRecordedSessions ? "Muse Code local sessions" : nil
            )
        case .hermes:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.hermes"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Hermes local profile" : nil
            )

        case .goose:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.config/goose"
            )
            let altConfigDir = "\(home)/.goose"
            let exists = FileManager.default.fileExists(atPath: configDir) || FileManager.default.fileExists(atPath: altConfigDir)
            let resolvedDir = FileManager.default.fileExists(atPath: configDir) ? configDir : altConfigDir
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? resolvedDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Goose local profile" : nil
            )

        case .windsurf:
            let configDir = "\(home)/Library/Application Support/Windsurf - Next/User/globalStorage"
            let altConfigDir = "\(home)/Library/Application Support/Windsurf/User/globalStorage"
            let exists = FileManager.default.fileExists(atPath: configDir) || FileManager.default.fileExists(atPath: altConfigDir)
            let resolvedDir = FileManager.default.fileExists(atPath: configDir) ? configDir : altConfigDir
            let authState: CLIAuthState = exists ? .authenticated(lastRefresh: nil) : (executablePath != nil ? .notAuthenticated : .notInstalled)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil || exists,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? resolvedDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "Windsurf profile" : nil
            )

        case .openClaude:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.openclaude"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "OpenClaude profile" : nil
            )

        case .openClaw:
            let configDir = normalizedConfigDirectory(
                configDirectoryOverride,
                fallback: "\(home)/.openclaw"
            )
            let exists = FileManager.default.fileExists(atPath: configDir)
            let authState: CLIAuthState = executablePath == nil ? .notInstalled : (exists ? .authenticated(lastRefresh: nil) : .notAuthenticated)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: exists ? configDir : normalizedNonEmpty(configDir),
                accountDescription: exists ? "OpenClaw profile" : nil
            )
        }
        #endif
    }

    // MARK: - fx Auth Detection

    private static func fxFileCredentialState(configDirectory: String) -> CLIAuthState? {
        for name in ["auth.json", "chatgpt-auth.json"]
            where fileContainsNonWhitespace(atPath: "\(configDirectory)/\(name)") {
            return .authenticated(lastRefresh: nil)
        }
        return fileContainsNonWhitespace(atPath: "\(configDirectory)/api-key")
            ? .apiKeyPresent
            : nil
    }

    /// Checks Keychain item metadata only. Omitting `-w` is intentional: the
    /// auth panel needs presence, never the credential bytes.
    private static func fxKeychainCredentialState() -> CLIAuthState? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else { return nil }
        if keychainItemExists(service: "FX_OAUTH_SESSION_V1") {
            return .authenticated(lastRefresh: nil)
        }
        if keychainItemExists(service: "FX_AI_GATEWAY_API_KEY") {
            return .apiKeyPresent
        }
        return nil
    }

    private static func keychainItemExists(service: String) -> Bool {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #else
        // iOS and other non-Mac targets cannot launch the macOS `security` CLI.
        return false
        #endif
    }

    private static func fileContainsNonWhitespace(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return false }
        return normalizedNonEmpty(text) != nil
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
            environment: claudeStatusEnvironment(configDirectory: configDirectory),
            timeout: 3.5
        )
    }

    static func claudeStatusEnvironment(configDirectory: String) -> [String: String] {
        #if os(macOS)
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .standardizedFileURL
            .path
        #else
        let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .standardizedFileURL
            .path
        #endif
        let requestedDirectory = URL(fileURLWithPath: configDirectory, isDirectory: true)
            .standardizedFileURL
            .path

        if requestedDirectory == defaultDirectory {
            return ["CLAUDE_CONFIG_PATH": requestedDirectory]
        }

        return [
            "CLAUDE_CONFIG_DIR": requestedDirectory,
            "CLAUDE_CONFIG_PATH": requestedDirectory
        ]
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

    private static func directoryContainsAnyEntry(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return true
        }
        return false
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
