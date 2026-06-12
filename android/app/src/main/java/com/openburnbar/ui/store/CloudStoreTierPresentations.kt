// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.store

import com.openburnbar.R

internal fun cloudTierPresentation(): TierPlanPresentation =
    TierPlanPresentation(
        label = "Cloud",
        title = "BurnBar Cloud",
        summary = "Sync your quota, encrypted history, and agent memory across devices.",
        drawableRes = R.drawable.cloud_tier_crest,
        accent = CloudStorePal.ember,
        featureChips = listOf("Quota sync", "History", "Memory"),
        holo = TierHolo.CLOUD,
    )

internal fun cloudProTierPresentation(): TierPlanPresentation =
    TierPlanPresentation(
        label = "Cloud Pro",
        title = "BurnBar Cloud Pro",
        summary = "Use your Mac from your phone and let agents work under your grant.",
        drawableRes = R.drawable.cloud_tier_crest_pro,
        accent = CloudStorePal.whimsy,
        featureChips = listOf("Floo", "Agent Control", "Relay"),
        featured = true,
        holo = TierHolo.PRO,
    )

internal fun cloudUltraTierPresentation(): TierPlanPresentation =
    TierPlanPresentation(
        label = "Cloud Ultra",
        title = "BurnBar Cloud Ultra",
        summary = "Everything in Cloud Pro, plus 10× agent memory — sealed on-device.",
        drawableRes = R.drawable.cloud_tier_crest_ultra,
        accent = CloudStorePal.aureate,
        featureChips = listOf("10× memory", "Sealed", "Pro relay"),
        holo = TierHolo.ULTRA,
    )
