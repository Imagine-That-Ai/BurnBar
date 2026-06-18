package com.openburnbar.analytics

/**
 * The one wrapper every instrumentation call goes through. Ported from
 * AgentLens/Services/Analytics/Analytics.swift and
 * website/src/lib/analytics/recorder.ts. It reads the consent gate on **every**
 * call and drops everything unless consent is granted AND a non-empty API key
 * is present, merges the shared super-properties onto each event, and owns SDK
 * start/stop. No view or component ever talks to the Amplitude SDK directly.
 *
 * Thread-safety: every public entry point synchronizes on [lock] so the
 * announce-once flag and transport start/stop stay consistent if events are
 * tracked from a background dispatcher while the user flips consent on the main
 * thread.
 */
class Analytics(
    private val consent: AnalyticsConsentStore,
    private val transport: AnalyticsTransport,
    private val apiKey: String,
    private val superProperties: () -> Map<String, AnalyticsValue>,
) {
    private val lock = Any()
    private var announcedGrant = false
    private var currentUserId: String? = null

    /** The single invariant: granted consent AND a non-empty key. No key → dark. */
    private val canSend: Boolean
        get() = consent.isGranted && apiKey.isNotEmpty()

    private fun ensureStarted() {
        if (!transport.isStarted) transport.start()
    }

    /** Record a taxonomy event. Silently dropped unless [canSend]. */
    fun track(event: AnalyticsEvent, properties: Map<String, AnalyticsValue> = emptyMap()) {
        synchronized(lock) {
            if (!canSend) return // the gate — checked on every call
            ensureStarted()
            emit(event, properties)
        }
    }

    /**
     * Call when consent changes (settings toggle / first-run prompt). On grant:
     * start the SDK and emit `consent.analytics.granted` exactly once. On
     * revoke: stop the SDK (nothing is flushed) and re-arm the announce flag.
     */
    fun consentDidChange() {
        synchronized(lock) {
            if (canSend) {
                ensureStarted()
                transport.setUserId(currentUserId)
                if (!announcedGrant) {
                    announcedGrant = true
                    emit(AnalyticsEvent.CONSENT_ANALYTICS_GRANTED, mapOf("consent_version" to CONSENT_VERSION.av()))
                }
            } else {
                if (transport.isStarted) transport.stop()
                announcedGrant = false
            }
        }
    }

    /**
     * Resume a previously-consented session on app launch by starting the SDK —
     * WITHOUT re-emitting `consent.analytics.granted` (a resumed session is not
     * a new opt-in). No-op when consent is not granted / no key.
     */
    fun startIfConsented() {
        synchronized(lock) {
            if (!canSend) return
            ensureStarted()
            transport.setUserId(currentUserId)
            announcedGrant = true
        }
    }

    /** Identify the signed-in user. Remembered while dark, forwarded only after [canSend]. */
    fun setUserId(id: String?) {
        synchronized(lock) {
            currentUserId = id
            if (!canSend) return
            ensureStarted()
            transport.setUserId(id)
        }
    }

    private fun emit(event: AnalyticsEvent, properties: Map<String, AnalyticsValue>) {
        val props = LinkedHashMap(superProperties())
        props.putAll(properties) // event props extend/override the super-properties
        transport.send(name = event.wire, category = event.category.wire, properties = props)
    }

    companion object {
        /** Version of the consent copy the user accepted; stamped on grant + every event. */
        const val CONSENT_VERSION = "1"
    }
}
