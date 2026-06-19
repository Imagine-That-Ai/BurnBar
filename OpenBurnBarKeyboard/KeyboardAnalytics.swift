import Foundation
import AmplitudeSwift
import OpenBurnBarAnalytics

/// Emit-only analytics for the custom keyboard extension. The keyboard runs in its
/// own sandboxed process and **reads the host app's consent** from the shared App
/// Group before sending anything — it never shows a prompt and never mutates
/// consent.
///
/// HARD PRIVACY RULE: this never sends keystrokes, typed text, the document
/// context, predictions, spell-check candidates, or snippet contents — EVER. It
/// emits only two usage OUTCOMES: that the keyboard became active, and that *a*
/// snippet was inserted (a bucketed count, no text). A keyboard extension with
/// "Allow Full Access" is exactly where a privacy mistake would be catastrophic,
/// so the surface is deliberately tiny and content-free.
///
/// Gated three ways before a byte leaves the process: host consent (shared
/// suite), a configured key (no key → no client), and the recorder's own gate.
@MainActor
enum KeyboardAnalytics {
    private static let shared: Analytics? = make()

    private static func make() -> Analytics? {
        guard AnalyticsConsentReader.isGranted() else { return nil }
        guard let key = KeyboardAnalyticsConfig.apiKey(), !key.isEmpty else { return nil }

        let consent = AnalyticsConsentStore() // reads shared App Group → .granted
        let transport = KeyboardAmplitudeTransport(apiKey: key, deviceId: AnalyticsIdentity.deviceId())
        let sessionId = UUID().uuidString
        let analytics = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { AnalyticsSuperProperties.keyboard(sessionId: sessionId).asDictionary() }
        )
        analytics.startIfConsented() // resume; never re-announce grant
        return analytics
    }

    /// The keyboard became the active input view. No content, ever.
    static func trackActivated() {
        shared?.track(.keyboardActivated)
    }

    /// A saved snippet was inserted. We send a BUCKETED count of how many snippets
    /// were available — never the snippet text, the typed text, or the document.
    static func trackSnippetInserted(availableSnippetCount: Int) {
        shared?.track(.keyboardSnippetInserted, [
            "available_count_bucket": .string(AnalyticsBuckets.count(availableSnippetCount))
        ])
    }
}

enum KeyboardAnalyticsConfig {
    static func apiKey(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let v = (bundle.object(forInfoDictionaryKey: "amplitude.apiKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !v.isEmpty, !v.hasPrefix("$("), !v.hasPrefix("__") {
            return v
        }
        if let e = environment["BURNBAR_AMPLITUDE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
            return e
        }
        return nil
    }
}

/// Hardened, short-lived Amplitude transport for the keyboard — identical posture
/// to the app transport (autocapture off; IP/carrier/city/DMA/IDFV/region
/// stripped; anonymous device id; flush-on-close). No key → never constructs.
@MainActor
final class KeyboardAmplitudeTransport: AnalyticsTransporting {
    private let apiKey: String?
    private let deviceId: String
    private var amplitude: Amplitude?

    init(apiKey: String?, deviceId: String) {
        self.apiKey = apiKey
        self.deviceId = deviceId
    }

    var isStarted: Bool { amplitude != nil }

    func start() {
        guard amplitude == nil, let key = apiKey, !key.isEmpty else { return }
        let configuration = Configuration(
            apiKey: key,
            flushQueueSize: 5,
            flushIntervalMillis: 5_000,
            instanceName: "openburnbar",
            optOut: false,
            trackingOptions: TrackingOptions()
                .disableTrackIpAddress()
                .disableTrackCarrier()
                .disableTrackCity()
                .disableTrackDMA()
                .disableTrackIDFV()
                .disableTrackRegion(),
            flushEventsOnClose: true,
            autocapture: []
        )
        let amp = Amplitude(configuration: configuration)
        amp.setDeviceId(deviceId: deviceId)
        amplitude = amp
    }

    func stop() {
        amplitude?.configuration.optOut = true
        amplitude = nil
    }

    func send(name: String, category: String, properties: [String: AnalyticsValue]) {
        guard let amp = amplitude else { return }
        var payload: [String: Any] = [:]
        for (key, value) in properties { payload[key] = value.anyValue }
        payload["event_category"] = category
        amp.track(eventType: name, eventProperties: payload)
    }

    func setUserId(_ id: String?) { amplitude?.setUserId(userId: id) }
}
