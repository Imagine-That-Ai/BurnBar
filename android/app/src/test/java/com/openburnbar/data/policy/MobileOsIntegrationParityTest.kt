package com.openburnbar.data.policy

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileOsIntegrationParityTest {
    // Walks every fixture vector:
    // os.notification.denied-not-delivered, os.notification.granted-may-deliver,
    // os.push.agent-reply-route, os.push.inbox-route, os.push.quota-route,
    // os.push.mercury-call-route, os.push.mission-route, os.push.unknown-type-no-route,
    // os.push.omit-uid-expiry-no-navigate, os.push.evil-https-deep-link-ignored,
    // os.push.navigate-happy-path, os.push.stale-expired-no-navigate,
    // os.push.account-mismatch-no-navigate, os.push.duplicate-tap-idempotent,
    // os.deeplink.cold-inbox, os.deeplink.warm-assistants,
    // os.deeplink.mixed-case-inbox-id, os.deeplink.encoded-thread-id,
    // os.widget.no-raw-uid, os.widget.no-secret, os.widget.no-conversation-text,
    // os.widget.aggregate-snapshot-safe, os.background.retry-attempt-0,
    // os.background.retry-attempt-1, os.background.retry-attempt-2,
    // os.background.retry-bounded, os.background.cancel-stops-retry,
    // os.state.pending-claim-once, os.lifecycle.foreground-same-thread-suppress,
    // os.lifecycle.foreground-other-thread-delivers
    @Test
    fun walksEveryOsIntegrationVector() {
        val vectors = osVectors()
        assertTrue(vectors.isNotEmpty())
        for (vector in vectors) {
            when (vector.getString("kind")) {
                "notificationDelivery" -> assertDelivery(vector)
                "pushRoute" -> assertRoute(vector)
                "navigation" -> assertNavigation(vector)
                "urlRoute" -> assertUrl(vector)
                "widgetPrivacy" -> assertPrivacy(vector)
                "widgetSnapshot" -> assertSnapshot(vector)
                "backgroundRetry" -> assertRetry(vector)
                "duplicateTap" -> assertClaim(vector)
                "foregroundSuppress" -> assertSuppress(vector)
                else -> error("unknown os vector kind ${vector.getString("id")}")
            }
        }
    }

    @Test
    fun pulseWindowMetricsIsLinearOverFixtureSize() {
        val count = 4_000
        val usages = (0 until count).map { index ->
            MobilePulseUsageEvent(
                startMs = index.toLong(),
                endMs = index.toLong(),
                tokens = 1,
                costUsd = 0.01,
            )
        }
        val result = MobilePulseWindowPolicy.metrics(
            scope = MobilePulseTimelineScope.DAY,
            rollups = emptyMap(),
            usages = usages,
            nowMs = 3_999,
        )
        assertEquals(count, result.total.requests)
        assertEquals(count.toLong(), result.total.tokens)
    }

    private fun assertDelivery(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val granted = vector.getBoolean("permissionGranted")
        assertEquals(expected.getString("delivery"), MobileOsIntegrationPolicy.delivery(granted).wire)
        assertEquals(expected.getBoolean("mayDeliver"), MobileOsIntegrationPolicy.mayDeliver(granted))
        if (!granted) {
            assertNotEquals(MobileNotificationDelivery.DELIVERED, MobileOsIntegrationPolicy.delivery(false))
        }
    }

    private fun assertRoute(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val routed = MobileOsIntegrationPolicy.route(stringMap(vector.getJSONObject("payload")))
        assertEquals(expected.getString("destination"), routed.destination.wire)
        if (expected.has("deepLink")) {
            assertEquals(expected.getString("deepLink"), routed.deepLink)
        }
    }

    private fun assertNavigation(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val envelope = MobileOsIntegrationPolicy.envelope(stringMap(vector.getJSONObject("payload")))
        val decision = MobileOsIntegrationPolicy.navigation(
            envelope = envelope,
            activeUid = vector.optString("activeUid").ifBlank { null },
            nowMs = vector.getLong("nowMs"),
            lastConsumedEventId = if (vector.has("lastConsumedEventId")) vector.getString("lastConsumedEventId") else null,
            permissionGranted = vector.getBoolean("permissionGranted"),
        )
        assertEquals(expected.getString("decision"), decision.wire)
        assertEquals(expected.getBoolean("navigates"), decision == MobileNavigationDecision.NAVIGATE)
    }

    private fun assertUrl(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val routed = MobileOsIntegrationPolicy.route(vector.getString("url"))
        assertEquals(expected.getString("destination"), routed.destination.wire)
        if (expected.has("itemId")) assertEquals(expected.getString("itemId"), routed.itemId)
        if (expected.has("threadId")) assertEquals(expected.getString("threadId"), routed.threadId)
        if (expected.has("runtime")) assertEquals(expected.getString("runtime"), routed.runtime)
    }

    private fun assertPrivacy(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val scan = MobileOsIntegrationPolicy.scanWidgetFields(stringMap(vector.getJSONObject("fields")))
        if (expected.has("hasRawUid")) assertEquals(expected.getBoolean("hasRawUid"), scan.hasRawUid)
        if (expected.has("hasSecret")) assertEquals(expected.getBoolean("hasSecret"), scan.hasSecret)
        if (expected.has("hasConversationText")) {
            assertEquals(expected.getBoolean("hasConversationText"), scan.hasConversationText)
        }
        assertEquals(expected.getBoolean("isPrivacySafe"), scan.isPrivacySafe)
    }

    private fun assertSnapshot(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        val providers = vector.getJSONArray("topProviders")
        val providerList = (0 until providers.length()).map { providers.getString(it) }
        assertEquals(
            expected.getBoolean("isPrivacySafe"),
            MobileOsIntegrationPolicy.widgetSnapshotIsPrivacySafe(
                heroTotalCost = vector.getDouble("heroTotalCost"),
                heroTotalTokens = vector.getInt("heroTotalTokens"),
                topProviders = providerList,
            ),
        )
        assertEquals(
            expected.getLong("refreshCadenceSeconds"),
            MobileOsIntegrationPolicy.WIDGET_REFRESH_CADENCE_SECONDS,
        )
        assertEquals("group.com.openburnbar.app", MobileOsIntegrationPolicy.WIDGET_APP_GROUP)
    }

    private fun assertClaim(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        assertEquals(
            expected.getBoolean("shouldConsume"),
            MobileOsIntegrationPolicy.shouldConsumeTap(
                eventId = vector.getString("eventId"),
                lastConsumedEventId = if (vector.isNull("lastConsumedEventId")) null else vector.getString("lastConsumedEventId"),
            ),
        )
        assertFalse(
            MobileOsIntegrationPolicy.shouldConsumeTap(
                eventId = vector.getString("eventId"),
                lastConsumedEventId = vector.getString("eventId"),
            ),
        )
    }

    private fun assertSuppress(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        assertEquals(
            expected.getBoolean("suppress"),
            MobileOsIntegrationPolicy.shouldSuppressForegroundSameThread(
                foreground = vector.getBoolean("foreground"),
                activeRuntime = vector.optString("activeRuntime").ifBlank { null },
                activeThreadId = vector.optString("activeThreadId").ifBlank { null },
                payloadRuntime = vector.optString("payloadRuntime").ifBlank { null },
                payloadThreadId = vector.optString("payloadThreadId").ifBlank { null },
            ),
        )
    }

    private fun assertRetry(vector: JSONObject) {
        val expected = vector.getJSONObject("expected")
        assertEquals(
            expected.getBoolean("shouldRetry"),
            MobileOsIntegrationPolicy.shouldRetryBackground(
                attempt = vector.getInt("attempt"),
                cancelled = vector.getBoolean("cancelled"),
            ),
        )
        assertEquals(expected.getInt("maxAttempts"), MobileOsIntegrationPolicy.MAX_BACKGROUND_RETRY_ATTEMPTS)
    }

    private fun osVectors(): List<JSONObject> {
        val fixture = JSONObject(locate("docs/mobile-parity/fixtures/product/os-integration-vectors.json").readText())
        val vectors = fixture.getJSONArray("vectors")
        return (0 until vectors.length()).map { vectors.getJSONObject(it) }
    }

    private fun stringMap(obj: JSONObject): Map<String, String> {
        val mapped = mutableMapOf<String, String>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            mapped[key] = obj.get(key).toString()
        }
        return mapped
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
