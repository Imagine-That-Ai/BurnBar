package com.openburnbar.data.inbox

import com.openburnbar.data.cloud.CloudVaultCrypto
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import java.util.Base64
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure half of the AI Inbox: opening a Mac-sealed mirror document,
 * joining the sibling user-state doc, ranking, sectioning, filtering, and
 * counting.
 *
 * The canonical JSON below is the exact shape `AIInboxMirrorCodec.encodeSealed`
 * writes (`JSONEncoder` with ISO-8601 dates and sorted keys). A drift here means
 * a Mac-written item renders blank — or not at all — on Android.
 *
 * Source of truth:
 *   `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AIInboxMirrorRecord.swift`
 */
class AIInboxRefreshPartsTest {
    private val uid = "user-1"
    private val vaultKey = ByteArray(32) { 0x37.toByte() }

    // 2026-08-04T15:30:00Z — a fixed "now" so every relative assertion below is
    // deterministic regardless of when the suite runs.
    private val now = 1_785_857_400_000L

    private val swiftCanonicalSealedJson =
        """
        {
          "payload": {
            "actions": [
              {
                "id": "open-run",
                "isPrimary": true,
                "kind": "open_url",
                "title": "Open the failing run",
                "value": "https://github.com/openburnbar/BurnBar/actions/runs/42"
              },
              {
                "id": "resume",
                "isPrimary": false,
                "kind": "resume_conversation",
                "title": "Resume that session",
                "value": "conv-99"
              }
            ],
            "evidence": [
              {
                "detail": "17 of the last 20 runs failed on the same step",
                "id": "run:42",
                "kind": "workflow_run",
                "label": "iOS build",
                "occurredAt": "2026-08-04T14:02:00Z",
                "url": "https://github.com/openburnbar/BurnBar/actions/runs/42"
              },
              {
                "id": "conv:99",
                "kind": "conversation",
                "label": "Codex — flaky simulator lane"
              }
            ],
            "memoryCandidates": [
              {
                "citationConversationIDs": ["conv-99"],
                "confidence": 0.82,
                "id": "mem-1",
                "kind": "gotcha",
                "text": "The iOS lane needs FIREBASE_SOURCE_FIRESTORE=1 at resolve time."
              }
            ],
            "metrics": {
              "failure_rate": "0.85",
              "wasted_minutes": "312"
            },
            "verification": {
              "checkedAt": "2026-08-04T14:05:00Z",
              "reason": "Recounted directly from the run index.",
              "verdict": "deterministic",
              "verifierModel": "openai:gpt-5.6-luna"
            },
            "version": 1
          },
          "projectName": "BurnBar",
          "summaryMarkdown": "The **iOS build** lane has failed 17 of its last 20 runs.",
          "title": "CI is burning cycles on the iOS lane"
        }
        """.trimIndent()

    // ── Parsing ──

    @Test
    fun `opens a Mac sealed mirror document into a full item`() = withBase64 {
        val item = parseAIInboxDocument(sealedDocument(), "item-1", uid, vaultKey)

        assertNotNull(item)
        requireNotNull(item)
        assertEquals("item-1", item.id)
        assertEquals("fp-ci-waste", item.fingerprint)
        assertEquals(AIInboxItemKind.CI_WASTE, item.kind)
        assertEquals(AIInboxPriority.P2, item.priority)
        assertEquals(AIInboxItemState.UPDATED, item.state)
        assertEquals(4, item.occurrenceCount)
        assertEquals("deepseek:deepseek-v4-flash", item.modelProvenance)
        assertTrue(item.hasMemoryCandidates)
        assertEquals("CI is burning cycles on the iOS lane", item.title)
        assertEquals("BurnBar", item.projectName)
        assertTrue(item.summaryMarkdown.contains("**iOS build**"))
    }

