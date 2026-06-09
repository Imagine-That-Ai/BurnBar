package com.openburnbar.ui.pro

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.SyncAlt
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.ui.graphics.vector.ImageVector
import com.openburnbar.R

// ── Feature Gating & Evocative Upsell — Android shared foundation ──
//
// Canonical spec: docs/FEATURE_GATING_SPEC.md
//
// This is the PARALLEL Kotlin catalog (iOS/macOS share a Swift catalog in
// OpenBurnBarCore/Sources/OpenBurnBarCore/Membership/GatedFeature.swift). Both
// catalogs carry IDENTICAL copy — keep them in sync with §3 of the spec.
//
// Copy below is VERBATIM from spec §3 and is honesty-checked:
//   • "Agent Control" — never "Computer Use" in user copy.
//   • The cloak is NOT described as "inversion-proof" / "fully unlinkable".
//   • Chat / agent memory is NEVER called "end-to-end encrypted" — agent
//     memory is "sealed on-device; search runs over encrypted structures
//     (some access patterns stay visible)". The bare "server can't read it"
//     claim is banned by the honesty gate.
//     The only feature that legitimately claims E2E is Floo (paired devices).

/**
 * The unified subscription-tier ladder. `Ultra ⊇ Pro ⊇ Cloud`: a user entitled
 * at a higher tier passes every lower-tier gate. The Android tier is derived
 * from [com.openburnbar.data.stores.HostedQuotaSubscriptionStore.currentTier]
 * (see spec §4.2).
 */
enum class CloudTier(val rank: Int) {
    NONE(0),
    CLOUD(1),
    PRO(2),
    ULTRA(3),
    ;

    /**
     * `true` when this tier is at least [req] — i.e. it satisfies the gate.
     * Higher tiers subsume lower ones.
     */
    fun satisfies(req: CloudTier): Boolean = rank >= req.rank

    /**
     * Marketing display name for the tier ("Cloud", "Cloud Pro", "Cloud
     * Ultra"). [NONE] has no marketing surface, so it reads as an empty string —
     * callers should never present [NONE] in upsell UI.
     */
    val displayName: String
        get() =
            when (this) {
                NONE -> ""
                CLOUD -> "Cloud"
                PRO -> "Cloud Pro"
                ULTRA -> "Cloud Ultra"
            }

    /**
     * The per-tier holographic crest drawable (spec §2):
     * cloud→`cloud_tier_crest`, pro→`_pro`, ultra→`_ultra`. [NONE] falls back to
     * the base Cloud crest so the UI never renders a missing asset.
     */
    val crestDrawable: Int
        get() =
            when (this) {
                NONE, CLOUD -> R.drawable.cloud_tier_crest
                PRO -> R.drawable.cloud_tier_crest_pro
                ULTRA -> R.drawable.cloud_tier_crest_ultra
            }

    /** The per-tier iridescent holo palette (mirrors the marketing `--holo-grad`). */
    val holo: TierHoloPalette
        get() =
            when (this) {
                NONE, CLOUD -> TierHoloPalette.CLOUD
                PRO -> TierHoloPalette.PRO
                ULTRA -> TierHoloPalette.ULTRA
            }
}

/** Stable identifiers for every gated feature (analytics + cross-platform parity). */
enum class GatedFeatureID {
    CLOUD_BACKUP,
    CROSS_DEVICE_RESUME,
    CLOUD_SEARCH,
    AGENT_CONTROL,
    FLOO,
    HOSTED_MCP,
    DATA_VAULT,
    TEN_X_MEMORY,
}

/**
 * One gated feature's full presentation data, consumed by both the resting
 * [TierLockBadge] and the [LockedFeatureVeil] / [FeatureUnlockSheet] unlock
 * experiences. All copy is verbatim from spec §3.
 */
