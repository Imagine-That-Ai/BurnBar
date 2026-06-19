import Foundation
import AmplitudeSwift
import OpenBurnBarAnalytics

/// Emit-only analytics for the WidgetKit extension. The widget runs in its own
/// process and **reads the host app's consent** from the shared App Group before
/// sending anything — it never shows a prompt and never mutates consent. It emits
/// render/tap OUTCOMES only (family + freshness + deep-link target); it never sees
/// or sends any rendered numbers, costs, or content.
///
/// Gated three ways before a single byte leaves the process:
///   1. `AnalyticsConsentReader.isGranted()` — the host must have opted in.
///   2. A configured Amplitude API key — no key → the client is never constructed.
///   3. The recorder's own consent gate (granted store) — defense in depth.
@MainActor
enum WidgetAnalytics {
    private static let shared: Analytics? = make()

    private static func make() -> Analytics? {
        // Read the host's decision from the shared suite. If not granted, return
        // nil so nothing — not even the recorder — is constructed.
        guard AnalyticsConsentReader.isGranted() else { return nil }
        guard let key = WidgetAnalyticsConfig.apiKey(), !key.isEmpty else { return nil }

        let consent = AnalyticsConsentStore() // reads the shared App Group → .granted
        let transport = AmplitudeTransport(apiKey: key, deviceId: AnalyticsIdentity.deviceId())
        let sessionId = UUID().uuidString
        let analytics = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { AnalyticsSuperProperties.widget(sessionId: sessionId).asDictionary() }
        )
        // Resume (do NOT re-announce grant): the host already emitted
        // consent.analytics.granted at opt-in; an extension is not a new opt-in.
        analytics.startIfConsented()
        return analytics
    }

    /// A timeline render completed. `family` and `freshness` are bounded enums.
    static func trackRender(family: String, freshness: String) {
        shared?.track(.widgetRendered, ["family": .string(family), "freshness": .string(freshness)])
    }

    /// The widget was tapped. `target` is the bounded deep-link destination only.
    static func trackTap(target: String) {
        shared?.track(.widgetTapped, ["target": .string(target)])
    }
}

/// Resolves the Amplitude key for the extension from its own Info.plist
/// (`amplitude.apiKey`, shipped as the empty `$(BURNBAR_AMPLITUDE_API_KEY)`
/// placeholder) with an env fallback. Never commits a key; placeholder → nil.
enum WidgetAnalyticsConfig {
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

/// The minimal Amplitude transport for the extension — hardened identically to
/// the app's `AmplitudeTransport`: autocapture off, IP/carrier/city/DMA/IDFV/
/// region stripped, anonymous device id, flush-on-close (extensions are
/// short-lived). With no key it never constructs the client.
@MainActor
final class AmplitudeTransport: AnalyticsTransporting {
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
            flushQueueSize: 5,            // extensions are short-lived: flush sooner
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