    @Test
    fun `opens the structured payload with typed evidence actions and verdict`() = withBase64 {
        val item = requireNotNull(parseAIInboxDocument(sealedDocument(), "item-1", uid, vaultKey))

        assertEquals(2, item.payload.evidence.size)
        assertEquals(AIInboxEvidenceKind.WORKFLOW_RUN, item.payload.evidence[0].kind)
        assertEquals("iOS build", item.payload.evidence[0].label)
        assertNotNull(item.payload.evidence[0].occurredAtEpoch)
        // An evidence entry with no detail/url stays renderable with nulls.
        assertEquals(AIInboxEvidenceKind.CONVERSATION, item.payload.evidence[1].kind)
        assertNull(item.payload.evidence[1].url)

        assertEquals(2, item.payload.actions.size)
        assertEquals(AIInboxActionKind.OPEN_URL, item.payload.actions[0].kind)
        assertTrue(item.payload.actions[0].isPrimary)
        assertEquals(AIInboxActionKind.RESUME_CONVERSATION, item.payload.actions[1].kind)

        assertEquals("312", item.payload.metrics["wasted_minutes"])
        assertEquals(AIInboxVerdict.DETERMINISTIC, item.payload.verification?.verdict)
        assertEquals("openai:gpt-5.6-luna", item.payload.verification?.verifierModel)

        assertEquals(1, item.payload.memoryCandidates.size)
        assertEquals("gotcha", item.payload.memoryCandidates[0].kind)
        assertEquals(listOf("conv-99"), item.payload.memoryCandidates[0].citationConversationIDs)
    }

    @Test
    fun `an unknown kind degrades to SYSTEM rather than dropping the item`() = withBase64 {
        // A Mac on a newer build publishes detectors this build has never heard
        // of. Dropping those items would leave this phone's inbox silently
        // incomplete, with nothing on screen to say so.
        val future = sealedDocument().toMutableMap().apply { this["kind"] = "some_future_detector" }

        val item = parseAIInboxDocument(future, "item-1", uid, vaultKey)

        assertNotNull("An unrecognized kind must not drop the item", item)
        requireNotNull(item)
        assertEquals(AIInboxItemKind.SYSTEM, item.kind)
        // Everything except the category survives intact.
        assertEquals("CI is burning cycles on the iOS lane", item.title)
        assertEquals(AIInboxPriority.P2, item.priority)
        assertEquals(4, item.occurrenceCount)
    }

    @Test
    fun `an unknown state still drops the item`() = withBase64 {
        // Unlike kind, an unrecognized lifecycle state would file the row under
        // the wrong filter — worse than omitting it.
        val future = sealedDocument().toMutableMap().apply { this["state"] = "some_future_state" }

        assertNull(parseAIInboxDocument(future, "item-1", uid, vaultKey))
    }

    @Test
    fun `refuses a document stamped with a future schema version`() = withBase64 {
        val future = sealedDocument().toMutableMap().apply { this["schemaVersion"] = AIInboxItem.CURRENT_SCHEMA_VERSION + 1 }

        assertNull(parseAIInboxDocument(future, "item-1", uid, vaultKey))
    }

    @Test
    fun `drops a document that cannot be opened rather than rendering it blank`() = withBase64 {
        val document = sealedDocument()

        // No vault key on this device.
        assertNull(parseAIInboxDocument(document, "item-1", uid, vaultKey = null))
        // Wrong key.
        assertNull(parseAIInboxDocument(document, "item-1", uid, ByteArray(32) { 0x01.toByte() }))
        // Missing seal entirely.
        val unsealed = document.toMutableMap().apply { remove(AIInboxMirrorCodec.SEALED_PAYLOAD_FIELD) }
        assertNull(parseAIInboxDocument(unsealed, "item-1", uid, vaultKey))
    }

    @Test
    fun `refuses a relocated document because the seal is path bound`() = withBase64 {
        val document = sealedDocument()

        // Same bytes, different document id / uid: the AAD no longer matches, so
        // a copied doc cannot be read out of its own address.
        assertNull(parseAIInboxDocument(document, "item-other", uid, vaultKey))
        assertNull(parseAIInboxDocument(document, "item-1", "user-2", vaultKey))
    }

