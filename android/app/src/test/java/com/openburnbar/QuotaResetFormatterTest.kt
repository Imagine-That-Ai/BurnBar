package com.openburnbar

import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.effectiveResetsAt
import com.openburnbar.util.QuotaResetFormatter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale

class QuotaResetFormatterTest {

    private val now = Instant.parse("2026-05-12T12:00:00Z")
    private val zoneUTC = ZoneId.of("UTC")
    private val englishUS = Locale.US

    @Test
    fun `relative half formats short future durations as "in Xh Ym"`() {
        val target = now.plusSeconds(2 * 3600 + 14 * 60)
        val parts = QuotaResetFormatter.format(target, now, zoneUTC, englishUS)
        assertEquals("in 2h 14m", parts.relative)
    }

    @Test
    fun `relative half formats multi-day futures with day-and-hour precision`() {
        val target = now.plusSeconds(6 * 24 * 3600 + 3 * 3600)
        val parts = QuotaResetFormatter.format(target, now, zoneUTC, englishUS)
        assertEquals("in 6d 3h", parts.relative)
    }

    @Test
    fun `relative half marks past targets with "ago"`() {
        val target = now.minusSeconds(45 * 60)
        val parts = QuotaResetFormatter.format(target, now, zoneUTC, englishUS)
        assertEquals("45m ago", parts.relative)
    }

    @Test
    fun `absolute half renders localized medium date plus short time`() {
        // Pick a deterministic moment so the localized formatter has no
        // wiggle room across hosts.
        val target = ZonedDateTime.of(2026, 5, 12, 15, 35, 0, 0, zoneUTC).toInstant()
        val parts = QuotaResetFormatter.format(target, now, zoneUTC, englishUS)
        assertTrue(
            "absolute output should mention month + time, got: ${parts.absolute}",
            parts.absolute.contains("May") && parts.absolute.contains("3:35")
        )
    }

    @Test
    fun `combinedLabel joins the two halves with a centre dot`() {
        val target = now.plusSeconds(60 * 60)
        val label = QuotaResetFormatter.combinedLabel(target, now, zoneUTC, englishUS)
        assertNotNull(label)
        assertTrue("expected centre-dot separator in: $label", label!!.contains(" · "))
    }

    @Test
    fun `combinedLabel returns null when input is null`() {
        assertNull(QuotaResetFormatter.combinedLabel(null))
    }

    @Test
    fun `effectiveResetsAt prefers top-level Timestamp over legacy meta string`() {
        val ts = com.google.firebase.Timestamp(now.epochSecond, 0)
        val bucket = QuotaBucket(
            name = "5h",
            used = 50.0, limit = 100.0, remaining = 50.0,
            window = "rollingHours",
            resetsAt = ts,
            meta = mapOf("resetsAt" to "2026-01-01T00:00:00Z") // far older
        )
        val result = bucket.effectiveResetsAt
        assertEquals(now, result)
    }

    @Test
    fun `effectiveResetsAt falls back to legacy meta string`() {
        val iso = "2026-05-12T12:00:00Z"
        val bucket = QuotaBucket(
            name = "weekly",
            used = 1.0, limit = 5.0, remaining = 4.0,
            window = "weekly",
            resetsAt = null,
            meta = mapOf("resetsAt" to iso)
        )
        assertEquals(Instant.parse(iso), bucket.effectiveResetsAt)
    }

    @Test
    fun `effectiveResetsAt is null when neither field is present`() {
        val bucket = QuotaBucket(
            name = "lifetime",
            used = 0.0, limit = -1.0, remaining = -1.0
        )
        assertNull(bucket.effectiveResetsAt)
    }
}
