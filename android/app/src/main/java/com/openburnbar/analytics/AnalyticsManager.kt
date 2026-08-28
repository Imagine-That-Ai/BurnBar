package com.openburnbar.analytics

import android.content.Context
import com.amplitude.core.ServerZone
import com.openburnbar.BuildConfig
import java.util.Locale
import java.util.UUID

/**
 * The single composition root + public entry point for Android analytics,
 * mirroring website/src/lib/analytics/index.ts. Holds the one [Analytics]
 * recorder, attaches the shared super-properties, owns the anonymous per-install
 * device id, and exposes the consent + tracking surface the rest of the app
 * uses. Nothing else constructs an [Analytics] or touches the Amplitude SDK.
 *
 * The API key comes from [BuildConfig.AMPLITUDE_API_KEY], injected at build time
 * from the `OPENBURNBAR_AMPLITUDE_API_KEY` env var or `amplitude.apiKey` in
 * local.properties (see app/build.gradle.kts). No key is committed; an absent
 * key leaves the recorder dark by construction (the recorder's key check).
 */
object AnalyticsManager {

    @Volatile private var analytics: Analytics? = null

    @Volatile private var consentStore: AnalyticsConsentStore? = null

    @Volatile private var anonymousDeviceId: String? = null

    @Volatile private var currentSessionIsFirstLaunch: Boolean = false

    /** Per-app-session id (rotated each process launch); NOT a user id. */
    private val sessionId: String = UUID.randomUUID().toString()

    /**
     * Initialize once from Application.onCreate. Builds the consent store, the
     * Amplitude transport, and the recorder; then resumes a previously-consented
     * session WITHOUT re-announcing the grant. Safe to call once per process.
     */
    fun initialize(context: Context) {
        if (analytics != null) return
        val app = context.applicationContext
        val storage = SharedPreferencesConsentStorage(app)
        val store = AnalyticsConsentStore(storage)
        val deviceId = AnonymousDeviceId.getOrCreate(app)
        anonymousDeviceId = deviceId
        val serverZone = if (BuildConfig.AMPLITUDE_SERVER_ZONE.equals("EU", ignoreCase = true)) {
            ServerZone.EU
        } else {
            ServerZone.US
        }
        val transport = AmplitudeTransport(
            context = app,
            apiKey = BuildConfig.AMPLITUDE_API_KEY.ifBlank { null },
            deviceId = deviceId,
            serverZone = serverZone,
        )
        val recorder = Analytics(
            consent = store,
            transport = transport,
            apiKey = BuildConfig.AMPLITUDE_API_KEY,
            superProperties = ::superProperties,
        )
        consentStore = store
        analytics = recorder
        // Resume a consented session (no grant re-emit); dark until opt-in.
        recorder.startIfConsented()
    }

    /** True once the visitor has answered the prompt either way (drives first-run UI). */
    val hasDecided: Boolean
        get() = consentStore?.hasDecided ?: false

    val isGranted: Boolean
        get() = consentStore?.isGranted ?: false

    val analyticsConsentPayload: String?
        get() = if (isGranted) AnalyticsConsent.GRANTED.raw else null

    val analyticsDeviceIdPayload: String?
        get() = if (isGranted) anonymousDeviceId else null

    /** Test seam: attach a recorder without Android Context / Amplitude SDK. */
    internal fun attachForTests(store: AnalyticsConsentStore, transport: AnalyticsTransport, apiKey: String = "test-key") {
        consentStore = store
        analytics = Analytics(
            consent = store,
            transport = transport,
            apiKey = apiKey,
            superProperties = ::superProperties,
        )
    }

    internal fun resetForTests() {
        analytics = null
        consentStore = null
        anonymousDeviceId = null
        currentSessionIsFirstLaunch = false
    }

    fun rememberLaunchContext(isFirstLaunch: Boolean) {
        currentSessionIsFirstLaunch = isFirstLaunch
    }

    /** Grant consent: persist, start the transport, emit consent.analytics.granted once. */
    fun grant() {
        consentStore?.grant()
        analytics?.consentDidChange()
    }

    /** Decline: persist; stays dark. */
    fun decline() {
        consentStore?.decline()
        analytics?.consentDidChange()
    }

    /** Revoke (= decline): persist, stop the transport, flush nothing, never re-prompt. */
    fun revoke() {
        consentStore?.revoke()
        analytics?.consentDidChange()
    }

    /** Record a taxonomy event. Silently dropped unless consent granted + key present. */
    fun track(event: AnalyticsEvent, properties: Map<String, AnalyticsValue> = emptyMap()) {
        analytics?.track(event, properties)
    }

    /** Identify the signed-in user with the stable account uid hash. No-op pre-consent. */
    fun setUserId(id: String?) {
        analytics?.setUserId(id)
    }

    /**
     * Emit the once-per-process session start. Call after [initialize] when a
     * consented session resumes (or right after [grant]). Dropped if not
     * consented. The first start in a process is the cold start.
     */
    fun trackSessionStartIfConsented(isFirstLaunch: Boolean) {
        if (!isGranted) return
        track(
            AnalyticsEvent.APP_SESSION_STARTED,
            mapOf(
                "is_first_launch" to isFirstLaunch.av(),
                "cold_start" to true.av(),
            ),
        )
        track(
            AnalyticsEvent.APP_OPENED,
            mapOf(
                "is_first_launch" to isFirstLaunch.av(),
                "cold_start" to true.av(),
                "surface" to "android".av(),
            ),
        )
        if (isFirstLaunch) {
            track(AnalyticsEvent.INSTALL_STARTED, mapOf("surface" to "android".av()))
        }
    }

    fun trackCurrentSessionStartIfConsented() {
        trackSessionStartIfConsented(isFirstLaunch = currentSessionIsFirstLaunch)
    }

    private fun superProperties(): Map<String, AnalyticsValue> {
        val locale = Locale.getDefault()
        val region = locale.country.takeIf { it.isNotBlank() }
        val bcp47 = if (region != null) "${locale.language}-$region" else locale.language
        return linkedMapOf(
            "product" to "burnbar".av(),
            "platform" to "android".av(),
            "app_version" to BuildConfig.VERSION_NAME.av(),
            "app_build" to BuildConfig.VERSION_CODE.toString().av(),
            "session_id" to sessionId.av(),
            "locale" to bcp47.av(),
            "consent_version" to Analytics.CONSENT_VERSION.av(),
        )
    }
}
