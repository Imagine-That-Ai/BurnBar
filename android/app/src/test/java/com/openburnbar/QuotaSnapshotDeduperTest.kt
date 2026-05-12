package com.openburnbar

import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.deduplicatedByProviderAccount
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QuotaSnapshotDeduperTest {
    @Test
    fun `same provider account snapshots collapse into one account card`() {
        val snapshots = listOf(
            ProviderQuotaSnapshot(
                id = "claude_account_weekly",
                provider = "claude_code",
                providerId = "claude_code",
                accountId = "acct_1",
                accountLabel = "Claude Code",
                sourceId = "weekly",
                updatedAt = "2026-05-11T10:00:00Z",
                buckets = listOf(
                    QuotaBucket(name = "weekly", used = 31.0, limit = 100.0, remaining = 69.0, window = "week")
                )
            ),
            ProviderQuotaSnapshot(
                id = "claude_account_requests",
                provider = "claude_code",
                providerId = "claude_code",
                accountId = "acct_1",
                accountLabel = "Claude Code",
                sourceId = "requests",
                updatedAt = "2026-05-11T10:01:00Z",
                buckets = listOf(
                    QuotaBucket(name = "requests", used = 26.0, limit = 100.0, remaining = 74.0, window = "week")
                )
            )
        )

        val deduped = snapshots.deduplicatedByProviderAccount()

        assertEquals(1, deduped.size)
        assertEquals("acct_1", deduped.single().accountId)
        assertEquals("Claude Code", deduped.single().accountLabel)
        assertEquals(2, deduped.single().buckets.size)
        assertTrue(deduped.single().sourceId.contains("weekly"))
        assertTrue(deduped.single().sourceId.contains("requests"))
    }

    @Test
    fun `different account ids stay separate`() {
        val snapshots = listOf(
            ProviderQuotaSnapshot(provider = "claude_code", providerId = "claude_code", accountId = "acct_1"),
            ProviderQuotaSnapshot(provider = "claude_code", providerId = "claude_code", accountId = "acct_2")
        )

        assertEquals(2, snapshots.deduplicatedByProviderAccount().size)
    }
}