    @Test
    fun `refuses documents missing required routing fields`() = withBase64 {
        // `kind` is deliberately absent from this list: it degrades to SYSTEM
        // (see the forward-compatibility tests below). The fields here are the
        // ones with no safe default — without them the row cannot be filed into
        // a filter, ordered against its peers, or version-checked, so showing it
        // would be worse than omitting it.
        for (missing in listOf("state", "firstSeenAt", "lastSeenAt", "schemaVersion")) {
            val document = sealedDocument().toMutableMap().apply { remove(missing) }
            assertNull("removing $missing should drop the item", parseAIInboxDocument(document, "item-1", uid, vaultKey))
        }
    }

    @Test
    fun `a missing kind degrades exactly like an unknown one`() = withBase64 {
        // Absent and unrecognized are the same situation from this build's point
        // of view, so they must not diverge.
        val document = sealedDocument().toMutableMap().apply { remove("kind") }

        val item = parseAIInboxDocument(document, "item-1", uid, vaultKey)

        assertNotNull(item)
        requireNotNull(item)
        assertEquals(AIInboxItemKind.SYSTEM, item.kind)
    }

    @Test
    fun `an empty title drops the item because a blank row is worse than none`() = withBase64 {
        val document = sealedDocument(titleOverride = "")

        assertNull(parseAIInboxDocument(document, "item-1", uid, vaultKey))
    }

    @Test
    fun `clamps an out of range priority instead of failing the item`() = withBase64 {
        val high = sealedDocument().toMutableMap().apply { this["priority"] = 99 }
        val low = sealedDocument().toMutableMap().apply { this["priority"] = 0 }

        assertEquals(AIInboxPriority.P4, parseAIInboxDocument(high, "item-1", uid, vaultKey)?.priority)
        assertEquals(AIInboxPriority.P1, parseAIInboxDocument(low, "item-1", uid, vaultKey)?.priority)
    }

    // ── Item state ──

    @Test
    fun `parses an item state document and honours the feedback allowlist`() {
        val state =
            parseAIInboxItemState(
                mapOf(
                    "id" to "item-1",
                    "readAt" to java.util.Date(now - 1_000),
                    "snoozedUntil" to java.util.Date(now + 60_000),
                    "feedback" to "useful",
                    "updatedAt" to java.util.Date(now),
                    "updatedByDeviceID" to "android-abc",
                ),
                "item-1",
            )

        requireNotNull(state)
        assertFalse(state.isUnread)
        assertTrue(state.isSuppressed(now))
        assertEquals("useful", state.feedback)
        assertEquals("android-abc", state.updatedByDeviceID)

        val offAllowlist =
            parseAIInboxItemState(mapOf("feedback" to "spectacular", "updatedAt" to java.util.Date(now)), "item-1")
        assertNull(requireNotNull(offAllowlist).feedback)

        // No updatedAt means the doc is not a state doc we can reason about.
        assertNull(parseAIInboxItemState(mapOf("feedback" to "useful"), "item-1"))
    }

    @Test
    fun `state joins to its item by id and leaves unmatched items bare`() {
        val rows =
            joinAIInboxRows(
                items = listOf(item("a"), item("b")),
                states = mapOf("a" to AIInboxItemUserState(id = "a", readAtEpoch = now, updatedAtEpoch = now)),
            )

        assertEquals(2, rows.size)
        assertFalse(rows.first { it.id == "a" }.isUnread())
        assertTrue(rows.first { it.id == "b" }.isUnread())
    }

    @Test
    fun `a resolved item never counts as unread`() {
        val row = AIInboxRow(item = item("a", state = AIInboxItemState.RESOLVED))

        assertFalse(row.isUnread())
    }

    // ── Optimistic state overlay ──

    @Test
    fun `a pending edit survives an unrelated server snapshot`() {
        // The window this closes: the user taps a row, and before that write is
        // echoed back a snapshot about a DIFFERENT item lands. Without the
        // overlay, the tapped row would flick back to unread.
        val server = mapOf("other" to state("other", updatedAt = now))
        val pending = mapOf("tapped" to state("tapped", readAt = now, updatedAt = now))

        val (merged, stillPending) = mergeAIInboxPendingStates(server, pending)

        assertEquals(now, merged["tapped"]?.readAtEpoch)
        assertEquals(now, merged["other"]?.updatedAtEpoch)
        assertEquals(setOf("tapped"), stillPending.keys)
    }

