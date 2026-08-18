// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.inbox

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.InboxPendingItem
import com.openburnbar.data.inbox.AIInboxFilter
import com.openburnbar.data.inbox.AIInboxRefreshParts
import com.openburnbar.data.inbox.AIInboxRow
import com.openburnbar.data.inbox.AIInboxStore
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

// MARK: - AI Inbox screen (Android)
//
// What the Mac's daemon noticed while nobody was watching, read on a phone. The
// list is the whole surface on a handset and the left column of a split on a
// tablet, matching `HermesSquareSplitLayout`'s 720dp threshold so the two
// list/detail surfaces in the product behave identically.

private const val SPLIT_WIDTH_THRESHOLD_DP = 720

@Composable
fun InboxScreen(store: AIInboxStore = viewModel(), onOpenRoute: (String) -> Unit = {}, modifier: Modifier = Modifier) {
    DisposableEffect(store) {
        store.startListening()
        onDispose { store.stopListening() }
    }

    val parts by store.parts.collectAsState()
    val filter by store.filter.collectAsState()
    val selectedID by store.selectedID.collectAsState()
    val isLoading by store.isLoading.collectAsState()
    val hasLoadedOnce by store.hasLoadedOnce.collectAsState()
    val isVaultReady by store.isVaultReady.collectAsState()
    val error by store.error.collectAsState()
    val nowEpoch = System.currentTimeMillis()

    // Open the item a `burnbar://inbox/<id>` push asked for.
    //
    // MainActivity parses the link and stashes the id rather than navigating,
    // because on a cold start the Activity routes the intent long before this
    // composable exists and long before the store's first Firestore snapshot
    // lands.
    //
    // Both the stash and the row set are keys, because either can arrive last: a
    // warm-start push updates the stash against rows already loaded, while a
    // cold start loads rows against a stash already set. Claiming before the row
    // exists would select an id the store cannot resolve, which `recompute` then
    // reconciles away — dropping the user on the list with no sign of what
    // interrupted them. The push only fires for a newly-created P1, which is
    // always in the default ACTIVE slice, so the visible rows are the right
    // place to look.
    val pendingItemID by InboxPendingItem.pending.collectAsState()
    LaunchedEffect(pendingItemID) {
        val pending = pendingItemID ?: return@LaunchedEffect
        store.focus(pending)
        InboxPendingItem.claim()
    }

    val isWide = LocalConfiguration.current.screenWidthDp >= SPLIT_WIDTH_THRESHOLD_DP
    val selectedRow = parts.rows.firstOrNull { it.id == selectedID }
    val listState =
        InboxListPaneState(
            parts = parts,
            filter = filter,
            // On a handset the detail replaces the list, so a persistent
            // selection highlight there would mark a row nobody can see.
            selectedID = if (isWide) selectedID else null,
            isLoading = isLoading,
            hasLoadedOnce = hasLoadedOnce,
            isVaultReady = isVaultReady,
            error = error,
            nowEpoch = nowEpoch,
        )

    if (isWide) {
        InboxSplitLayout(
            listState = listState,
            selectedRow = selectedRow,
            store = store,
            onOpenRoute = onOpenRoute,
            modifier = modifier,
        )
        return
    }

    if (selectedRow != null) {
        // System Back clears the selection, returning to the list.
        BackHandler { store.select(null) }
        InboxDetail(
            row = selectedRow,
            nowEpoch = nowEpoch,
            callbacks = inboxDetailCallbacks(store, selectedRow, onOpenRoute),
            modifier = modifier,
        )
        return
    }
    InboxListPane(state = listState, store = store, modifier = modifier)
}

@Composable
private fun InboxSplitLayout(
    listState: InboxListPaneState,
    selectedRow: AIInboxRow?,
    store: AIInboxStore,
    onOpenRoute: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier.fillMaxSize()) {
        InboxListPane(state = listState, store = store, modifier = Modifier.weight(0.42f).fillMaxHeight())
        VerticalDivider(
            color = MaterialTheme.colorScheme.outline.copy(alpha = 0.20f),
            modifier = Modifier.width(1.dp).fillMaxHeight(),
        )
        Box(modifier = Modifier.weight(0.58f).fillMaxHeight()) {
            if (selectedRow == null) {
                InboxPlaceholder("Pick an item on the left to read it.")
            } else {
                InboxDetail(
                    row = selectedRow,
                    nowEpoch = listState.nowEpoch,
                    callbacks = inboxDetailCallbacks(store, selectedRow, onOpenRoute),
                )
            }
        }
    }
}

private fun inboxDetailCallbacks(store: AIInboxStore, row: AIInboxRow, onOpenRoute: (String) -> Unit) = InboxDetailCallbacks(
    onArchive = { store.setArchived(row.id, !row.isArchived) },
    onSnooze = { interval -> store.snooze(row.id, interval) },
    onFeedback = { value -> store.setFeedback(row.id, value) },
    onOpenRoute = onOpenRoute,
)

internal data class InboxListPaneState(
    val parts: AIInboxRefreshParts,
    val filter: AIInboxFilter,
    val selectedID: String?,
    val isLoading: Boolean,
    val hasLoadedOnce: Boolean,
    val isVaultReady: Boolean,
    val error: String?,
    val nowEpoch: Long,
)

