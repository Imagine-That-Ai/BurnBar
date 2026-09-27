import Foundation

/// Presence-only view of the official Grok Build CLI store at `~/.grok/auth.json`.
///
/// Official `grok login` writes a JSON object keyed by OIDC/API-key scopes
/// (see xAI grok-build user-guide authentication). This type never returns
/// bearer tokens, refresh tokens, or client IDs. It only reports whether a
/// usable `key` field exists, which kind of login it is, and a safe identity
/// label (email) when the CLI stored one.
public enum GrokCLIAuthFile: Sendable {
    public enum Kind: Equatable, Sendable {
        case oauthSession
        case apiKey
    }

    public struct Summary: Equatable, Sendable {
        public var kind: Kind
        public var accountDescription: String?
        public var expiresAt: Date?

        public init(kind: Kind, accountDescription: String? = nil, expiresAt: Date? = nil) {
            self.kind = kind
            self.accountDescription = accountDescription
            self.expiresAt = expiresAt
        }
    }

    /// Official API-key scope written by `grok login --api-key`.
    public static let apiKeyScope = "xai::api_key"
    /// Legacy pre-OIDC scope still present on older Macs.
    public static let legacySignInScope = "https://accounts.x.ai/sign-in"
    /// Current SpaceXAI OAuth issuer prefix. Entries are `issuer::client`;
    /// this code matches the issuer only and never hard-codes a client id.
    public static let oauthIssuerPrefix = "https://auth.x.ai"

    public static func inspect(fileAt url: URL, fileManager: FileManager = .default) -> Summary? {
        guard fileManager.fileExists(atPath: url.path),
              let data = fileManager.contents(atPath: url.path) else {
            return nil
        }
        return inspect(data)
    }

    public static func inspect(_ data: Data) -> Summary? {
        guard let object = try? JSONDecoder().decode([String: AuthEntry].self, from: data) else {
            return nil
        }

        var oauth: Summary?
        var preferredOAuth: Summary?
        var apiKey: Summary?

        for (scope, entry) in object {
            guard let key = entry.key,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let mode = entry.authMode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isAPIKey = scope == apiKeyScope || mode == "api_key"
            let summary = Summary(
                kind: isAPIKey ? .apiKey : .oauthSession,
                accountDescription: accountDescription(from: entry, apiKey: isAPIKey),
                expiresAt: parseExpiry(entry.expiresAt)
            )

            if isAPIKey {
                if apiKey == nil { apiKey = summary }
                continue
            }

            if oauth == nil { oauth = summary }
            if preferredOAuth == nil, scope.hasPrefix(oauthIssuerPrefix) {
                preferredOAuth = summary
            }
        }

        return preferredOAuth ?? oauth ?? apiKey
    }

    private static func accountDescription(from entry: AuthEntry, apiKey: Bool) -> String {
        let email = stringValue(entry.email)
        let first = stringValue(entry.firstName)
        let last = stringValue(entry.lastName)
        let nameParts = [first, last].compactMap { $0 }
        let name = nameParts.isEmpty ? nil : nameParts.joined(separator: " ")
        if let name, let email {
            return "\(name) • \(email)"
        }
        if let email { return email }
        if let name { return name }
        return apiKey ? "Grok CLI API key" : "Grok CLI login"
    }

    private static func stringValue(_ raw: String?) -> String? {
        guard let text = raw else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseExpiry(_ raw: AuthEntry.Expiry?) -> Date? {
        switch raw {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if let date = ThreadSafeISO8601DateFormatter.parse(trimmed) {
                return date
            }
            if let seconds = Double(trimmed) {
                return dateFromEpoch(seconds)
            }
            return nil
        case .seconds(let seconds):
            return dateFromEpoch(seconds)
        case nil:
            return nil
        }
    }

    private static func dateFromEpoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        if value > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        return Date(timeIntervalSince1970: value)
    }

    /// One scope entry of `auth.json`. Every field is read leniently: a value of
    /// an unexpected type (or a non-object entry) reads as absent instead of
    /// failing the whole file. Token material other than `key` presence is
    /// never decoded.
    private struct AuthEntry: Decodable {
        enum Expiry {
            case text(String)
            case seconds(Double)
        }

        let key: String?
        let authMode: String?
        let email: String?
        let firstName: String?
        let lastName: String?
        let expiresAt: Expiry?

        private enum CodingKeys: String, CodingKey {
            case key
            case authMode = "auth_mode"
            case email
            case firstName = "first_name"
            case lastName = "last_name"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String? {
                (try? container?.decodeIfPresent(String.self, forKey: key)) ?? nil
            }
            key = string(.key)
            authMode = string(.authMode)
            email = string(.email)
            firstName = string(.firstName)
            lastName = string(.lastName)
            if let seconds = (try? container?.decodeIfPresent(Double.self, forKey: .expiresAt)) ?? nil {
                expiresAt = .seconds(seconds)
            } else {
                expiresAt = string(.expiresAt).map(Expiry.text)
            }
        }
    }
}
