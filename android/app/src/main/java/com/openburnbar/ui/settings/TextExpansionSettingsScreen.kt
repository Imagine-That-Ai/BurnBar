package com.openburnbar.ui.settings

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
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
    var snippets by remember { mutableStateOf<List<TextExpansionSnippetEntity>>(emptyList()) }
    var editing by remember { mutableStateOf<TextExpansionSnippetEntity?>(null) }
    var title by remember { mutableStateOf("") }
    var trigger by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var enabled by remember { mutableStateOf(true) }
    var status by remember { mutableStateOf<String?>(null) }
    var statusIsError by remember { mutableStateOf(false) }
    val prefs = remember(context) { context.getSharedPreferences("text_expansion_settings", android.content.Context.MODE_PRIVATE) }
    var cloudSyncEnabled by remember { mutableStateOf(prefs.getBoolean("cloud_sync_enabled", true)) }

    val surfaceColor = if (isDark) AuroraColors.darkSurface else AuroraColors.lightSurface
    val surfaceElevatedColor = if (isDark) AuroraColors.darkSurfaceElevated else AuroraColors.lightSurfaceElevated
    val borderSubtleColor = if (isDark) AuroraColors.darkBorderSubtle else AuroraColors.lightBorderSubtle
    val textPrimaryColor = if (isDark) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary
    val textSecondaryColor = if (isDark) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary
    val textMutedColor = if (isDark) AuroraColors.darkTextMuted else AuroraColors.lightTextMuted
    val successColor = if (isDark) AuroraColors.successDark else AuroraColors.success
    val errorColor = if (isDark) AuroraColors.errorDark else AuroraColors.error
    val backgroundCol = if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground

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
            trigger = "&&${snippet.trigger}"
            body = snippet.body
            enabled = snippet.isEnabled
        }
        status = null
    }

    // Auto-dismiss status
    LaunchedEffect(status) {
        if (status != null) {
            delay(2500)
            status = null
        }
    }

    LaunchedEffect(Unit) { reload() }

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
                ) {
                    Column(
                        modifier = Modifier.padding(AuroraSpacing.lg.dp),
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
                                        status = "Syncing..."
                                        statusIsError = false
                                        val result = withContext(Dispatchers.IO) {
                                            TextExpansionSyncManager(context).sync()
                                        }
                                        if (result.isSuccess) {
                                            status = "Sync complete"
                                            statusIsError = false
                                            reload()
                                        } else {
                                            status = result.exceptionOrNull()?.message ?: "Sync failed"
                                            statusIsError = true
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
                                shape = RoundedCornerShape(AuroraRadius.sm.dp),
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

            // Editor card
            item {
                Surface(
                    shape = RoundedCornerShape(AuroraRadius.md.dp),
                    color = surfaceElevatedColor,
                    border = BorderStroke(0.75.dp, borderSubtleColor),
                ) {
                    Column(
                        modifier = Modifier.padding(AuroraSpacing.lg.dp),
                        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
                    ) {
                        // Section header
                        Text(
                            text = (if (editing == null) "NEW SNIPPET" else "EDIT SNIPPET"),
                            style = AuroraType.tiny,
                            color = textMutedColor,
                            letterSpacing = 1.4.dp.value.sp,
                        )

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

                        // Fields
                        OutlinedTextField(
                            value = title,
                            onValueChange = { title = it },
                            label = { Text("Name", style = AuroraType.caption) },
                            textStyle = AuroraType.body,
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                        OutlinedTextField(
                            value = trigger,
                            onValueChange = { trigger = it },
                            label = { Text("Trigger", style = AuroraType.caption) },
                            textStyle = AuroraType.mono,
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                        )
                        OutlinedTextField(
                            value = body,
                            onValueChange = { body = it },
                            label = { Text("Snippet", style = AuroraType.caption) },
                            textStyle = AuroraType.body,
                            modifier = Modifier.fillMaxWidth(),
                            minLines = 4,
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
                                        status = "Saved &&${entity.trigger}"
                                        statusIsError = false
                                        if (cloudSyncEnabled) {
                                            TextExpansionSyncWorker.enqueueImmediate(context)
                                        }
                                        loadDraft(entity)
                                        reload()
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
                                shape = RoundedCornerShape(AuroraRadius.sm.dp),
                            ) {
                                Icon(Icons.Filled.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                Text("Save", style = AuroraType.caption)
                            }
                            Button(
                                enabled = editing != null,
                                onClick = {
                                    val target = editing ?: return@Button
                                    scope.launch {
                                        withContext(Dispatchers.IO) {
                                            AppDatabase.getDatabase(context).textExpansionDao().softDelete(target.id)
                                        }
                                        status = "Deleted &&${target.trigger}"
                                        statusIsError = false
                                        if (cloudSyncEnabled) {
                                            TextExpansionSyncWorker.enqueueImmediate(context)
                                        }
                                        loadDraft(null)
                                        reload()
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = errorColor.copy(alpha = 0.85f)),
                                shape = RoundedCornerShape(AuroraRadius.sm.dp),
                            ) {
                                Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                Text("Delete", style = AuroraType.caption)
                            }
                        }

                        // Status feedback
                        AnimatedVisibility(
                            visible = status != null,
                            enter = fadeIn(),
                            exit = fadeOut(),
                        ) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    imageVector = if (statusIsError) Icons.Filled.Warning else Icons.Filled.CheckCircle,
                                    contentDescription = null,
                                    tint = if (statusIsError) errorColor else successColor,
                                    modifier = Modifier.size(12.dp),
                                )
                                Text(
                                    text = status.orEmpty(),
                                    style = AuroraType.tiny,
                                    color = if (statusIsError) errorColor else successColor,
                                )
                            }
                        }
                    }
                }
            }

            // Saved snippets header
            item {
                Text(
                    text = "SAVED SNIPPETS",
                    style = AuroraType.tiny,
                    color = textMutedColor,
                    letterSpacing = 1.4.dp.value.sp,
                    modifier = Modifier.padding(top = AuroraSpacing.sm.dp),
                )
            }

            // Empty state
            if (snippets.isEmpty()) {
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
                        Text("No snippets saved", style = AuroraType.headline, color = textSecondaryColor)
                        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
                        Text("Create your first &&trigger", style = AuroraType.caption, color = textMutedColor)
                    }
                }
            }

            // Snippet cards
            items(snippets, key = { it.id }) { snippet ->
                Surface(
                    onClick = { loadDraft(snippet) },
                    shape = RoundedCornerShape(AuroraRadius.md.dp),
                    color = surfaceColor,
                    border = BorderStroke(0.75.dp, borderSubtleColor),
                    modifier = Modifier
                        .fillMaxWidth()
                        .animateItem(),
                ) {
                    Column(
                        modifier = Modifier
                            .padding(AuroraSpacing.md.dp)
                            .alpha(if (snippet.isEnabled) 1f else 0.55f),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = snippet.title,
                                style = AuroraType.headline,
                                color = textPrimaryColor,
                                modifier = Modifier.weight(1f),
                            )
                            if (!snippet.isEnabled) {
                                Icon(
                                    Icons.Filled.Block,
                                    contentDescription = "Disabled",
                                    tint = textMutedColor,
                                    modifier = Modifier.size(14.dp),
                                )
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
                                color = textSecondaryColor,
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
                }
            }

            // Bottom spacing
            item { Spacer(modifier = Modifier.height(AuroraSpacing.xxl.dp)) }
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
