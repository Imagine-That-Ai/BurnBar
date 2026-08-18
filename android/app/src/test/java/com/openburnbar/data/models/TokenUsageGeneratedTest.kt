package com.openburnbar.data.models

import com.openburnbar.data.models.generated.FirestoreUsageEventDoc
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TokenUsageGeneratedTest {
    @Test
    fun tokenUsageFromGeneratedRejectsBlankProviderOrRecordedAt() {
        assertNull(tokenUsageFromGenerated(FirestoreUsageEventDoc(), "evt-1"))
        assertNull(
            tokenUsageFromGenerated(
                FirestoreUsageEventDoc(provider = "  ", recordedAt = "2026-01-01T00:00:00Z"),
                "evt-1",
            ),
        )
        assertNull(
            tokenUsageFromGenerated(
                FirestoreUsageEventDoc(provider = "anthropic", recordedAt = " "),
                "evt-1",
            ),
        )
    }

    @Test
    fun tokenUsageFromGeneratedMapsDocFieldsAndDefaultsMissingCounts() {
        val usage =
            tokenUsageFromGenerated(
                FirestoreUsageEventDoc(
                    provider = " anthropic ",
                    providerId = "claude",
                    providerAccountId = "acct-1",
                    model = "opus",
                    inputTokens = 11,
                    outputTokens = 7,
                    recordedAt = " 2026-01-01T00:00:00Z ",
                    eventKind = "usage",
                    idempotencyKey = "idem-1",
                ),
                "evt-1",
            )

        requireNotNull(usage)
        assertEquals("evt-1", usage.id)
        assertEquals("anthropic", usage.provider)
        assertEquals("claude", usage.providerId)
        assertEquals("acct-1", usage.providerAccountId)
        assertEquals("opus", usage.model)
        assertEquals(11, usage.inputTokens)
        assertEquals(7, usage.outputTokens)
        assertEquals(0, usage.totalTokens)
        assertEquals(0.0, usage.costUSD, 0.0)
        assertEquals("2026-01-01T00:00:00Z", usage.recordedAt)
        assertEquals("usage", usage.eventKind)
        assertEquals("idem-1", usage.idempotencyKey)
    }
}
