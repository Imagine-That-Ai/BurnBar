package com.openburnbar

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-AND-03 — whitelist + dynamic-segment validation for inbound `burnbar://` deep links. */
class BurnBarDeepLinkValidatorTest {
    @Test
    fun allowsKnownStaticHosts() {
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "pulse", emptyList()))
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "hermes", emptyList()))
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "dashboard", emptyList()))
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "quickglance", emptyList()))
    }

    @Test
    fun rejectsUnknownHostDefaultDeny() {
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "evil", emptyList()))
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "admin", listOf("wipe")))
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", null, emptyList()))
    }

    @Test
    fun doesNotPoliceForeignSchemes() {
        // A non-burnbar scheme is not ours — pass it through (the platform routes it).
        assertTrue(BurnBarDeepLinkValidator.isAllowed("https", "example.com", listOf("path")))
    }

    @Test
    fun validatesMercuryCallConnectionId() {
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "mercury", listOf("call", "conn-123_ABC.4")))
        // Wrong literal prefix.
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "mercury", listOf("dial", "conn-123")))
        // Illegal charset (space) in the id.
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "mercury", listOf("call", "conn 123")))
        // Missing id.
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "mercury", listOf("call")))
    }

    @Test
    fun validatesPairedMacConnectionId() {
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "paired-mac", emptyList()))
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "paired-mac", listOf("mac-007")))
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "paired-mac", listOf("../../etc")))
    }

    @Test
    fun validatesInsightsSlug() {
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "insights", emptyList()))
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "insights", listOf("weekly_burn-rate")))
        // Path traversal in the slug is rejected.
        assertFalse(BurnBarDeepLinkValidator.isAllowed("burnbar", "insights", listOf("..")))
        assertFalse(BurnBarDeepLinkValidator.isSafeSlug("a/../b"))
    }

    @Test
    fun rejectsOverlongSegments() {
        val huge = "a".repeat(500)
        assertFalse(BurnBarDeepLinkValidator.isSafeConnectionId(huge))
        assertFalse(BurnBarDeepLinkValidator.isSafeSlug(huge))
        assertFalse(BurnBarDeepLinkValidator.isSafeEncodedSegment(huge))
    }

    @Test
    fun agentEncodedSegmentBoundsButAllowsEncodedChars() {
        // The agent {uri} is URL-encoded and registry-checked downstream; only bound length
        // and reject control bytes here.
        assertTrue(BurnBarDeepLinkValidator.isAllowed("burnbar", "agent", listOf("openburnbar%3A%2F%2Fclaude")))
        // A raw control byte (bell, U+0007) is rejected.
        assertFalse(BurnBarDeepLinkValidator.isSafeEncodedSegment("badbell"))
    }
}
