@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.hermes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.R
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.CliRuntimeModelOption
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.components.ProviderLogoStyle
import com.openburnbar.ui.components.ProviderLogoView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients

// MARK: - CLI model picker

internal data class CliModelPickerCatalog(
    val options: List<CliRuntimeModelOption>,
    val isLoading: Boolean,
    val errorText: String?,
    val selectedModelID: String?,
)

internal data class CliModelPickerCallbacks(
    val onDismiss: () -> Unit,
    val onRefresh: () -> Unit,
    val onClear: () -> Unit,
    val onSelect: (CliRuntimeModelOption) -> Unit,
)

@Composable
internal fun CliModelPickerDialog(runtime: AssistantRuntimeID, catalog: CliModelPickerCatalog, callbacks: CliModelPickerCallbacks) {
    androidx.compose.ui.window.Dialog(onDismissRequest = callbacks.onDismiss) {
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
            border = BorderStroke(1.2.dp, Brush.linearGradient(AuroraGradients.glassStroke)),
            modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp, horizontal = 12.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                CliModelPickerHeader(runtime = runtime)
                CliModelPickerBody(runtime = runtime, catalog = catalog, callbacks = callbacks)
                CliModelPickerFooter(callbacks = callbacks)
            }
        }
    }
}

@Composable
private fun CliModelPickerHeader(runtime: AssistantRuntimeID) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Icon(
            imageVector = Icons.Filled.Psychology,
            contentDescription = null,
            tint = AuroraColors.ember,
            modifier = Modifier.size(24.dp),
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "${runtime.displayName} Model",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun CliModelPickerBody(runtime: AssistantRuntimeID, catalog: CliModelPickerCatalog, callbacks: CliModelPickerCallbacks) {
    Box(modifier = Modifier.weight(1f, fill = false).fillMaxWidth()) {
        if (catalog.options.isEmpty()) {
            CliModelPickerEmptyState(runtime = runtime, catalog = catalog, onRefresh = callbacks.onRefresh)
        } else {
            CliModelPickerOptionsList(catalog = catalog, onSelect = callbacks.onSelect)
        }
    }
}

@Composable
private fun CliModelPickerEmptyState(runtime: AssistantRuntimeID, catalog: CliModelPickerCatalog, onRefresh: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text =
            if (catalog.isLoading) {
                "Reading ${runtime.displayName}'s live model catalog from the paired Mac..."
            } else {
                catalog.errorText ?: "${runtime.displayName} has not returned a live Mac catalog yet."
            },
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        if (catalog.isLoading) {
            androidx.compose.material3.CircularProgressIndicator(
                color = AuroraColors.ember,
                modifier = Modifier.size(24.dp),
                strokeWidth = 2.5.dp,
            )
        } else {
            Surface(
                shape = RoundedCornerShape(percent = 50),
                color = AuroraColors.ember.copy(alpha = 0.12f),
                border = BorderStroke(0.75.dp, AuroraColors.ember.copy(alpha = 0.35f)),
                modifier = Modifier.clip(RoundedCornerShape(percent = 50)).clickable { onRefresh() },
            ) {
                Text(
                    text = "Refresh Mac catalog",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = AuroraColors.ember,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun CliModelPickerOptionsList(catalog: CliModelPickerCatalog, onSelect: (CliRuntimeModelOption) -> Unit) {
    val grouped = remember(catalog.options) { catalog.options.groupBy { it.providerName } }
    LazyColumn(
        modifier = Modifier.heightIn(max = 420.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        grouped.forEach { (groupName, rows) ->
            item(key = "header-$groupName") {
                CliModelPickerGroupHeader(groupName = groupName, rows = rows)
            }
            items(rows, key = { it.modelID }) { option ->
                val optionID = option.modelID.trim()
                val selectedID = catalog.selectedModelID?.trim()
                CliModelPickerRow(
                    option = option,
                    selected = if (optionID.isEmpty()) selectedID.isNullOrEmpty() else optionID == selectedID,
                    onClick = { onSelect(option) },
                )
            }
        }
    }
}

@Composable
private fun CliModelPickerGroupHeader(groupName: String, rows: List<CliRuntimeModelOption>) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
    ) {
        if (rows.any { it.source.showsOpenBurnBarProxyBadge }) {
            AppLogoBadge(size = 18.dp)
        } else {
            ProviderLogoView(
                drawableRes = ProviderLogo.drawableForAnyIdentifier(rows.firstOrNull()?.providerID ?: groupName),
                size = 18.dp,
                style = ProviderLogoStyle.Tile,
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = groupName.uppercase(),
            fontSize = 11.sp,
            fontWeight = FontWeight.ExtraBold,
            color = AuroraColors.ember,
            letterSpacing = 1.sp,
        )
    }
}

@Composable
private fun CliModelPickerFooter(callbacks: CliModelPickerCallbacks) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
    ) {
        TextButton(onClick = callbacks.onClear) {
            Text("Use default", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Surface(
            shape = RoundedCornerShape(percent = 50),
            color = AuroraColors.ember,
            modifier = Modifier.clip(RoundedCornerShape(percent = 50)).clickable { callbacks.onDismiss() },
        ) {
            Text(
                text = "Done",
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
internal fun CliModelPickerRow(option: CliRuntimeModelOption, selected: Boolean, onClick: () -> Unit) {
    val accent = sourceColor(option)
    val glassStrokeBrush =
        Brush.linearGradient(
            if (selected) {
                listOf(accent, accent.copy(alpha = 0.4f))
            } else {
                listOf(MaterialTheme.colorScheme.outline.copy(alpha = 0.12f), MaterialTheme.colorScheme.outline.copy(alpha = 0.06f))
            },
        )
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = if (selected) accent.copy(alpha = 0.08f) else MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        border = BorderStroke(if (selected) 1.2.dp else 0.6.dp, glassStrokeBrush),
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .clickable { onClick() },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            CliModelLogo(option = option, size = 32.dp)
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = option.displayName,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    SourcePill(option = option)
                }
                if (option.modelID.isNotBlank()) {
                    Text(
                        text = option.modelID,
                        fontSize = 10.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    )
                }
                Text(
                    text = option.source.detailLabel,
                    fontSize = 10.sp,
                    color = accent.copy(alpha = 0.8f),
                )
            }
        }
    }
}

@Composable
internal fun CliModelLogo(option: CliRuntimeModelOption, size: androidx.compose.ui.unit.Dp) {
    Box(modifier = Modifier.size(size), contentAlignment = Alignment.BottomEnd) {
        ProviderLogoView(
            drawableRes = ProviderLogo.drawableForAnyIdentifier("${option.providerID} ${option.modelID}"),
            size = size,
            style = ProviderLogoStyle.Tile,
        )
        if (option.source.showsOpenBurnBarProxyBadge) {
            AppLogoBadge(
                size = size * 0.42f,
                modifier =
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 0.dp, bottom = 0.dp),
            )
        }
    }
}

@Composable
internal fun AppLogoBadge(size: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    Box(
        modifier =
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.96f))
            .border(0.7.dp, Color.White.copy(alpha = 0.55f), RoundedCornerShape(size * 0.28f)),
        contentAlignment = Alignment.Center,
    ) {
        Image(
            painter = painterResource(id = R.drawable.app_logo),
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = Modifier.size(size * 0.74f),
        )
    }
}

@Composable
internal fun SourcePill(option: CliRuntimeModelOption) {
    val accent = sourceColor(option)
    Surface(
        shape = RoundedCornerShape(percent = 50),
        color = accent.copy(alpha = 0.16f),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, accent.copy(alpha = 0.36f)),
    ) {
        Text(
            text = option.source.displayLabel,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = accent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp),
        )
    }
}

internal fun sourceColor(option: CliRuntimeModelOption): Color = when (option.source) {
    com.openburnbar.data.hermes.CliModelSource.DROID_STANDARD_QUOTA,
    com.openburnbar.data.hermes.CliModelSource.DROID_CORE_QUOTA,
    -> Color(0xFFF59E0B)
    com.openburnbar.data.hermes.CliModelSource.OPENBURNBAR_PROXY -> Color(0xFF22C55E)
    com.openburnbar.data.hermes.CliModelSource.DROID_CUSTOM_MODEL -> MaterialThemeColorFallback.textSecondary
    else -> MaterialThemeColorFallback.textSecondary
}

internal object MaterialThemeColorFallback {
    val textSecondary = Color(0xFF9CA3AF)
}

