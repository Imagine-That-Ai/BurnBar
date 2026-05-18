package com.openburnbar.data.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The empty-response rescue table: same 7 cases the iOS suite exercises.
 *
 * 1. `normal` (refusal blank, reasoning blank, no finish reason path
 *    other than `length|content_filter|tool_calls|empty`).
 * 2. `refusal` — refusal string trumps everything.
 * 3. `reasoning fallback` — refusal blank but reasoning channel non-empty.
 * 4. `length cap` — finish reason `length`.
 * 5. `content filter` — finish reason `content_filter`.
 * 6. `tool call no follow up` — finish reason `tool_calls`.
 * 7. `empty` — finish reason missing / unknown.
 */
class HermesChatMessageOutcomeTest {

    @Test
    fun normal_outcome_label_and_retry_semantics() {
        assertEquals(null, HermesChatMessageOutcome.NORMAL.label)
        assertFalse(HermesChatMessageOutcome.NORMAL.supportsRetry)
        assertEquals(null, HermesChatMessageOutcome.NORMAL.iconName)
    }

    @Test
    fun refusal_string_promotes_to_refusal_outcome() {
        val rescue = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = "  I can't help with that.  ",
            reasoning = "thinking-only",
            finishReason = "length",
        )
        assertEquals(HermesChatMessageOutcome.REFUSAL, rescue.outcome)
        assertEquals("I can't help with that.", rescue.text)
        assertFalse(rescue.isError)
        assertFalse(rescue.outcome.supportsRetry)
    }

    @Test
    fun reasoning_only_promotes_to_reasoning_fallback() {
        val rescue = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = "",
            reasoning = "  Step 1: …  ",
            finishReason = "length",
        )
        assertEquals(HermesChatMessageOutcome.REASONING_FALLBACK, rescue.outcome)
        assertEquals("Step 1: …", rescue.text)
        assertFalse(rescue.isError)
        assertFalse(rescue.outcome.supportsRetry)
    }

    @Test
    fun length_finish_reason_promotes_to_length_cap() {
        val rescue = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = "",
            reasoning = "",
            finishReason = "length",
        )
        assertEquals(HermesChatMessageOutcome.LENGTH_CAP, rescue.outcome)
        assertTrue(rescue.isError)
        assertTrue(rescue.outcome.supportsRetry)
        assertEquals("Reply truncated", HermesChatMessageOutcome.LENGTH_CAP.label)
    }

    @Test
    fun content_filter_promotes_to_content_filter() {
        val rescue = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = "",
            reasoning = "",
            finishReason = "content_filter",
        )
        assertEquals(HermesChatMessageOutcome.CONTENT_FILTER, rescue.outcome)
        assertTrue(rescue.isError)
        assertTrue(rescue.outcome.supportsRetry)
        assertEquals("Filtered", HermesChatMessageOutcome.CONTENT_FILTER.label)
    }

    @Test
    fun tool_calls_promotes_to_tool_call_no_follow_up() {
        val rescue = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = "",
            reasoning = "",
            finishReason = "tool_calls",
        )
        assertEquals(HermesChatMessageOutcome.TOOL_CALL_NO_FOLLOW_UP, rescue.outcome)
        assertTrue(rescue.isError)
        assertTrue(rescue.outcome.supportsRetry)
    }

    @Test
    fun unknown_finish_reason_promotes_to_empty() {
        val rescue = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = "",
            reasoning = "",
            finishReason = null,
        )
        assertEquals(HermesChatMessageOutcome.EMPTY, rescue.outcome)
        assertTrue(rescue.isError)
        assertTrue(rescue.outcome.supportsRetry)
        assertEquals("No reply", HermesChatMessageOutcome.EMPTY.label)
    }
}
