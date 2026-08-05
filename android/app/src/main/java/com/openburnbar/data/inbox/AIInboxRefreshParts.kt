package com.openburnbar.data.inbox

import com.openburnbar.data.cloud.CloudVaultAADContext
import com.openburnbar.data.cloud.CloudVaultCrypto
import java.util.Calendar
import java.util.TimeZone

// MARK: - AI Inbox pure parts (no Firebase)
//
// Everything the inbox does between "a document map arrived" and "a list is on
// screen" lives here as free functions over plain data: parse, join state, rank,
// section, filter, count. `AIInboxStore` supplies the Firestore listeners and
// nothing else, so the behaviour that actually decides what the user sees is
// exercised by JVM unit tests rather than by an instrumented run.

/** Raw numeric timestamps below this are epoch seconds (true through 2286). */
private const val EPOCH_SECONDS_CUTOFF = 10_000_000_000L

private const val DEFAULT_MODEL_PROVENANCE = "local-rules"

/**
 * Which slice of the inbox is on screen. Mirrors the Mac `InboxModel.Filter` so
 * the two surfaces answer the same questions in the same words.
 */
enum class AIInboxFilter(val title: String) {
    /** Everything open and not hidden — the default reading position. */
    ACTIVE("Active"),

    /** P1/P2 only: the subset worth interrupting a day for. */
    ATTENTION("Needs attention"),

    /** Closed history, kept for trend reading rather than action. */
    RESOLVED("Resolved"),

    /** Explicitly put away, still reachable. */
    ARCHIVED("Archived"),
    ;

    /**
     * Item lifecycle states this filter reads, or `null` for "any state".
     * Archived items stay open-state on the Mac — being archived is a *user*
     * decision recorded in the sibling state doc, not a lifecycle transition.
     */
    val states: List<AIInboxItemState>?
        get() = when (this) {
            ACTIVE, ATTENTION, ARCHIVED -> AIInboxItemState.openStates
            RESOLVED -> listOf(AIInboxItemState.RESOLVED, AIInboxItemState.EXPIRED)
        }
}

/**
 * Section headings in the list. Grouping by urgency-then-recency (rather than by
 * kind) matches how the surface is actually read: "what is happening now" first.
 */
enum class AIInboxSection(val title: String) {
    ATTENTION("Needs attention"),
    TODAY("Today"),
    EARLIER("Earlier"),
    CLOSED("Closed"),
}

/** One item joined with the user state that governs how it is displayed. */
data class AIInboxRow(
    val item: AIInboxItem,
    val userState: AIInboxItemUserState? = null,
) {
    val id: String get() = item.id

    val isArchived: Boolean get() = userState?.archivedAtEpoch != null

    val feedback: String? get() = userState?.feedback

    fun isUnread(): Boolean = userState?.readAtEpoch == null && item.state.isOpen

    fun isSnoozed(nowEpoch: Long): Boolean = (userState?.snoozedUntilEpoch ?: Long.MIN_VALUE) > nowEpoch

    /** Hidden from the default list but still reachable through a filter. */
    fun isHidden(nowEpoch: Long): Boolean = isArchived || isSnoozed(nowEpoch)
}

/** A section heading plus the rows under it. */
data class AIInboxSectionGroup(
    val section: AIInboxSection,
    val rows: List<AIInboxRow>,
)

/** Everything a rendered inbox needs, derived in one pass. */
data class AIInboxRefreshParts(
    val rows: List<AIInboxRow>,
    val sections: List<AIInboxSectionGroup>,
    val unreadCount: Int,
    val attentionCount: Int,
)

// ── Parsing ──────────────────────────────────────────────────────────────────

/**
 * Opens one mirror document into an [AIInboxItem].
 *
 * Returns `null` — rather than a partial item — for anything unreadable: a
 * schema from the future, a missing seal, an absent vault key, a key that does
 * not open it, or an empty title. Matches `AIInboxMirrorCodec.decodeSealed` on
 * the Swift side exactly, including the path-bound AAD, so a document relocated
 * to another user or another id fails to open instead of rendering.
 */
