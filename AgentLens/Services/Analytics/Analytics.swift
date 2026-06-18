import Foundation

/// The one wrapper every instrumentation call goes through. It reads the consent
/// gate on **every** call and drops everything when consent != granted, merges the
/// shared super-properties onto each event, and owns SDK start/stop. No view or
/// component ever talks to the Amplitude SDK directly.
@MainActor
final class Analytics {
    private let consent: AnalyticsConsentStore
    private let transport: AnalyticsTransporting
    private let superProperties: () -> [String: AnalyticsValue]
    private var announcedGrant = false

    init(
        consent: AnalyticsConsentStore,
        transport: AnalyticsTransporting,
        superProperties: @escaping () -> [String: AnalyticsValue]
    ) {
        self.consent = consent
        self.transport = transport
        self.superProperties = superProperties
    }

    /// Call when consent changes (settings toggle / first-run prompt). On grant:
    /// start the SDK and emit `consent.analytics.granted` exactly once. On revoke:
    /// stop the SDK (nothing is flushed) and re-arm the announce flag.
    func consentDidChange() {
        if consent.isGranted {
            if !transport.isStarted { transport.start() }
            if !announcedGrant {
                announcedGrant = true
                emit(.consentAnalyticsGranted, ["consent_version": "1"])
            }
        } else {
            if transport.isStarted { transport.stop() }
            announcedGrant = false
        }
    }

    /// Record a taxonomy event. Silently dropped unless consent is granted.
    /// Call at app launch: if consent was previously granted, resume sending by
    /// starting the SDK — WITHOUT re-emitting `consent.analytics.granted` (a
    /// resumed session is not a new opt-in). No-op when consent is not granted.
    func startIfConsented() {
        guard consent.isGranted else { return }
        if !transport.isStarted { transport.start() }
        announcedGrant = true
    }

    func track(_ event: AnalyticsEvent, _ properties: [String: AnalyticsValue] = [:]) {
        guard consent.isGranted else { return }     // the gate — checked on every call
        if !transport.isStarted { transport.start() }
        emit(event, properties)
    }

    /// Identify the signed-in user. No-op unless consent is granted.
    func setUserId(_ id: String?) {
        guard consent.isGranted else { return }
        transport.setUserId(id)
    }

    private func emit(_ event: AnalyticsEvent, _ properties: [String: AnalyticsValue]) {
        var props = superProperties()
        for (key, value) in properties { props[key] = value } // event props extend/override
        transport.send(name: event.rawValue, category: event.category.rawValue, properties: props)
    }
}
