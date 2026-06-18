import Foundation

/// Stable per-install device id for Amplitude — a random UUID persisted in
/// UserDefaults, **never** a hardware identifier (IDFV/serial/MAC). Generated
/// once per install; the wrapper sets it as Amplitude's `device_id` so anonymous
/// users are counted without any hardware fingerprint.
enum AnalyticsIdentity {
    static let deviceIdKey = "analyticsDeviceId"

    static func deviceId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIdKey)
        return id
    }
}