// Sequential guard clauses; a single-exit rewrite obscures the precedence order.
fun parseAIInboxDocument(data: Map<String, Any?>, documentID: String, uid: String, vaultKey: ByteArray?): AIInboxItem? {
    val schemaVersion = intValue(data["schemaVersion"]) ?: return null
    if (schemaVersion > AIInboxItem.CURRENT_SCHEMA_VERSION) return null

    // An UNKNOWN kind degrades to SYSTEM rather than dropping the item. The Mac
    // ships detectors ahead of the phones that read them, so an older Android
    // build will meet kinds it has never heard of; dropping those would make the
    // inbox silently incomplete here with no error to notice. Title, priority,
    // body, and evidence all still read correctly — only the icon and category
    // label go generic. Matches `AIInboxMirrorCodec.decodeSealed` on Apple.
    //
    // `state` stays strict: an unknown lifecycle state would file the row under
    // the wrong filter, which is worse than omitting it.
    val kind = AIInboxItemKind.fromToken(data["kind"] as? String) ?: AIInboxItemKind.SYSTEM
    val state = AIInboxItemState.fromToken(data["state"] as? String) ?: return null
    val firstSeenAt = epochMillis(data["firstSeenAt"]) ?: return null
    val lastSeenAt = epochMillis(data["lastSeenAt"]) ?: return null

    val key = vaultKey ?: return null
    val envelope =
        CloudVaultCrypto.sealedPayloadFromMap(data[AIInboxMirrorCodec.SEALED_PAYLOAD_FIELD] as? Map<*, *>) ?: return null

    val sealed =
        runCatching {
            val bytes = CloudVaultCrypto.openPayload(envelope, key, aiInboxSealedPayloadAAD(uid, documentID))
            aiInboxSealedJson.decodeFromString(AIInboxSealedPayload.serializer(), bytes.toString(Charsets.UTF_8))
        }.getOrNull() ?: return null

    if (sealed.title.isBlank()) return null

    return AIInboxItem(
        id = documentID,
        fingerprint = (data["fingerprint"] as? String)?.ifBlank { null } ?: documentID,
        kind = kind,
        priority = AIInboxPriority.clamping(intValue(data["priority"])),
        state = state,
        occurrenceCount = maxOf(1, intValue(data["occurrenceCount"]) ?: 1),
        firstSeenAtEpoch = firstSeenAt,
        lastSeenAtEpoch = lastSeenAt,
        resolvedAtEpoch = epochMillis(data["resolvedAt"]),
        modelProvenance = (data["modelProvenance"] as? String)?.ifBlank { null } ?: DEFAULT_MODEL_PROVENANCE,
        hasMemoryCandidates = data["hasMemoryCandidates"] as? Boolean ?: false,
        schemaVersion = schemaVersion,
        title = sealed.title,
        summaryMarkdown = sealed.summaryMarkdown,
        projectName = sealed.projectName?.ifBlank { null },
        resolutionNote = sealed.resolutionNote?.ifBlank { null },
        payload = sealed.payload.toItemPayload(),
    )
}

/** Reads one `ai_inbox_item_state` document. Unparseable state is simply absent. */
fun parseAIInboxItemState(data: Map<String, Any?>, documentID: String): AIInboxItemUserState? {
    val updatedAt = epochMillis(data["updatedAt"]) ?: return null
    val feedback = (data["feedback"] as? String)?.takeIf { it in AIInboxMirrorCodec.ALLOWED_FEEDBACK_VALUES }
    return AIInboxItemUserState(
        id = documentID,
        readAtEpoch = epochMillis(data["readAt"]),
        archivedAtEpoch = epochMillis(data["archivedAt"]),
        snoozedUntilEpoch = epochMillis(data["snoozedUntil"]),
        feedback = feedback,
        updatedAtEpoch = updatedAt,
        updatedByDeviceID = (data["updatedByDeviceID"] as? String)?.ifBlank { null },
    )
}

/**
 * The AAD every sealed inbox payload is bound to. Identical in shape to the
 * `cli_sessions` binding, so a document moved between collections, users, or
 * document ids fails to decrypt rather than silently rendering elsewhere.
 */
internal fun aiInboxSealedPayloadAAD(uid: String, documentID: String) = CloudVaultAADContext(
    uid = uid,
    collection = AIInboxMirrorCodec.COLLECTION,
    docID = documentID,
    field = AIInboxMirrorCodec.SEALED_PAYLOAD_FIELD,
)

// ── Joining, ranking, sectioning ─────────────────────────────────────────────

/** Joins items to their user-state documents by id. */
fun joinAIInboxRows(items: List<AIInboxItem>, states: Map<String, AIInboxItemUserState>): List<AIInboxRow> =
    items.map { item -> AIInboxRow(item = item, userState = states[item.id]) }

