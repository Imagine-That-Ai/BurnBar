package com.openburnbar.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The consent contract — the security spine of the opt-in analytics system.
 * Every assertion here is the Kotlin mirror of the macOS / website contract
 * tests: dark before opt-in (SDK never constructed), correct name+category+props
 * after grant, exactly one grant emission, resume-without-re-announce, silent
 * after revoke, and dark with no key. The fake transport makes "dark" a concrete
 * fact (`startCount == 0`), not an assertion of intent.
 */
class AnalyticsConsentContractTest {

    private val key = "test-key"

    private fun superProps(): Map<String, AnalyticsValue> = linkedMapOf(
        "platform" to "android".av(),
        "app_version" to "1.0.18".av(),
    )

    private fun makeRecorder(initialConsent: String? = null, apiKey: String = key): Pair<Analytics, FakeAnalyticsTransport> {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(initialConsent))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(
            consent = store,
            transport = transport,
            apiKey = apiKey,
            superProperties = ::superProps,
        )
        return recorder to transport
    }

    // ── DARK BEFORE OPT-IN (default unset) ──

    @Test
    fun `unset consent is provably dark — SDK never constructed, nothing sent`() {
        val (recorder, transport) = makeRecorder(initialConsent = null)
        recorder.startIfConsented()
        recorder.track(AnalyticsEvent.SCREEN_VIEWED, mapOf("surface" to "dashboard".av()))
        recorder.track(AnalyticsEvent.CHAT_MESSAGE_SENT)
        recorder.setUserId("hashed-uid")

        assertEquals("transport must never start before opt-in", 0, transport.startCount)
        assertFalse(transport.isStarted)
        assertTrue("no events may be sent before opt-in", transport.sent.isEmpty())
        assertEquals("no user id may be set before opt-in", 0, transport.userIdSetCount)
    }

    @Test
    fun `declined consent is dark — identical to unset`() {
        val (recorder, transport) = makeRecorder(initialConsent = AnalyticsConsent.DECLINED.raw)
        recorder.startIfConsented()
        recorder.consentDidChange() // declined → ensure no start/announce
        recorder.track(AnalyticsEvent.SCREEN_VIEWED)

        assertEquals(0, transport.startCount)
        assertTrue(transport.sent.isEmpty())
    }

    @Test
    fun `no api key stays dark even when consent is granted`() {
        val (recorder, transport) = makeRecorder(initialConsent = AnalyticsConsent.GRANTED.raw, apiKey = "")
        recorder.startIfConsented()
        recorder.consentDidChange()
        recorder.track(AnalyticsEvent.SCREEN_VIEWED)

        assertEquals("empty key must keep the SDK dark by construction", 0, transport.startCount)
        assertTrue(transport.sent.isEmpty())
    }

    // ── GRANT ──

    @Test
    fun `grant starts the transport and emits exactly one consent granted`() {
        val (recorder, transport) = makeRecorder(initialConsent = null)
        // Simulate the manager: persist grant then notify the recorder.
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val grantedRecorder = Analytics(store, transport, key, ::superProps)
        grantedRecorder.consentDidChange()

        assertEquals(1, transport.startCount)
        assertTrue(transport.isStarted)
        val grants = transport.names().filter { it == AnalyticsEvent.CONSENT_ANALYTICS_GRANTED.wire }
        assertEquals("exactly one consent.analytics.granted at opt-in", 1, grants.size)
    }

    @Test
    fun `consent granted carries lifecycle category and consent_version plus super properties`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange()

        val grant = transport.sent.single { it.name == AnalyticsEvent.CONSENT_ANALYTICS_GRANTED.wire }
        assertEquals("lifecycle", grant.category)
        assertEquals(AnalyticsValue.Str("1"), grant.properties["consent_version"])
        // Super-properties are merged onto every event.
        assertEquals(AnalyticsValue.Str("android"), grant.properties["platform"])
        assertEquals(AnalyticsValue.Str("1.0.18"), grant.properties["app_version"])
    }

    @Test
    fun `double grant does not double-announce`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange()
        recorder.consentDidChange() // idempotent

        assertEquals(1, transport.names().count { it == AnalyticsEvent.CONSENT_ANALYTICS_GRANTED.wire })
        assertEquals("transport started exactly once", 1, transport.startCount)
    }

    // ── EVENTS AFTER GRANT ──

    @Test
    fun `tracked event after grant has correct name category and merged props`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange()

        recorder.track(
            AnalyticsEvent.SCREEN_VIEWED,
            mapOf("surface" to "dashboard".av(), "is_first_view" to true.av()),
        )

        val view = transport.sent.single { it.name == AnalyticsEvent.SCREEN_VIEWED.wire }
        assertEquals("screen.viewed", view.name)
        assertEquals("screen_view", view.category)
        assertEquals(AnalyticsValue.Str("dashboard"), view.properties["surface"])
        assertEquals(AnalyticsValue.Bool(true), view.properties["is_first_view"])
        assertEquals(AnalyticsValue.Str("android"), view.properties["platform"]) // super-prop merged
    }

    @Test
    fun `event props override super properties on key collision`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        // super-property 'platform' is overridden by an event prop of the same key.
        val recorder = Analytics(store, transport, key) { mapOf("platform" to "android".av(), "surface" to "app".av()) }
        recorder.consentDidChange()
        recorder.track(AnalyticsEvent.SCREEN_VIEWED, mapOf("surface" to "settings".av()))

        val view = transport.sent.single { it.name == AnalyticsEvent.SCREEN_VIEWED.wire }
        assertEquals(AnalyticsValue.Str("settings"), view.properties["surface"])
    }

    @Test
    fun `setUserId after grant is forwarded to the transport`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange()
        recorder.setUserId("hashed-account-id")

        assertEquals("hashed-account-id", transport.lastUserId)
    }

    @Test
    fun `setUserId before grant is replayed when consent opens`() {
        val storage = InMemoryConsentStorage(null)
        val store = AnalyticsConsentStore(storage)
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)

        recorder.setUserId("hashed-before-consent")
        assertEquals("no user id may be forwarded while dark", 0, transport.userIdSetCount)

        store.grant()
        recorder.consentDidChange()

        assertEquals("hashed-before-consent", transport.lastUserId)
        assertEquals(1, transport.userIdSetCount)
    }

    // ── RESUME WITHOUT RE-ANNOUNCE ──

    @Test
    fun `startIfConsented resumes a consented session without re-emitting grant`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)

        recorder.startIfConsented() // app relaunch with prior consent
        recorder.track(AnalyticsEvent.SCREEN_VIEWED)

        assertEquals(1, transport.startCount)
        assertTrue(transport.isStarted)
        assertTrue(
            "a resumed session must NOT re-emit consent.analytics.granted",
            transport.names().none { it == AnalyticsEvent.CONSENT_ANALYTICS_GRANTED.wire },
        )
        assertEquals(1, transport.names().count { it == AnalyticsEvent.SCREEN_VIEWED.wire })
    }

    // ── REVOKE ──

    @Test
    fun `revoke stops the transport and silences all further sends`() {
        val storage = InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw)
        val store = AnalyticsConsentStore(storage)
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange()
        recorder.track(AnalyticsEvent.SCREEN_VIEWED)
        val sentBeforeRevoke = transport.sent.size

        // Revoke: persist declined, then notify.
        store.revoke()
        recorder.consentDidChange()
        recorder.track(AnalyticsEvent.CHAT_MESSAGE_SENT) // must be dropped

        assertEquals("transport stopped on revoke", 1, transport.stopCount)
        assertFalse(transport.isStarted)
        assertEquals("no sends after revoke", sentBeforeRevoke, transport.sent.size)
        assertTrue(transport.names().none { it == AnalyticsEvent.CHAT_MESSAGE_SENT.wire })
    }

    @Test
    fun `revoke emits no revoked event — silence is the contract`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange()
        val countAtGrant = transport.sent.size

        store.revoke()
        recorder.consentDidChange()

        // No new event of any kind was emitted by the revoke transition.
        assertEquals(countAtGrant, transport.sent.size)
    }

    @Test
    fun `re-grant after revoke announces again exactly once`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        val transport = FakeAnalyticsTransport()
        val recorder = Analytics(store, transport, key, ::superProps)
        recorder.consentDidChange() // grant #1
        store.revoke()
        recorder.consentDidChange()
        store.grant()
        recorder.consentDidChange() // grant #2

        assertEquals(
            "each fresh opt-in announces once",
            2,
            transport.names().count { it == AnalyticsEvent.CONSENT_ANALYTICS_GRANTED.wire },
        )
    }

    // ── STORE STATE MACHINE ──

    @Test
    fun `consent store tri-state and revoke lands in declined never unset`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage(null))
        assertEquals(AnalyticsConsent.UNSET, store.state)
        assertFalse(store.hasDecided)
        assertFalse(store.isGranted)

        store.grant()
        assertEquals(AnalyticsConsent.GRANTED, store.state)
        assertTrue(store.isGranted)
        assertTrue(store.hasDecided)

        store.revoke()
        assertEquals("revoke = declined, never back to unset", AnalyticsConsent.DECLINED, store.state)
        assertFalse(store.isGranted)
        assertTrue("declined still counts as decided — no re-prompt", store.hasDecided)
    }

    @Test
    fun `unknown persisted raw value defaults to unset`() {
        val store = AnalyticsConsentStore(InMemoryConsentStorage("garbage"))
        assertEquals(AnalyticsConsent.UNSET, store.state)
    }
}
