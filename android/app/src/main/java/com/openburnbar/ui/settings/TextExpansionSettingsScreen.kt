package com.openburnbar.ui.settings

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.TextExpansionSnippetEntity
import com.openburnbar.data.text.TextExpansionTrigger
import com.openburnbar.data.text.TextExpansionSyncManager
import com.openburnbar.data.text.TextExpansionSyncWorker
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TextExpansionSettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val isDark = isSystemInDarkTheme()

    // Core data states
    var snippets by remember { mutableStateOf<List<TextExpansionSnippetEntity>>(emptyList()) }
    var editing by remember { mutableStateOf<TextExpansionSnippetEntity?>(null) }
    var title by remember { mutableStateOf("") }
    var trigger by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var enabled by remember { mutableStateOf(true) }

    // Search State
    var searchQuery by remember { mutableStateOf("") }

    // Sandbox States
    var sandboxText by remember { mutableStateOf("") }
    var sandboxSuccess by remember { mutableStateOf(false) }

    // Toast States
    var status by remember { mutableStateOf<String?>(null) }
    var statusIsError by remember { mutableStateOf(false) }

    val prefs = remember(context) { context.getSharedPreferences("text_expansion_settings", android.content.Context.MODE_PRIVATE) }
    var cloudSyncEnabled by remember { mutableStateOf(prefs.getBoolean("cloud_sync_enabled", true)) }

    // Unified color tokens
    val surfaceColor = if (isDark) AuroraColors.darkSurface else AuroraColors.lightSurface
    val surfaceElevatedColor = if (isDark) AuroraColors.darkSurfaceElevated else AuroraColors.lightSurfaceElevated
    val borderSubtleColor = if (isDark) AuroraColors.darkBorderSubtle else AuroraColors.lightBorderSubtle
    val textPrimaryColor = if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary
    val textSecondaryColor = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary
    val textMutedColor = if (isDark) AuroraColors.darkTextMuted else AuroraColors.lightTextMuted
    val successColor = if (isDark) AuroraColors.successDark else AuroraColors.success
    val errorColor = if (isDark) AuroraColors.errorDark else AuroraColors.error
    val backgroundCol = if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground

    // Focus state helpers for Glowing borders
    var titleFocused by remember { mutableStateOf(false) }
    var triggerFocused by remember { mutableStateOf(false) }
    var bodyFocused by remember { mutableStateOf(false) }
    var sandboxFocused by remember { mutableStateOf(false) }

    suspend fun reload() {
        snippets = withContext(Dispatchers.IO) {
            AppDatabase.getDatabase(context).textExpansionDao().getAllActive()
        }
    }

    fun loadDraft(snippet: TextExpansionSnippetEntity?) {
        editing = snippet
        if (snippet == null) {
            title = ""
            trigger = ""
            body = ""
            enabled = true
        } else {
            title = snippet.title
            trigger = snippet.trigger
            body = snippet.body
            enabled = snippet.isEnabled
        }
        status = null
    }

    fun showToast(message: String, isError: Boolean = false) {
        status = message
        statusIsError = isError
    }

    // Auto-dismiss status
    LaunchedEffect(status) {
        if (status != null) {
            delay(2500)
            status = null
        }
    }

    LaunchedEffect(Unit) { reload() }

    // Suffix Expansion Trigger Sandbox Logic
    fun handleSandboxInput(newVal: String) {
        val activeTrigger = trigger.replace("&&", "").trim()
        if (activeTrigger.isNotEmpty() && newVal.endsWith("&&$activeTrigger ")) {
            val prefix = newVal.substring(0, newVal.length - (activeTrigger.length + 3))
            sandboxText = prefix + body.trim()
            scope.launch {
                sandboxSuccess = true
                delay(1500)
                sandboxSuccess = false
            }
            return
        }

        for (snippet in snippets) {
            val token = "&&${snippet.trigger}"
            if (newVal.endsWith("$token ")) {
                val prefix = newVal.substring(0, newVal.length - (token.length + 1))
                sandboxText = prefix + snippet.body.trim()
                scope.launch {
                    sandboxSuccess = true
                    delay(1500)
                    sandboxSuccess = false
                }
                break
            }
        }
    }

    val filteredSnippets = remember(snippets, searchQuery) {
        if (searchQuery.isBlank()) snippets else {
            val query = searchQuery.trim().lowercase()
            snippets.filter {
                it.title.lowercase().contains(query) ||
                it.trigger.lowercase().contains(query) ||
                it.body.lowercase().contains(query)
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = backgroundCol,
            topBar = {
                CenterAlignedTopAppBar(
                    title = {
                        Text("Text Expansion", style = AuroraType.headline, color = textPrimaryColor)
                    },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = textPrimaryColor)
                        }
                    },
                    actions = {
                        IconButton(onClick = { loadDraft(null) }) {
                            Icon(Icons.Filled.Add, contentDescription = "New snippet", tint = AuroraColors.ember)
                        }
                    },
                    colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                        containerColor = backgroundCol
                    ),
                )
            }
        ) { padding ->
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(horizontal = AuroraSpacing.lg.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
            ) {
                // IME settings button
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                        Button(
                            onClick = {
                                context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            },
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
                            color = textMutedColor,
                            modifier = Modifier.padding(horizontal = AuroraSpacing.xs.dp),
                        )
                    }
                }

                // Cloud Sync Section
                item {
                    Surface(
                        shape = RoundedCornerShape(AuroraRadius.md.dp),
                        color = surfaceElevatedColor,
                        border = BorderStroke(0.75.dp, borderSubtleColor),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Box {
                            // Left accent gradient bar
                            Box(
                                modifier = Modifier
                                    .width(3.dp)
                                    .align(Alignment.CenterStart)
                                    .matchParentSize()
                                    .background(
                                        Brush.verticalGradient(
                                            listOf(
                                                AuroraColors.whimsy,
                                                AuroraColors.teal
                                            )
                                        )
                                    )
                            )

                            Column(
                                modifier = Modifier.padding(start = AuroraSpacing.lg.dp + 3.dp, top = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp, bottom = AuroraSpacing.lg.dp),
                                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
                            ) {
                                Text(
                                    text = "CLOUD SYNC",
                                    style = AuroraType.tiny,
                                    color = textMutedColor,
                                    letterSpacing = 1.4.dp.value.sp,
                                )

                                AuroraSettingsToggle(
                                    icon = Icons.Filled.Cloud,
                                    label = "Sync across devices",
                                    subtitle = "Encrypted end-to-end via Cloud Vault",
                                    checked = cloudSyncEnabled,
                                    onCheckedChange = { checked ->
                                        cloudSyncEnabled = checked
                                        prefs.edit().putBoolean("cloud_sync_enabled", checked).apply()
                                        if (checked) {
                                            TextExpansionSyncWorker.enqueueImmediate(context)
                                        }
                                    },
                                )

                                if (cloudSyncEnabled) {
                                    Button(
                                        onClick = {
                                            scope.launch {
                                                showToast("Syncing...")
                                                val result = withContext(Dispatchers.IO) {
                                                    TextExpansionSyncManager(context).sync()
                                                }
                                                if (result.isSuccess) {
                                                    showToast("Sync complete")
                                                    reload()
                                                } else {
                                                    showToast(result.exceptionOrNull()?.message ?: "Sync failed", isError = true)
                                                }
                                            }
                                        },
                                        modifier = Modifier.fillMaxWidth(),
                                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
                                        shape = RoundedCornerShape(AuroraRadius.full.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Filled.Sync,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                                        Text("Sync Now", style = AuroraType.caption)
                                    }
                                }
                            }
                        }
                    }
                }

                // Editor card
                item {
                    Surface(
                        shape = RoundedCornerShape(AuroraRadius.md.dp),
                        color = surfaceElevatedColor,
                        border = BorderStroke(0.75.dp, borderSubtleColor),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Box {
                            // Left accent gradient bar
                            Box(
                                modifier = Modifier
                                    .width(3.dp)
                                    .align(Alignment.CenterStart)
                                    .matchParentSize()
                                    .background(
                                        Brush.verticalGradient(
                                            listOf(
                                                AuroraColors.ember,
                                                AuroraColors.hermesAureate
                                            )
                                        )
                                    )
                            )

                            Column(
                                modifier = Modifier.padding(start = AuroraSpacing.lg.dp + 3.dp, top = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp, bottom = AuroraSpacing.lg.dp),
                                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
                            ) {
                                // Section header
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = (if (editing == null) "NEW SNIPPET" else "EDIT SNIPPET"),
                                        style = AuroraType.tiny,
                                        color = textMutedColor,
                                        letterSpacing = 1.4.dp.value.sp,
                                        modifier = Modifier.weight(1f)
                                    )
                                    if (editing != null) {
                                        Text(
                                            text = "✨ Editing",
                                            style = AuroraType.tiny,
                                            color = AuroraColors.hermesAureate,
                                            modifier = Modifier.padding(horizontal = AuroraSpacing.xs.dp)
                                        )
                                    }
                                }

                                // Trigger chip preview
                                if (trigger.isNotBlank()) {
                                    val displayTrigger = if (trigger.startsWith("&&")) trigger else "&&$trigger"
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Text(
                                            text = displayTrigger,
                                            style = AuroraType.monoSmall,
                                            color = AuroraColors.hermesAureate,
                                            modifier = Modifier
                                                .background(
                                                    color = AuroraColors.hermesAureate.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(AuroraRadius.full.dp),
                                                )
                                                .border(0.75.dp, AuroraColors.hermesAureate.copy(alpha = 0.25f), RoundedCornerShape(AuroraRadius.full.dp))
                                                .padding(horizontal = AuroraSpacing.sm.dp, vertical = AuroraSpacing.xs.dp),
                                        )
                                        // Static-only badge
                                        Text(
                                            text = "Static",
                                            style = AuroraType.tiny,
                                            color = textMutedColor,
                                            modifier = Modifier
                                                .background(
                                                    color = textMutedColor.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(AuroraRadius.full.dp),
                                                )
                                                .padding(horizontal = 6.dp, vertical = 2.dp),
                                        )
                                    }
                                }

                                // Fields with Focus GLOOPS!
                                OutlinedTextField(
                                    value = title,
                                    onValueChange = { title = it },
                                    label = { Text("Name", style = AuroraType.caption) },
                                    textStyle = AuroraType.body,
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = AuroraColors.hermesAureate,
                                        unfocusedBorderColor = borderSubtleColor,
                                        focusedLabelColor = AuroraColors.hermesAureate,
                                        unfocusedLabelColor = textMutedColor,
                                        cursorColor = AuroraColors.hermesAureate,
                                        focusedContainerColor = surfaceElevatedColor,
                                        unfocusedContainerColor = Color.Transparent
                                    ),
                                    shape = RoundedCornerShape(AuroraRadius.sm.dp),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .onFocusChanged { titleFocused = it.isFocused },
                                    singleLine = true,
                                )
                                OutlinedTextField(
                                    value = trigger.replace("&&", ""),
                                    onValueChange = { trigger = it },
                                    label = { Text("Trigger", style = AuroraType.caption) },
                                    textStyle = AuroraType.mono,
                                    leadingIcon = {
                                        Text(
                                            text = "&&",
                                            style = AuroraType.mono,
                                            color = AuroraColors.hermesAureate,
                                            modifier = Modifier.padding(start = 12.dp)
                                        )
                                    },
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = AuroraColors.hermesAureate,
                                        unfocusedBorderColor = borderSubtleColor,
                                        focusedLabelColor = AuroraColors.hermesAureate,
                                        unfocusedLabelColor = textMutedColor,
                                        cursorColor = AuroraColors.hermesAureate,
                                        focusedContainerColor = surfaceElevatedColor,
                                        unfocusedContainerColor = Color.Transparent
                                    ),
                                    shape = RoundedCornerShape(AuroraRadius.sm.dp),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .onFocusChanged { triggerFocused = it.isFocused },
                                    singleLine = true,
                                )
                                OutlinedTextField(
                                    value = body,
                                    onValueChange = { body = it },
                                    label = { Text("Snippet Expansion Text", style = AuroraType.caption) },
                                    textStyle = AuroraType.body,
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = AuroraColors.hermesAureate,
                                        unfocusedBorderColor = borderSubtleColor,
                                        focusedLabelColor = AuroraColors.hermesAureate,
                                        unfocusedLabelColor = textMutedColor,
                                        cursorColor = AuroraColors.hermesAureate,
                                        focusedContainerColor = surfaceElevatedColor,
                                        unfocusedContainerColor = Color.Transparent
                                    ),
                                    shape = RoundedCornerShape(AuroraRadius.sm.dp),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .onFocusChanged { bodyFocused = it.isFocused },
                                    minLines = 3,
                                )

                                // Enabled toggle
                                AuroraSettingsToggle(
                                    icon = Icons.Filled.CheckCircle,
                                    label = "Enabled",
                                    subtitle = "Snippet will expand when typed",
                                    checked = enabled,
                                    onCheckedChange = { enabled = it },
                                )

                                // Validation
                                val validationError = TextExpansionTrigger.validationError(trigger)
                                val canonicalTrigger = TextExpansionTrigger.canonicalName(trigger)
                                val duplicateTrigger = validationError == null && snippets.any {
                                    it.id != editing?.id && it.trigger == canonicalTrigger
                                }
                                if (validationError != null) {
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(Icons.Filled.Warning, contentDescription = null, tint = errorColor, modifier = Modifier.size(14.dp))
                                        Text(validationError, style = AuroraType.tiny, color = errorColor)
                                    }
                                } else if (duplicateTrigger) {
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(Icons.Filled.Warning, contentDescription = null, tint = errorColor, modifier = Modifier.size(14.dp))
                                        Text("Trigger already exists.", style = AuroraType.tiny, color = errorColor)
                                    }
                                }

                                // Action bar
                                Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                                    Button(
                                        enabled = validationError == null && !duplicateTrigger && title.isNotBlank() && body.isNotBlank() && trigger.isNotBlank(),
                                        onClick = {
                                            scope.launch {
                                                val now = System.currentTimeMillis()
                                                val entity = TextExpansionSnippetEntity(
                                                    id = editing?.id ?: UUID.randomUUID().toString(),
                                                    title = title.trim(),
                                                    trigger = TextExpansionTrigger.canonicalName(trigger),
                                                    body = body.trim(),
                                                    mode = "static",
                                                    isEnabled = enabled,
                                                    scopeJson = editing?.scopeJson ?: "{}",
                                                    revision = (editing?.revision ?: 0) + 1,
                                                    createdAtMillis = editing?.createdAtMillis ?: now,
                                                    updatedAtMillis = now,
                                                    sourceDeviceID = editing?.sourceDeviceID,
                                                )
                                                withContext(Dispatchers.IO) {
                                                    AppDatabase.getDatabase(context).textExpansionDao().upsert(entity)
                                                }
                                                showToast("Saved &&${entity.trigger}")
                                                if (cloudSyncEnabled) {
                                                    TextExpansionSyncWorker.enqueueImmediate(context)
                                                }
                                                loadDraft(entity)
                                                reload()
                                            }
                                        },
                                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
                                        shape = RoundedCornerShape(AuroraRadius.full.dp),
                                    ) {
                                        Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                                        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                        Text("Save", style = AuroraType.caption)
                                    }

                                    if (editing != null) {
                                        Button(
                                            onClick = {
                                                val target = editing ?: return@Button
                                                scope.launch {
                                                    withContext(Dispatchers.IO) {
                                                        AppDatabase.getDatabase(context).textExpansionDao().softDelete(target.id)
                                                    }
                                                    showToast("Deleted &&${target.trigger}")
                                                    if (cloudSyncEnabled) {
                                                        TextExpansionSyncWorker.enqueueImmediate(context)
                                                    }
                                                    loadDraft(null)
                                                    reload()
                                                }
                                            },
                                            colors = ButtonDefaults.buttonColors(containerColor = errorColor.copy(alpha = 0.85f)),
                                            shape = RoundedCornerShape(AuroraRadius.full.dp),
                                        ) {
                                            Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                                            Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                            Text("Delete", style = AuroraType.caption)
                                        }

                                        Button(
                                            onClick = { loadDraft(null) },
                                            colors = ButtonDefaults.buttonColors(containerColor = borderSubtleColor),
                                            shape = RoundedCornerShape(AuroraRadius.full.dp),
                                        ) {
                                            Text("Cancel", style = AuroraType.caption, color = textPrimaryColor)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Interactive Live Sandbox Testing Card
                item {
                    Surface(
                        shape = RoundedCornerShape(AuroraRadius.md.dp),
                        color = surfaceElevatedColor,
                        border = BorderStroke(0.75.dp, borderSubtleColor),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Box {
                            Box(
                                modifier = Modifier
                                    .width(3.dp)
                                    .align(Alignment.CenterStart)
                                    .matchParentSize()
                                    .background(AuroraColors.hermesAureate)
                            )

                            Column(
                                modifier = Modifier.padding(start = AuroraSpacing.lg.dp + 3.dp, top = AuroraSpacing.lg.dp, end = AuroraSpacing.lg.dp, bottom = AuroraSpacing.lg.dp),
                                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Filled.PlayCircle,
                                        contentDescription = null,
                                        tint = AuroraColors.hermesAureate,
                                        modifier = Modifier.size(16.dp)
                                    )
                                    Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                    Text(
                                        text = "LIVE EXPANSION SANDBOX",
                                        style = AuroraType.caption,
                                        color = AuroraColors.hermesAureate,
                                        modifier = Modifier.weight(1f)
                                    )
                                    if (sandboxSuccess) {
                                        Text(
                                            text = "✨ Expanded Live!",
                                            style = AuroraType.tiny,
                                            color = successColor
                                        )
                                    }
                                }

                                val activeTrigger = trigger.replace("&&", "").trim()
                                val demoText = if (activeTrigger.isNotEmpty()) activeTrigger else "trigger"
                                Text(
                                    text = "Test ground: Type `&&$demoText` followed by a space to watch it expand in real-time:",
                                    style = AuroraType.tiny,
                                    color = textMutedColor
                                )

                                val sandboxBorder = if (sandboxSuccess) successColor else if (sandboxFocused) AuroraColors.hermesAureate else borderSubtleColor
                                OutlinedTextField(
                                    value = sandboxText,
                                    onValueChange = {
                                        sandboxText = it
                                        handleSandboxInput(it)
                                    },
                                    placeholder = { Text("Test expanding your shortcuts here...", style = AuroraType.caption) },
                                    textStyle = AuroraType.mono,
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = sandboxBorder,
                                        unfocusedBorderColor = sandboxBorder,
                                        cursorColor = AuroraColors.hermesAureate,
                                        focusedContainerColor = surfaceElevatedColor,
                                        unfocusedContainerColor = Color.Transparent
                                    ),
                                    shape = RoundedCornerShape(AuroraRadius.sm.dp),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .onFocusChanged { sandboxFocused = it.isFocused }
                                )
                            }
                        }
                    }
                }

                // Saved snippets header + Search
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                        Text(
                            text = "SAVED SNIPPETS",
                            style = AuroraType.tiny,
                            color = textMutedColor,
                            letterSpacing = 1.4.dp.value.sp,
                            modifier = Modifier.padding(top = AuroraSpacing.sm.dp),
                        )

                        // Dynamic Search Field
                        OutlinedTextField(
                            value = searchQuery,
                            onValueChange = { searchQuery = it },
                            placeholder = { Text("Search trigger or title...", style = AuroraType.caption) },
                            textStyle = AuroraType.caption,
                            leadingIcon = {
                                Icon(Icons.Filled.Search, contentDescription = null, tint = textMutedColor, modifier = Modifier.size(16.dp))
                            },
                            trailingIcon = {
                                if (searchQuery.isNotEmpty()) {
                                    IconButton(onClick = { searchQuery = "" }) {
                                        Icon(Icons.Filled.Close, contentDescription = "Clear", tint = textMutedColor, modifier = Modifier.size(14.dp))
                                    }
                                }
                            },
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = AuroraColors.hermesAureate,
                                unfocusedBorderColor = borderSubtleColor,
                                cursorColor = AuroraColors.hermesAureate
                            ),
                            shape = RoundedCornerShape(AuroraRadius.full.dp),
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true
                        )
                    }
                }

                // Empty state
                if (filteredSnippets.isEmpty()) {
                    item {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = AuroraSpacing.xxl.dp),
                        ) {
                            Icon(
                                Icons.Filled.Keyboard,
                                contentDescription = null,
                                tint = textMutedColor,
                                modifier = Modifier.size(48.dp),
                            )
                            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
                            Text(if (searchQuery.isEmpty()) "No snippets saved" else "No matching snippets", style = AuroraType.headline, color = textSecondaryColor)
                            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                            Text(if (searchQuery.isEmpty()) "Create your first &&trigger" else "Adjust search query", style = AuroraType.caption, color = textMutedColor)
                        }
                    }
                }

                // Redesigned Snippet cards with left vertical glow strips & quick toggle action!
                items(filteredSnippets, key = { it.id }) { snippet ->
                    val isSelected = editing?.id == snippet.id
                    val cardBorder = if (isSelected) {
                        BorderStroke(1.5.dp, AuroraColors.hermesAureate)
                    } else {
                        BorderStroke(0.75.dp, borderSubtleColor)
                    }
                    val cardBg = if (isSelected) {
                        surfaceElevatedColor
                    } else {
                        surfaceColor
                    }

                    Surface(
                        onClick = { loadDraft(snippet) },
                        shape = RoundedCornerShape(AuroraRadius.md.dp),
                        color = cardBg,
                        border = cardBorder,
                        modifier = Modifier
                            .fillMaxWidth()
                            .animateItem(),
                    ) {
                        Box {
                            // Left vertical accent strip
                            Box(
                                modifier = Modifier
                                    .width(4.dp)
                                    .align(Alignment.CenterStart)
                                    .matchParentSize()
                                    .background(
                                        if (snippet.isEnabled) {
                                            Brush.verticalGradient(
                                                listOf(
                                                    AuroraColors.hermesAureate,
                                                    AuroraColors.ember
                                                )
                                            )
                                        } else {
                                            Brush.verticalGradient(
                                                listOf(
                                                    textMutedColor.copy(alpha = 0.4f),
                                                    textMutedColor.copy(alpha = 0.2f)
                                                )
                                            )
                                        }
                                    )
                            )

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(start = AuroraSpacing.md.dp + 4.dp, top = AuroraSpacing.md.dp, end = AuroraSpacing.md.dp, bottom = AuroraSpacing.md.dp)
                                    .alpha(if (snippet.isEnabled) 1f else 0.55f),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = snippet.title,
                                            style = AuroraType.headline,
                                            color = textPrimaryColor,
                                            modifier = Modifier.weight(1f),
                                        )
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
                                                    .border(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.25f), RoundedCornerShape(AuroraRadius.full.dp))
                                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                                            )
                                            Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                        }
                                    }
                                    Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Text(
                                            text = "&&${snippet.trigger}",
                                            style = AuroraType.monoSmall,
                                            color = AuroraColors.hermesAureate,
                                            modifier = Modifier
                                                .background(
                                                    color = AuroraColors.hermesAureate.copy(alpha = 0.08f),
                                                    shape = RoundedCornerShape(AuroraRadius.full.dp),
                                                )
                                                .border(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.15f), RoundedCornerShape(AuroraRadius.full.dp))
                                                .padding(horizontal = 8.dp, vertical = 2.dp),
                                        )
                                        Text(
                                            text = "Static",
                                            style = AuroraType.tiny,
                                            color = textMutedColor,
                                            modifier = Modifier
                                                .background(
                                                    color = textMutedColor.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(AuroraRadius.full.dp),
                                                )
                                                .padding(horizontal = 6.dp, vertical = 1.dp),
                                        )
                                    }
                                    Spacer(modifier = Modifier.height(AuroraSpacing.xxs.dp))
                                    Text(
                                        text = relativeTime(snippet.updatedAtMillis),
                                        style = AuroraType.tiny,
                                        color = textMutedColor,
                                    )
                                }

                                // Quick Inline Toggle!
                                IconButton(
                                    onClick = {
                                        scope.launch {
                                            val updated = snippet.copy(
                                                isEnabled = !snippet.isEnabled,
                                                revision = snippet.revision + 1,
                                                updatedAtMillis = System.currentTimeMillis()
                                            )
                                            withContext(Dispatchers.IO) {
                                                AppDatabase.getDatabase(context).textExpansionDao().upsert(updated)
                                            }
                                            showToast(
                                                if (updated.isEnabled) "Enabled &&${updated.trigger}" else "Disabled &&${updated.trigger}"
                                            )
                                            reload()
                                        }
                                    }
                                ) {
                                    Icon(
                                        imageVector = if (snippet.isEnabled) Icons.Filled.CheckCircle else Icons.Filled.Block,
                                        contentDescription = "Toggle status",
                                        tint = if (snippet.isEnabled) AuroraColors.ember else textMutedColor.copy(alpha = 0.5f),
                                        modifier = Modifier.size(22.dp)
                                    )
                                }
                            }
                        }
                    }
                }

                // Bottom spacing
                item { Spacer(modifier = Modifier.height(AuroraSpacing.xxl.dp)) }
            }
        }

        // Dynamic Glassmorphic Floating Toast Notification Overlay
        AnimatedVisibility(
            visible = status != null,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = 20.dp)
        ) {
            Surface(
                shape = RoundedCornerShape(AuroraRadius.full.dp),
                color = surfaceElevatedColor.copy(alpha = 0.95f),
                border = BorderStroke(1.dp, borderSubtleColor),
                shadowElevation = 8.dp,
                modifier = Modifier.padding(horizontal = 24.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)
                ) {
                    Icon(
                        imageVector = if (statusIsError) Icons.Filled.Warning else Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = if (statusIsError) errorColor else successColor,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        text = status.orEmpty(),
                        style = AuroraType.body,
                        color = textPrimaryColor
                    )
                }
            }
        }
    }
}

private fun relativeTime(millis: Long): String {
    val seconds = (System.currentTimeMillis() - millis) / 1000
    if (seconds < 60) return "just now"
    val minutes = seconds / 60
    if (minutes < 60) return "${minutes}m ago"
    val hours = minutes / 60
    if (hours < 24) return "${hours}h ago"
    val days = hours / 24
    if (days < 30) return "${days}d ago"
    return java.text.SimpleDateFormat("MMM d", java.util.Locale.getDefault()).format(java.util.Date(millis))
}

// letterSpacing workaround: dp.value gives Float, needed for sp
private inline val Float.sp: androidx.compose.ui.unit.TextUnit
    get() = androidx.compose.ui.unit.TextUnit(this, androidx.compose.ui.unit.TextUnitType.Sp)
