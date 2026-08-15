package com.openburnbar.data.inbox

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// MARK: - AI Inbox mirror models (Android parity)
//
// The AI Inbox is produced on the Mac by the daemon and mirrored to
// `users/{uid}/ai_inbox_items/{itemId}` as a Cloud Vault sealed document. The
// premise of the surface — "tell me what happened while I wasn't watching" — is
// exactly why the transport is Firestore rather than a live relay: the moment
// the phone is reached for is the moment the Mac is most likely asleep.
//
// Routing metadata (kind / priority / state / timestamps) stays top-level so the
// list can sort, filter, and badge without a decrypt; everything that reads like
// the user's own work lives inside `sealedPayload`.
//
// Source of truth for every raw string and field name below:
//   OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AIInboxMirrorRecord.swift
//   OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarAIInboxContracts.swift

/** Item taxonomy. Raw values are persisted on both ends, so cases are append-only. */
enum class AIInboxItemKind(val token: String) {
    CI_WASTE("ci_waste"),
    PROMISED_NOT_LANDED("promised_not_landed"),
    UNCOMMITTED_WORK("uncommitted_work"),
    COST_ANOMALY("cost_anomaly"),
    STUCK_PR("stuck_pr"),
    INDEX_HEALTH("index_health"),
    BRIEF("brief"),
    BUDGET("budget"),
    SYSTEM("system"),
    ;

    /** `brief` and `system` are narration; everything else asserts a problem. */
    val isAlert: Boolean get() = this != BRIEF && this != SYSTEM

    companion object {
        fun fromToken(value: String?): AIInboxItemKind? = entries.firstOrNull { it.token == value }
    }
}

/**
 * Lifecycle of an item. `NEW` and `UPDATED` are the open states — exactly one
 * open item exists per fingerprint on the Mac, so a recurring condition updates
 * in place instead of flooding the list.
 */
enum class AIInboxItemState(val token: String) {
    NEW("new"),
    UPDATED("updated"),
    RESOLVED("resolved"),
    EXPIRED("expired"),
    ;

    val isOpen: Boolean get() = this == NEW || this == UPDATED

    companion object {
        val openStates: List<AIInboxItemState> = listOf(NEW, UPDATED)

        fun fromToken(value: String?): AIInboxItemState? = entries.firstOrNull { it.token == value }
    }
}

/**
 * Priority band. P1 is the "you would want to be interrupted for this" tier and
 * is the only band permitted to raise a notification.
 */
enum class AIInboxPriority(val rank: Int) {
    P1(1),
    P2(2),
    P3(3),
    P4(4),
    ;

    companion object {
        /** Used when the field is absent or unparseable — "worth knowing". */
        private val FALLBACK = P3

        /** Clamps out-of-range values the way the Swift `init(clamping:)` does. */
        fun clamping(raw: Int?): AIInboxPriority {
            val bounded = (raw ?: FALLBACK.rank).coerceIn(P1.rank, P4.rank)
            return entries.first { it.rank == bounded }
        }
    }
}

/**
 * A single citation backing an item. Evidence is reference-shaped by design: the
 * inbox points at truth rather than copying it, so a row can deep-link and the
 * payload stays small enough to seal cheaply.
 */
enum class AIInboxEvidenceKind(val token: String) {
    CONVERSATION("conversation"),
    PULL_REQUEST("pull_request"),
    ISSUE("issue"),
    WORKFLOW_RUN("workflow_run"),
    COMMIT("commit"),
    FILE("file"),
    USAGE("usage"),
    METRIC("metric"),
    ;

    companion object {
        fun fromToken(value: String?): AIInboxEvidenceKind? = entries.firstOrNull { it.token == value }
    }
}

/** A suggested next step. Declarative so each platform decides how to render it. */
enum class AIInboxActionKind(val token: String) {
    OPEN_URL("open_url"),
    RESUME_CONVERSATION("resume_conversation"),
    OPEN_SESSION_LOG("open_session_log"),
    OPEN_PROJECT("open_project"),
    OPEN_SETTINGS("open_settings"),
    RUN_COMMAND("run_command"),
    ;