@Composable
private fun InboxListPane(state: InboxListPaneState, store: AIInboxStore, modifier: Modifier = Modifier) {
    Column(modifier = modifier.fillMaxSize()) {
        InboxHeader(
            unreadCount = state.parts.unreadCount,
            attentionCount = state.parts.attentionCount,
            onMarkAllRead = store::markEverythingRead,
        )
        InboxFilterBar(selected = state.filter, onSelect = store::setFilter)
        if (state.isLoading && !state.hasLoadedOnce) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        state.error?.let { InboxNotice(icon = Icons.Filled.CloudOff, message = it) }
        if (!state.isVaultReady) {
            InboxNotice(
                icon = Icons.Filled.CloudOff,
                message =
                "This device cannot open your inbox yet. Approve it from your Mac or iPhone to unlock the " +
                    "Cloud Vault key — until then, sealed items stay hidden rather than showing blank.",
            )
        }

        if (state.parts.sections.isEmpty()) {
            InboxEmptyState(filter = state.filter, hasLoadedOnce = state.hasLoadedOnce, hasError = state.error != null)
            return@Column
        }

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = AuroraSpacing.XXL.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            for (group in state.parts.sections) {
                item(key = "section-${group.section.name}") {
                    InboxSectionHeader(title = group.section.title, count = group.rows.size)
                }
                items(items = group.rows, key = { it.id }) { row ->
                    InboxRow(
                        row = row,
                        isSelected = row.id == state.selectedID,
                        nowEpoch = state.nowEpoch,
                        onClick = { store.select(row.id) },
                    )
                }
            }
        }
    }
}

@Composable
private fun InboxHeader(unreadCount: Int, attentionCount: Int, onMarkAllRead: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
    ) {
        Text("Inbox", style = AuroraType.title, color = MaterialTheme.colorScheme.onSurface)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        if (attentionCount > 0) {
            AuroraBadge(text = "$attentionCount needs attention", tone = AuroraBadgeTone.Warning)
        }
        Spacer(modifier = Modifier.weight(1f))
        if (unreadCount > 0) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier =
                Modifier
                    .clickable(onClick = onMarkAllRead)
                    .padding(AuroraSpacing.XS.dp)
                    .semantics { contentDescription = "Mark all $unreadCount unread items read" },
            ) {
                Icon(
                    imageVector = Icons.Filled.DoneAll,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(15.dp),
                )
                Spacer(modifier = Modifier.width(AuroraSpacing.XS.dp))
                Text("$unreadCount unread", style = AuroraType.tiny, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun InboxFilterBar(selected: AIInboxFilter, onSelect: (AIInboxFilter) -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.XS.dp),
    ) {
        for (filter in AIInboxFilter.entries) {
            val isSelected = filter == selected
            Text(
                text = filter.title,
                style = AuroraType.caption,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                color = if (isSelected) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier =
                Modifier
                    .background(
                        if (isSelected) AuroraColors.ember.copy(alpha = 0.14f) else androidx.compose.ui.graphics.Color.Transparent,
                        RoundedCornerShape(AuroraRadius.FULL.dp),
                    )
                    .clickable { onSelect(filter) }
                    .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.XS.dp),
            )
        }
    }
}

@Composable
private fun InboxNotice(icon: androidx.compose.ui.graphics.vector.ImageVector, message: String) {
    Row(
        verticalAlignment = Alignment.Top,
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.XS.dp)
            .background(AuroraColors.warning.copy(alpha = 0.10f), RoundedCornerShape(AuroraRadius.SM.dp))
            .padding(AuroraSpacing.SM.dp),
    ) {
        Icon(imageVector = icon, contentDescription = null, tint = AuroraColors.warning, modifier = Modifier.size(14.dp))
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Text(message, style = AuroraType.tiny, color = MaterialTheme.colorScheme.onSurface)
    }
}

/**
 * Empty copy that tells the truth about *which* empty this is: an inbox that has
 * never produced anything needs different words from one the user has cleared.
 */
@Composable
private fun InboxEmptyState(filter: AIInboxFilter, hasLoadedOnce: Boolean, hasError: Boolean) {
    val message =
        when {
            // The error banner above already says what went wrong; repeating
            // "Loading…" underneath it would contradict it.
            hasError -> "Nothing to show while that is unresolved."
            !hasLoadedOnce -> "Loading what your Mac noticed…"
            filter == AIInboxFilter.ATTENTION -> "Nothing urgent. The quieter items are under Active."
            filter == AIInboxFilter.RESOLVED -> "Nothing has been resolved yet."
            filter == AIInboxFilter.ARCHIVED -> "You have not archived anything."
            else ->
                "Nothing is waiting for you. The inbox fills up when your Mac's daemon notices something worth " +
                    "your attention — it only runs while OpenBurnBar is running there."
        }
    InboxPlaceholder(message)
}

@Composable
private fun InboxPlaceholder(message: String) {
    Column(
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxSize().padding(AuroraSpacing.XL.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.Inbox,
            contentDescription = null,
            tint = AuroraColors.whimsy.copy(alpha = 0.5f),
            modifier = Modifier.size(40.dp),
        )
        Spacer(modifier = Modifier.size(AuroraSpacing.MD.dp))
        Text(
            message,
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}