    @Test
    fun `a confirmed edit drains from the pending overlay`() {
        val pending = mapOf("tapped" to state("tapped", readAt = now, updatedAt = now))
        val server = mapOf("tapped" to state("tapped", readAt = now + 5, updatedAt = now + 5))

        val (merged, stillPending) = mergeAIInboxPendingStates(server, pending)

        // Once the server reports the same edit or newer, the local copy is
        // redundant — keeping it would pin a stale value forever.
        assertEquals(now + 5, merged["tapped"]?.readAtEpoch)
        assertTrue(stillPending.isEmpty())
    }

    @Test
    fun `a newer local edit outranks a stale server state`() {
        val server = mapOf("tapped" to state("tapped", updatedAt = now - 10_000))
        val pending = mapOf("tapped" to state("tapped", archivedAt = now, updatedAt = now))

        val (merged, stillPending) = mergeAIInboxPendingStates(server, pending)

        assertEquals(now, merged["tapped"]?.archivedAtEpoch)
        assertEquals(setOf("tapped"), stillPending.keys)
    }

    @Test
    fun `an empty overlay returns the server states untouched`() {
        val server = mapOf("a" to state("a", updatedAt = now))

        val (merged, stillPending) = mergeAIInboxPendingStates(server, emptyMap())

        assertEquals(server, merged)
        assertTrue(stillPending.isEmpty())
    }

    // ── Ranking ──

    @Test
    fun `ranks by priority then unread then recency`() {
        val rows =
            listOf(
                AIInboxRow(item("old-p3", priority = AIInboxPriority.P3, lastSeenAtEpoch = now - 90_000)),
                AIInboxRow(item("new-p3", priority = AIInboxPriority.P3, lastSeenAtEpoch = now - 1_000)),
                AIInboxRow(item("urgent", priority = AIInboxPriority.P1, lastSeenAtEpoch = now - 500_000)),
                AIInboxRow(
                    item = item("read-p3", priority = AIInboxPriority.P3, lastSeenAtEpoch = now),
                    userState = AIInboxItemUserState(id = "read-p3", readAtEpoch = now, updatedAtEpoch = now),
                ),
            )

        // P1 outranks every P3 regardless of age; among equal-priority rows the
        // unread ones come first, and only then does recency decide.
        assertEquals(listOf("urgent", "new-p3", "old-p3", "read-p3"), rows.rankedForInbox().map { it.id })
    }

    // ── Filtering ──

    @Test
    fun `active hides archived and still-snoozed rows`() {
        val rows =
            listOf(
                AIInboxRow(item("plain")),
                AIInboxRow(item("archived"), AIInboxItemUserState(id = "archived", archivedAtEpoch = now, updatedAtEpoch = now)),
                AIInboxRow(item("snoozed"), AIInboxItemUserState(id = "snoozed", snoozedUntilEpoch = now + 60_000, updatedAtEpoch = now)),
                AIInboxRow(item("woke"), AIInboxItemUserState(id = "woke", snoozedUntilEpoch = now - 60_000, updatedAtEpoch = now)),
            )

        val active = rows.filteredForInbox(AIInboxFilter.ACTIVE, now).map { it.id }

        // An expired snooze brings the row back on its own — no write required.
        assertEquals(setOf("plain", "woke"), active.toSet())
        assertEquals(listOf("archived"), rows.filteredForInbox(AIInboxFilter.ARCHIVED, now).map { it.id })
    }

    @Test
    fun `attention keeps only the visible P1 and P2 rows`() {
        val rows =
            listOf(
                AIInboxRow(item("p1", priority = AIInboxPriority.P1)),
                AIInboxRow(item("p2", priority = AIInboxPriority.P2)),
                AIInboxRow(item("p3", priority = AIInboxPriority.P3)),
                AIInboxRow(
                    item("p1-archived", priority = AIInboxPriority.P1),
                    AIInboxItemUserState(id = "p1-archived", archivedAtEpoch = now, updatedAtEpoch = now),
                ),
            )

        assertEquals(listOf("p1", "p2"), rows.filteredForInbox(AIInboxFilter.ATTENTION, now).map { it.id })
    }