/**
 * Overlays not-yet-confirmed local edits on top of the server's state snapshot.
 *
 * Firestore's latency compensation usually replays a pending write through the
 * listener, but not instantly: between tapping a row and the write reaching the
 * local cache, an unrelated snapshot can land and momentarily undo the tap. The
 * overlay closes that window — a pending edit wins until the server reports a
 * state at least as new, at which point the local copy is redundant and dropped.
 *
 * Returns the merged map alongside the pending entries still worth keeping, so
 * the overlay drains itself instead of pinning stale edits forever.
 */
fun mergeAIInboxPendingStates(
    server: Map<String, AIInboxItemUserState>,
    pending: Map<String, AIInboxItemUserState>,
): Pair<Map<String, AIInboxItemUserState>, Map<String, AIInboxItemUserState>> {
    if (pending.isEmpty()) return server to pending
    val stillPending =
        pending.filter { (id, local) ->
            val confirmed = server[id] ?: return@filter true
            confirmed.updatedAtEpoch < local.updatedAtEpoch
        }
    return (server + stillPending) to stillPending
}

/**
 * Ranking: attention first, then unread, then recency.
 *
 * Deliberately one comparator shared by every caller so the phone, the tablet
 * split view, and the badge all agree on what "first" means.
 */
fun List<AIInboxRow>.rankedForInbox(): List<AIInboxRow> = sortedWith(
    Comparator { a, b ->
        if (a.item.priority.rank != b.item.priority.rank) {
            return@Comparator a.item.priority.rank.compareTo(b.item.priority.rank)
        }
        val aUnread = a.isUnread()
        val bUnread = b.isUnread()
        if (aUnread != bUnread) {
            return@Comparator if (aUnread) -1 else 1
        }
        return@Comparator b.item.lastSeenAtEpoch.compareTo(a.item.lastSeenAtEpoch)
    },
)

/** Rows visible under [filter], ranked. */
fun List<AIInboxRow>.filteredForInbox(filter: AIInboxFilter, nowEpoch: Long): List<AIInboxRow> {
    val filtered =
        when (filter) {
            AIInboxFilter.ACTIVE -> filter { !it.isHidden(nowEpoch) }
            AIInboxFilter.ATTENTION -> filter { !it.isHidden(nowEpoch) && it.item.priority.rank <= AIInboxPriority.P2.rank }
            AIInboxFilter.RESOLVED -> this
            AIInboxFilter.ARCHIVED -> filter { it.isArchived }
        }
    return filtered.rankedForInbox()
}

/**
 * Groups visible rows into display sections.
 *
 * The closed filters collapse to a single `Closed` group: once an item is
 * resolved or archived, urgency is history and only the list matters.
 */
fun List<AIInboxRow>.sectionedForInbox(filter: AIInboxFilter, nowEpoch: Long, timeZone: TimeZone = TimeZone.getDefault()): List<AIInboxSectionGroup> {
    val visible = filteredForInbox(filter, nowEpoch)
    if (filter == AIInboxFilter.RESOLVED || filter == AIInboxFilter.ARCHIVED) {
        return if (visible.isEmpty()) emptyList() else listOf(AIInboxSectionGroup(AIInboxSection.CLOSED, visible))
    }

    val startOfToday = startOfDayEpoch(nowEpoch, timeZone)
    val attention = mutableListOf<AIInboxRow>()
    val today = mutableListOf<AIInboxRow>()
    val earlier = mutableListOf<AIInboxRow>()
    for (row in visible) {
        when {
            row.item.priority.rank <= AIInboxPriority.P2.rank -> attention.add(row)
            row.item.lastSeenAtEpoch >= startOfToday -> today.add(row)
            else -> earlier.add(row)
        }
    }

    return listOf(
        AIInboxSectionGroup(AIInboxSection.ATTENTION, attention),
        AIInboxSectionGroup(AIInboxSection.TODAY, today),
        AIInboxSectionGroup(AIInboxSection.EARLIER, earlier),
    ).filter { it.rows.isNotEmpty() }
}

/** Unread items the user has not put away — the number the tab badge shows. */
fun List<AIInboxRow>.unreadCountForInbox(nowEpoch: Long): Int = count { it.isUnread() && !it.isHidden(nowEpoch) }

/** Visible P1/P2 items, whether or not they have been read. */
fun List<AIInboxRow>.attentionCountForInbox(nowEpoch: Long): Int = count {
    !it.isHidden(nowEpoch) && it.item.priority.rank <= AIInboxPriority.P2.rank
}

