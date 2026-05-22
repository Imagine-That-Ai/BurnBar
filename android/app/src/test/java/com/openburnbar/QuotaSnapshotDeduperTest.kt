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

    @Test
    fun `provider level stale aggregate does not shadow account snapshots`() {
        val snapshots = listOf(
            ProviderQuotaSnapshot(
                id = "claude_provider_rollup",
                provider = "claude_code",
                providerId = "claude_code",
                updatedAt = "2026-05-11T10:02:00Z",
                buckets = listOf(
                    QuotaBucket(name = "five-hour", used = 100.0, limit = 100.0, remaining = 0.0, window = "rollingHours")
                )
            ),
            ProviderQuotaSnapshot(
                id = "claude_account_fresh",
                provider = "claude_code",
                providerId = "claude_code",
                accountId = "acct_1",
                accountLabel = "Claude Work",
                updatedAt = "2026-05-11T10:00:00Z",
                buckets = listOf(
                    QuotaBucket(name = "five-hour", used = 62.0, limit = 100.0, remaining = 38.0, window = "rollingHours")
                )
            )
        )

        val deduped = snapshots.deduplicatedByProviderAccount()

        assertEquals(1, deduped.size)
        assertEquals("claude_account_fresh", deduped.single().id)
        assertEquals("acct_1", deduped.single().accountId)
    }
}
