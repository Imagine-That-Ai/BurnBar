package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.media.AttachmentSaver
import com.openburnbar.irohrelay.HermesRealtimeRelayAttachmentManifest
import com.openburnbar.ui.theme.AuroraColors

/**
 * 1:1 Compose port of iOS `AttachmentBubble.swift`. Mercury-stroked
 * attachment row shown in the chat thread when a peer (or the local
 * user) attaches a file. Image MIME types surface a Photos action;
 * everything else falls through to Files / SAF.
 */
@Composable
fun AttachmentBubble(
    manifest: HermesRealtimeRelayAttachmentManifest,
    state: AttachmentBubbleState,
    onPreview: () -> Unit,
    onSavePhotos: () -> Unit,
    onSaveFiles: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val borderBrush = when (state) {
        is AttachmentBubbleState.Error -> Brush.horizontalGradient(
            listOf(Color(0xFFCC4242), Color(0xFFCC4242).copy(alpha = 0.4f))
        )
        else -> Brush.horizontalGradient(
            listOf(
                AuroraColors.hermesMercury.copy(alpha = 0.85f),
                AuroraColors.hermesAureate.copy(alpha = 0.7f),
                AuroraColors.hermesMercury.copy(alpha = 0.85f),
            )
        )
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(AuroraColors.darkSurface)
            .border(width = 1.dp, brush = borderBrush, shape = RoundedCornerShape(18.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(AuroraColors.ember.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                val glyph = when (state) {
                    is AttachmentBubbleState.Error -> Icons.Outlined.ErrorOutline
                    else -> when {
                        manifest.mime.startsWith("image/") -> Icons.Outlined.Image
                        manifest.mime.startsWith("video/") -> Icons.Outlined.Movie
                        else -> Icons.Outlined.Description
                    }
                }
                Icon(
                    imageVector = glyph,
                    contentDescription = null,
                    tint = if (state is AttachmentBubbleState.Error) Color(0xFFCC4242) else AuroraColors.ember,
                )
            }

            Spacer(Modifier.size(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = manifest.filename,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = AuroraColors.darkTextPrimary,
                )
                Text(
                    text = secondaryLine(manifest = manifest, state = state),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    color = AuroraColors.darkTextSecondary,
                )
            }
        }

        when (state) {
            is AttachmentBubbleState.InFlight -> Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(2.dp)
                    .clip(RoundedCornerShape(1.dp))
                    .background(AuroraColors.darkBorderSubtle),
            ) {
                val progress = state.progress.coerceIn(0.0, 1.0).toFloat()
                Box(
                    modifier = Modifier
                        .fillMaxWidth(progress)
                        .height(2.dp)
                        .background(
                            Brush.horizontalGradient(
                                listOf(
                                    AuroraColors.hermesMercury,
                                    AuroraColors.hermesAureate,
                                )
                            )
                        ),
                )
            }

            is AttachmentBubbleState.Complete -> Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (state.destinationUri != null) {
                    Button(
                        onClick = onPreview,
                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember),
                    ) { Text("Preview") }
                }
                if (AttachmentSaver.isPhotoCandidate(manifest.mime)) {
                    OutlinedButton(onClick = onSavePhotos) { Text("Photos") }
                }
                OutlinedButton(onClick = onSaveFiles) { Text("Files") }
            }

            is AttachmentBubbleState.Error -> TextButton(onClick = onRetry) { Text("Retry") }
        }
    }
}

sealed class AttachmentBubbleState {
    data class InFlight(val progress: Double) : AttachmentBubbleState()
    data class Complete(val destinationUri: String?) : AttachmentBubbleState()
    data class Error(val message: String) : AttachmentBubbleState()
}

private fun secondaryLine(
    manifest: HermesRealtimeRelayAttachmentManifest,
    state: AttachmentBubbleState,
): String {
    val size = humanReadableBytes(manifest.size)
    return when (state) {
        is AttachmentBubbleState.InFlight -> "$size · ${(state.progress * 100).toInt()}%"
        is AttachmentBubbleState.Complete -> size
        is AttachmentBubbleState.Error -> state.message
    }
}

private fun humanReadableBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return String.format("%.1f KB", kb)
    val mb = kb / 1024.0
    if (mb < 1024) return String.format("%.1f MB", mb)
    val gb = mb / 1024.0
    return String.format("%.1f GB", gb)
}
