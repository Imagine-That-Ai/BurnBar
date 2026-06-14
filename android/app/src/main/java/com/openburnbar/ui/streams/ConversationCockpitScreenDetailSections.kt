// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.streams

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DateRangePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDateRangePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.CockpitConversationRow
import com.openburnbar.data.stores.ConversationCockpitStore
import com.openburnbar.ui.components.ErrorStateView
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.util.Formatting
import kotlinx.coroutines.launch

internal data class EntitledCockpitOverlaySheetState(
    val selectedRow: CockpitConversationRow?,
    val showFilters: Boolean,
    val showSaveQuery: Boolean,
    val dateFrom: Long?,
    val dateTo: Long?,
)

internal data class EntitledCockpitOverlaySheetCallbacks(
    val onDismissRow: () -> Unit,
    val onDismissFilters: () -> Unit,
    val onDismissSaveQuery: () -> Unit,
)

@Composable
internal fun EntitledCockpitOverlays(
    store: ConversationCockpitStore,
    sheetState: EntitledCockpitOverlaySheetState,
    callbacks: EntitledCockpitOverlaySheetCallbacks,
) {
    sheetState.selectedRow?.let { row ->
        CockpitConversationDetailSheet(store = store, row = row, onDismiss = callbacks.onDismissRow)
    }
    if (sheetState.showFilters) {
        CockpitFilterSheet(
            dateFrom = sheetState.dateFrom,
            dateTo = sheetState.dateTo,
            onApply = { from, to ->
                store.filters.setDateRange(from, to)
                callbacks.onDismissFilters()
            },
            onReset = {
                store.filters.clearFilters()
                callbacks.onDismissFilters()
            },
            onDismiss = callbacks.onDismissFilters,
        )
    }
    if (sheetState.showSaveQuery) {
        CockpitSaveQueryDialog(
            onSave = { store.filters.saveCurrentQuery(it) },
            onDismiss = callbacks.onDismissSaveQuery,
        )
    }
}

@Composable
internal fun CockpitPaginatingIndicator() {
    Box(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(
            color = AuroraColors.ember,
            strokeWidth = 2.dp,
            modifier = Modifier.size(22.dp),
        )
    }
}

// ── Detail sheet ──

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CockpitConversationDetailSheet(store: ConversationCockpitStore, row: CockpitConversationRow, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var transcript by remember(row.id) { mutableStateOf<String?>(null) }
    var loadError by remember(row.id) { mutableStateOf<String?>(null) }
    var isLoading by remember(row.id) { mutableStateOf(true) }

    LaunchedEffect(row.id) {
        isLoading = true
        loadError = null
        try {
            transcript = store.queries.loadTranscript(row)
        } catch (e: IllegalStateException) {
            loadError = e.localizedMessage ?: "Could not open transcript."
        } finally {
            isLoading = false
        }
    }

    val retryLoad: () -> Unit = {
        scope.launch {
            isLoading = true
            loadError = null
            try {
                transcript = store.queries.loadTranscript(row)
            } catch (e: IllegalStateException) {
                loadError = e.localizedMessage ?: "Could not open transcript."
            } finally {
                isLoading = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        CockpitDetailSheetBody(
            row = row,
            transcript = transcript,
            isLoading = isLoading,
            loadError = loadError,
            onRetry = retryLoad,
        )
    }
}

@Composable
private fun CockpitDetailSheetBody(row: CockpitConversationRow, transcript: String?, isLoading: Boolean, loadError: String?, onRetry: () -> Unit) {
    val context = LocalContext.current
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.LG.dp)
            .padding(bottom = AuroraSpacing.XL.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        CockpitDetailSheetHeader(row = row, transcript = transcript, context = context)
        Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
        CockpitDetailFacetsGrid(row = row)
        HorizontalDivider(modifier = Modifier.padding(vertical = AuroraSpacing.SM.dp))
        CockpitDetailTranscriptSection(
            row = row,
            transcript = transcript,
            isLoading = isLoading,
            loadError = loadError,
            onRetry = onRetry,
        )
    }
}

@Composable
private fun CockpitDetailSheetHeader(row: CockpitConversationRow, transcript: String?, context: android.content.Context) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        row.providerEnum?.let { ProviderAvatar(providerKey = it.key, size = 40) }
        Column(modifier = Modifier.weight(1f)) {
            Text(row.displayTitle, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        }
        transcript?.takeIf { it.isNotBlank() }?.let { body ->
            IconButton(onClick = {
                val intent =
                    Intent(Intent.ACTION_SEND).apply {
                        type = "text/markdown"
                        putExtra(Intent.EXTRA_TEXT, cockpitBuildShareMarkdown(row, body))
                        putExtra(Intent.EXTRA_SUBJECT, row.displayTitle)
                    }
                context.startActivity(Intent.createChooser(intent, "Share conversation"))
            }) {
                Icon(Icons.Filled.Share, contentDescription = "Share transcript")
            }
        }
    }
}

