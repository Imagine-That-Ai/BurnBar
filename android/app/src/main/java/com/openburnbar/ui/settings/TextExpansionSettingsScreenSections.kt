@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openburnbar.data.db.TextExpansionSnippetEntity
import com.openburnbar.data.text.TextExpansionTrigger
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.components.liquidGlassSurface
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TextExpansionSettingsScreenContent(onBack: () -> Unit, state: TextExpansionSettingsState) {
    val colors = state.colors
    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = colors.backgroundCol,
            topBar = {
                CenterAlignedTopAppBar(
                    title = { Text("Text Expansion", style = AuroraType.headline, color = colors.textPrimaryColor) },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = colors.textPrimaryColor)
                        }
                    },
                    actions = {
                        IconButton(onClick = { state.loadDraft(null) }) {
                            Icon(Icons.Filled.Add, contentDescription = "New snippet", tint = AuroraColors.ember)
                        }
                    },
                    colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = colors.backgroundCol),
                )
            }
        ) { padding ->
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = AuroraSpacing.lg.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            ) {
                textExpansionSettingsItems(state)
            }
        }
        TextExpansionToastOverlay(state)
    }
}

@OptIn(ExperimentalFoundationApi::class)
internal fun LazyListScope.textExpansionSettingsItems(state: TextExpansionSettingsState) {
    item { TextExpansionImeSection(state) }
    item { TextExpansionCloudSyncSection(state) }
    item { TextExpansionEditorSection(state) }
    item { TextExpansionSandboxSection(state) }
    item { TextExpansionSnippetsSearchHeader(state) }
    if (state.filteredSnippets.isEmpty()) {
        item { TextExpansionEmptyState(state) }
    }
    items(state.filteredSnippets, key = { it.id }) { snippet ->
        TextExpansionSnippetCard(
            snippet = snippet,
            state = state,
            modifier = Modifier.animateItem(),
        )
    }
    item { Spacer(modifier = Modifier.height(AuroraSpacing.xxl.dp)) }
}

@Composable
internal fun TextExpansionImeSection(state: TextExpansionSettingsState) {
    val colors = state.colors
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        Button(
            onClick = state.openKeyboardSettings,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.amber),
            shape = RoundedCornerShape(AuroraRadius.sm.dp),
        ) {
            Icon(Icons.Filled.Keyboard, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text("Open Android Keyboard Settings", style = AuroraType.caption)
        }
        Text(
            "Enable OpenBurnBar Snippets keyboard in Android settings to expand &&triggers in any app.",
            style = AuroraType.tiny,
            color = colors.textMutedColor,
            modifier = Modifier.padding(horizontal = AuroraSpacing.xs.dp),
        )
    }
}

@Composable
internal fun TextExpansionCloudSyncSection(state: TextExpansionSettingsState) {
    val colors = state.colors
    Surface(
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = Color.Transparent,
        modifier = Modifier.fillMaxWidth().liquidGlassSurface(shape = RoundedCornerShape(AuroraRadius.md.dp))
    ) {
        Box {
            Box(
                modifier = Modifier.width(3.dp).align(Alignment.CenterStart).matchParentSize().background(
                    Brush.verticalGradient(listOf(AuroraColors.whimsy, AuroraColors.teal))
                )
            )
            Column(
                modifier = Modifier.padding(start = AuroraSpacing.lg.dp + 3.dp, top = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp, bottom = AuroraSpacing.lg.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            ) {
                Text("CLOUD SYNC", style = AuroraType.tiny, color = colors.textMutedColor, letterSpacing = 1.4.dp.value.sp)
                AuroraSettingsToggle(
                    icon = Icons.Filled.Cloud,
                    label = "Sync across devices",
                    subtitle = "Encrypted end-to-end via Cloud Vault",
                    checked = state.cloudSyncEnabled,
                    onCheckedChange = state.onCloudSyncChange,
                )
                if (state.cloudSyncEnabled) {
                    Button(
                        onClick = state.syncNow,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
                        shape = RoundedCornerShape(AuroraRadius.full.dp),
                    ) {
                        Icon(Icons.Filled.Sync, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                        Text("Sync Now", style = AuroraType.caption)
                    }
                }
            }
        }
    }
}

@Composable
internal fun TextExpansionEditorSection(state: TextExpansionSettingsState) {
    Surface(
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = Color.Transparent,
        modifier = Modifier.fillMaxWidth().liquidGlassSurface(shape = RoundedCornerShape(AuroraRadius.md.dp))
    ) {
        Box {
            Box(
                modifier = Modifier.width(3.dp).align(Alignment.CenterStart).matchParentSize().background(
                    Brush.verticalGradient(listOf(AuroraColors.ember, AuroraColors.hermesAureate))
                )
            )
            Column(
                modifier = Modifier.padding(start = AuroraSpacing.lg.dp + 3.dp, top = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp, bottom = AuroraSpacing.lg.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            ) {
                TextExpansionEditorHeader(state)
                TextExpansionEditorTriggerPreview(state)
                TextExpansionEditorFields(state)
                TextExpansionEditorValidation(state)
                TextExpansionEditorActions(state)
            }
        }
    }
}

@Composable
internal fun TextExpansionEditorHeader(state: TextExpansionSettingsState) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = if (state.editing == null) "NEW SNIPPET" else "EDIT SNIPPET",
            style = AuroraType.tiny,
            color = state.colors.textMutedColor,
            letterSpacing = 1.4.dp.value.sp,
            modifier = Modifier.weight(1f)
        )
        if (state.editing != null) {
            Text("✨ Editing", style = AuroraType.tiny, color = AuroraColors.hermesAureate, modifier = Modifier.padding(horizontal = AuroraSpacing.xs.dp))
        }
    }
}