data class GatedFeature(
    /** Stable feature id. */
    val id: GatedFeatureID,
    /** The marketing-facing feature name (e.g. "Agent Control", "Floo"). */
    val publicName: String,
    /** The minimum tier that unlocks this feature. */
    val requiredTier: CloudTier,
    /** The single evocative desire line shown beneath the hero crest. */
    val oneLineBenefit: String,
    /** The 3–4 "what you'll unlock" benefit bullets. */
    val benefitBullets: List<String>,
    /** A Compose icon for the feature's glyph. */
    val imageVector: ImageVector,
) {
    /** The holographic crest drawable for the required tier (derived from §2). */
    val crestDrawable: Int get() = requiredTier.crestDrawable
}

/**
 * The shared catalog. Copy verbatim from spec §3; the crest drawable for each
 * entry is derived from its required tier so the mapping can never drift from §2.
 */
object GatedFeatureCatalog {
    /** The catalog in spec §3 order (Cloud features, then Pro, then Ultra). */
    val ordered: List<GatedFeature> =
        listOf(
            // cloudBackup — BurnBar Cloud (encrypted history + backup) — cloud
            GatedFeature(
                id = GatedFeatureID.CLOUD_BACKUP,
                publicName = "BurnBar Cloud",
                requiredTier = CloudTier.CLOUD,
                oneLineBenefit =
                    "Every agent conversation, backed up and safe — so a wiped Mac never means a lost thread.",
                benefitBullets =
                    listOf(
                        "Your whole session history rides along, encrypted, ready to pick back up the moment you sign in on any device",
                        "Hosted quota refresh keeps your five-hour and weekly windows current even when your Mac is asleep",
                        "Reinstall, switch machines, or hand off to a new laptop — your runs are already there waiting",
                        "One verified subscription lights up everything in Cloud across iPhone, iPad, and Mac",
                    ),
                imageVector = Icons.Filled.Cloud,
            ),
            // crossDeviceResume — Cross-device resume — cloud
            GatedFeature(
                id = GatedFeatureID.CROSS_DEVICE_RESUME,
                publicName = "Cross-device resume",
                requiredTier = CloudTier.CLOUD,
                oneLineBenefit =
                    "Start on your Mac, keep going on your phone — the conversation never drops the thread.",
                benefitBullets =
                    listOf(
                        "Walk away from your desk mid-run and pick the exact same conversation back up on your iPhone or iPad",
                        "No copy-paste, no re-explaining context — the agent remembers where you both left off",
                        "Your iPhone, iPad, and Mac stay in lockstep, the same backed-up history on every screen",
                    ),
                imageVector = Icons.Filled.SyncAlt,
            ),
            // cloudSearch — Cloud search — cloud
            GatedFeature(
                id = GatedFeatureID.CLOUD_SEARCH,
                publicName = "Cloud search",
                requiredTier = CloudTier.CLOUD,
                oneLineBenefit =
                    "Find that one answer from three weeks ago — searchable across every device, in seconds.",
                benefitBullets =
                    listOf(
                        "Search your entire encrypted session history from any signed-in device, not just the Mac it happened on",
                        "That fix, that command, that explanation — surface it instantly instead of scrolling forever",
                        "Your past work becomes a searchable library, everywhere you are",
                    ),
                imageVector = Icons.Filled.Search,
            ),
            // agentControl — Agent Control — cloud_pro
            GatedFeature(
                id = GatedFeatureID.AGENT_CONTROL,
                publicName = "Agent Control",
                requiredTier = CloudTier.PRO,
                oneLineBenefit =
                    "Hand off the busywork and watch an agent do it — every click in plain sight, every step under your grant.",
                benefitBullets =
                    listOf(
                        "Let an agent drive a real browser to fill the form, pull the data, click through the flow while your hands stay free",
                        "Watch every move live on your Mac or mirrored to your phone — nothing ever happens out of sight",
                        "Approve each step, or set the lines once and let it move freely inside them; mark off-limits windows it can never touch",
                        "Stop it instantly with a shortcut or a gesture, and read back a tamper-proof record of everything it did",
                    ),
                imageVector = Icons.Filled.TouchApp,
            ),
            // floo — Floo (phone ↔ Mac) — cloud_pro
            GatedFeature(
                id = GatedFeatureID.FLOO,
                publicName = "Floo",
                requiredTier = CloudTier.PRO,
                oneLineBenefit =
                    "Your Mac, in your pocket — see it, reach in, and run it from your phone, end to end private.",
                benefitBullets =
                    listOf(
                        "Open a live view of your whole desktop, or just one window, and watch a long agent run from the couch",
                        "Reach in and take over: tap, scroll, and type — touch a field and your keyboard rises and zooms right to it",
                        "Send a file, screenshot, or photo either direction in a tap; share one clipboard across both devices",
                        "Call your Mac, or unlock it with Face ID — your password sealed end to end, never in a log or a server",
                    ),
                imageVector = Icons.Filled.PhoneIphone,
            ),
            // hostedMCP — Hosted Remote MCP — cloud_pro
            GatedFeature(
                id = GatedFeatureID.HOSTED_MCP,
                publicName = "Hosted Remote MCP",
                requiredTier = CloudTier.PRO,
                oneLineBenefit =
                    "Give any agent, anywhere, a secure line into your sealed memory and tools — no Mac required.",
                benefitBullets =
                    listOf(
                        "Your hosted endpoint lets a remote agent recall your private knowledge without anything running on your Mac",
                        "The server routes tools and ranks over cloaked structures; plaintext and vault keys stay device-only, while search patterns remain visible",
                        "Always-on access from your phone, a cloud agent, or another tool — isolated to your account alone",
                    ),
                imageVector = Icons.Filled.Storage,
            ),
            // dataVault — Data Vault / agent memory — cloud_pro
            GatedFeature(
                id = GatedFeatureID.DATA_VAULT,
                publicName = "Data Vault",
                requiredTier = CloudTier.PRO,
                oneLineBenefit =
                    "A private memory your agents can recall — your repo docs, notes, and chats, sealed on your device.",
                benefitBullets =
                    listOf(
                        "Your agents quietly recall the repo docs, notes, and chat-derived memories that matter, mid-task",
                        "Every chunk of text is sealed on your device before it leaves — hosted recall searches cloaked structures, and some patterns stay visible",
                        "Nearest-neighbor recall finds candidates by meaning while exposing structural signals, not plaintext content",
                        "Sources, chunks, and storage you control, with one tap to delete any source or purge it all",
                    ),
                imageVector = Icons.Filled.Memory,
            ),
            // tenXMemory — 10× agent memory — cloud_ultra
            GatedFeature(
                id = GatedFeatureID.TEN_X_MEMORY,
                publicName = "10× agent memory",
                requiredTier = CloudTier.ULTRA,
                oneLineBenefit =
                    "Give your agents a whole second brain — 10× the private memory they can recall while they work.",
                benefitBullets =
                    listOf(
                        "Jump from 3 sources to 15, from 5,000 memory chunks to 50,000, from 25 MB to 250 MB of recallable knowledge",
                        "Feed in far more repo docs, notes, and chat memories so your agents stay deeply in context across big projects",
                        "Same on-device seal and cloaked vectors — search runs over encrypted structures (some access patterns stay visible)",
                        "Everything in Cloud Pro stays included: Floo, Agent Control, and the same hosted action and relay allowance",
                    ),
                imageVector = Icons.Filled.AutoAwesome,
            ),
        )

    /** The full catalog keyed by feature id. */
    val byID: Map<GatedFeatureID, GatedFeature> = ordered.associateBy { it.id }

    /**
     * Look up the gated feature for an id. Total over [GatedFeatureID] — every
     * case is populated in [ordered], so this never returns null.
     */
    fun feature(id: GatedFeatureID): GatedFeature =
        byID[id] ?: error("GatedFeature catalog is missing an entry for $id")
}
