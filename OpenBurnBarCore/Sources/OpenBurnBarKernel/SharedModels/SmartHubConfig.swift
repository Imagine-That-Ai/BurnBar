import Foundation

// MARK: - Smart Hub Config
//
// Shared across macOS (publisher) and iOS (consumer). Lets the iPhone show
// a "Cast Now" button that pings the Mac's local DashCast bridge so the
// quota dashboard renders on the configured Google Nest Hub / Chromecast.
//
// Stored at `users/{uid}/smart_hub_config/{deviceId}` on Firestore. The Mac
// publishes whenever Settings → Provider Quota → "Nest Hub quota display"
// changes; iOS reads on app launch and pull-to-refresh.

public struct SmartHubConfig: Codable, Sendable, Equatable {

    /// `true` when the Mac has the smart-hub feature switched on. iOS hides
    /// the Cast Now button when this is `false`.
    public var enabled: Bool

    /// Local URL of the rendered dashboard (e.g. `http://127.0.0.1:8787/render.html`).
    /// Open in a browser to view the live render.
    public var dashboardURL: String?

    /// Refresh endpoint — a POST here re-renders + pushes to the Nest Hub.
    /// This is the URL the "Cast Now" button hits.
    public var refreshURL: String?

    /// Voice routine endpoint — kicks off a Google Routine that voice-shouts
    /// the quota status. Optional; we surface a separate "Speak now" action
    /// on iOS when present.
    public var voiceRefreshURL: String?

    /// Friendly name of the Mac that's running the bridge (e.g. "Alberto's MBP").
    public var sourceDeviceName: String?

    /// Last time the Mac published this doc. iOS shows "Last synced 5m ago".
    public var publishedAt: Date

    /// Time period to display on the smart hub dashboard. Lets users see
    /// usage across the rolling 5h / 24h / 7d / 30d window.
    public var timePeriod: SmartHubTimePeriod

    /// Optional ULANZI TC001 / AWTRIX pixel clock target. This is non-secret
    /// owner-scoped LAN configuration used by the Mac bridge and mobile apps.
    public var pixelClock: PixelClockConfig?

    /// Per-Nest-Hub display customization. Added in schema v3 alongside
    /// `displayOrder`. Decodes as `nil` for older documents so the Mac
    /// applies sane defaults.
    public var displayConfig: SmartHubDisplayConfig?

    /// User-chosen order of the Smart Display cards. `nil` decodes as
    /// the canonical default `[.nestHub, .pixelClock]`.
    public var displayOrder: SmartDisplayOrder?

    /// Firestore payload schema. Older documents omit this and decode as v1.
    public var schemaVersion: Int

    private enum CodingKeys: String, CodingKey {
        case enabled
        case dashboardURL
        case refreshURL
        case voiceRefreshURL
        case sourceDeviceName
        case publishedAt
        case timePeriod
        case pixelClock
        case displayConfig
        case displayOrder
        case schemaVersion
    }

    public init(
        enabled: Bool,
        dashboardURL: String? = nil,
        refreshURL: String? = nil,
        voiceRefreshURL: String? = nil,
        sourceDeviceName: String? = nil,
        publishedAt: Date = Date(),
        timePeriod: SmartHubTimePeriod = .rolling5h,
        pixelClock: PixelClockConfig? = nil,
        displayConfig: SmartHubDisplayConfig? = nil,
        displayOrder: SmartDisplayOrder? = nil,
        schemaVersion: Int = 2
    ) {
        self.enabled = enabled
        self.dashboardURL = dashboardURL
        self.refreshURL = refreshURL
        self.voiceRefreshURL = voiceRefreshURL
        self.sourceDeviceName = sourceDeviceName
        self.publishedAt = publishedAt
        self.timePeriod = timePeriod
        self.pixelClock = pixelClock
        self.displayConfig = displayConfig
        self.displayOrder = displayOrder
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        dashboardURL = try c.decodeIfPresent(String.self, forKey: .dashboardURL)
        refreshURL = try c.decodeIfPresent(String.self, forKey: .refreshURL)
        voiceRefreshURL = try c.decodeIfPresent(String.self, forKey: .voiceRefreshURL)
        sourceDeviceName = try c.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt) ?? Date.distantPast
        timePeriod = try c.decodeIfPresent(SmartHubTimePeriod.self, forKey: .timePeriod) ?? .rolling5h
        pixelClock = try c.decodeIfPresent(PixelClockConfig.self, forKey: .pixelClock)
        displayConfig = try c.decodeIfPresent(SmartHubDisplayConfig.self, forKey: .displayConfig)
        displayOrder = try c.decodeIfPresent(SmartDisplayOrder.self, forKey: .displayOrder)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(dashboardURL, forKey: .dashboardURL)
        try c.encodeIfPresent(refreshURL, forKey: .refreshURL)
        try c.encodeIfPresent(voiceRefreshURL, forKey: .voiceRefreshURL)
        try c.encodeIfPresent(sourceDeviceName, forKey: .sourceDeviceName)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(timePeriod, forKey: .timePeriod)
        try c.encodeIfPresent(pixelClock, forKey: .pixelClock)
        try c.encodeIfPresent(displayConfig, forKey: .displayConfig)
        try c.encodeIfPresent(displayOrder, forKey: .displayOrder)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }

    /// Convenience: an empty/disabled config that iOS treats as "no smart
    /// hub configured".
    public static let disabled = SmartHubConfig(enabled: false)
}

// MARK: - Smart Hub Time Period

/// Window the smart-hub dashboard renders. Bucket selection in the bridge
/// snapshot pump picks the matching provider bucket (rolling 5-hour for
/// Claude Code, weekly for Factory plan limits, etc.) so the same UI
/// surfaces meaningful numbers regardless of provider.
public enum SmartHubTimePeriod: String, Codable, Sendable, CaseIterable {
    case rolling5h
    case rolling24h
    case rolling7d
    case rolling30d

    /// Long-form label for settings UI.
    public var displayName: String {
        switch self {
        case .rolling5h:  return "Last 5 hours"
        case .rolling24h: return "Last 24 hours"
        case .rolling7d:  return "Last 7 days"
        case .rolling30d: return "Last 30 days"
        }
    }

    /// Compact label for the on-device segmented control.
    public var shortLabel: String {
        switch self {
        case .rolling5h:  return "5h"
        case .rolling24h: return "24h"
        case .rolling7d:  return "7d"
        case .rolling30d: return "30d"
        }
    }

    /// Number of hours the period covers — used to score which provider
    /// bucket best matches the selection (closest hours wins).
    public var spanHours: Double {
        switch self {
        case .rolling5h:  return 5
        case .rolling24h: return 24
        case .rolling7d:  return 24 * 7
        case .rolling30d: return 24 * 30
        }
    }
}