@Composable
private fun CockpitDetailFacetsGrid(row: CockpitConversationRow) {
    val facets = cockpitDetailFacets(row)
    facets.chunked(2).forEach { pair ->
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp), modifier = Modifier.padding(bottom = AuroraSpacing.SM.dp)) {
            pair.forEach { (title, value) ->
                CockpitFacetCell(title = title, value = value, modifier = Modifier.weight(1f))
            }
            if (pair.size == 1) Spacer(modifier = Modifier.weight(1f))
        }
    }
}

private fun cockpitDetailFacets(row: CockpitConversationRow): List<Pair<String, String>> = buildList {
    add("Cost" to Formatting.formatCurrency(row.costUSD))
    add("Tokens" to Formatting.formatTokens(row.totalTokens.toLong()))
    if (row.inputTokens > 0 || row.outputTokens > 0) {
        add("In · Out" to "${Formatting.formatTokens(row.inputTokens.toLong())} · ${Formatting.formatTokens(row.outputTokens.toLong())}")
    }
    if (row.messageCount > 0) add("Messages" to row.messageCount.toString())
    row.model?.takeIf { it.isNotBlank() }?.let { add("Model" to it) }
    row.durationSeconds?.takeIf { it > 0 }?.let { add("Duration" to cockpitFormatDuration(it)) }
    (row.startTimeMs ?: row.updatedAtMs)?.takeIf { it > 0 }?.let { add("Started" to Formatting.formatRelativeTime(it)) }
    row.sourceType?.takeIf { it.isNotBlank() }?.let { add("Source" to it.replaceFirstChar { c -> c.uppercase() }) }
}