    companion object {
        fun fromToken(value: String?): AIInboxActionKind? = entries.firstOrNull { it.token == value }
    }
}

/**
 * Outcome of the adversarial verification pass. `UNVERIFIED` means no verifier
 * was reachable — surfaced honestly rather than silently implied.
 */
enum class AIInboxVerdict(val token: String) {
    CONFIRMED("confirmed"),
    REFUTED("refuted"),
    UNCLEAR("unclear"),
    UNVERIFIED("unverified"),
    DETERMINISTIC("deterministic"),
    ;

    companion object {
        fun fromToken(value: String?): AIInboxVerdict? = entries.firstOrNull { it.token == value }
    }
}

// ── Sealed payload wire shape ────────────────────────────────────────────────
//
// `@Serializable` mirrors of the Swift Codables the Mac seals. Property names
// are pinned to the Swift names so the JSON round-trips byte-for-byte; dates
// arrive as ISO-8601 strings (Swift `.iso8601` strategy) and are kept as
// `String` here, converted to epoch millis on the way into the in-app model so
// no kotlinx date serializer is needed and fractional seconds stay tolerated.

@Serializable
internal data class AIInboxSealedPayload(
    val title: String = "",
    val summaryMarkdown: String = "",
    val projectName: String? = null,
    val resolutionNote: String? = null,
    val payload: AIInboxSealedItemPayload = AIInboxSealedItemPayload(),
)

@Serializable
internal data class AIInboxSealedItemPayload(
    val version: Int = 1,
    val evidence: List<AIInboxSealedEvidence> = emptyList(),
    val memoryCandidates: List<AIInboxSealedMemoryCandidate> = emptyList(),
    val actions: List<AIInboxSealedAction> = emptyList(),
    val metrics: Map<String, String> = emptyMap(),
    val verification: AIInboxSealedVerification? = null,
)

@Serializable
internal data class AIInboxSealedEvidence(
    val id: String = "",
    val kind: String = "metric",
    val label: String = "",
    val detail: String? = null,
    val url: String? = null,
    val occurredAt: String? = null,
)

@Serializable
internal data class AIInboxSealedMemoryCandidate(
    val id: String = "",
    val text: String = "",
    val kind: String = "",
    val confidence: Double = 0.0,
    val citationConversationIDs: List<String> = emptyList(),
)

@Serializable
internal data class AIInboxSealedAction(
    val id: String = "",
    val kind: String = "open_url",
    val title: String = "",
    val value: String = "",
    val isPrimary: Boolean = false,
)

@Serializable
internal data class AIInboxSealedVerification(
    val verdict: String = "unverified",
    val reason: String? = null,
    @SerialName("checkedAt") val checkedAt: String? = null,
    val verifierModel: String? = null,
)

/**
 * Shared decoder for the sealed inbox payload. `ignoreUnknownKeys` keeps Android
 * forward-tolerant when the Mac writer ships a new field first; `isLenient`
 * tolerates the wire shape `JSONEncoder` produces.
 */
internal val aiInboxSealedJson: Json =
    Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

// ── In-app model ─────────────────────────────────────────────────────────────

/** One citation, resolved into the shape the UI renders. */
data class AIInboxEvidence(
    val id: String,
    val kind: AIInboxEvidenceKind,
    val label: String,
    val detail: String? = null,
    val url: String? = null,
    val occurredAtEpoch: Long? = null,
)

/**
 * A durable fact the inbox believes is worth remembering. It is a proposal:
 * approval runs through the Mac's memory quarantine flow, so Android renders
 * these read-only.
 */
data class AIInboxMemoryCandidate(
    val id: String,
    val text: String,
    val kind: String,
    val confidence: Double,
    val citationConversationIDs: List<String> = emptyList(),
)

