package com.openburnbar

import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.ui.burn.matchingQuotaAccounts
import com.openburnbar.ui.burn.quotaAccountEmail
import com.openburnbar.ui.burn.quotaAccountName
import org.junit.Assert.assertEquals
import org.junit.Test

class QuotaAccountDisplayTest {
    @Test
    fun `matches snapshot to account id and exposes identity email`() {
        val snapshot = ProviderQuotaSnapshot(
            provider = "codex",
            providerId = "codex",
            accountId = "codex_default",
            accountLabel = "Codex"
        )
        val accounts = listOf(
            ProviderAccount(
                id = "codex_default",
                providerId = "codex",
                label = "Work Codex",
                identityHint = "alberto@example.com"
            )
        )

        assertEquals(1, matchingQuotaAccounts(snapshot, accounts).size)
        assertEquals("Work Codex", quotaAccountName(snapshot, accounts))
        assertEquals("alberto@example.com", quotaAccountEmail(snapshot, accounts))
    }

    @Test
    fun `falls back to snapshot account label when account doc is unavailable`() {
        val snapshot = ProviderQuotaSnapshot(
            provider = "codex",
            accountId = "codex_default",
            accountLabel = "alberto@example.com"
        )

        assertEquals("alberto@example.com", quotaAccountName(snapshot, emptyList()))
        assertEquals("alberto@example.com", quotaAccountEmail(snapshot, emptyList()))
    }

    @Test
    fun `falls back to signed in email when provider account has no email hint`() {
        val snapshot = ProviderQuotaSnapshot(
            provider = "cursor",
            providerId = "cursor",
            accountId = "cursor_default",
            accountLabel = "Account"
        )

        assertEquals(
            "alberto@example.com",
            quotaAccountEmail(snapshot, emptyList(), "alberto@example.com")
        )
    }
}
