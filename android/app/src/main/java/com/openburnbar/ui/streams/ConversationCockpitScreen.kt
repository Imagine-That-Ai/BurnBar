@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.ConversationCockpitStore
import com.openburnbar.ui.pro.LockedFeatureVeil

// ── Conversation Cockpit ──
//
// Transforms Streams into a faceted database over every backed-up agent
// conversation. KPI header (server aggregates) → facet bar (providers, model,
// sort, saved queries) → dense decrypted result list → full-transcript reader.
// Gated behind Cloud entitlement with a teaser veil for free users so the value
// is visible before purchase. Mirrors the iOS cockpit in StreamsView.swift.

@Composable
fun ConversationCockpitSection(
    isEntitled: Boolean,
    onOpenCloudStore: () -> Unit,
    modifier: Modifier = Modifier,
    store: ConversationCockpitStore = viewModel(),
) {
    if (!isEntitled) {
        Box(modifier = modifier.fillMaxSize()) {
            LockedFeatureVeil(
                headline = "Every conversation, queryable.",
                detail =
                "A private cockpit over every Codex, Claude, Droid, and CLI-agent session — " +
                    "faceted search, cost and token rollups, and full encrypted transcripts. " +
                    "Included with OpenBurnBar Cloud.",
                onCta = onOpenCloudStore,
                ctaLabel = "Open Cloud",
            ) {
                CockpitTeaserBackground()
            }
        }
        return
    }
    EntitledCockpit(store = store, modifier = modifier)
}
