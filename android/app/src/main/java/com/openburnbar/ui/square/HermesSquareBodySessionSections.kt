// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.assistants.CLIAgentRelayChatTransport
import com.openburnbar.data.assistants.CLIAgentSessionActionKind
import com.openburnbar.data.assistants.CLIAgentSessionActionRequest
import com.openburnbar.data.assistants.CLIAgentSessionActionStatus
import com.openburnbar.data.cloud.CloudConversationSearchRow
import com.openburnbar.data.hermes.HermesService
import com.openburnbar.data.square.CLIAgentMessage
import com.openburnbar.data.square.CLIAgentSessionRecord
import com.openburnbar.data.stores.ActivityStore
import kotlinx.coroutines.launch

@Composable
internal fun CLIAgentSessionSheet(session: CLIAgentSessionRecord, hermesService: HermesService, onDismiss: () -> Unit) {
    val transport = remember(hermesService) { CLIAgentRelayChatTransport(hermesService) }
    val actionState = rememberCLIAgentSessionActionState(session = session, transport = transport)

    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.48f))
            .clickableUnit(onClick = onDismiss),
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            tonalElevation = 4.dp,
            modifier =
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(560.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier =
                Modifier
                    .fillMaxSize()
                    .padding(18.dp),
            ) {
                CLIAgentSessionSheetHeader(session = session, onDismiss = onDismiss)
                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.22f))
                CLIAgentSessionActionButtons(
                    session = session,
                    isStarting = actionState.isStarting,
                    actionMessage = actionState.actionMessage,
                    actionIsError = actionState.actionIsError,
                    onResume = actionState.onResume,
                    onOpenPackage = actionState.onOpenPackage,
                )
                CLIAgentSessionMessageList(session = session, modifier = Modifier.weight(1f))
            }
        }
    }
}

private data class CLIAgentSessionActionState(
    val isStarting: Boolean,
    val actionMessage: String?,
    val actionIsError: Boolean,
    val onResume: () -> Unit,
    val onOpenPackage: () -> Unit,
)

@Composable
private fun rememberCLIAgentSessionActionState(
    session: CLIAgentSessionRecord,
    transport: CLIAgentRelayChatTransport,
): CLIAgentSessionActionState {
    val scope = rememberCoroutineScope()
    var isStarting by remember(session.id) { mutableStateOf(false) }
    var actionMessage by remember(session.id) { mutableStateOf<String?>(null) }
    var actionIsError by remember(session.id) { mutableStateOf(false) }

    fun startSessionAction(action: CLIAgentSessionActionKind, targetRuntime: String?) {
        if (isStarting) return
        isStarting = true
        actionIsError = false
        actionMessage = "Sending ${session.title} to your Mac..."
        scope.launch {
            try {
                val response =
                    transport.performSessionAction(
                        CLIAgentSessionActionRequest(
                            sessionID = session.resumeLookupID,
                            action = action,
                            targetRuntime = targetRuntime ?: session.agent,
                        ),
                    )
                actionIsError = response.status == CLIAgentSessionActionStatus.ERROR
                actionMessage =
                    if (actionIsError) {
                        response.errorRecovery ?: response.errorCode ?: "The Mac could not restart this session."
                    } else {
                        when (response.status) {
                            CLIAgentSessionActionStatus.NATIVE_RESUME -> "Native resume opened on your Mac."
                            CLIAgentSessionActionStatus.HANDOFF -> "Handoff package opened on your Mac."
                            CLIAgentSessionActionStatus.PACKAGE_ONLY -> "Resume package is open on your Mac."
                            CLIAgentSessionActionStatus.SPAWNED -> "Mac session opened."
                            CLIAgentSessionActionStatus.ERROR -> "The Mac could not restart this session."
                        }
                    }
            } catch (t: IllegalStateException) {
                actionIsError = true
                actionMessage = t.message ?: "The Mac could not restart this session."
            } finally {
                isStarting = false
            }
        }
    }

    return CLIAgentSessionActionState(
        isStarting = isStarting,
        actionMessage = actionMessage,
        actionIsError = actionIsError,
        onResume = { startSessionAction(CLIAgentSessionActionKind.RESUME, null) },
        onOpenPackage = { startSessionAction(CLIAgentSessionActionKind.PACKAGE_ONLY, null) },
    )
}

