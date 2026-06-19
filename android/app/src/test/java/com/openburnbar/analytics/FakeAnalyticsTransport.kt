package com.openburnbar.analytics

/**
 * Test double for [AnalyticsTransport]. Records every lifecycle call and every
 * send so the consent contract can be asserted on a pure JVM with no Amplitude
 * SDK and no network — the same role the macOS/website fakes play. Crucially it
 * records whether [start] was EVER called, so "provably dark before opt-in" is a
 * concrete assertion (`startCount == 0`), not a vibe.
 */
class FakeAnalyticsTransport : AnalyticsTransport {
    data class Sent(val name: String, val category: String, val properties: Map<String, AnalyticsValue>)

    val sent = mutableListOf<Sent>()
    var startCount = 0
        private set
    var stopCount = 0
        private set
    var lastUserId: String? = null
    var userIdSetCount = 0
        private set

    private var started = false

    override val isStarted: Boolean
        get() = started

    override fun start() {
        started = true
        startCount++
    }

    override fun stop() {
        started = false
        stopCount++
    }

    override fun send(name: String, category: String, properties: Map<String, AnalyticsValue>) {
        // Mirror the production transport: a send only lands while started.
        if (!started) return
        sent.add(Sent(name, category, properties))
    }

    override fun setUserId(id: String?) {
        lastUserId = id
        userIdSetCount++
    }

    /** Names of events recorded, in order — convenient for sequence assertions. */
    fun names(): List<String> = sent.map { it.name }
}

/** In-memory [ConsentStorage] so tests need no SharedPreferences / Robolectric. */
class InMemoryConsentStorage(initial: String? = null) : ConsentStorage {
    private val map = HashMap<String, String>()

    init {
        if (initial != null) map[AnalyticsConsentStore.CONSENT_STORAGE_KEY] = initial
    }

    override fun getString(key: String): String? = map[key]

    override fun putString(key: String, value: String) {
        map[key] = value
    }
}
