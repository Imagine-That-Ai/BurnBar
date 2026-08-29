import Foundation

@MainActor
enum AnalyticsRuntime {
    private static var consentStore: AnalyticsConsentStore?
    private static var recorder: Analytics?
    private static var rememberedFirstLaunch = false
    private static var sessionSpineEmitted = false

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
        sessionSpineEmitted = false
        rememberedFirstLaunch = false
    }

    static var consent: AnalyticsConsentStore {
        if let consentStore {
            return consentStore
        }
        let store = AnalyticsConsentStore()
        consentStore = store
        return store
    }

    static func rememberFirstLaunch(_ isFirst: Bool) {
        rememberedFirstLaunch = isFirst
    }

    static var currentSessionIsFirstLaunch: Bool { rememberedFirstLaunch }

    static func trackFunnelSessionStart() {
        guard consent.isGranted else { return }
        guard !sessionSpineEmitted else { return }
        sessionSpineEmitted = true
        let isFirst = rememberedFirstLaunch
        analytics.track(.appSessionStarted, [
            "is_first_launch": .bool(isFirst),
            "cold_start": .bool(true)
        ])
        analytics.track(.appOpened, [
            "is_first_launch": .bool(isFirst),
            "cold_start": .bool(true),
            "surface": .string("macos")
        ])
        if isFirst {
            analytics.track(.installStarted, ["surface": .string("macos")])
        }
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

    static func rememberFirstLaunch(_ isFirst: Bool) {
        AnalyticsRuntime.rememberFirstLaunch(isFirst)
    }

    static func trackFunnelSessionStartIfConsented() {
        AnalyticsRuntime.trackFunnelSessionStart()
    }
}
