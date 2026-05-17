package com.openburnbar.ui.computeruse

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.computeruse.ComputerUseActionLogEntry
import com.openburnbar.data.computeruse.ComputerUseActionStatus
import com.openburnbar.data.computeruse.ComputerUseApprovalRequest
import com.openburnbar.data.computeruse.ComputerUseTrustMode
import com.openburnbar.data.computeruse.ComputerUseWatchReducer
import com.openburnbar.data.computeruse.ComputerUseWatchState
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing

@Composable
fun rememberComputerUseWatchReducer(): ComputerUseWatchReducer = remember { ComputerUseWatchReducer() }

/**
 * Android Agent Watch surface. It mirrors the iOS first screen: full-bleed
 * watch area, trust-mode status, action timeline, approval controls, and a
 * long-press panic halt affordance.
 */
@Composable
fun ComputerUseAgentWatchScreen(
    reducer: ComputerUseWatchReducer = rememberComputerUseWatchReducer(),
    modifier: Modifier = Modifier,
) {
    val state by reducer.state.collectAsState()
    ComputerUseAgentWatchContent(
        state = state,
        onApprove = { reducer.approve(System.currentTimeMillis()) },
        onReject = { reducer.reject(halt = false, nowMillis = System.currentTimeMillis()) },
        onRejectAndHalt = { reducer.reject(halt = true, nowMillis = System.currentTimeMillis()) },
        onDowngrade = reducer::downgradeTrustMode,
        onPanic = reducer::panicHalt,
        modifier = modifier,
    )
}

@Composable
fun ComputerUseAgentWatchContent(
    state: ComputerUseWatchState,
    onApprove: () -> Unit,
    onReject: () -> Unit,
    onRejectAndHalt: () -> Unit,
    onDowngrade: (ComputerUseTrustMode) -> Unit,
    onPanic: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(Unit) {
                detectTapGestures(onLongPress = { onPanic() })
            }
    ) {
        WatchPlaceholder(state = state, modifier = Modifier.fillMaxSize())

        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StatusStrip(state = state, onDowngrade = onDowngrade)
            if (state.deniedReason != null) {
                Text(
                    text = "Denied: ${state.deniedReason}",
                    color = AuroraColors.blaze,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                )
            }
        }

        state.currentFrame?.cursor?.let { cursor ->
            CursorDot(
                xFraction = (cursor.x.toFloat() / 1920f).coerceIn(0f, 1f),
                yFraction = (cursor.y.toFloat() / 1080f).coerceIn(0f, 1f),
                modifier = Modifier.fillMaxSize(),
            )
        }

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            TimelinePreview(entries = state.actionTimeline.takeLast(3))
            state.pendingApproval?.let {
                ApprovalRow(
                    request = it,
                    onApprove = onApprove,
                    onReject = onReject,
                    onRejectAndHalt = onRejectAndHalt,
                )
            }
        }
    }
}

@Composable
private fun WatchPlaceholder(state: ComputerUseWatchState, modifier: Modifier = Modifier) {
    Box(modifier = modifier.background(Color(0xFF070707)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = if (state.currentFrame == null) "Waiting for Mac surface stream" else "Agent Watch live",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = state.sessionId ?: "No active Computer Use session",
                color = Color.White.copy(alpha = 0.58f),
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun StatusStrip(
    state: ComputerUseWatchState,
    onDowngrade: (ComputerUseTrustMode) -> Unit,
) {
    Surface(
        color = Color.Black.copy(alpha = 0.58f),
        shape = RoundedCornerShape(18.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Watching", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            Text(state.trustMode.name.lowercase().replaceFirstChar { it.uppercase() }, color = AuroraColors.hermesAureate, fontSize = 12.sp)
            if (state.trustMode != ComputerUseTrustMode.MANUAL) {
                OutlinedButton(onClick = { onDowngrade(ComputerUseTrustMode.MANUAL) }) {
                    Text("Manual")
                }
            }
        }
    }
}

@Composable
private fun CursorDot(xFraction: Float, yFraction: Float, modifier: Modifier = Modifier) {
    Box(modifier = modifier.padding(18.dp)) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(
                    start = (xFraction * 300).dp,
                    top = (yFraction * 520).dp,
                )
        ) {
            Box(
                modifier = Modifier
                    .size(14.dp)
                    .clip(CircleShape)
                    .background(AuroraColors.hermesAureate)
            )
        }
    }
}

@Composable
private fun TimelinePreview(entries: List<ComputerUseActionLogEntry>) {
    if (entries.isEmpty()) return
    Surface(
        color = Color.Black.copy(alpha = 0.62f),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            entries.forEach { entry ->
                Text(
                    text = "${entry.entryIndex.toString().padStart(2, '0')}  ${entry.status.label()}  ${entry.summary}",
                    color = Color.White,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

@Composable
private fun ApprovalRow(
    request: ComputerUseApprovalRequest,
    onApprove: () -> Unit,
    onReject: () -> Unit,
    onRejectAndHalt: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        shape = RoundedCornerShape(20.dp),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(request.actionSummary, fontWeight = FontWeight.SemiBold)
            Text(request.toolKind, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onApprove, colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesAureate)) {
                    Text("Approve")
                }
                OutlinedButton(onClick = onReject) {
                    Text("Reject")
                }
                Button(onClick = onRejectAndHalt, colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.blaze)) {
                    Text("Halt")
                }
            }
        }
    }
}

private fun ComputerUseActionStatus.label(): String = when (this) {
    ComputerUseActionStatus.PLANNED -> "planned"
    ComputerUseActionStatus.AWAITING_APPROVAL -> "approval"
    ComputerUseActionStatus.EXECUTING -> "running"
    ComputerUseActionStatus.COMPLETED -> "done"
    ComputerUseActionStatus.REJECTED -> "rejected"
    ComputerUseActionStatus.FAILED -> "failed"
    ComputerUseActionStatus.PANIC_HALTED -> "halted"
}