    @Test
    fun `each filter reads the item states it is meant to`() {
        assertEquals(AIInboxItemState.openStates, AIInboxFilter.ACTIVE.states)
        assertEquals(AIInboxItemState.openStates, AIInboxFilter.ATTENTION.states)
        // Archived is a user decision, not a lifecycle transition, so the
        // archived filter still reads OPEN items.
        assertEquals(AIInboxItemState.openStates, AIInboxFilter.ARCHIVED.states)
        assertEquals(listOf(AIInboxItemState.RESOLVED, AIInboxItemState.EXPIRED), AIInboxFilter.RESOLVED.states)
    }

    // ── Sectioning ──

    @Test
    fun `sections split attention from today and earlier`() {
        val rows =
            listOf(
                AIInboxRow(item("urgent", priority = AIInboxPriority.P1, lastSeenAtEpoch = now - 400L * 60 * 60 * 1000)),
                AIInboxRow(item("today", priority = AIInboxPriority.P3, lastSeenAtEpoch = now - 60_000)),
                AIInboxRow(item("earlier", priority = AIInboxPriority.P3, lastSeenAtEpoch = now - 400L * 60 * 60 * 1000)),
            )

        val sections = rows.sectionedForInbox(AIInboxFilter.ACTIVE, now, TimeZone.getTimeZone("UTC"))

        assertEquals(
            listOf(AIInboxSection.ATTENTION, AIInboxSection.TODAY, AIInboxSection.EARLIER),
            sections.map { it.section },
        )
        // An urgent row is urgent no matter how stale it is — priority wins over
        // recency for section assignment.
        assertEquals(listOf("urgent"), sections[0].rows.map { it.id })
        assertEquals(listOf("today"), sections[1].rows.map { it.id })
        assertEquals(listOf("earlier"), sections[2].rows.map { it.id })
    }

    @Test
    fun `empty sections are omitted entirely`() {
        val rows = listOf(AIInboxRow(item("today", priority = AIInboxPriority.P3, lastSeenAtEpoch = now - 60_000)))

        val sections = rows.sectionedForInbox(AIInboxFilter.ACTIVE, now, TimeZone.getTimeZone("UTC"))

        assertEquals(listOf(AIInboxSection.TODAY), sections.map { it.section })
    }

    @Test
    fun `closed filters collapse to a single section`() {
        val rows =
            listOf(
                AIInboxRow(item("r1", state = AIInboxItemState.RESOLVED, priority = AIInboxPriority.P1)),
                AIInboxRow(item("r2", state = AIInboxItemState.EXPIRED, priority = AIInboxPriority.P3)),
            )

        val sections = rows.sectionedForInbox(AIInboxFilter.RESOLVED, now, TimeZone.getTimeZone("UTC"))

        assertEquals(listOf(AIInboxSection.CLOSED), sections.map { it.section })
        assertEquals(2, sections.single().rows.size)
        assertTrue(rows.take(0).sectionedForInbox(AIInboxFilter.RESOLVED, now).isEmpty())
    }

    // ── Counting ──

    @Test
    fun `unread counting ignores hidden and closed rows`() {
        val rows =
            listOf(
                AIInboxRow(item("unread")),
                AIInboxRow(item("read"), AIInboxItemUserState(id = "read", readAtEpoch = now, updatedAtEpoch = now)),
                AIInboxRow(item("archived"), AIInboxItemUserState(id = "archived", archivedAtEpoch = now, updatedAtEpoch = now)),
                AIInboxRow(item("snoozed"), AIInboxItemUserState(id = "snoozed", snoozedUntilEpoch = now + 60_000, updatedAtEpoch = now)),
                AIInboxRow(item("resolved", state = AIInboxItemState.RESOLVED)),
            )

        assertEquals(1, rows.unreadCountForInbox(now))
    }

