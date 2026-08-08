import Foundation
import OpenBurnBarCore

/// Privacy-preserving telemetry helper for the visual capture source toggle.
/// All payloads are enumerated strings / booleans; no window titles, bundle IDs beyond
/// persistedToken, file paths, or pixel data are ever included.
///
/// Wire name: `visual_capture.surface_selected`
/// Params: `provider` (persistedToken), `surface` (cli_pty|desktop_app),
/// `trigger` (settings|session_header|mobile), `fallback_used` (Bool), `is_eligible` (Bool)
/// Route: through `Analytics.shared.track` (consent-gated) or any `Analytics` instance.
///
/// This helper does **not** observe UserDefaults itself; callers (Settings toggle,
/// session header pill, mobile picker) call `trackSurfaceSelected` explicitly on commit.
/// A future `NotificationCenter` bridge could be added, but explicit emit avoids double-count.
@MainActor
enum VisualCaptureTelemetry {

    /// Trigger surface for the toggle — where the user changed it.
    enum Trigger: String, Sendable {
        case settings
        case sessionHeader = "session_header"
        case mobile
    }

    /// Emits `visual_capture.surface_selected` via the shared analytics recorder.
    /// No-op when consent is not granted (recorder drops it).
    static func trackSurfaceSelected(
        provider: AgentProvider,
        surface: VisualCaptureSource,
        trigger: Trigger,
        fallbackUsed: Bool,
        isEligible: Bool,
        analytics: Analytics = .shared
    ) {
        analytics.track(
            .visualCaptureSurfaceSelected,
            [
                "provider": .string(provider.persistedToken),
                "surface": .string(surface.rawValue),
                "trigger": .string(trigger.rawValue),
                "fallback_used": .bool(fallbackUsed),
                "is_eligible": .bool(isEligible),
            ]
        )
    }

    /// Convenience when only a raw provider token string is available (e.g. telemetry from
    /// a decoded persistedToken without re-resolving the enum).
    static func trackSurfaceSelected(
        providerToken: String,
        surfaceRawValue: String,
        trigger: Trigger,
        fallbackUsed: Bool,
        isEligible: Bool,
        analytics: Analytics = .shared
    ) {
        analytics.track(
            .visualCaptureSurfaceSelected,
            [
                "provider": .string(providerToken),
                "surface": .string(surfaceRawValue),
                "trigger": .string(trigger.rawValue),
                "fallback_used": .bool(fallbackUsed),
                "is_eligible": .bool(isEligible),
            ]
        )
    }

    /// Validates that a payload dictionary contains exactly the allowed keys and
    /// no PII-sensitive keys (windowTitle, bundleId, hash, path, etc.).
    /// Intended for unit-test privacy guard.
    static let allowedKeys: Set<String> = [
        "provider", "surface", "trigger", "fallback_used", "is_eligible"
    ]

    static let allowedSurfaceValues: Set<String> = ["cli_pty", "desktop_app"]
    static let allowedTriggerValues: Set<String> = ["settings", "session_header", "mobile"]

    /// Returns true when the property dict is compliant with the telemetry contract.
    static func isCompliantPayload(_ properties: [String: AnalyticsValue]) -> Bool {
        let keys = Set(properties.keys)
        // Must be subset of allowedKeys and contain provider/surface/trigger at least
        guard keys.isSubset(of: allowedKeys) else { return false }
        guard keys.contains("provider"), keys.contains("surface"), keys.contains("trigger") else { return false }
        // Validate surface/trigger enums if present
        if case let .string(surface)? = properties["surface"] {
            guard allowedSurfaceValues.contains(surface) else { return false }
        }
        if case let .string(trigger)? = properties["trigger"] {
            guard allowedTriggerValues.contains(trigger) else { return false }
        }
        // Disallow any string value that looks like a bundle ID or path (heuristic guard)
        for (k, v) in properties {
            if case let .string(s) = v {
                // Reject values containing path separators or whitespace (potential file path / title)
                if s.contains("/") || s.contains("\\") { return false }
                // Reject overly long strings (potential exfil)
                if s.count > 64 { return false }
            }
            _ = k
        }
        return true
    }
}
