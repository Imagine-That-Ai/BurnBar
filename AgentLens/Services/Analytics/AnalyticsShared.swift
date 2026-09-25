import Foundation
import OpenBurnBarAnalytics

@MainActor
enum AnalyticsRuntime {
    private static var consentStore: AnalyticsConsentStore?
    private static var recorder: Analytics?

    static func configure(
        consentStore newConsentStore: AnalyticsConsentStore? = nil,
        recorder newRecorder: Analytics? = nil
    ) {
        if let newConsentStore {
            consentStore = newConsentStore
        }
        if let newRecorder {
            recorder = newRecorder
        }
    }

    static var consent: AnalyticsConsentStore {
        if let consentStore {
            return consentStore
        }
        // Pinned to .standard: the Core default is the shared App Group suite (iOS
        // extensions), but macOS has always persisted consent in .standard.
        let store = AnalyticsConsentStore(defaults: .standard)
        consentStore = store
        return store
    }

    static var analytics: Analytics {
        if let recorder {
            return recorder
        }
        let sessionId = UUID().uuidString
        let transport = AmplitudeTransport(
            apiKey: AnalyticsConfig.apiKey,
            // Pinned to .standard: same as consent above — the macOS device id has
            // always lived in .standard, not the iOS App Group suite.
            deviceId: AnalyticsIdentity.deviceId(defaults: .standard)
        )
        let instance = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { AnalyticsSuperProperties.macOS(sessionId: sessionId).asDictionary() }
        )
        recorder = instance
        return instance
    }
}

extension AnalyticsConsentStore {
    /// App-wide consent store owned by `AnalyticsRuntime`. The settings toggle
    /// and first-run prompt mutate this; the recorder reads it on every call.
    static var shared: AnalyticsConsentStore { AnalyticsRuntime.consent }
}

extension Analytics {
    /// App-wide recorder owned by `AnalyticsRuntime`. Every instrumentation call
    /// site goes through this accessor; nothing touches the Amplitude SDK directly.
    static var shared: Analytics { AnalyticsRuntime.analytics }
}