/** One pass from raw parsed documents to everything a rendered inbox needs. */
fun buildAIInboxRefreshParts(
    items: List<AIInboxItem>,
    states: Map<String, AIInboxItemUserState>,
    filter: AIInboxFilter,
    nowEpoch: Long,
    timeZone: TimeZone = TimeZone.getDefault(),
): AIInboxRefreshParts {
    val joined = joinAIInboxRows(items, states)
    val scoped = joined.filter { row -> filter.states?.contains(row.item.state) ?: true }
    return AIInboxRefreshParts(
        rows = scoped.filteredForInbox(filter, nowEpoch),
        sections = scoped.sectionedForInbox(filter, nowEpoch, timeZone),
        // Badge counts read the OPEN slice regardless of which filter is on
        // screen — switching to "Resolved" must not zero the tab badge.
        unreadCount = joined.filter { it.item.state.isOpen }.unreadCountForInbox(nowEpoch),
        attentionCount = joined.filter { it.item.state.isOpen }.attentionCountForInbox(nowEpoch),
    )
}

// ── Value coercion ───────────────────────────────────────────────────────────

/**
 * Firestore hands back `Timestamp`, a local encode hands back `Date`, and the
 * ISO-8601 strings inside the sealed payload arrive as `String`. All three are
 * accepted so the same helper reads a live document and a test fixture.
 */
internal fun epochMillis(raw: Any?): Long? = when (raw) {
    is com.google.firebase.Timestamp -> raw.toDate().time
    is java.util.Date -> raw.time
    is Number -> raw.toLong().let { if (it < EPOCH_SECONDS_CUTOFF) it * 1000L else it }
    is String -> runCatching { java.time.Instant.parse(raw.trim()).toEpochMilli() }.getOrNull()
    else -> null
}

internal fun intValue(raw: Any?): Int? = when (raw) {
    is Int -> raw
    is Number -> raw.toInt()
    is String -> raw.toIntOrNull()
    else -> null
}

private fun startOfDayEpoch(nowEpoch: Long, timeZone: TimeZone): Long {
    val calendar = Calendar.getInstance(timeZone)
    calendar.timeInMillis = nowEpoch
    calendar.set(Calendar.HOUR_OF_DAY, 0)
    calendar.set(Calendar.MINUTE, 0)
    calendar.set(Calendar.SECOND, 0)
    calendar.set(Calendar.MILLISECOND, 0)
    return calendar.timeInMillis
}

// ── Sealed → in-app mapping ──────────────────────────────────────────────────

private fun AIInboxSealedItemPayload.toItemPayload(): AIInboxItemPayload = AIInboxItemPayload(
    version = version,
    // An evidence entry with an unrecognised kind is dropped rather than
    // coerced: a mislabelled citation would misinform the "why we believe it"
    // section, which is the one part of the item that must not lie.
    evidence =
    evidence.mapNotNull { raw ->
        val kind = AIInboxEvidenceKind.fromToken(raw.kind) ?: return@mapNotNull null
        AIInboxEvidence(
            id = raw.id.ifBlank { raw.label },
            kind = kind,
            label = raw.label,
            detail = raw.detail?.ifBlank { null },
            url = raw.url?.ifBlank { null },
            occurredAtEpoch = raw.occurredAt?.let(::epochMillis),
        )
    },
    memoryCandidates =
    memoryCandidates.map { raw ->
        AIInboxMemoryCandidate(
            id = raw.id,
            text = raw.text,
            kind = raw.kind,
            confidence = raw.confidence,
            citationConversationIDs = raw.citationConversationIDs,
        )
    },
    actions =
    actions.mapNotNull { raw ->
        val kind = AIInboxActionKind.fromToken(raw.kind) ?: return@mapNotNull null
        AIInboxAction(
            id = raw.id.ifBlank { raw.title },
            kind = kind,
            title = raw.title,
            value = raw.value,
            isPrimary = raw.isPrimary,
        )
    },
    metrics = metrics,
    verification =
    verification?.let { raw ->
        AIInboxVerification(
            verdict = AIInboxVerdict.fromToken(raw.verdict) ?: AIInboxVerdict.UNVERIFIED,
            reason = raw.reason?.ifBlank { null },
            checkedAtEpoch = raw.checkedAt?.let(::epochMillis),
            verifierModel = raw.verifierModel?.ifBlank { null },
        )
    },
)
