import CryptoKit
import Foundation

// MARK: - Claude OAuth Usage Fetcher

/// Calls `https://api.anthropic.com/api/oauth/usage` to retrieve the
/// exact usage payload Claude Code's statusline uses when credentials are
/// explicitly injected by tests, route credential slots, or configured CLI
/// profiles. Provider-level production refresh does not discover Claude OAuth
/// credentials from third-party credential stores.
///
/// ## Rate limit reality (read this before changing the cooldowns)
///
/// Anthropic's `/api/oauth/usage` is bizarrely aggressive about 429s
/// (see https://github.com/anthropics/claude-code/issues/31637). The
/// limit is **per access token, not per account**, and there is **no
/// `Retry-After` header** — once you trip it, you're stuck for the rest
/// of the session. The fix that ships in real-world tools (onWatch,
/// Jarvest, Claude Code itself):
///
/// 1. **Cache the response on disk keyed by `resets_at`.** Usage data
///    only changes every few hours, so once we have a payload we don't
///    need to re-poll until the cached `five_hour.resets_at` window
///    closes. This is the single most important optimization — without
///    it, the popover refresh interval will trip 429 on day one.
/// 2. **Treat 429 as "use last cached payload, do not retry until the
///    cached reset window passes"** — never enter the exponential
///    backoff ladder, that's what bricks the endpoint indefinitely.
/// 3. **Cap the live-poll cadence at 5 minutes** even when the cache
///    is missing. Faster polling provides zero benefit (server-side
///    counters don't update faster than that) and trips the wall.
/// 4. **Refresh the access token transparently** when it's about to
///    expire. Claude Code OAuth access tokens last 8 hours. The refresh
///    endpoint (`https://platform.claude.com/v1/oauth/token`) accepts
///    the `refresh_token` grant and returns a new access/refresh pair
///    that stays in memory for this fetch result. OpenBurnBar does not
///    write refreshed tokens into Claude Code's credential files.
///
/// ## On-disk cache format
///
/// `<appPaths>/Claude/oauth-usage-cache.json`:
///
/// ```json
/// {
///   "fetchedAt": "2026-05-11T02:55:00Z",
///   "fiveHourResetsAt": "2026-05-11T07:55:00Z",
///   "sevenDayResetsAt": "2026-05-18T02:55:00Z",
///   "payload": { ... raw usage-window JSON ... }
/// }
/// ```
///
/// `fetchedAt` is when we hit the endpoint. `fiveHourResetsAt` /
/// `sevenDayResetsAt` come from the response — the cache is fresh
/// until the soonest of those two moments arrives.

struct ClaudeOAuthUsageFetcher {
    let session: URLSession
    let cacheURL: URL
    let fileManager: FileManagerSendableBox
    /// Minimum gap between live calls when no cache exists. Defaults
    /// to 5 minutes — anything tighter trips the 429 wall.
    let minimumLivePollInterval: TimeInterval

    init(
        session: URLSession,
        cacheURL: URL,
        fileManager: FileManager = .default,
        minimumLivePollInterval: TimeInterval = 300
    ) {
        self.session = session
        self.cacheURL = cacheURL
        self.fileManager = FileManagerSendableBox(fileManager)
        self.minimumLivePollInterval = minimumLivePollInterval
    }

