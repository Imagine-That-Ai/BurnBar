@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
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
    val borderBrush =
        when (state) {
            is AttachmentBubbleState.Error ->
                androidx.compose.ui.graphics.Brush.horizontalGradient(
                    listOf(
                        androidx.compose.ui.graphics.Color(0xFFCC4242),
                        androidx.compose.ui.graphics.Color(0xFFCC4242).copy(alpha = 0.4f),
                    ),
                )
            else ->
                androidx.compose.ui.graphics.Brush.horizontalGradient(
                    listOf(
                        AuroraColors.hermesMercury.copy(alpha = 0.85f),
                        AuroraColors.hermesAureate.copy(alpha = 0.7f),
                        AuroraColors.hermesMercury.copy(alpha = 0.85f),
                    ),
                )
        }

    Column(
        modifier =
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(AuroraColors.darkSurface)
            .border(width = 1.dp, brush = borderBrush, shape = RoundedCornerShape(18.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        AttachmentBubblePreviewRow(manifest = manifest, state = state)

        AttachmentBubbleStateActions(
            manifest = manifest,
            state = state,
            onPreview = onPreview,
            onSavePhotos = onSavePhotos,
            onSaveFiles = onSaveFiles,
            onRetry = onRetry,
        )
    }
}

sealed class AttachmentBubbleState {
    data class InFlight(val progress: Double) : AttachmentBubbleState()

    data class Complete(val destinationUri: String?) : AttachmentBubbleState()

    data class Error(val message: String) : AttachmentBubbleState()
}
