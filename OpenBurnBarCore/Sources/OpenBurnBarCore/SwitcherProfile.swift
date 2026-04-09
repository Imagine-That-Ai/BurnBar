import Foundation

// MARK: - Switcher Profile Target Kind

/// The class of target a switcher profile controls.
public enum SwitcherProfileTargetKind: String, Codable, CaseIterable, Sendable {
    /// Browser-based profile (Chrome or Safari).
    case browser
    /// CLI-based profile (Codex, Claude, OpenCode).
    case cli
}

// MARK: - Browser Profile Type

/// Supported browser targets for profile-based launching.
public enum SwitcherBrowserProfileType: String, Codable, CaseIterable, Sendable {
    case chrome
    case safari

    public var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        }
    }
}

// MARK: - CLI Profile Type

/// Supported CLI targets for profile-based launching.
public enum SwitcherCLIProfileType: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case opencode

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        }
    }

    /// The canonical executable name for this CLI.
    public var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .opencode: return "opencode"
        }
    }

    /// Trusted executable paths for this CLI.
    public var trustedExecutablePaths: [String] {
        switch self {
        case .codex:
            return [
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                "$HOME/.codex/bin/codex"
            ]
        case .claude:
            return [
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "$HOME/.claude/bin/claude",
                "/usr/bin/claude"
            ]
        case .opencode:
            return [
                "/usr/local/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "$HOME/.opencode/bin/opencode"
            ]
        }
    }
}

// MARK: - Browser Profile Metadata

/// Metadata specific to a browser profile launch target.
/// NOTE: This contains only launch metadata — no cookies, auth tokens, or session data.
public struct SwitcherBrowserProfileMetadata: Codable, Equatable, Sendable {
    /// The Chrome/Safari profile directory name or profile ID.
    /// For Chrome: the profile folder name (e.g., "Profile 1", "Default")
    /// For Safari: the WebKit profile container name.
    public let profileIdentifier: String

    /// Optional human-readable display label for this profile.
    /// If nil, defaults to the profileIdentifier.
    public let displayLabel: String?

    public init(profileIdentifier: String, displayLabel: String? = nil) {
        self.profileIdentifier = profileIdentifier
        self.displayLabel = displayLabel
    }
}

// MARK: - CLI Profile Metadata

/// Metadata specific to a CLI profile launch target.
/// NOTE: This contains only launch metadata — no API keys, auth tokens, or session data.
public struct SwitcherCLIProfileMetadata: Codable, Equatable, Sendable {
    /// Optional working directory for the CLI session.
    public let workingDirectory: String?

    /// Optional additional CLI arguments (allowlisted — see LaunchValidator).
    public let additionalArgs: [String]

    /// Optional environment variable keys to pass through (allowlisted).
    /// Values are NOT stored — only the keys. Actual values resolved at launch.
    public let envKeysToPass: [String]

    /// Optional label for this CLI configuration (e.g., "Work", "Personal").
    public let displayLabel: String?

    public init(
        workingDirectory: String? = nil,
        additionalArgs: [String] = [],
        envKeysToPass: [String] = [],
        displayLabel: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.additionalArgs = additionalArgs
        self.envKeysToPass = envKeysToPass
        self.displayLabel = displayLabel
    }
}

// MARK: - Switcher Profile Record

/// A complete switcher profile record representing a launchable identity.
///
/// SECURITY: This record contains ONLY non-sensitive launch metadata.
/// No OAuth tokens, passwords, cookies, API keys, or session credentials are stored.
public struct SwitcherProfileRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let targetKind: SwitcherProfileTargetKind

    // Browser-specific fields (non-nil when targetKind == .browser)
    public let browserType: SwitcherBrowserProfileType?
    public let browserMetadata: SwitcherBrowserProfileMetadata?

    // CLI-specific fields (non-nil when targetKind == .cli)
    public let cliType: SwitcherCLIProfileType?
    public let cliMetadata: SwitcherCLIProfileMetadata?

    /// Stable sort key for deterministic ordering.
    /// Lower values sort first. CreatedAt is used as tiebreaker.
    public let sortKey: Int

    /// When this profile was first created.
    public let createdAt: Date

    /// When this profile was last modified.
    public let updatedAt: Date

    /// NOTE: This record intentionally omits:
    /// - Raw OAuth tokens or refresh tokens
    /// - Passwords or session credentials
    /// - Browser cookies or session storage
    /// - API keys or secret values
    ///
    /// Launch adapters resolve these at runtime from system keychain/browser credential stores.

    public init(
        id: String = UUID().uuidString,
        targetKind: SwitcherProfileTargetKind,
        browserType: SwitcherBrowserProfileType? = nil,
        browserMetadata: SwitcherBrowserProfileMetadata? = nil,
        cliType: SwitcherCLIProfileType? = nil,
        cliMetadata: SwitcherCLIProfileMetadata? = nil,
        sortKey: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.targetKind = targetKind
        self.browserType = browserType
        self.browserMetadata = browserMetadata
        self.cliType = cliType
        self.cliMetadata = cliMetadata
        self.sortKey = sortKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Human-readable name for this profile.
    public var displayName: String {
        if let browserMetadata {
            return browserMetadata.displayLabel ?? browserMetadata.profileIdentifier
        }
        if let cliMetadata {
            return cliMetadata.displayLabel ?? cliType?.displayName ?? "CLI Profile"
        }
        return "Unknown Profile"
    }

    /// The concrete target type as a string (e.g., "chrome", "safari", "codex", "claude", "opencode").
    public var concreteTargetType: String {
        if let browserType {
            return browserType.rawValue
        }
        if let cliType {
            return cliType.rawValue
        }
        return "unknown"
    }
}

// MARK: - Active Profile State

/// Represents the current active profile selection.
/// Stored separately from profiles to allow atomic active-profile changes.
public struct SwitcherActiveProfileState: Equatable, Sendable {
    /// The ID of the currently active profile, if any.
    public let activeProfileID: String?

    /// When the active profile was last changed.
    public let updatedAt: Date

    public init(activeProfileID: String?, updatedAt: Date = Date()) {
        self.activeProfileID = activeProfileID
        self.updatedAt = updatedAt
    }
}

// MARK: - Profile Normalization

extension SwitcherProfileRecord {
    /// Returns a normalized name suitable for uniqueness comparison.
    /// Normalization: lowercase, trimmed, collapsed whitespace.
    public static func normalizeName(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
