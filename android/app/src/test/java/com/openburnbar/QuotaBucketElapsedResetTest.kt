
package com.openburnbar

import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingFractionAsOf
import com.openburnbar.data.models.effectiveResetsAt
import com.openburnbar.data.models.elapsedWindowReset
import com.openburnbar.data.models.progressFractionAsOf
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for "Codex quota never resets after the 5h clock rolls over."
 *
 * The reset countdown advanced past a stale `resetsAt` while the usage bar
 * stayed pinned at the old window's value. The bar now reconciles to the same
 * gate as the countdown: an elapsed window reads full remaining / empty
 * progress with the reset advanced to the next boundary.
 *
 * The buckets here use the exact shape the Mac sync writes — `name` is the
 * bucket key, `window` is the `ProviderQuotaWindowKind` raw value, the human
 * label lives in `meta.label`, and the reset arrives as the legacy
 * `meta["resetsAt"]` ISO string — so the inference must key off `rollingHours`,
 * not a digit/word marker.
 */
class QuotaBucketElapsedResetTest {
    private val now: Instant = Instant.parse("2026-06-05T00:00:00Z")
    private val pastReset = "2026-06-02T00:00:00Z" // 3 days before `now`
    private val futureReset = "2026-06-05T02:00:00Z" // 2 hours after `now`

    private fun codexBucket(window: String, resetsAtIso: String, usedPercent: String, name: String = "codex-primary", label: String = "5-hour window") =
        QuotaBucket(
            name = name,
            used = usedPercent.toDouble(),
            limit = 100.0,
            remaining = 100.0 - usedPercent.toDouble(),
            window = window,
            meta = mapOf("unit" to "percent", "usedPercent" to usedPercent, "label" to label, "resetsAt" to resetsAtIso),
        )

    @Test
    fun `elapsed codex 5h window reads full remaining and empty progress`() {
        val bucket = codexBucket(window = "rollingHours", resetsAtIso = pastReset, usedPercent = "100")

        val elapsedReset = requireNotNull(bucket.elapsedWindowReset(now)) {
            "rollingHours window must be recognised as rolled over"
        }
        assertTrue("the rolled-over reset is advanced to a future boundary", elapsedReset.isAfter(now))
        val remainingFraction = requireNotNull(bucket.displayRemainingFractionAsOf(now))
        assertEquals(1.0, remainingFraction, 0.0001)
        assertEquals(0.0, bucket.progressFractionAsOf(now), 0.0001)
        // effectiveResetsAt is the raw resolved value (contract preserved); only
        // the reset-detection / countdown advance past it.
        assertTrue("raw effectiveResetsAt stays in the past", requireNotNull(bucket.effectiveResetsAt).isBefore(now))
    }

    @Test
    fun `elapsed codex weekly window advances seven days not one`() {
        val tenDaysAgo = "2026-05-26T00:00:00Z" // 10 days before `now`
        val bucket = codexBucket(
            window = "rollingDays",
            resetsAtIso = tenDaysAgo,
            usedPercent = "90",
            name = "codex-secondary",
            label = "7-day window",
        )

        assertEquals(1.0, requireNotNull(bucket.displayRemainingFractionAsOf(now)), 0.0001)
        // 10 days elapsed against a 7-day window lands ~4 days out; a wrong
        // 1-day advance would land ~1 day out.
        val elapsedReset = requireNotNull(bucket.elapsedWindowReset(now))
        assertTrue(
            "weekly window must advance by 7 days, not 1",
            elapsedReset.isAfter(now.plusSeconds(2 * 24 * 3600)),
        )
    }

    @Test
    fun `active codex 5h window keeps its reported usage`() {
        val bucket = codexBucket(window = "rollingHours", resetsAtIso = futureReset, usedPercent = "40")

        assertNull(bucket.elapsedWindowReset(now))
        assertEquals(0.60, requireNotNull(bucket.displayRemainingFractionAsOf(now)), 0.0001)
        assertEquals(0.40, bucket.progressFractionAsOf(now), 0.0001)
    }

    @Test
    fun `unknown window is never auto-reset`() {
        // No inferable period: leave the last-known usage alone.
        val bucket = QuotaBucket(
            name = "custom",
            used = 80.0,
            limit = 100.0,
            remaining = 20.0,
            window = "session",
            meta = mapOf("unit" to "percent", "usedPercent" to "80", "resetsAt" to pastReset),
        )

        assertNull(bucket.elapsedWindowReset(now))
        assertEquals(0.20, requireNotNull(bucket.displayRemainingFractionAsOf(now)), 0.0001)
    }
}