    @Test
    fun `attention counting includes read rows but not hidden ones`() {
        val rows =
            listOf(
                AIInboxRow(item("p1"), AIInboxItemUserState(id = "p1", readAtEpoch = now, updatedAtEpoch = now)),
                AIInboxRow(item("p2", priority = AIInboxPriority.P2)),
                AIInboxRow(item("p3", priority = AIInboxPriority.P3)),
                AIInboxRow(
                    item("p1-snoozed", priority = AIInboxPriority.P1),
                    AIInboxItemUserState(id = "p1-snoozed", snoozedUntilEpoch = now + 60_000, updatedAtEpoch = now),
                ),
            )

        // Reading an urgent item does not make it less urgent; snoozing does.
        assertEquals(2, rows.attentionCountForInbox(now))
    }

    // ── End-to-end assembly ──

    @Test
    fun `builds rows sections and badge counts in one pass`() {
        val items =
            listOf(
                item("urgent", priority = AIInboxPriority.P1, lastSeenAtEpoch = now - 5_000),
                item("today", priority = AIInboxPriority.P3, lastSeenAtEpoch = now - 60_000),
                item("closed", state = AIInboxItemState.RESOLVED, priority = AIInboxPriority.P3),
            )
        val states = mapOf("today" to AIInboxItemUserState(id = "today", readAtEpoch = now, updatedAtEpoch = now))

        val parts = buildAIInboxRefreshParts(items, states, AIInboxFilter.ACTIVE, now, TimeZone.getTimeZone("UTC"))

        // The resolved item is out of the ACTIVE slice but still absent from the
        // badge, which only ever counts open rows.
        assertEquals(listOf("urgent", "today"), parts.rows.map { it.id })
        assertEquals(listOf(AIInboxSection.ATTENTION, AIInboxSection.TODAY), parts.sections.map { it.section })
        assertEquals(1, parts.unreadCount)
        assertEquals(1, parts.attentionCount)
    }

    @Test
    fun `switching to a closed filter keeps the open badge counts intact`() {
        val items =
            listOf(
                item("urgent", priority = AIInboxPriority.P1),
                item("closed", state = AIInboxItemState.RESOLVED),
            )

        val parts = buildAIInboxRefreshParts(items, emptyMap(), AIInboxFilter.RESOLVED, now, TimeZone.getTimeZone("UTC"))

        assertEquals(listOf("closed"), parts.rows.map { it.id })
        assertEquals(1, parts.unreadCount)
        assertEquals(1, parts.attentionCount)
    }

    // ── Fixtures ──

    private fun state(id: String, readAt: Long? = null, archivedAt: Long? = null, updatedAt: Long = now) =
        AIInboxItemUserState(id = id, readAtEpoch = readAt, archivedAtEpoch = archivedAt, updatedAtEpoch = updatedAt)

    private fun item(
        id: String,
        kind: AIInboxItemKind = AIInboxItemKind.CI_WASTE,
        priority: AIInboxPriority = AIInboxPriority.P1,
        state: AIInboxItemState = AIInboxItemState.NEW,
        lastSeenAtEpoch: Long = now,
    ) = AIInboxItem(
        id = id,
        fingerprint = "fp-$id",
        kind = kind,
        priority = priority,
        state = state,
        firstSeenAtEpoch = lastSeenAtEpoch - 1_000,
        lastSeenAtEpoch = lastSeenAtEpoch,
        title = "Item $id",
    )

    /** The exact top-level document shape `encodeSealed` writes. */
    private fun sealedDocument(documentID: String = "item-1", titleOverride: String? = null): Map<String, Any?> {
        val json =
            if (titleOverride == null) {
                swiftCanonicalSealedJson
            } else {
                swiftCanonicalSealedJson.replace(
                    "\"title\": \"CI is burning cycles on the iOS lane\"",
                    "\"title\": \"$titleOverride\"",
                )
            }
        val sealed =
            CloudVaultCrypto.sealPayload(
                json.toByteArray(Charsets.UTF_8),
                vaultKey,
                CloudVaultCrypto.vaultKeyID(vaultKey),
                aiInboxSealedPayloadAAD(uid, documentID),
            )
        return mapOf(
            "id" to documentID,
            "fingerprint" to "fp-ci-waste",
            "kind" to "ci_waste",
            "priority" to 2,
            "state" to "updated",
            "occurrenceCount" to 4,
            "firstSeenAt" to java.util.Date(now - 86_400_000),
            "lastSeenAt" to java.util.Date(now - 3_600_000),
            "modelProvenance" to "deepseek:deepseek-v4-flash",
            "hasMemoryCandidates" to true,
            "schemaVersion" to AIInboxItem.CURRENT_SCHEMA_VERSION,
            "sealedSchemaVersion" to 2,
            "vaultKeyID" to CloudVaultCrypto.vaultKeyID(vaultKey),
            "contentSealed" to true,
            "updatedAt" to java.util.Date(now),
            AIInboxMirrorCodec.SEALED_PAYLOAD_FIELD to CloudVaultCrypto.sealedPayloadMap(sealed),
        )
    }