/** A suggested next step, resolved into the shape the UI renders. */
data class AIInboxAction(
    val id: String,
    val kind: AIInboxActionKind,
    val title: String,
    val value: String,
    val isPrimary: Boolean = false,
)

/** Verifier outcome for one item. */
data class AIInboxVerification(
    val verdict: AIInboxVerdict,
    val reason: String? = null,
    val checkedAtEpoch: Long? = null,
    val verifierModel: String? = null,
)

/** The structured body of an item. */
data class AIInboxItemPayload(
    val version: Int = 1,
    val evidence: List<AIInboxEvidence> = emptyList(),
    val memoryCandidates: List<AIInboxMemoryCandidate> = emptyList(),
    val actions: List<AIInboxAction> = emptyList(),
    val metrics: Map<String, String> = emptyMap(),
    val verification: AIInboxVerification? = null,
)

/**
 * One mirrored inbox item, as it exists on the phone: top-level routing fields
 * plus the opened sealed content.
 *
 * A partially-decoded item is never constructed — if the seal cannot be opened
 * the row is dropped, because a blank-bodied inbox row is worse than an absent
 * one.
 */
data class AIInboxItem(
    val id: String,
    val fingerprint: String,
    val kind: AIInboxItemKind,
    val priority: AIInboxPriority,
    val state: AIInboxItemState,
    val occurrenceCount: Int = 1,
    val firstSeenAtEpoch: Long,
    val lastSeenAtEpoch: Long,
    val resolvedAtEpoch: Long? = null,
    val modelProvenance: String = "local-rules",
    val hasMemoryCandidates: Boolean = false,
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val title: String,
    val summaryMarkdown: String = "",
    val projectName: String? = null,
    val resolutionNote: String? = null,
    val payload: AIInboxItemPayload = AIInboxItemPayload(),
) {
    val isOpen: Boolean get() = state.isOpen

    val searchableText: String =
        listOf(title, summaryMarkdown, projectName.orEmpty(), kind.token).joinToString(" ")

    companion object {
        /**
         * Bumped when the mirror shape changes in a way older clients cannot
         * read. A document stamped from the future is refused outright.
         */
        const val CURRENT_SCHEMA_VERSION = 1
    }
}

/**
 * Per-item user intent, written by whichever device the user acted on.
 *
 * Kept in a sibling collection because the item is Mac-owned while the state is
 * user-owned — the same split the Mac's local schema uses. Any device may write
 * it; last writer wins.
 *
 * Named `…UserState` rather than mirroring Swift's `AIInboxMirrorItemState`
 * because [AIInboxItemState] is already taken by the item's *lifecycle* enum;
 * the two are genuinely different axes and collapsing the names would invite
 * exactly the mixup this comment prevents.
 */
data class AIInboxItemUserState(
    val id: String,
    val readAtEpoch: Long? = null,
    val archivedAtEpoch: Long? = null,
    val snoozedUntilEpoch: Long? = null,
    val feedback: String? = null,
    val updatedAtEpoch: Long = 0L,
    val updatedByDeviceID: String? = null,
) {
    fun isSuppressed(nowEpoch: Long): Boolean {
        if (archivedAtEpoch != null) return true
        val snoozed = snoozedUntilEpoch ?: return false
        return snoozed > nowEpoch
    }

    val isUnread: Boolean get() = readAtEpoch == null
}

/** Collection names and field allowlists, pinned to `AIInboxMirrorCodec`. */
object AIInboxMirrorCodec {
    const val COLLECTION = "ai_inbox_items"
    const val STATE_COLLECTION = "ai_inbox_item_state"
    const val SEALED_PAYLOAD_FIELD = "sealedPayload"

    /** Feedback values the Firestore rules accept; anything else is dropped. */
    val ALLOWED_FEEDBACK_VALUES: Set<String> = setOf("useful", "not_useful", "wrong")
}
