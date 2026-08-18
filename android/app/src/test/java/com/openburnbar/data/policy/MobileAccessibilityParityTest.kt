package com.openburnbar.data.policy

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileAccessibilityParityTest {
    // Walks every fixture vector:
    // a11y.hero-burn.currency, a11y.hero-burn.tokens, a11y.hero-burn.live-rate,
    // a11y.quota-ring, a11y.stop-streaming, a11y.stop-idle,
    // a11y.inbox-row-unread, a11y.inbox-row-read, a11y.chart.live-cost,
    // a11y.icon-only.stop, a11y.loading.pulse, a11y.error.pulse,
    // a11y.live-stream.mercury
    @Test
    fun walksEveryA11yContractVector() {
        val vectors = a11yVectors()
        assertTrue(vectors.isNotEmpty())
        for (vector in vectors) {
            val expected = vector.getJSONObject("expected").getString("label")
            when (vector.getString("kind")) {
                "heroBurn" -> assertHero(vector)
                "quotaRing" -> assertEquals(
                    expected,
                    MobileAccessibilityLabelPolicy.quotaRing(
                        label = vector.getString("label"),
                        percentRemaining = vector.getInt("percentRemaining"),
                    ),
                )
                "stopButton" -> assertStop(vector)
                "inboxRow" -> assertInbox(vector)
                "chart" -> assertEquals(
                    expected,
                    MobileAccessibilityLabelPolicy.chart(vector.getString("label"), vector.getString("summary")),
                )
                "iconOnly" -> assertEquals(
                    expected,
                    MobileAccessibilityLabelPolicy.iconOnly(vector.getString("action")),
                )
                "loading" -> assertEquals(
                    expected,
                    MobileAccessibilityLabelPolicy.loading(vector.getString("surface")),
                )
                "error" -> assertEquals(
                    expected,
                    MobileAccessibilityLabelPolicy.error(vector.getString("surface")),
                )
                "liveStream" -> assertEquals(
                    expected,
                    MobileAccessibilityLabelPolicy.liveStream(vector.getString("surface")),
                )
                else -> error("unknown a11y vector ${vector.getString("id")}")
            }
        }
    }

    @Test
    fun missingLabelFailsTheVectorCheck() {
        val golden = a11yVectors().first { it.getString("id") == "a11y.hero-burn.currency" }
            .getJSONObject("expected").getString("label")
        val empty = MobileAccessibilityLabelPolicy.heroBurn("currency", "", null)
        assertTrue(empty.startsWith("Hero burn, currency"))
        assertTrue(empty.endsWith(", "))
        assertNotEquals(golden, empty)
    }

    private fun assertHero(vector: JSONObject) {
        val liveRate = if (vector.isNull("liveRate")) null else vector.getString("liveRate")
        assertEquals(
            vector.getJSONObject("expected").getString("label"),
            MobileAccessibilityLabelPolicy.heroBurn(
                displayMode = vector.getString("displayMode"),
                heroText = vector.getString("heroText"),
                liveRate = liveRate,
            ),
        )
    }

    private fun assertStop(vector: JSONObject) {
        assertEquals(
            vector.getJSONObject("expected").getString("label"),
            MobileAccessibilityLabelPolicy.stopButton(vector.getBoolean("isStreaming")),
        )
    }

    private fun assertInbox(vector: JSONObject) {
        val priority = if (vector.isNull("priorityLabel")) null else vector.getString("priorityLabel")
        assertEquals(
            vector.getJSONObject("expected").getString("label"),
            MobileAccessibilityLabelPolicy.inboxRow(
                unread = vector.getBoolean("unread"),
                kindLabel = vector.getString("kindLabel"),
                priorityLabel = priority,
                title = vector.getString("title"),
            ),
        )
    }

    private fun a11yVectors(): List<JSONObject> {
        val fixture = JSONObject(locate("docs/mobile-parity/fixtures/product/a11y-contract-vectors.json").readText())
        val vectors = fixture.getJSONArray("vectors")
        return (0 until vectors.length()).map { vectors.getJSONObject(it) }
    }

    private fun locate(relative: String): File {
        val cwd = System.getProperty("user.dir").orEmpty().ifBlank { "." }
        val anchors = listOf(File(cwd), File(cwd, "../.."), File(cwd, ".."))
        for (anchor in anchors) {
            var dir: File? = anchor.absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        error("could not locate $relative")
    }
}