@Composable
private fun CLIAgentSessionSheetHeader(session: CLIAgentSessionRecord, onDismiss: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                session.title,
                fontSize = 17.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOf(session.agent, session.modelName.orEmpty(), session.workspaceLabel.orEmpty())
                    .filter { it.isNotBlank() }
                    .joinToString(" · "),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onDismiss) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Close",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CLIAgentSessionActionButtons(
    session: CLIAgentSessionRecord,
    isStarting: Boolean,
    actionMessage: String?,
    actionIsError: Boolean,
    onResume: () -> Unit,
    onOpenPackage: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            Button(
                onClick = onResume,
                enabled = !isStarting,
                modifier = Modifier.weight(1f),
            ) {
                Text(if (isStarting) "Starting..." else "Resume on Mac")
            }
            TextButton(
                onClick = onOpenPackage,
                enabled = !isStarting,
                modifier = Modifier.weight(1f),
            ) {
                Text("Open package")
            }
        }
        Text(
            text = actionMessage ?: if (session.canResume) "Native resume is available when the Mac validates this handle." else "This provider uses a Mac-local handoff package.",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (actionIsError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun CLIAgentSessionMessageList(session: CLIAgentSessionRecord, modifier: Modifier = Modifier) {
    if (session.messages.isEmpty()) {
        Text(
            session.preview.ifBlank { "No mirrored messages yet." },
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp),
        )
        return
    }
    Column(
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
    ) {
        session.messages.forEach { message ->
            CLIAgentMessageBubble(message = message)
        }
    }
}

@Composable
private fun CLIAgentMessageBubble(message: CLIAgentMessage) {
    val isUser = message.role.equals("user", ignoreCase = true)
    Surface(
        shape = RoundedCornerShape(12.dp),
        color =
        if (isUser) {
            MaterialTheme.colorScheme.primary.copy(alpha = 0.16f)
        } else {
            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(12.dp),
        ) {
            Text(
                message.role.uppercase(),
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = if (message.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (message.text.isNotBlank()) {
                Text(
                    message.text,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            if (message.toolUses.isNotEmpty()) {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(message.toolUses, key = { it.id }) { tool ->
                        Surface(
                            shape = RoundedCornerShape(999.dp),
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                        ) {
                            Text(
                                listOf(tool.name, tool.status, tool.detail.orEmpty())
                                    .filter { it.isNotBlank() }
                                    .joinToString(" · "),
                                fontSize = 10.sp,
                                color = MaterialTheme.colorScheme.primary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun CloudSessionResultSheet(row: CloudConversationSearchRow, activityStore: ActivityStore, onDismiss: () -> Unit) {
    var bodyText by remember(row.id) { mutableStateOf<String?>(null) }
    var errorText by remember(row.id) { mutableStateOf<String?>(null) }
    var isLoading by remember(row.id) { mutableStateOf(true) }

    LaunchedEffect(row.id) {
        isLoading = true
        errorText = null
        bodyText = null
        runCatching { activityStore.loadCloudConversationBody(row) }
            .onSuccess { bodyText = it }
            .onFailure { errorText = it.message ?: it::class.java.simpleName }
        isLoading = false
    }

    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.48f))
            .clickableUnit(onClick = onDismiss),
    ) {
        Surface(
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            tonalElevation = 4.dp,
            modifier =
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(520.dp),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier =
                Modifier
                    .fillMaxSize()
                    .padding(18.dp),
            ) {
                CloudSessionSheetHeader(row = row, onDismiss = onDismiss)
                Text(
                    row.snippet,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.22f))
                CloudSessionSheetBody(
                    modifier = Modifier.weight(1f),
                    isLoading = isLoading,
                    errorText = errorText,
                    bodyText = bodyText,
                )
            }
        }
    }
}

@Composable
private fun CloudSessionSheetHeader(row: CloudConversationSearchRow, onDismiss: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                row.title,
                fontSize = 17.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(row.provider).joinToString(" · ")
                    .ifBlank { "Encrypted cloud session" },
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onDismiss) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Close",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CloudSessionSheetBody(modifier: Modifier, isLoading: Boolean, errorText: String?, bodyText: String?) {
    when {
        isLoading -> {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = 12.dp),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Text(
                    "Decrypting transcript…",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        errorText != null -> {
            Text(
                errorText ?: "Unable to open encrypted transcript.",
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.error,
            )
        }
        else -> {
            Text(
                bodyText.orEmpty(),
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
            )
        }
    }
}
