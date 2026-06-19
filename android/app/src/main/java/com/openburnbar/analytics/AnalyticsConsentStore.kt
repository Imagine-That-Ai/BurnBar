package com.openburnbar.analytics

/**
 * Tri-state analytics consent — the spine of the opt-in analytics system.
 * Ported from AgentLens/Services/Analytics/AnalyticsConsentStore.swift and
 * website/src/lib/analytics/consent.ts.
 *
 * Default is [AnalyticsConsent.UNSET]: nothing initializes Amplitude and no
 * event leaves the device until the user affirmatively grants. [DECLINED] and
 * [UNSET] are treated identically by the gate ([isGranted] == false).
 * [revoke] lands in [DECLINED], which stops all future sends — nothing is
 * flushed, and the first-run prompt never reappears.
 */
enum class AnalyticsConsent(val raw: String) {
    UNSET("unset"),
    GRANTED("granted"),
    DECLINED("declined"),
    ;

    companion object {
        fun fromRaw(raw: String?): AnalyticsConsent = entries.firstOrNull { it.raw == raw } ?: UNSET
    }
}

/**
 * The minimal key/value seam the store depends on. The production binding is
 * SharedPreferences (see [SharedPreferencesConsentStorage]); tests inject an
 * in-memory map, so the consent contract is verifiable on a pure JVM with no
 * Android runtime.
 */
interface ConsentStorage {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
}

class AnalyticsConsentStore(
    private val storage: ConsentStorage,
    private val key: String = CONSENT_STORAGE_KEY,
) {
    /** The current persisted tri-state, read fresh from storage. */
    val state: AnalyticsConsent
        get() = AnalyticsConsent.fromRaw(storage.getString(key))

    /** The single check the Amplitude wrapper reads on every call. */
    val isGranted: Boolean
        get() = state == AnalyticsConsent.GRANTED

    /** Whether the user has answered the opt-in prompt yet (drives first-run UI). */
    val hasDecided: Boolean
        get() = state != AnalyticsConsent.UNSET

    fun grant() = storage.putString(key, AnalyticsConsent.GRANTED.raw)

    fun decline() = storage.putString(key, AnalyticsConsent.DECLINED.raw)

    /** Revoke = decline. Stops all future sends; flushes nothing; never re-prompts. */
    fun revoke() = storage.putString(key, AnalyticsConsent.DECLINED.raw)

    companion object {
        const val CONSENT_STORAGE_KEY = "analyticsConsentState"
    }
}