    // ── Cross-language token parity ──
    //
    // Every raw string below is copied from the Swift contracts by hand:
    //   BurnBarInboxItemKind / BurnBarInboxItemState / BurnBarInboxPriority /
    //   BurnBarInboxEvidence.Kind / BurnBarInboxAction.Kind /
    //   BurnBarInboxVerification.Verdict
    //     — OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarAIInboxContracts.swift
    //   AIInboxMirrorCodec.collection / .stateCollection / .sealedPayloadField /
    //   .allowedFeedbackValues
    //     — OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AIInboxMirrorRecord.swift
    //
    // These are the failure mode with no symptom. A mistyped token does not
    // crash and does not log — `fromToken` returns null — and the phone shows an
    // inbox that is simply empty, indistinguishable from "the Mac found
    // nothing". Enumerating all of them here is what turns that silence into a
    // red test.
    //
    // `kind` is the one token that degrades instead of dropping (unknown reads
    // as SYSTEM), because a newer Mac legitimately publishes kinds this build
    // has never seen. Every other token below is exact-match or bust.

    @Test
    fun `item kind tokens match the Swift raw values exactly`() {
        assertEquals(
            listOf(
                "ci_waste", "promised_not_landed", "uncommitted_work", "cost_anomaly",
                "stuck_pr", "index_health", "brief", "budget", "system",
            ),
            AIInboxItemKind.entries.map { it.token },
        )
        for (kind in AIInboxItemKind.entries) {
            assertEquals(kind, AIInboxItemKind.fromToken(kind.token))
        }
    }

    @Test
    fun `only brief and system are non-alert kinds`() {
        // Mirrors `BurnBarInboxItemKind.isAlert`. Getting this backwards would
        // style a routine narration as a problem, or vice versa.
        assertEquals(
            listOf(AIInboxItemKind.BRIEF, AIInboxItemKind.SYSTEM),
            AIInboxItemKind.entries.filter { !it.isAlert },
        )
    }

    @Test
    fun `lifecycle state tokens match the Swift raw values exactly`() {
        assertEquals(
            listOf("new", "updated", "resolved", "expired"),
            AIInboxItemState.entries.map { it.token },
        )
        // `new`/`updated` are the OPEN pair the Mac enforces one-per-fingerprint
        // on; the badge counts and the ACTIVE filter both read this.
        assertEquals(
            listOf(AIInboxItemState.NEW, AIInboxItemState.UPDATED),
            AIInboxItemState.entries.filter { it.isOpen },
        )
        assertEquals(AIInboxItemState.openStates, AIInboxItemState.entries.filter { it.isOpen })
        for (state in AIInboxItemState.entries) {
            assertEquals(state, AIInboxItemState.fromToken(state.token))
        }
    }

    @Test
    fun `evidence kind tokens match the Swift raw values exactly`() {
        assertEquals(
            listOf(
                "conversation",
                "pull_request",
                "issue",
                "workflow_run",
                "commit",
                "file",
                "usage",
                "metric",
            ),
            AIInboxEvidenceKind.entries.map { it.token },
        )
        for (kind in AIInboxEvidenceKind.entries) {
            assertEquals(kind, AIInboxEvidenceKind.fromToken(kind.token))
        }
    }

