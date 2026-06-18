import Foundation

extension AnalyticsConsentStore {
    /// The single app-wide consent store. The settings toggle and the first-run
    /// prompt mutate this; `Analytics.shared` reads it on every call. Persisted to
    /// `UserDefaults.standard`.
    static let shared = AnalyticsConsentStore()
}

extension Analytics {
    /// The single app-wide recorder. Every instrumentation call site goes through
    /// `Analytics.shared.track(...)`; nothing touches the Amplitude SDK directly.
    /// Built once, lazily, on first access — the SDK is not constructed until the
    /// recorder's `start()` runs (which only happens after consent is granted).
    static let shared: Analytics = {
        let sessionId = UUID().uuidString
        let transport = AmplitudeTransport(
            apiKey: AnalyticsConfig.apiKey,
            deviceId: AnalyticsIdentity.deviceId()
        )
        return Analytics(
            consent: AnalyticsConsentStore.shared,
            transport: transport,
            superProperties: { AnalyticsSuperProperties.macOS(sessionId: sessionId).asDictionary() }
        )
    }()
}
