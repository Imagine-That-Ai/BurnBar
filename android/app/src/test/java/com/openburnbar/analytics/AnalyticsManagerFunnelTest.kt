package com.openburnbar.analytics

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Covers the CMO funnel session-start path on [AnalyticsManager]: dark without
 * consent, `app.opened` after grant, `install.started` only on first launch,
 * and `product=burnbar` on super-properties.
 */
class AnalyticsManagerFunnelTest {

    @Before
    fun resetManager() {
        AnalyticsManager.resetForTests()
    }

    @After
    fun clearManager() {
        AnalyticsManager.resetForTests()
    }

    @Test
    fun `session start stays dark when consent is unset`() {
        val transport = FakeAnalyticsTransport()
        val store = AnalyticsConsentStore(InMemoryConsentStorage(null))
        AnalyticsManager.attachForTests(store, transport)

        AnalyticsManager.trackSessionStartIfConsented(isFirstLaunch = true)

        assertEquals(0, transport.startCount)
        assertTrue(transport.sent.isEmpty())
    }

    @Test
    fun `consented first launch emits session start, app opened, and install started`() {
        val transport = FakeAnalyticsTransport()
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        AnalyticsManager.attachForTests(store, transport)

        AnalyticsManager.trackSessionStartIfConsented(isFirstLaunch = true)

        assertEquals(
            listOf(
                AnalyticsEvent.APP_SESSION_STARTED.wire,
                AnalyticsEvent.APP_OPENED.wire,
                AnalyticsEvent.INSTALL_STARTED.wire,
            ),
            transport.names(),
        )
        val opened = transport.sent.single { it.name == AnalyticsEvent.APP_OPENED.wire }
        assertEquals("lifecycle", opened.category)
        assertEquals(AnalyticsValue.Bool(true), opened.properties["is_first_launch"])
        assertEquals(AnalyticsValue.Bool(true), opened.properties["cold_start"])
        assertEquals(AnalyticsValue.Str("burnbar"), opened.properties["product"])
        assertEquals(AnalyticsValue.Str("android"), opened.properties["platform"])
        assertEquals(AnalyticsValue.Str("android"), opened.properties["surface"])
    }

    @Test
    fun `consented relaunch emits app opened but not install started`() {
        val transport = FakeAnalyticsTransport()
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        AnalyticsManager.attachForTests(store, transport)

        AnalyticsManager.trackSessionStartIfConsented(isFirstLaunch = false)

        assertEquals(
            listOf(
                AnalyticsEvent.APP_SESSION_STARTED.wire,
                AnalyticsEvent.APP_OPENED.wire,
            ),
            transport.names(),
        )
        assertTrue(transport.names().none { it == AnalyticsEvent.INSTALL_STARTED.wire })
    }

    @Test
    fun `settings grant emits the session spine once`() {
        val transport = FakeAnalyticsTransport()
        val store = AnalyticsConsentStore(InMemoryConsentStorage(null))
        AnalyticsManager.attachForTests(store, transport)
        AnalyticsManager.rememberLaunchContext(isFirstLaunch = true)

        AnalyticsManager.grant()
        AnalyticsManager.grant()

        assertEquals(1, transport.names().count { it == AnalyticsEvent.APP_OPENED.wire })
        assertEquals(1, transport.names().count { it == AnalyticsEvent.INSTALL_STARTED.wire })
        assertEquals(AnalyticsValue.Str("android"), transport.sent.single { it.name == AnalyticsEvent.APP_OPENED.wire }.properties["surface"])
    }

    @Test
    fun `current session start uses remembered first-launch flag`() {
        val transport = FakeAnalyticsTransport()
        val store = AnalyticsConsentStore(InMemoryConsentStorage(AnalyticsConsent.GRANTED.raw))
        AnalyticsManager.attachForTests(store, transport)
        AnalyticsManager.rememberLaunchContext(isFirstLaunch = true)

        AnalyticsManager.trackCurrentSessionStartIfConsented()

        assertTrue(transport.names().contains(AnalyticsEvent.INSTALL_STARTED.wire))
        assertTrue(transport.names().contains(AnalyticsEvent.APP_OPENED.wire))
    }
}