    static func scopedCacheURL(
        baseURL: URL,
        credentials: ClaudeOAuthCredentials
    ) -> URL {
        let stableSecret = credentials.refreshToken ?? credentials.accessToken
        let identity = [
            credentials.organizationUuid ?? "",
            credentials.subscriptionType,
            credentials.rateLimitTier,
            stableSecret,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("ClaudeOAuthUsage", isDirectory: true)
            .appendingPathComponent("usage-\(digest.prefix(24)).json", isDirectory: false)
    }

    // MARK: - Public API

    /// Returns the parsed rate-limits buckets. Reads from on-disk
    /// cache when fresh; otherwise calls `/api/oauth/usage`.
    /// Returns `nil` rate limits when the endpoint cannot be reached
    /// and no cached payload survives — callers should fall through
    /// to the JSONL token reader.
    ///
    /// When the access token is within 60 seconds of expiry and a
    /// refresh token is available, this method may transparently
    /// refresh the token. The refreshed credentials are returned for
    /// in-memory use only.
    func fetchRateLimits(
        credentials: ClaudeOAuthCredentials,
        now: Date = Date()
    ) async -> RateLimitsResult {
        // 1. Cached payload still inside the soonest reset window.
        if let cached = readCache() {
            if cached.isFresh(now: now) {
                return RateLimitsResult(
                    rateLimits: cached.payload,
                    fetchedAt: cached.fetchedAt,
                    sourceWasCache: true,
                    refreshedCredentials: nil
                )
            }
            // Cache exists but is stale; honor the live-poll cooldown
            // so we don't 429 ourselves while the user mashes Refresh.
            if now.timeIntervalSince(cached.fetchedAt) < minimumLivePollInterval {
                return RateLimitsResult(
                    rateLimits: cached.payload,
                    fetchedAt: cached.fetchedAt,
                    sourceWasCache: true,
                    refreshedCredentials: nil
                )
            }
        }

        // 2. Live call. Honor the cooldown when there's no cache too —
        // otherwise we'd hammer 429 from a fresh install.
        if let last = readLastFetchAttempt(),
           now.timeIntervalSince(last) < minimumLivePollInterval {
            return RateLimitsResult(rateLimits: nil, fetchedAt: nil, sourceWasCache: false, refreshedCredentials: nil)
        }
        recordFetchAttempt(now: now)

        // 2a. Refresh the access token first when we're inside the
        // expiry window AND have a refresh token. Skipping this is
        // what made the old adapter silently die after 8 hours.
        var workingCredentials = credentials
        var refreshedCredentials: ClaudeOAuthCredentials?
        if credentials.isExpired(now: now), credentials.refreshToken != nil {
            if let refreshed = await refreshAccessToken(credentials: credentials) {
                workingCredentials = refreshed
                refreshedCredentials = refreshed
            } else {
                // Refresh failed — fall through with the old token. It
                // may still work (Anthropic typically grants a few
                // minutes of grace) and if it doesn't, the 401 path
                // below will surface the cached payload.
            }
        }

        guard let payload = await live(credentials: workingCredentials) else {
            // Live call failed; surface whatever cached payload we
            // have, even if stale, so the popover doesn't blink to
            // "unavailable" on a transient failure.
            if let cached = readCache() {
                return RateLimitsResult(
                    rateLimits: cached.payload,
                    fetchedAt: cached.fetchedAt,
                    sourceWasCache: true,
                    refreshedCredentials: refreshedCredentials
                )
            }
            return RateLimitsResult(
                rateLimits: nil,
                fetchedAt: nil,
                sourceWasCache: false,
                refreshedCredentials: refreshedCredentials
            )
        }
        writeCache(payload: payload, fetchedAt: now)
        return RateLimitsResult(
            rateLimits: payload,
            fetchedAt: now,
            sourceWasCache: false,
            refreshedCredentials: refreshedCredentials
        )
    }

    // MARK: - Result Type

    /// Fully-typed payload (no `[String: Any]`). The dictionary form
    /// only lives at the JSON-decoding boundary; callers see only
    /// strongly-typed buckets.
    struct RateLimitsResult: Sendable {
        let rateLimits: ClaudeRateLimits?
        let fetchedAt: Date?
        let sourceWasCache: Bool
        /// When the access token had to be refreshed during this call,
        /// the new credentials are surfaced here so the caller can
        /// update its in-memory copy. `nil` means the existing
        /// credentials are still valid.
        let refreshedCredentials: ClaudeOAuthCredentials?
    }

    // MARK: - Live Request

    private func live(credentials: ClaudeOAuthCredentials) async -> ClaudeRateLimits? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        // Required beta header — Anthropic gates the OAuth surface
        // behind this opaque flag. Skipping it returns 404.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A real Claude-Code-shaped UA helps avoid edge filters that
        // return 403 for unknown clients.
        request.setValue("Claude-Code/2.1 (OpenBurnBar quota refresh)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            // Don't retry on 429 — that's exactly what bricks the
            // endpoint. The cache will be reused on the next call.
            return nil
        }
        return ClaudeRateLimits(from: data)
    }

    // MARK: - Token Refresh