@Composable
private fun CockpitDetailTranscriptSection(row: CockpitConversationRow, transcript: String?, isLoading: Boolean, loadError: String?, onRetry: () -> Unit) {
    when {
        isLoading -> {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
                modifier = Modifier.padding(vertical = AuroraSpacing.LG.dp),
            ) {
                CircularProgressIndicator(color = AuroraColors.ember, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                Text("Opening encrypted transcript…", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        loadError != null -> {
            ErrorStateView(
                icon = Icons.Filled.LockOpen,
                title = "Could not open transcript",
                message = loadError ?: "",
                onRetry = onRetry,
            )
        }
        !transcript.isNullOrBlank() -> {
            SelectionContainer {
                Text(
                    transcript!!,
                    fontSize = 12.sp,
                    lineHeight = 17.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        else -> {
            Text(
                row.preview ?: "No transcript available.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun CockpitFacetCell(title: String, value: String, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        modifier =
        modifier
            .clip(RoundedCornerShape(AuroraRadius.MD.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.55f))
            .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f), RoundedCornerShape(AuroraRadius.MD.dp))
            .padding(10.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text(
                value,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// ── Filter sheet ──

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CockpitFilterSheet(dateFrom: Long?, dateTo: Long?, onApply: (Long?, Long?) -> Unit, onReset: () -> Unit, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var fromDraft by remember { mutableStateOf(dateFrom) }
    var toDraft by remember { mutableStateOf(dateTo) }
    var showRangePicker by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        CockpitFilterSheetForm(
            state =
            CockpitFilterSheetFormState(
                fromDraft = fromDraft,
                toDraft = toDraft,
            ),
            callbacks =
            CockpitFilterSheetFormCallbacks(
                onOpenRangePicker = { showRangePicker = true },
                onClearRange = {
                    fromDraft = null
                    toDraft = null
                },
                onReset = onReset,
                onApply = { onApply(fromDraft, toDraft) },
            ),
        )
    }

    if (showRangePicker) {
        CockpitFilterDateRangePicker(
            fromDraft = fromDraft,
            toDraft = toDraft,
            onDismiss = { showRangePicker = false },
            onConfirm = { from, to ->
                fromDraft = from
                toDraft = to
                showRangePicker = false
            },
        )
    }
}

private data class CockpitFilterSheetFormState(
    val fromDraft: Long?,
    val toDraft: Long?,
)

private data class CockpitFilterSheetFormCallbacks(
    val onOpenRangePicker: () -> Unit,
    val onClearRange: () -> Unit,
    val onReset: () -> Unit,
    val onApply: () -> Unit,
)

@Composable
private fun CockpitFilterSheetForm(state: CockpitFilterSheetFormState, callbacks: CockpitFilterSheetFormCallbacks) {
    val fromDraft = state.fromDraft
    val toDraft = state.toDraft
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = AuroraSpacing.LG.dp)
            .padding(bottom = AuroraSpacing.XL.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        Text("Cockpit Filters", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
        CockpitFilterDateRangeRow(
            fromDraft = fromDraft,
            toDraft = toDraft,
            onOpenRangePicker = callbacks.onOpenRangePicker,
            onClearRange = callbacks.onClearRange,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = callbacks.onReset, modifier = Modifier.weight(1f)) { Text("Reset") }
            Button(
                onClick = callbacks.onApply,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
            ) { Text("Apply") }
        }
    }
}

@Composable
private fun CockpitFilterDateRangeRow(fromDraft: Long?, toDraft: Long?, onOpenRangePicker: () -> Unit, onClearRange: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Start date range", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Text(
                if (fromDraft != null || toDraft != null) {
                    "${fromDraft?.let { Formatting.formatRelativeTime(it) } ?: "Any"} → ${toDraft?.let { Formatting.formatRelativeTime(it) } ?: "Now"}"
                } else {
                    "Sorting falls back to start time when a range is set."
                },
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(onClick = onOpenRangePicker) { Text("Set range") }
        if (fromDraft != null || toDraft != null) {
            TextButton(onClick = onClearRange) { Text("Clear") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CockpitFilterDateRangePicker(fromDraft: Long?, toDraft: Long?, onDismiss: () -> Unit, onConfirm: (Long?, Long?) -> Unit) {
    val rangeState =
        rememberDateRangePickerState(
            initialSelectedStartDateMillis = fromDraft,
            initialSelectedEndDateMillis = toDraft,
        )
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = { onConfirm(rangeState.selectedStartDateMillis, rangeState.selectedEndDateMillis) }) { Text("Done") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    ) {
        DateRangePicker(state = rangeState, modifier = Modifier.heightIn(max = 480.dp))
    }
}

// ── Save query dialog ──

@Composable
private fun CockpitSaveQueryDialogForm(name: String, onNameChange: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Text(
            "Recall this provider, model, date, and sort combination from the saved-query rail.",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedTextField(
            value = name,
            onValueChange = onNameChange,
            label = { Text("Name") },
            singleLine = true,
        )
    }
}

@Composable
internal fun CockpitSaveQueryDialog(onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Save query") },
        text = { CockpitSaveQueryDialogForm(name = name, onNameChange = { name = it }) },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank(),
                onClick = {
                    onSave(name)
                    onDismiss()
                },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// ── Teaser veil background ──

@Composable
internal fun CockpitTeaserBackground() {
    val isDark = isSystemInDarkTheme()
    val base = if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground
    val tile = if (isDark) AuroraColors.darkSurface else AuroraColors.lightSurface
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(base)
            .padding(AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
            repeat(3) {
                Box(
                    modifier =
                    Modifier
                        .weight(1f)
                        .height(76.dp)
                        .clip(RoundedCornerShape(AuroraRadius.LG.dp))
                        .background(tile),
                )
            }
        }
        repeat(5) {
            Box(
                modifier =
                Modifier
                    .fillMaxWidth()
                    .height(70.dp)
                    .clip(RoundedCornerShape(AuroraRadius.LG.dp))
                    .background(tile.copy(alpha = 0.7f)),
            )
        }
    }
}

// ── helpers ──

internal fun Modifier.cockpitClickableNoRipple(onClick: () -> Unit): Modifier = this.then(
    Modifier.clickable(
        interactionSource = androidx.compose.foundation.interaction.MutableInteractionSource(),
        indication = null,
        onClick = onClick,
    ),
)

internal fun cockpitFormatDuration(seconds: Int): String {
    if (seconds < 60) return "${seconds}s"
    val minutes = seconds / 60
    if (minutes < 60) return "${minutes}m"
    val hours = minutes / 60
    val rem = minutes % 60
    return if (rem == 0) "${hours}h" else "${hours}h ${rem}m"
}

// Builds a shareable Markdown document (metadata header + transcript) that
// matches the iOS share sheet and the Mac bundle export.
internal fun cockpitBuildShareMarkdown(row: CockpitConversationRow, body: String): String = buildString {
    appendLine("# ${row.displayTitle}")
    appendLine()
    appendLine("| Property | Value |")
    appendLine("|----------|-------|")
    appendLine("| Provider | ${row.providerEnum?.displayName ?: row.provider ?: "—"} |")
    row.model?.takeIf { it.isNotBlank() }?.let { appendLine("| Model | $it |") }
    (row.startTimeMs ?: row.updatedAtMs)?.takeIf { it > 0 }?.let {
        appendLine("| Started | ${Formatting.formatRelativeTime(it)} |")
    }
    if (row.messageCount > 0) appendLine("| Messages | ${row.messageCount} |")
    if (row.totalTokens > 0) appendLine("| Tokens | ${Formatting.formatTokens(row.totalTokens.toLong())} |")
    if (row.costUSD > 0) appendLine("| Cost | ${Formatting.formatCurrency(row.costUSD)} |")
    appendLine()
    appendLine("## Transcript")
    appendLine()
    append(if (body.isBlank()) "_No transcript body was available._" else body)
}
