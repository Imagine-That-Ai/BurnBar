package com.openburnbar.ui.inbox

import com.openburnbar.data.inbox.AIInboxSnoozeInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The [InboxDetailCallbacks] bundle forwards each callback unchanged: the
 * detail surface stays ignorant of `AIInboxStore`, so this contract is the
 * only wiring between the sheet and the store.
 */
class InboxDetailCallbacksTest {
    @Test
    fun invokesEachCallbackWithItsPayload() {
        var archived = false
        var snoozedWith: AIInboxSnoozeInterval? = null
        var feedbackWith: String? = "sentinel"
        var routeWith: String? = null

        val callbacks = InboxDetailCallbacks(
            onArchive = { archived = true },
            onSnooze = { snoozedWith = it },
            onFeedback = { feedbackWith = it },
            onOpenRoute = { routeWith = it },
        )

        callbacks.onArchive()
        callbacks.onSnooze(AIInboxSnoozeInterval.TOMORROW)
        callbacks.onFeedback(null)
        callbacks.onOpenRoute("inbox/item-42")

        assertTrue(archived)
        assertEquals(AIInboxSnoozeInterval.TOMORROW, snoozedWith)
        assertEquals(null, feedbackWith)
        assertEquals("inbox/item-42", routeWith)
    }

    @Test
    fun forwardsEverySnoozeIntervalAndFeedbackToken() {
        val snoozes = mutableListOf<AIInboxSnoozeInterval>()
        val feedback = mutableListOf<String?>()
        val callbacks = InboxDetailCallbacks(
            onArchive = {},
            onSnooze = { snoozes.add(it) },
            onFeedback = { feedback.add(it) },
            onOpenRoute = {},
        )

        AIInboxSnoozeInterval.entries.forEach { callbacks.onSnooze(it) }
        callbacks.onFeedback("useful")
        callbacks.onFeedback("not_useful")

        assertEquals(AIInboxSnoozeInterval.entries.toList(), snoozes)
        assertEquals(listOf<String?>("useful", "not_useful"), feedback)
    }
}