@Composable
internal fun TextExpansionEditorTriggerPreview(state: TextExpansionSettingsState) {
    if (state.trigger.isBlank()) return
    val displayTrigger = if (state.trigger.startsWith("&&")) state.trigger else "&&${state.trigger}"
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = displayTrigger,
            style = AuroraType.monoSmall,
            color = AuroraColors.hermesAureate,
            modifier = Modifier
                .background(color = AuroraColors.hermesAureate.copy(alpha = 0.12f), shape = RoundedCornerShape(AuroraRadius.full.dp))
                .border(0.75.dp, AuroraColors.hermesAureate.copy(alpha = 0.25f), RoundedCornerShape(AuroraRadius.full.dp))
                .padding(horizontal = AuroraSpacing.sm.dp, vertical = AuroraSpacing.xs.dp),
        )
        Text(
            text = "Static",
            style = AuroraType.tiny,
            color = state.colors.textMutedColor,
            modifier = Modifier
                .background(color = state.colors.textMutedColor.copy(alpha = 0.12f), shape = RoundedCornerShape(AuroraRadius.full.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

@Composable
internal fun TextExpansionEditorFields(state: TextExpansionSettingsState) {
    val colors = state.colors
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedBorderColor = AuroraColors.hermesAureate,
        unfocusedBorderColor = colors.borderSubtleColor,
        focusedLabelColor = AuroraColors.hermesAureate,
        unfocusedLabelColor = colors.textMutedColor,
        cursorColor = AuroraColors.hermesAureate,
        focusedContainerColor = colors.surfaceElevatedColor,
        unfocusedContainerColor = Color.Transparent
    )
    OutlinedTextField(
        value = state.title,
        onValueChange = state.onTitleChange,
        label = { Text("Name", style = AuroraType.caption) },
        textStyle = AuroraType.body,
        colors = fieldColors,
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    OutlinedTextField(
        value = state.trigger.replace("&&", ""),
        onValueChange = state.onTriggerChange,
        label = { Text("Trigger", style = AuroraType.caption) },
        textStyle = AuroraType.mono,
        leadingIcon = {
            Text("&&", style = AuroraType.mono, color = AuroraColors.hermesAureate, modifier = Modifier.padding(start = 12.dp))
        },
        colors = fieldColors,
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    OutlinedTextField(
        value = state.body,
        onValueChange = state.onBodyChange,
        label = { Text("Snippet Expansion Text", style = AuroraType.caption) },
        textStyle = AuroraType.body,
        colors = fieldColors,
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        modifier = Modifier.fillMaxWidth(),
        minLines = 3,
    )
    AuroraSettingsToggle(
        icon = Icons.Filled.CheckCircle,
        label = "Enabled",
        subtitle = "Snippet will expand when typed",
        checked = state.enabled,
        onCheckedChange = state.onEnabledChange,
    )
}

@Composable
internal fun TextExpansionEditorValidation(state: TextExpansionSettingsState) {
    val validationError = TextExpansionTrigger.validationError(state.trigger)
    val canonicalTrigger = TextExpansionTrigger.canonicalName(state.trigger)
    val duplicateTrigger = validationError == null &&
        state.snippets.any { it.id != state.editing?.id && it.trigger == canonicalTrigger }
    when {
        validationError != null -> TextExpansionValidationRow(validationError, state.colors.errorColor)
        duplicateTrigger -> TextExpansionValidationRow("Trigger already exists.", state.colors.errorColor)
    }
}

@Composable
internal fun TextExpansionValidationRow(message: String, errorColor: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Warning, contentDescription = null, tint = errorColor, modifier = Modifier.size(14.dp))
        Text(message, style = AuroraType.tiny, color = errorColor)
    }
}

@Composable
internal fun TextExpansionEditorActions(state: TextExpansionSettingsState) {
    val validationError = TextExpansionTrigger.validationError(state.trigger)
    val canonicalTrigger = TextExpansionTrigger.canonicalName(state.trigger)
    val duplicateTrigger = validationError == null &&
        state.snippets.any { it.id != state.editing?.id && it.trigger == canonicalTrigger }
    val canSave = validationError == null &&
        !duplicateTrigger &&
        state.title.isNotBlank() &&
        state.body.isNotBlank() &&
        state.trigger.isNotBlank()
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        Button(
            onClick = state.saveSnippet,
            enabled = canSave,
            colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
            shape = RoundedCornerShape(AuroraRadius.full.dp),
        ) {
            Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
            Text("Save", style = AuroraType.caption)
        }
        if (state.editing != null) {
            Button(
                onClick = state.deleteSnippet,
                colors = ButtonDefaults.buttonColors(containerColor = state.colors.errorColor.copy(alpha = 0.85f)),
                shape = RoundedCornerShape(AuroraRadius.full.dp),
            ) {
                Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                Text("Delete", style = AuroraType.caption)
            }
            Button(
                onClick = { state.loadDraft(null) },
                colors = ButtonDefaults.buttonColors(containerColor = state.colors.borderSubtleColor),
                shape = RoundedCornerShape(AuroraRadius.full.dp),
            ) {
                Text("Cancel", style = AuroraType.caption, color = state.colors.textPrimaryColor)
            }
        }
    }
}

@Composable
internal fun TextExpansionSandboxSection(state: TextExpansionSettingsState) {
    Surface(
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = Color.Transparent,
        modifier = Modifier.fillMaxWidth().liquidGlassSurface(shape = RoundedCornerShape(AuroraRadius.md.dp))
    ) {
        Box {
            Box(modifier = Modifier.width(3.dp).align(Alignment.CenterStart).matchParentSize().background(AuroraColors.hermesAureate))
            Column(
                modifier = Modifier.padding(start = AuroraSpacing.lg.dp + 3.dp, top = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp, bottom = AuroraSpacing.lg.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                TextExpansionSandboxHeader(state)
                TextExpansionSandboxField(state)
            }
        }
    }
}

@Composable
internal fun TextExpansionSandboxHeader(state: TextExpansionSettingsState) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = AuroraColors.hermesAureate, modifier = Modifier.size(16.dp))
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        Text("LIVE EXPANSION SANDBOX", style = AuroraType.caption, color = AuroraColors.hermesAureate, modifier = Modifier.weight(1f))
        if (state.sandboxSuccess) {
            Text("✨ Expanded Live!", style = AuroraType.tiny, color = state.colors.successColor)
        }
    }
    val activeTrigger = state.trigger.replace("&&", "").trim()
    val demoText = if (activeTrigger.isNotEmpty()) activeTrigger else "trigger"
    Text(
        text = "Test ground: Type `&&$demoText` followed by a space to watch it expand in real-time:",
        style = AuroraType.tiny,
        color = state.colors.textMutedColor
    )
}