    /// Exchanges a refresh token for a new access/refresh pair using
    /// the same endpoint Claude Code's CLI uses. Returns `nil` on any
    /// failure — caller should reuse the old token rather than emit
    /// "unavailable".
    private func refreshAccessToken(credentials: ClaudeOAuthCredentials) async -> ClaudeOAuthCredentials? {
        guard let refreshToken = credentials.refreshToken,
              let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            return nil
        }
        // Form-urlencoded body — JSON returns invalid_grant.
        // `URLComponents.percentEncodedQuery` is unreliable when the
        // components has no scheme, so build the body by hand. This
        // is also slightly faster than constructing components only
        // to throw the rest away.
        let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
        }
        let bodyString = [
            "grant_type=refresh_token",
            "refresh_token=\(encode(refreshToken))",
            "client_id=\(encode(ClaudeOAuthConstants.clientID))"
        ].joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claude-Code/2.1 (OpenBurnBar token refresh)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(bodyString.utf8)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = quotaNonEmpty(json["access_token"] as? String) else {
            return nil
        }

        let newRefresh = quotaNonEmpty(json["refresh_token"] as? String) ?? refreshToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map { Double($0) }
            ?? 8 * 60 * 60 // 8h Anthropic default
        let newExpiry = Date().addingTimeInterval(expiresIn)

        return ClaudeOAuthCredentials(
            accessToken: newAccess,
            refreshToken: newRefresh,
            expiresAt: newExpiry,
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            organizationUuid: credentials.organizationUuid
        )
    }

    // MARK: - Cache I/O

    private struct CacheEntry {
        let fetchedAt: Date
        let fiveHourResetsAt: Date?
        let sevenDayResetsAt: Date?
        let payload: ClaudeRateLimits

        func isFresh(now: Date) -> Bool {
            // Fresh as long as we're inside the soonest reset window.
            // If both reset times are nil (server didn't include them)
            // we still trust the cache for `minimumLivePollInterval`
            // — the caller's outer cooldown gate handles that case.
            let candidates = [fiveHourResetsAt, sevenDayResetsAt].compactMap { $0 }
            guard let earliest = candidates.min() else { return false }
            return now < earliest
        }
    }

    private func readCache() -> CacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        let fetchedAt = (json["fetchedAt"] as? String).flatMap { formatter.date(from: $0) }
        let fiveHourResetsAt = (json["fiveHourResetsAt"] as? String).flatMap { formatter.date(from: $0) }
        let sevenDayResetsAt = (json["sevenDayResetsAt"] as? String).flatMap { formatter.date(from: $0) }
        guard let fetchedAt,
              let payloadDict = json["payload"] as? [String: Any] else {
            return nil
        }
        let payload = ClaudeRateLimits(from: payloadDict)
        guard !payload.isEmpty else { return nil }
        return CacheEntry(
            fetchedAt: fetchedAt,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayResetsAt: sevenDayResetsAt,
            payload: payload
        )
    }

    private func writeCache(payload: ClaudeRateLimits, fetchedAt: Date) {
        let formatter = ISO8601DateFormatter()
        var envelope: [String: Any] = [
            "fetchedAt": formatter.string(from: fetchedAt),
            "payload": payload.rawDictionary
        ]
        if let reset = payload.window(named: "five_hour")?.resetsAt {
            envelope["fiveHourResetsAt"] = formatter.string(from: reset)
        }
        if let reset = payload.window(named: "seven_day")?.resetsAt {
            envelope["sevenDayResetsAt"] = formatter.string(from: reset)
        }
        let parent = cacheURL.deletingLastPathComponent()
        try? fileManager.value.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted]) {
            try? data.write(to: cacheURL, options: [.atomic])
        }
    }

    // MARK: - Live-poll Cooldown

    /// Sibling marker file recording the last live attempt (success or
    /// failure). Persists across process restarts so a fresh launch
    /// after a 429 doesn't immediately re-trigger the wall.
    private var attemptMarkerURL: URL {
        let markerName = cacheURL.deletingPathExtension().lastPathComponent
        return cacheURL.deletingLastPathComponent()
            .appendingPathComponent("\(markerName)-last-attempt.json", isDirectory: false)
    }

    private func readLastFetchAttempt() -> Date? {
        guard let data = try? Data(contentsOf: attemptMarkerURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let iso = json["lastAttempt"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    private func recordFetchAttempt(now: Date) {
        let envelope: [String: String] = [
            "lastAttempt": ISO8601DateFormatter().string(from: now)
        ]
        let parent = attemptMarkerURL.deletingLastPathComponent()
        try? fileManager.value.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: envelope) {
            try? data.write(to: attemptMarkerURL, options: [.atomic])
        }
    }
}

// MARK: - OAuth Constants

/// Anthropic's published OAuth client ID for Claude Code — identical
/// across all integrations (CLI, IDE plugins, OpenBurnBar). Hard-coded
/// because the value never changes and embedding it spares us a
/// configuration round-trip.
enum ClaudeOAuthConstants {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}

// MARK: - Strongly-Typed Rate Limits

/// Anthropic's `/api/oauth/usage` payload, modeled as Sendable value
/// types so we can pass it across actor boundaries safely. Replaces
/// the old `[String: Any]` shape that violated Swift 6 concurrency.
struct ClaudeRateLimits: Sendable, Equatable {
    let windows: [String: Window]
    /// Preserved JSON shape used purely for round-tripping into the
    /// disk cache. Read-only — callers must use `windows` for any
    /// logic. Sendable because we encode it back to JSON before any
    /// cross-actor handoff.
    private let _rawJSON: Data

    var rawDictionary: [String: Any] {
        (try? JSONSerialization.jsonObject(with: _rawJSON) as? [String: Any]) ?? [:]
    }

    var isEmpty: Bool { windows.isEmpty }

    func window(named key: String) -> Window? { windows[key] }

    /// One named limit bucket returned by `/api/oauth/usage`. We model
    /// `usedPercentage`, `remainingPercentage`, and `resetsAt`; any
    /// other server fields are preserved in `rawDictionary` for the
    /// cache round-trip but ignored for UI.
    struct Window: Sendable, Equatable {
        let key: String
        let usedPercentage: Double?
        let remainingPercentage: Double?
        let resetsAt: Date?
    }

    static let empty = ClaudeRateLimits(windows: [:], rawJSON: Data("{}".utf8))

    init(windows: [String: Window], rawJSON: Data) {
        self.windows = windows
        self._rawJSON = rawJSON
    }

    /// Parses the response body directly. The endpoint returns either
    /// `{"rate_limits": {...}}` or the bare `{...}` map — we accept
    /// both for forward-compatibility.
    init(from data: Data) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self = .empty
            return
        }
        let bucket = (raw["rate_limits"] as? [String: Any]) ?? raw
        self.init(from: bucket)
    }

    init(from dictionary: [String: Any]) {
        var parsed: [String: Window] = [:]
        for (key, value) in dictionary {
            guard let payload = value as? [String: Any] else { continue }
            let used = Self.firstNumber(
                in: payload,
                keys: ["used_percentage", "usedPercent", "percentage", "utilization", "used"]
            )
            let remaining = Self.firstNumber(in: payload, keys: ["remaining_percentage", "remainingPercent"])
                ?? used.map { max(0, 100 - $0) }
            let reset = Self.firstDate(in: payload, keys: ["resets_at", "reset_at", "resetTime"])
            guard used != nil || remaining != nil || reset != nil else { continue }
            parsed[key] = Window(
                key: key,
                usedPercentage: used,
                remainingPercentage: remaining,
                resetsAt: reset
            )
        }
        // Persist the original payload so the disk cache round-trips
        // unknown fields. Falls back to a synthetic encoding when the
        // dictionary contains non-JSON-encodable values.
        let raw = (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data("{}".utf8)
        self.init(windows: parsed, rawJSON: raw)
    }

    private static func firstNumber(in payload: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = payload[key] as? Double { return v }
            if let v = payload[key] as? Int { return Double(v) }
            if let v = payload[key] as? String, let parsed = Double(v) { return parsed }
        }
        return nil
    }

    private static func firstDate(in payload: [String: Any], keys: [String]) -> Date? {
        let iso = ISO8601DateFormatter()
        let isoWithFractionalSeconds = ISO8601DateFormatter()
        isoWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for key in keys {
            if let v = payload[key] as? Double { return Date(timeIntervalSince1970: v) }
            if let v = payload[key] as? Int { return Date(timeIntervalSince1970: Double(v)) }
            if let s = payload[key] as? String {
                if let parsed = iso.date(from: s) ?? isoWithFractionalSeconds.date(from: s) { return parsed }
                if let unix = Double(s) { return Date(timeIntervalSince1970: unix) }
            }
        }
        return nil
    }
}

// MARK: - Sendable Helpers

/// `FileManager` is a non-Sendable reference type. Wrapping it in a
/// `@unchecked Sendable` box localizes the unsafety to one place we
/// audit (it's a thread-safe Foundation singleton in practice) rather
/// than scattering `@unchecked` annotations across every struct that
/// holds one.
struct FileManagerSendableBox: @unchecked Sendable {
    let value: FileManager
    init(_ value: FileManager) { self.value = value }
}
