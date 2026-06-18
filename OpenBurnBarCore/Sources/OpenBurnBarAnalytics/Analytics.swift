import Foundation

/// The one wrapper every instrumentation call goes through. It reads the consent
/// gate on **every** call and drops everything when consent != granted, merges the
/// shared super-properties onto each event, and owns SDK start/stop. No view or
/// component ever talks to the Amplitude SDK directly.
///
/// Ported from `AgentLens/Services/Analytics/Analytics.swift` — same lazy-start,
/// announce-once, stop-on-revoke contract.
@MainActor
public final class Analytics {
    private let consent: AnalyticsConsentStore
    private let transport: AnalyticsTransporting
    private let superProperties: () -> [String: AnalyticsValue]
    private let authenticatedUserId: () -> String?
    private var announcedGrant = false

    public init(
        consent: AnalyticsConsentStore,
        transport: AnalyticsTransporting,
        superProperties: @escaping () -> [String: AnalyticsValue],
        // Yields the **already-hashed** Amplitude `user_id` when a session is
        // authenticated right now, or `nil` when signed out. Consulted on a fresh
        // grant so a user who signed in BEFORE opting in is (re)identified the
        // moment consent flips — without waiting for the next auth-state change.
        // Default `nil` keeps the package usable (and dark) with no auth wiring;
        // the iOS host injects the live signed-in uid hash. Never the raw uid.
        authenticatedUserId: @escaping () -> String? = { nil }
    ) {
        self.consent = consent
        self.transport = transport
        self.superProperties = superProperties
        self.authenticatedUserId = authenticatedUserId
    }

    /// Call when consent changes (settings toggle / first-run prompt). On grant:
    /// start the SDK, emit `consent.analytics.granted` exactly once, and — if a
    /// session is already authenticated — re-identify so a sign-in-then-opt-in
    /// user isn't left anonymous until their next auth-state change. On revoke:
    /// stop the SDK (nothing is flushed) and re-arm the announce flag.
    public func consentDidChange() {
        if consent.isGranted {
            if !transport.isStarted { transport.start() }
            // Re-identify on a fresh grant when already signed in. AuthStore sets
            // `user_id` on auth-state changes, but a grant after sign-in is not an
            // auth-state change, so without this the identity is never set. The
            // provider returns the SHA-256 account-uid hash (never the raw uid),
            // or `nil` when signed out — in which case this is a no-op and the
            // session stays anonymous. Guarded by `isGranted` (this branch), so it
            // can never set an id while consent is off.
            if let userId = authenticatedUserId() {
                transport.setUserId(userId)
            }
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
    public func startIfConsented() {
        guard consent.isGranted else { return }
        if !transport.isStarted { transport.start() }
        announcedGrant = true
    }

    public func track(_ event: AnalyticsEvent, _ properties: [String: AnalyticsValue] = [:]) {
        guard consent.isGranted else { return }     // the gate — checked on every call
        if !transport.isStarted { transport.start() }
        emit(event, properties)
    }

    /// Identify the signed-in user. No-op unless consent is granted.
    public func setUserId(_ id: String?) {
        guard consent.isGranted else { return }
        transport.setUserId(id)
    }

    private func emit(_ event: AnalyticsEvent, _ properties: [String: AnalyticsValue]) {
        var props = superProperties()
        for (key, value) in properties { props[key] = value } // event props extend/override
        transport.send(name: event.rawValue, category: event.category.rawValue, properties: props)
    }
}