@Composable
internal fun TextExpansionSandboxField(state: TextExpansionSettingsState) {
    val colors = state.colors
    val sandboxBorder = if (state.sandboxSuccess) colors.successColor else colors.borderSubtleColor
    OutlinedTextField(
        value = state.sandboxText,
        onValueChange = state.onSandboxTextChange,
        placeholder = { Text("Test expanding your shortcuts here...", style = AuroraType.caption) },
        textStyle = AuroraType.mono,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = sandboxBorder,
            unfocusedBorderColor = sandboxBorder,
            cursorColor = AuroraColors.hermesAureate,
            focusedContainerColor = colors.surfaceElevatedColor,
            unfocusedContainerColor = Color.Transparent
        ),
        shape = RoundedCornerShape(AuroraRadius.sm.dp),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
internal fun TextExpansionSnippetsSearchHeader(state: TextExpansionSettingsState) {
    val colors = state.colors
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        Text(
            text = "SAVED SNIPPETS",
            style = AuroraType.tiny,
            color = colors.textMutedColor,
            letterSpacing = 1.4.dp.value.sp,
            modifier = Modifier.padding(top = AuroraSpacing.sm.dp),
        )
        OutlinedTextField(
            value = state.searchQuery,
            onValueChange = state.onSearchQueryChange,
            placeholder = { Text("Search trigger or title...", style = AuroraType.caption) },
            textStyle = AuroraType.caption,
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = colors.textMutedColor, modifier = Modifier.size(16.dp)) },
            trailingIcon = {
                if (state.searchQuery.isNotEmpty()) {
                    IconButton(onClick = { state.onSearchQueryChange("") }) {
                        Icon(Icons.Filled.Close, contentDescription = "Clear", tint = colors.textMutedColor, modifier = Modifier.size(14.dp))
                    }
                }
            },
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = AuroraColors.hermesAureate,
                unfocusedBorderColor = colors.borderSubtleColor,
                cursorColor = AuroraColors.hermesAureate
            ),
            shape = RoundedCornerShape(AuroraRadius.full.dp),
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )
    }
}

