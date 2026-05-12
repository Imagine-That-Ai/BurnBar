import Foundation
#if os(macOS)
import Security
#endif

// MARK: - Claude OAuth Credentials Reader

/// Reads Claude Code's OAuth credentials so OpenBurnBar can call
/// `/api/oauth/usage` directly without forcing the user to launch the
/// CLI first.
///
/// ## Why this exists
///
/// Before this reader, the only way to get Claude's `rate_limits` JSON
/// was the statusline bridge — which only fires when the user actually
/// runs `claude` and types a prompt. Fresh installs of OpenBurnBar
/// would sit on "Bridge installed but no payload captured yet" until
/// the user happened to run Claude Code. With Keychain-stored OAuth
/// credentials, we can hit Anthropic's usage endpoint directly and
/// surface five-hour / seven-day percentages immediately.
///
/// ## Where credentials live
///
/// 1. **macOS Keychain** — service `"Claude Code-credentials"`,
///    account `<short username>`. Claude Code writes the JSON blob
///    here on every successful OAuth refresh. The keychain ACL is
///    permissive (no per-app gate), so OpenBurnBar can read it without
///    triggering an authorization prompt.
/// 2. **`~/.claude/.credentials.json`** — Linux / CI fallback path.
///    Same JSON shape; checked when Keychain returns nothing.
/// 3. **`CLAUDE_CODE_OAUTH_TOKEN` env var** — manual override for
///    headless tests / dev machines without Claude Code installed.
///
/// ## Payload shape (as observed 2026-05)
///
/// ```json
/// {
///   "claudeAiOauth": {
///     "accessToken": "...",
///     "refreshToken": "...",
///     "expiresAt": 1778310120051,
///     "scopes": ["user:inference", "user:profile", ...],
///     "subscriptionType": "max",
///     "rateLimitTier": "default_claude_max_20x"
///   },
///   "organizationUuid": "..."
/// }
/// ```
///
/// `expiresAt` is **milliseconds** since epoch (not seconds) — easy to
/// mis-parse if you're not careful.

struct ClaudeOAuthCredentials: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    /// Self-reported Claude plan: `"pro"`, `"max"`, `"team"`, etc.
    /// Empty string when Claude Code hasn't tagged the credentials.
    let subscriptionType: String
    /// e.g. `"default_claude_max_20x"`, `"default_claude_pro_5x"`. The
    /// multiplier in the suffix tells us the plan tier even when
    /// `subscriptionType` is blank or unrecognized.
    let rateLimitTier: String
    let organizationUuid: String?

    /// Returns true when the access token expires within the next 60
    /// seconds. Callers should refresh before that window closes so a
    /// request mid-refresh doesn't see a 401. Returns `false` when
    /// `expiresAt` is `nil` (e.g. env-override credentials) — those
    /// are treated as never-expiring because we have no signal.
    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }

    /// Returns true when the credentials are usable against the
    /// usage endpoint, either directly or after a refresh. Failure
    /// cases:
    ///   - Both access token AND refresh token expired (impossible to
    ///     recover without re-login).
    /// We deliberately allow the call even when `isExpired()` is true
    /// as long as a refresh token is present — the fetcher knows how
    /// to refresh transparently.
    func canCallUsageEndpoint(now: Date = Date()) -> Bool {
        if !isExpired(now: now) { return true }
        return refreshToken != nil
    }

    /// Human-readable plan label: `"Max"`, `"Pro"`, `"Team"`, etc.
    /// Used in the popover status line so users see their plan tier
    /// even when the usage endpoint is rate-limited.
    var planDisplayName: String {
        let s = subscriptionType.lowercased()
        if s.contains("max") { return "Max" }
        if s.contains("pro") { return "Pro" }
        if s.contains("team") { return "Team" }
        if s.contains("enterprise") { return "Enterprise" }
        // Fall through to the rateLimitTier multiplier — e.g.
        // `default_claude_max_20x` → "Max".
        let tier = rateLimitTier.lowercased()
        if tier.contains("max") { return "Max" }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("team") { return "Team" }
        if tier.contains("enterprise") { return "Enterprise" }
        return subscriptionType.isEmpty ? "Claude" : subscriptionType.capitalized
    }
}

