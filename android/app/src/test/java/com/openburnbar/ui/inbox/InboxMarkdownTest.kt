package com.openburnbar.ui.inbox

import com.openburnbar.data.inbox.AIInboxItem
import com.openburnbar.data.inbox.AIInboxItemKind
import com.openburnbar.data.inbox.AIInboxItemPayload
import com.openburnbar.data.inbox.AIInboxItemState
import com.openburnbar.data.inbox.AIInboxItemUserState
import com.openburnbar.data.inbox.AIInboxPriority
import com.openburnbar.data.inbox.AIInboxRow
import com.openburnbar.data.inbox.AIInboxVerdict
import com.openburnbar.data.inbox.AIInboxVerification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure presentation logic behind the inbox: the inline-markdown parse
 * that stands in for the Mac's `.inlineOnlyPreservingWhitespace` rendering, the
 * metric humanizer, the relative-time vocabulary, and the provenance sentence.
 *
 * The provenance line in particular is a product promise, not decoration: the
 * user must always be able to tell whether an item came from arithmetic or from
 * a model, and whether anything checked it.
 */
class InboxMarkdownTest {
    private val now = 1_785_857_400_000L

    // ── Markdown ──

    @Test
    fun `plain text becomes one unstyled run`() {
        val spans = InboxMarkdown.parse("The iOS lane is failing.")

        assertEquals(1, spans.size)
        assertEquals("The iOS lane is failing.", spans.single().text)
        assertTrue(spans.single().let { !it.bold && !it.italic && !it.code && it.linkURL == null })
    }

    @Test
    fun `bold italic and inline code are recognised`() {
        val spans = InboxMarkdown.parse("a **bold** b *slant* c `code` d")

        assertEquals("bold", spans.first { it.bold }.text)
        assertEquals("slant", spans.first { it.italic }.text)
        assertEquals("code", spans.first { it.code }.text)
        // Every literal character survives, including the spaces around markers.
        assertEquals("a bold b slant c code d", spans.joinToString("") { it.text })
    }

    @Test
    fun `links keep their label and url`() {
        val spans = InboxMarkdown.parse("see [the run](https://example.com/runs/42) for detail")

        val link = spans.single { it.linkURL != null }
        assertEquals("the run", link.text)
        assertEquals("https://example.com/runs/42", link.linkURL)
        assertEquals("see the run for detail", spans.joinToString("") { it.text })
    }

    @Test
    fun `newlines are preserved so the Mac's line breaks survive`() {
        val spans = InboxMarkdown.parse("first line\n\nsecond **line**")

        assertEquals("first line\n\nsecond line", spans.joinToString("") { it.text })
    }

    @Test
    fun `an unterminated delimiter stays literal instead of eating the body`() {
        // A stray asterisk in a model-written brief must not blank the item.
        assertEquals("cost is up 40% *", InboxMarkdown.parse("cost is up 40% *").joinToString("") { it.text })
        assertEquals("unclosed **bold", InboxMarkdown.parse("unclosed **bold").joinToString("") { it.text })
        assertEquals("a `tick", InboxMarkdown.parse("a `tick").joinToString("") { it.text })
        assertEquals("[label](", InboxMarkdown.parse("[label](").joinToString("") { it.text })
    }

    @Test
    fun `italics do not reach across a paragraph break`() {
        val spans = InboxMarkdown.parse("rate *rose\n\nthen fell* again")

        assertTrue(spans.none { it.italic })
        assertEquals("rate *rose\n\nthen fell* again", spans.joinToString("") { it.text })
    }

    @Test
    fun `a backslash escapes the delimiter that follows it`() {
        val spans = InboxMarkdown.parse("""literal \*\*stars\*\* here""")

        assertTrue(spans.none { it.bold })
        assertEquals("literal **stars** here", spans.joinToString("") { it.text })
    }

    @Test
    fun `an empty body parses to nothing`() {
        assertTrue(InboxMarkdown.parse("").isEmpty())
    }

    // ── Metrics ──