@Composable
internal fun TextExpansionEmptyState(state: TextExpansionSettingsState) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth().padding(vertical = AuroraSpacing.xxl.dp)) {
        Icon(Icons.Filled.Keyboard, contentDescription = null, tint = state.colors.textMutedColor, modifier = Modifier.size(48.dp))
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        Text(if (state.searchQuery.isEmpty()) "No snippets saved" else "No matching snippets", style = AuroraType.headline, color = state.colors.textSecondaryColor)
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Text(if (state.searchQuery.isEmpty()) "Create your first &&trigger" else "Adjust search query", style = AuroraType.caption, color = state.colors.textMutedColor)
    }
}

@Composable
internal fun TextExpansionSnippetCard(
    snippet: TextExpansionSnippetEntity,
    state: TextExpansionSettingsState,
    modifier: Modifier = Modifier,
) {
    val colors = state.colors
    val isSelected = state.editing?.id == snippet.id
    val glassModifier = modifier.fillMaxWidth().liquidGlassSurface(shape = RoundedCornerShape(AuroraRadius.md.dp))
    Surface(
        onClick = { state.loadDraft(snippet) },
        shape = RoundedCornerShape(AuroraRadius.md.dp),
        color = Color.Transparent,
        modifier = if (isSelected) {
            glassModifier.border(BorderStroke(1.5.dp, AuroraColors.hermesAureate), RoundedCornerShape(AuroraRadius.md.dp))
        } else {
            glassModifier
        },
    ) {
        Box {
            TextExpansionSnippetAccentStrip(snippet, colors)
            TextExpansionSnippetRow(snippet, state, isSelected)
        }
    }
}

@Composable
internal fun BoxScope.TextExpansionSnippetAccentStrip(snippet: TextExpansionSnippetEntity, colors: TextExpansionColorTokens) {
    Box(
        modifier = Modifier.width(4.dp).align(Alignment.CenterStart).matchParentSize().background(
            if (snippet.isEnabled) Brush.verticalGradient(listOf(AuroraColors.hermesAureate, AuroraColors.ember))
            else Brush.verticalGradient(listOf(colors.textMutedColor.copy(alpha = 0.4f), colors.textMutedColor.copy(alpha = 0.2f)))
        )
    )
}