    @Test
    fun `action kind tokens match the Swift raw values exactly`() {
        assertEquals(
            listOf(
                "open_url",
                "resume_conversation",
                "open_session_log",
                "open_project",
                "open_settings",
                "run_command",
            ),
            AIInboxActionKind.entries.map { it.token },
        )
        for (kind in AIInboxActionKind.entries) {
            assertEquals(kind, AIInboxActionKind.fromToken(kind.token))
        }
    }

    @Test
    fun `verification verdict tokens match the Swift raw values exactly`() {
        assertEquals(
            listOf("confirmed", "refuted", "unclear", "unverified", "deterministic"),
            AIInboxVerdict.entries.map { it.token },
        )
        for (verdict in AIInboxVerdict.entries) {
            assertEquals(verdict, AIInboxVerdict.fromToken(verdict.token))
        }
    }

    @Test
    fun `priority clamps the way the Swift initializer does`() {
        // `BurnBarInboxPriority(clamping:)` bounds to 1...4 and falls back to p3
        // for an absent value. An off-by-one here silently re-bands every item.
        assertEquals(listOf(1, 2, 3, 4), AIInboxPriority.entries.map { it.rank })
        assertEquals(AIInboxPriority.P1, AIInboxPriority.clamping(0))
        assertEquals(AIInboxPriority.P1, AIInboxPriority.clamping(1))
        assertEquals(AIInboxPriority.P4, AIInboxPriority.clamping(4))
        assertEquals(AIInboxPriority.P4, AIInboxPriority.clamping(99))
        assertEquals(AIInboxPriority.P3, AIInboxPriority.clamping(null))
    }

    @Test
    fun `collection names and the sealed field match the Swift codec`() {
        // These three strings are also baked into the firestore.rules match
        // blocks and into the AAD every payload is bound to, so a drift here
        // fails the decrypt rather than merely reading the wrong path.
        assertEquals("ai_inbox_items", AIInboxMirrorCodec.COLLECTION)
        assertEquals("ai_inbox_item_state", AIInboxMirrorCodec.STATE_COLLECTION)
        assertEquals("sealedPayload", AIInboxMirrorCodec.SEALED_PAYLOAD_FIELD)
        assertEquals(setOf("useful", "not_useful", "wrong"), AIInboxMirrorCodec.ALLOWED_FEEDBACK_VALUES)
    }

    @Test
    fun `the sealed payload AAD is bound to the item path`() {
        // Byte-for-byte the Swift `CloudVaultAADContext(uid:collection:docID:field:)`
        // built by `AIInboxMirrorCodec.encodeSealed`. This is what makes a
        // document copied to another user or another id fail to open.
        val aad = aiInboxSealedPayloadAAD(uid = "uid-1", documentID = "inb_1")
        assertEquals("uid-1", aad.uid)
        assertEquals("ai_inbox_items", aad.collection)
        assertEquals("inb_1", aad.docID)
        assertEquals("sealedPayload", aad.field)
        assertEquals(2, aad.schemaVersion)
        // Swift defaults `purpose` to the field name when none is passed.
        assertEquals("sealedPayload", aad.purpose)
    }

    @Test
    fun `a schema version from the future is refused rather than partly read`() {
        // `AIInboxMirrorCodec.decodeSealed` returns nil for schemaVersion >
        // current. A client that guessed instead would render an item whose
        // meaning it does not actually know.
        assertEquals(1, AIInboxItem.CURRENT_SCHEMA_VERSION)
    }

    /**
     * `CloudVaultCrypto` base64s through `android.util.Base64`, which is a stub
     * on the JVM. Route it to the JDK encoder for the duration of one test.
     */
    private fun withBase64(body: () -> Unit) {
        mockkStatic(android.util.Base64::class)
        every { android.util.Base64.encodeToString(any(), any()) } answers {
            Base64.getEncoder().encodeToString(firstArg<ByteArray>())
        }
        every { android.util.Base64.decode(any<String>(), any()) } answers {
            Base64.getDecoder().decode(firstArg<String>())
        }
        try {
            body()
        } finally {
            unmockkStatic(android.util.Base64::class)
        }
    }

    @After
    fun ensureUnmocked() {
        // Guards against a leaked static mock if a Base64-using test threw.
        runCatching { unmockkStatic(android.util.Base64::class) }
    }
}