    @Test
    fun `metric keys are humanized and suffixed values formatted`() {
        val display =
            inboxDisplayMetrics(
                mapOf(
                    "wasted_minutes" to "312.4",
                    "failure_rate" to "0.85",
                    "spend_usd" to "1.5",
                    "run_count" to "20",
                    "note" to "not a number",
                ),
            )

        val byLabel = display.toMap()
        assertEquals("312m", byLabel["Wasted minutes"])
        assertEquals("85%", byLabel["Failure rate"])
        assertEquals("$1.500", byLabel["Spend usd"])
        // A key with no recognised suffix keeps its raw value verbatim.
        assertEquals("20", byLabel["Run count"])
        assertEquals("not a number", byLabel["Note"])
    }

    @Test
    fun `metric chip order is stable regardless of map iteration order`() {
        val a = inboxDisplayMetrics(mapOf("z_count" to "1", "a_count" to "2")).map { it.first }
        val b = inboxDisplayMetrics(mapOf("a_count" to "2", "z_count" to "1")).map { it.first }

        assertEquals(a, b)
        assertEquals(listOf("A count", "Z count"), a)
    }

    // ── Relative time ──

    @Test
    fun `relative time degrades gracefully from minutes to months`() {
        assertEquals("just now", inboxRelativeTime(now, now))
        assertEquals("just now", inboxRelativeTime(now + 5_000, now))
        assertEquals("5m ago", inboxRelativeTime(now - 5 * 60_000, now))
        assertEquals("3h ago", inboxRelativeTime(now - 3 * 3_600_000L, now))
        assertEquals("2d ago", inboxRelativeTime(now - 2 * 86_400_000L, now))
        assertEquals("1 week ago", inboxRelativeTime(now - 8 * 86_400_000L, now))
        assertEquals("3 weeks ago", inboxRelativeTime(now - 22 * 86_400_000L, now))
        assertEquals("2 months ago", inboxRelativeTime(now - 70 * 86_400_000L, now))
    }

    // ── Row subtitle ──

    @Test
    fun `the row subtitle names the claim the project and the recency`() {
        val row =
            AIInboxRow(
                item = item(occurrenceCount = 4),
                userState = null,
            )

        val subtitle = inboxRowSubtitle(row, now)

        assertTrue(subtitle.startsWith("CI waste · BurnBar · "))
        assertTrue(subtitle.contains("seen 4×"))
    }

    @Test
    fun `the row subtitle discloses resolved and snoozed states`() {
        val resolved = AIInboxRow(item = item(state = AIInboxItemState.RESOLVED))
        val snoozed =
            AIInboxRow(
                item = item(),
                userState = AIInboxItemUserState(id = "i", snoozedUntilEpoch = now + 60_000, updatedAtEpoch = now),
            )

        assertTrue(inboxRowSubtitle(resolved, now).endsWith("resolved"))
        assertTrue(inboxRowSubtitle(snoozed, now).endsWith("snoozed"))
    }

    @Test
    fun `the accessibility label leads with unread and urgency`() {
        val unread = AIInboxRow(item = item(priority = AIInboxPriority.P1))

        assertTrue(inboxRowAccessibilityLabel(unread).startsWith("Unread, "))
        assertTrue(inboxRowAccessibilityLabel(unread).contains("Urgent"))
    }

    @Test
    fun `inbox row accessibility matches shared a11y vectors`() {
        val vectors = a11yVectors().filter { it.getString("id").startsWith("a11y.inbox-row") }
        assertTrue(vectors.isNotEmpty())
        for (vector in vectors) {
            val expected = vector.getJSONObject("expected").getString("label")
            val unread = vector.getBoolean("unread")
            val kind = kindFromLabel(vector.getString("kindLabel"))
            val priority = if (vector.isNull("priorityLabel")) AIInboxPriority.P3 else AIInboxPriority.P1
            val row =
                AIInboxRow(
                    item = item(
                        priority = priority,
                        kind = kind,
                        title = vector.getString("title"),
                    ),
                    userState =
                    if (unread) {
                        null
                    } else {
                        AIInboxItemUserState(id = "i", readAtEpoch = now, updatedAtEpoch = now)
                    },
                )
            assertEquals(vector.getString("id"), expected, inboxRowAccessibilityLabel(row))
        }
    }