@Composable
internal fun TextExpansionSnippetRow(snippet: TextExpansionSnippetEntity, state: TextExpansionSettingsState, isSelected: Boolean) {
    val colors = state.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = AuroraSpacing.md.dp + 4.dp,
                top = AuroraSpacing.md.dp,
                end = AuroraSpacing.md.dp,
                bottom = AuroraSpacing.md.dp,
            )
            .alpha(if (snippet.isEnabled) 1f else 0.55f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextExpansionSnippetDetails(snippet, colors, isSelected)
        IconButton(onClick = { state.toggleSnippetEnabled(snippet) }) {
            Icon(
                imageVector = if (snippet.isEnabled) Icons.Filled.CheckCircle else Icons.Filled.Block,
                contentDescription = "Toggle status",
                tint = if (snippet.isEnabled) AuroraColors.ember else colors.textMutedColor.copy(alpha = 0.5f),
                modifier = Modifier.size(22.dp)
            )
        }
    }
}

@Composable
internal fun RowScope.TextExpansionSnippetDetails(
    snippet: TextExpansionSnippetEntity,
    colors: TextExpansionColorTokens,
    isSelected: Boolean,
) {
    Column(modifier = Modifier.weight(1f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(text = snippet.title, style = AuroraType.headline, color = colors.textPrimaryColor, modifier = Modifier.weight(1f))
            if (isSelected) {
                Text(
                    text = "✨ Editing",
                    style = AuroraType.tiny,
                    color = AuroraColors.hermesAureate,
                    modifier = Modifier
                        .background(
                            color = AuroraColors.hermesAureate.copy(alpha = 0.12f),
                            shape = RoundedCornerShape(AuroraRadius.full.dp),
                        )
                        .border(
                            0.5.dp,
                            AuroraColors.hermesAureate.copy(alpha = 0.25f),
                            RoundedCornerShape(AuroraRadius.full.dp),
                        )
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
            }
        }
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "&&${snippet.trigger}",
                style = AuroraType.monoSmall,
                color = AuroraColors.hermesAureate,
                modifier = Modifier
                    .background(
                        color = AuroraColors.hermesAureate.copy(alpha = 0.08f),
                        shape = RoundedCornerShape(AuroraRadius.full.dp),
                    )
                    .border(
                        0.5.dp,
                        AuroraColors.hermesAureate.copy(alpha = 0.15f),
                        RoundedCornerShape(AuroraRadius.full.dp),
                    )
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
            Text(
                text = "Static",
                style = AuroraType.tiny,
                color = colors.textMutedColor,
                modifier = Modifier
                    .background(color = colors.textMutedColor.copy(alpha = 0.12f), shape = RoundedCornerShape(AuroraRadius.full.dp))
                    .padding(horizontal = 6.dp, vertical = 1.dp),
            )
        }
        Spacer(modifier = Modifier.height(AuroraSpacing.xxs.dp))
        Text(text = textExpansionRelativeTime(snippet.updatedAtMillis), style = AuroraType.tiny, color = colors.textMutedColor)
    }
}

@Composable
internal fun BoxScope.TextExpansionToastOverlay(state: TextExpansionSettingsState) {
    val colors = state.colors
    AnimatedVisibility(
        visible = state.status != null,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
        modifier = Modifier.align(Alignment.TopCenter).padding(top = 20.dp)
    ) {
        Surface(
            shape = RoundedCornerShape(AuroraRadius.full.dp),
            color = colors.surfaceElevatedColor.copy(alpha = 0.95f),
            border = BorderStroke(1.dp, colors.borderSubtleColor),
            shadowElevation = 8.dp,
            modifier = Modifier.padding(horizontal = 24.dp)
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
            ) {
                Icon(
                    imageVector = if (state.statusIsError) Icons.Filled.Warning else Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = if (state.statusIsError) colors.errorColor else colors.successColor,
                    modifier = Modifier.size(16.dp)
                )
                Text(text = state.status.orEmpty(), style = AuroraType.body, color = colors.textPrimaryColor)
            }
        }
    }
}

internal fun textExpansionRelativeTime(millis: Long): String {
    val seconds = (System.currentTimeMillis() - millis) / 1000
    return when {
        seconds < 60 -> "just now"
        seconds < 3_600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3_600}h ago"
        seconds < 86_400 * 30 -> "${seconds / 86_400}d ago"
        else -> java.text.SimpleDateFormat("MMM d", java.util.Locale.getDefault()).format(java.util.Date(millis))
    }
}

private inline val Float.sp: androidx.compose.ui.unit.TextUnit
    get() = androidx.compose.ui.unit.TextUnit(this, androidx.compose.ui.unit.TextUnitType.Sp)

private inline val Int.sp: androidx.compose.ui.unit.TextUnit
    get() = this.toFloat().sp
