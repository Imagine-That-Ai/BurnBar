import Foundation

// MARK: - Home Assistant Recovery Config
//
// All non-secret state for the OpenBurnBar Smart Display recovery flow.
// The access token never lives here — it sits in `HomeAssistantTokenStore`.
// `webhookID` is the random secret OpenBurnBar provisioned when it
// installed the recovery automation; it is reproduced into the webhook
// URL on every recovery call.

struct HomeAssistantConfig: Codable, Equatable, Sendable {

    /// Normalized HA base URL ("http://homeassistant.local:8123",
    /// "https://my.example.com"). Does not contain trailing slash.
    var baseURL: URL

    /// Selected `media_player.*` entity that will be cast to during
    /// recovery. Empty until the user confirms the picker.
    var mediaPlayerEntityID: String

    /// Friendly display name surfaced in the UI / logs.
    var mediaPlayerFriendlyName: String

    /// Random URL-safe ID used as the webhook trigger ID inside HA.
    /// We prefix with `openburnbar_cast_recover_` to make it visually
    /// recognizable in users' HA configs.
    var webhookID: String

    /// HA-side automation entity ID we created or updated.
    var automationEntityID: String

    /// Whether the recovery automation is currently considered installed.
    var automationInstalled: Bool

    /// Whether the live test successfully reached HA at least once.
    var lastTestPassed: Bool

    /// ISO8601 timestamp of last successful verification.
    var lastVerifiedAt: Date?

    /// Mode used for setup. We branch UI on this in Settings.
    var setupMode: SetupMode

    enum SetupMode: String, Codable, Sendable, CaseIterable {
        case rest                 // Phase A — REST automation provisioning
        case blueprint            // Blueprint fallback path
        case manualWebhook        // User pasted a webhook URL by hand
    }

    init(
        baseURL: URL,
        mediaPlayerEntityID: String = "",
        mediaPlayerFriendlyName: String = "",
        webhookID: String = "",
        automationEntityID: String = "",
        automationInstalled: Bool = false,
        lastTestPassed: Bool = false,
        lastVerifiedAt: Date? = nil,
        setupMode: SetupMode = .rest
    ) {
        self.baseURL = baseURL
        self.mediaPlayerEntityID = mediaPlayerEntityID
        self.mediaPlayerFriendlyName = mediaPlayerFriendlyName
        self.webhookID = webhookID
        self.automationEntityID = automationEntityID
        self.automationInstalled = automationInstalled
        self.lastTestPassed = lastTestPassed
        self.lastVerifiedAt = lastVerifiedAt
        self.setupMode = setupMode
    }

    /// Webhook URL to call on the configured HA instance.
    /// HA exposes webhooks at `<baseURL>/api/webhook/<id>`.
    var webhookURL: URL? {
        guard !webhookID.isEmpty else { return nil }
        return baseURL.appendingPathComponent("api/webhook/\(webhookID)")
    }
}

// MARK: - URL Normalization

enum HomeAssistantURLNormalizer {

    /// Accepts free-form user input ("homeassistant.local",
    /// "http://homeassistant.local:8123/", "https://x.duckdns.org") and
    /// returns a canonical URL we can use as `baseURL`.
    ///
    /// Rules:
    ///   - If no scheme is present, we assume `http://` for `*.local`
    ///     hostnames and `https://` for everything else.
    ///   - We append `:8123` only for `http` schemes that omit a port,
    ///     since that's HA's default; HTTPS endpoints (Nabu Casa,
    ///     reverse proxies) typically already terminate on 443.
    ///   - We strip any trailing slash, query, and path.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else if trimmed.hasSuffix(".local") || trimmed.contains(".local:") {
            withScheme = "http://" + trimmed
        } else {
            withScheme = "https://" + trimmed
        }

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else { return nil }

        // Drop path/query/fragment — we only want the origin.
        components.path = ""
        components.query = nil
        components.fragment = nil

        // Default port for plain http when missing.
        if components.scheme == "http", components.port == nil {
            components.port = 8123
        }

        return components.url
    }
}
