import Foundation

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
        let store = AnalyticsConsentStore()
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
            deviceId: AnalyticsIdentity.deviceId()
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
