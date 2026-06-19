import Foundation

/// Stable per-install device id for Amplitude — a random UUID persisted in the
/// shared App Group, **never** a hardware identifier (IDFV/serial/MAC). Generated
/// once per install; the wrapper sets it as Amplitude's `device_id` so anonymous
/// users are counted without any hardware fingerprint.
///
/// Ported from `AgentLens/Services/Analytics/AnalyticsIdentity.swift`. iOS stores
/// it in the App Group suite so the (rare) extension that initializes a transport
/// shares the same anonymous id as the host rather than minting a second one.
public enum AnalyticsIdentity {
    public static let deviceIdKey = "analyticsDeviceId"

    public static func deviceId(
        defaults: UserDefaults? = nil
    ) -> String {
        let resolved = defaults
            ?? UserDefaults(suiteName: AnalyticsConsentStorage.appGroupIdentifier)
            ?? .standard
        if let existing = resolved.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        resolved.set(id, forKey: deviceIdKey)
        return id
    }
}
