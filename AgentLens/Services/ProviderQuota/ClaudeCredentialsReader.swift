import Foundation

// MARK: - Claude OAuth Credential Shapes

/// Claude OAuth credential payload used by explicit test/self-hosted
/// integrations. Provider-level production refresh deliberately does not
/// discover these credentials from Claude Code's global Keychain item. Explicit
/// account/profile refresh paths may inject credentials that the user already
/// configured inside OpenBurnBar or an OpenBurnBar-managed CLI profile.
///
/// ## Security boundary
///
/// OpenBurnBar must not trigger macOS authorization prompts for third-party
/// Claude credentials. The default reader is `NoClaudeCredentialsReader`, so
/// provider-level Claude quota refresh relies on the statusline bridge and
/// local JSONL session logs unless an account-scoped caller injects credentials
/// intentionally.
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
    /// `expiresAt` is `nil` (e.g. injected synthetic credentials) — those
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

    /// Storage payload for BurnBar's Anthropic route credential slot.
    ///
    /// The UI still displays/probes `accessToken`, but saving the full OAuth
    /// payload lets the daemon refresh the bearer later instead of making the
    /// user re-import Claude Code whenever the access token expires.
    func routeCredentialStoragePayload() -> String {
        var oauth: [String: Any] = ["accessToken": accessToken]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }
        if !subscriptionType.isEmpty { oauth["subscriptionType"] = subscriptionType }
        if !rateLimitTier.isEmpty { oauth["rateLimitTier"] = rateLimitTier }

        var root: [String: Any] = ["claudeAiOauth": oauth]
        if let organizationUuid { root["organizationUuid"] = organizationUuid }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let payload = String(data: data, encoding: .utf8) else {
            return accessToken
        }
        return payload
    }
}

protocol ClaudeCredentialsReading: Sendable {
    /// Returns the most recent credentials, or `nil` if none are
    /// intentionally supplied to this OpenBurnBar process.
    func load() -> ClaudeOAuthCredentials?
}

/// Production default: no third-party credential discovery. This keeps
/// Claude quota refresh prompt-free and prevents OpenBurnBar from
/// reading or mutating Claude Code's own credential stores.
struct NoClaudeCredentialsReader: ClaudeCredentialsReading {
    func load() -> ClaudeOAuthCredentials? { nil }
}

enum ClaudeCredentialsReader {
    /// Internal so tests can exercise the parser against synthetic
    /// JSON without touching user credential stores. Returns `nil` on
    /// any schema deviation — better unavailable than a half-formed
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

/// Test seam: exposes a fixed credentials value without any user-store
/// dependency. Used by `ProviderQuotaServiceTests`
/// to drive the OAuth-fetch path deterministically.
struct StaticClaudeCredentialsReader: ClaudeCredentialsReading {
    let credentials: ClaudeOAuthCredentials?
    func load() -> ClaudeOAuthCredentials? { credentials }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