    private fun kindFromLabel(label: String): AIInboxItemKind = AIInboxItemKind.entries.first { InboxPresentation.kindLabel(it) == label }

    private fun a11yVectors(): List<org.json.JSONObject> {
        val file = locateA11y("docs/mobile-parity/fixtures/product/a11y-contract-vectors.json")
        val root = org.json.JSONObject(file.readText())
        val array = root.optJSONArray("vectors") ?: root.optJSONArray("cases")
        if (array != null) {
            return (0 until array.length()).map { array.getJSONObject(it) }
        }
        return emptyList()
    }

    private fun locateA11y(relative: String): java.io.File {
        val cwd = System.getProperty("user.dir").orEmpty().ifBlank { "." }
        val anchors = listOf(java.io.File(cwd), java.io.File(cwd, "../.."), java.io.File(cwd, ".."))
        for (anchor in anchors) {
            var dir: java.io.File? = anchor.absoluteFile
            while (dir != null) {
                val candidate = java.io.File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        error("could not locate $relative")
    }

    // ── Provenance ──

    @Test
    fun `rules-only items say plainly that no model was involved`() {
        val text = inboxProvenanceText(item(provenance = "local-rules"))

        assertEquals("Measured directly on your Mac — no model was involved.", text)
    }

    @Test
    fun `model-written items name the models in friendly form`() {
        val text = inboxProvenanceText(item(provenance = "deepseek:deepseek-v4-flash+openai:gpt-5.6-luna"))

        // Provider prefixes are stripped: the user cares which model wrote it,
        // not which vendor endpoint it came from.
        assertEquals("Written by deepseek-v4-flash and gpt-5.6-luna.", text)
    }

    @Test
    fun `each verification verdict gets its own honest sentence`() {
        fun textFor(verdict: AIInboxVerdict, reason: String? = null) =
            inboxProvenanceText(item(provenance = "openai:gpt-5.6-luna", verdict = verdict, reason = reason))

        assertTrue(textFor(AIInboxVerdict.CONFIRMED).endsWith("A second model checked this and agreed."))
        assertTrue(textFor(AIInboxVerdict.UNCLEAR).endsWith("could not confirm it, so it is ranked lower."))
        assertTrue(textFor(AIInboxVerdict.UNVERIFIED).endsWith("It was not independently checked."))
        assertTrue(textFor(AIInboxVerdict.DETERMINISTIC, "Recounted from the index.").endsWith("Recounted from the index."))
        // A refuted item should not have shipped; if one does, the footer says
        // nothing extra rather than inventing a reassurance.
        assertEquals("Written by gpt-5.6-luna.", textFor(AIInboxVerdict.REFUTED))
    }

    @Test
    fun `an unqualified provenance token is shown as-is`() {
        assertEquals("Written by some-model.", inboxProvenanceText(item(provenance = "some-model")))
    }

    private fun item(
        priority: AIInboxPriority = AIInboxPriority.P2,
        state: AIInboxItemState = AIInboxItemState.NEW,
        occurrenceCount: Int = 1,
        provenance: String = "local-rules",
        verdict: AIInboxVerdict? = null,
        reason: String? = null,
        kind: AIInboxItemKind = AIInboxItemKind.CI_WASTE,
        title: String = "CI is burning cycles",
    ) = AIInboxItem(
        id = "i",
        fingerprint = "fp",
        kind = kind,
        priority = priority,
        state = state,
        occurrenceCount = occurrenceCount,
        firstSeenAtEpoch = now - 86_400_000,
        lastSeenAtEpoch = now - 3_600_000,
        modelProvenance = provenance,
        title = title,
        projectName = "BurnBar",
        payload =
        AIInboxItemPayload(
            verification = verdict?.let { AIInboxVerification(verdict = it, reason = reason, checkedAtEpoch = now) },
        ),
    )
}
