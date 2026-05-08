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

    public init(
        enabled: Bool,
        dashboardURL: String? = nil,
        refreshURL: String? = nil,
        voiceRefreshURL: String? = nil,
        sourceDeviceName: String? = nil,
        publishedAt: Date = Date(),
        timePeriod: SmartHubTimePeriod = .rolling5h
    ) {
        self.enabled = enabled
        self.dashboardURL = dashboardURL
        self.refreshURL = refreshURL
        self.voiceRefreshURL = voiceRefreshURL
        self.sourceDeviceName = sourceDeviceName
        self.publishedAt = publishedAt
        self.timePeriod = timePeriod
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
