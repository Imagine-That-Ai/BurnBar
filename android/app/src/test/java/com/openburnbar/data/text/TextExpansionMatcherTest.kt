package com.openburnbar.data.text

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class TextExpansionMatcherTest {
    @Test
    fun normalizesAndValidatesTriggers() {
        assertEquals("confident", TextExpansionTrigger.canonicalName("&&Confident"))
        assertNull(TextExpansionTrigger.validationError("follow-up_2"))
        assertNotNull(TextExpansionTrigger.validationError("with space"))
        assertNotNull(TextExpansionTrigger.validationError("bad$"))
    }

    @Test
    fun staticExpansionPreservesBoundary() {
        val snippet =
            TextExpansionSnippet(
                id = "1",
                title = "Confident",
                trigger = "confident",
                body = "I'm confident this is the right next step.",
            )

        val result =
            TextExpansionMatcher.expandStaticIfAvailable(
                text = "Send &&confident ",
                snippets = listOf(snippet),
                surface = TextExpansionSurface.IN_APP_THREAD,
            )

        assertEquals("Send I'm confident this is the right next step. ", result?.text)
        assertEquals("&&confident", result?.match?.token)
        assertEquals(' ', result?.match?.boundary)
    }

    @Test
    fun punctuationIsBoundary() {
        val snippet =
            TextExpansionSnippet(
                id = "1",
                title = "Thanks",
                trigger = "thanks",
                body = "Thank you",
            )

        val result =
            TextExpansionMatcher.expandStaticIfAvailable(
                text = "Send &&thanks.",
                snippets = listOf(snippet),
                surface = TextExpansionSurface.IN_APP_THREAD,
            )

        assertEquals("Send Thank you.", result?.text)
    }

    @Test
    fun prefixCollisionWaitsForBoundary() {
        val snippets =
            listOf(
                TextExpansionSnippet(id = "1", title = "Pro", trigger = "pro", body = "professional"),
                TextExpansionSnippet(id = "2", title = "Proposal", trigger = "proposal", body = "proposal draft"),
            )

        assertNull(
            TextExpansionMatcher.expandStaticIfAvailable(
                text = "&&pro",
                snippets = snippets,
                surface = TextExpansionSurface.IN_APP_THREAD,
            ),
        )
        assertEquals(
            "professional ",
            TextExpansionMatcher.expandStaticIfAvailable(
                text = "&&pro ",
                snippets = snippets,
                surface = TextExpansionSurface.IN_APP_THREAD,
            )?.text,
        )
    }

    @Test
    fun llmSnippetReturnsPreviewMatch() {
        val snippet =
            TextExpansionSnippet(
                id = "1",
                title = "Contextual",
                trigger = "ctx",
                body = "Make this fit.",
                mode = TextExpansionMode.LLM_REWRITE,
            )

        val match =
            TextExpansionMatcher.match(
                text = "Please &&ctx ",
                snippets = listOf(snippet),
                surface = TextExpansionSurface.IN_APP_THREAD,
            )

        assertEquals(true, match?.requiresPreview)
        assertNull(
            TextExpansionMatcher.expandStaticIfAvailable(
                text = "Please &&ctx ",
                snippets = listOf(snippet),
                surface = TextExpansionSurface.IN_APP_THREAD,
            ),
        )
    }
}