protocol ClaudeCredentialsReading: Sendable {
    /// Returns the most recent credentials, or `nil` if none are
    /// reachable on this host. Implementations should swallow I/O
    /// errors — quota refresh must never crash because Keychain is
    /// locked or the credentials file is missing.
    func load() -> ClaudeOAuthCredentials?
}

/// Lets the OAuth fetcher persist refreshed access/refresh tokens
/// back to `~/.claude/.credentials.json` so the Claude Code CLI
/// benefits from the refreshed pair too.
protocol ClaudeCredentialsPersisting: Sendable {
    func write(_ credentials: ClaudeOAuthCredentials)
}

struct ClaudeCredentialsReader: ClaudeCredentialsReading, ClaudeCredentialsPersisting {
    let homeDirectoryURL: URL
    let environment: [String: String]
    let fileManager: FileManagerSendableBox
    /// Service name Claude Code uses when persisting credentials to the
    /// macOS Keychain. Anthropic has shipped this exact label since the
    /// first Claude Code release.
    static let keychainService = "Claude Code-credentials"

    init(
        homeDirectoryURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.environment = environment
        self.fileManager = FileManagerSendableBox(fileManager)
    }

    func load() -> ClaudeOAuthCredentials? {
        // 1. Environment override — used by tests and headless machines.
        if let envToken = quotaNonEmpty(environment["CLAUDE_CODE_OAUTH_TOKEN"]) {
            return ClaudeOAuthCredentials(
                accessToken: envToken,
                refreshToken: quotaNonEmpty(environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"]),
                expiresAt: nil,
                subscriptionType: quotaNonEmpty(environment["CLAUDE_CODE_SUBSCRIPTION"]) ?? "",
                rateLimitTier: quotaNonEmpty(environment["CLAUDE_CODE_RATE_LIMIT_TIER"]) ?? "",
                organizationUuid: quotaNonEmpty(environment["CLAUDE_CODE_ORGANIZATION_UUID"])
            )
        }

        // Test hook: when the file path is explicitly synthetic and
        // the dev machine has a real Keychain entry, skip Keychain
        // reads so unit tests exercise the file-fallback path. Real
        // users never set this flag and never reach this branch.
        let skipKeychain = quotaNonEmpty(environment["CLAUDE_CREDENTIALS_SKIP_KEYCHAIN"]) != nil

        // 2. Keychain — the canonical location on macOS.
        #if os(macOS)
        if !skipKeychain, let blob = Self.readKeychainBlob() {
            if let creds = Self.decode(blob) {
                return creds
            }
        }
        #endif

        // 3. `~/.claude/.credentials.json` — Linux / CI fallback.
        let fileURL = credentialsFileURL
        if let data = try? Data(contentsOf: fileURL),
           let creds = Self.decode(data) {
            return creds
        }

        return nil
    }

    // MARK: - Persistence

    /// Filesystem path Claude Code reads on every CLI invocation. We
    /// write refreshed tokens here so a fresh `claude` command keeps
    /// working without the user having to re-authenticate.
    var credentialsFileURL: URL {
        homeDirectoryURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
    }

    /// Writes the credentials JSON in Anthropic's canonical shape
    /// (the `claudeAiOauth` wrapper with ms-precision `expiresAt`)
    /// so Claude Code's reader accepts it. Best-effort — failures
    /// are swallowed because quota refresh must keep functioning
    /// even when the credentials file is locked or symlinked into
    /// a non-writable mount.
    ///
    /// **Note on the Keychain:** Anthropic stores the canonical
    /// credentials in the macOS Keychain — the JSON file is only the
    /// Linux/CI fallback. We do not currently rewrite the Keychain
    /// entry because doing so requires the same ACL Claude Code uses
    /// at sign-in time, and clobbering the entry from another app is
    /// likely to surface a user-facing keychain prompt. Instead we
    /// rewrite the file fallback, which the CLI will pick up if the
    /// Keychain entry is absent. On macOS-with-Keychain the refresh
    /// still benefits OpenBurnBar's in-memory copy via
    /// `RateLimitsResult.refreshedCredentials`.
    func write(_ credentials: ClaudeOAuthCredentials) {
        let isoFormatter = ISO8601DateFormatter()
        var oauth: [String: Any] = [
            "accessToken": credentials.accessToken
        ]
        if let refresh = credentials.refreshToken { oauth["refreshToken"] = refresh }
        if let expires = credentials.expiresAt {
            oauth["expiresAt"] = Int(expires.timeIntervalSince1970 * 1000)
            oauth["expiresAtIso"] = isoFormatter.string(from: expires)
        }
        if !credentials.subscriptionType.isEmpty {
            oauth["subscriptionType"] = credentials.subscriptionType
        }
        if !credentials.rateLimitTier.isEmpty {
            oauth["rateLimitTier"] = credentials.rateLimitTier
        }
        var envelope: [String: Any] = ["claudeAiOauth": oauth]
        if let org = credentials.organizationUuid { envelope["organizationUuid"] = org }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted]) else {
            return
        }
        let url = credentialsFileURL
        let parent = url.deletingLastPathComponent()
        try? fileManager.value.createDirectory(at: parent, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        // Match Claude Code's 0600 perms (read/write owner only). Best
        // effort — error is fine because the file is in $HOME.
        try? fileManager.value.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Keychain

    #if os(macOS)
    private static func readKeychainBlob() -> Data? {
        // We deliberately do NOT pin `kSecAttrAccount` so Claude
        // Code's chosen account name (typically the login username
        // but sometimes the OAuth subject) doesn't have to match
        // anything OpenBurnBar can pre-compute. `kSecMatchLimitOne`
        // picks the most recently modified item, which is what we
        // want when a user has switched Claude accounts.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }
    #endif

    // MARK: - Decoding

    /// Internal so tests can exercise the parser against synthetic
    /// JSON without touching the Keychain. Returns `nil` on any
    /// schema deviation — better unavailable than a half-formed
    /// credential that 401s on every request.
    static func decode(_ data: Data) -> ClaudeOAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = json["claudeAiOauth"] as? [String: Any] ?? json
        guard let accessToken = quotaNonEmpty(oauth["accessToken"] as? String) else {
            return nil
        }
        let refreshToken = quotaNonEmpty(oauth["refreshToken"] as? String)
        let expiresAt: Date? = {
            if let ms = oauth["expiresAt"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
            if let ms = oauth["expiresAt"] as? Int    { return Date(timeIntervalSince1970: Double(ms) / 1000) }
            if let s = oauth["expiresAt"] as? String, let v = Double(s) {
                return Date(timeIntervalSince1970: v / 1000)
            }
            return nil
        }()
        let subscriptionType = (oauth["subscriptionType"] as? String) ?? ""
        let rateLimitTier = (oauth["rateLimitTier"] as? String) ?? ""
        let organizationUuid = quotaNonEmpty(json["organizationUuid"] as? String)
            ?? quotaNonEmpty(oauth["organizationUuid"] as? String)
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            organizationUuid: organizationUuid
        )
    }
}

/// Test seam: exposes a fixed credentials value without any
/// Keychain / filesystem dependency. Used by `ProviderQuotaServiceTests`
/// to drive the OAuth-fetch path deterministically.
struct StaticClaudeCredentialsReader: ClaudeCredentialsReading {
    let credentials: ClaudeOAuthCredentials?
    func load() -> ClaudeOAuthCredentials? { credentials }
}
