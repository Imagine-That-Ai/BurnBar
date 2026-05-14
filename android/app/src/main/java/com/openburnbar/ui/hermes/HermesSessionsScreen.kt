package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.hermes.HermesSessionSummary
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import kotlinx.coroutines.launch

/**
 * Browser for host-side Hermes sessions. Reads from `service.sessions`,
 * imports the selected session into the local chat history store, then
 * returns the new thread id via [onImported].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HermesSessionsScreen(
    service: HermesService,
    onBack: () -> Unit,
    onImported: (threadId: String) -> Unit
) {
    val sessions by service.sessions.collectAsState()
    val isLoading by service.isLoadingSessions.collectAsState()
    val error by service.sessionsErrorText.collectAsState()
    val scope = rememberCoroutineScope()
    var importingId by remember { mutableStateOf<String?>(null) }
    var errorDialog by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { scope.launch { service.refreshSessions() } }
    LaunchedEffect(error) { error?.let { errorDialog = it } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Hermes library", fontSize = AuroraTypography.headline.sp, fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back"
                        )
                    }
                },
                actions = {
                    IconButton(
                        onClick = { scope.launch { service.refreshSessions() } },
                        enabled = !isLoading
                    ) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            when {
                isLoading && sessions.isEmpty() -> CircularProgressIndicator(
                    modifier = Modifier.align(Alignment.Center),
                    color = AuroraColors.hermesMercury
                )
                sessions.isEmpty() -> EmptyState()
                else -> LazyColumn(
                    contentPadding = PaddingValues(AuroraSpacing.md.dp),
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
                ) {
                    items(sessions) { session ->
                        SessionRow(
                            session = session,
                            isImporting = importingId == session.id,
                            onClick = {
                                if (importingId == null) {
                                    importingId = session.id
                                    scope.launch {
                                        val thread = service.importSession(session.id)
                                        importingId = null
                                        if (thread != null) onImported(thread)
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    errorDialog?.let { message ->
        AlertDialog(
            onDismissRequest = { errorDialog = null },
            confirmButton = {
                TextButton(onClick = { errorDialog = null }) { Text("OK") }
            },
            title = { Text("Could not load Hermes sessions") },
            text = { Text(message) }
        )
    }
}

@Composable
private fun EmptyState() {
    Column(
        modifier = Modifier.fillMaxSize().padding(AuroraSpacing.xl.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            Icons.Filled.History,
            contentDescription = null,
            tint = AuroraColors.hermesMercury,
            modifier = Modifier.size(48.dp)
        )
        Spacer(Modifier.height(AuroraSpacing.md.dp))
        Text(
            text = "No Hermes sessions yet",
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(Modifier.height(AuroraSpacing.xs.dp))
        Text(
            text = "Sessions you run on a paired Hermes host will appear here for import.",
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun SessionRow(
    session: HermesSessionSummary,
    isImporting: Boolean,
    onClick: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .clickable(enabled = !isImporting, onClick = onClick),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        tonalElevation = 1.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = session.title?.takeIf { it.isNotBlank() } ?: "Hermes session",
                    fontSize = AuroraTypography.body.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(AuroraSpacing.xxs.dp))
                Text(
                    text = session.preview?.takeIf { it.isNotBlank() }
                        ?: session.model?.let { "model: $it" }
                        ?: "${session.messageCount} messages",
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (isImporting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    color = AuroraColors.hermesMercury,
                    strokeWidth = 2.dp
                )
            }
        }
    }
}
