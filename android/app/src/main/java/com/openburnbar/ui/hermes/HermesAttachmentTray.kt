package com.openburnbar.ui.hermes

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesAttachment
import com.openburnbar.data.hermes.HermesAttachmentLoader
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun HermesAttachmentTray(
    attachments: List<HermesAttachment>,
    onAddAttachment: (HermesAttachment) -> Unit,
    onRemoveAttachment: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        uri?.let { onAddAttachment(buildAttachment(context, it, fallbackName = "image.jpg", fallbackMime = "image/jpeg")) }
    }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let { onAddAttachment(buildAttachment(context, it, fallbackName = "file", fallbackMime = "application/octet-stream")) }
    }

    Column(modifier = modifier.fillMaxWidth()) {
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            items(attachments) { attachment ->
                AttachmentChip(
                    attachment = attachment,
                    onRemove = { onRemoveAttachment(attachment.id) }
                )
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

        Row(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            AttachmentActionChip(
                icon = Icons.Filled.Image,
                label = "Photo",
                onClick = { photoPicker.launch("image/*") }
            )
            AttachmentActionChip(
                icon = Icons.Filled.AttachFile,
                label = "File",
                onClick = { filePicker.launch(arrayOf("*/*")) }
            )
        }
    }
}

@Composable
private fun AttachmentChip(
    attachment: HermesAttachment,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val isImage = attachment.mimeType.startsWith("image/")
    var thumbnail by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }

    LaunchedEffect(attachment.uriString) {
        if (isImage && attachment.uriString != null) {
            try {
                val uri = Uri.parse(attachment.uriString)
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    val bitmap = BitmapFactory.decodeStream(stream)
                    thumbnail = bitmap?.asImageBitmap()
                }
            } catch (_: Exception) {
            }
        }
    }

    Box(modifier = modifier) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .width(80.dp)
                .clip(RoundedCornerShape(AuroraRadius.md.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f))
                .padding(AuroraSpacing.sm.dp)
        ) {
            if (thumbnail != null) {
                Image(
                    bitmap = thumbnail!!,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(48.dp)
                        .clip(RoundedCornerShape(AuroraRadius.sm.dp))
                )
            } else {
                Icon(
                    imageVector = if (isImage) Icons.Filled.Image else Icons.Filled.InsertDriveFile,
                    contentDescription = null,
                    modifier = Modifier.size(32.dp),
                    tint = AuroraColors.hermesMercury
                )
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
            Text(
                text = attachment.fileName,
                fontSize = AuroraTypography.tiny.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        IconButton(
            onClick = onRemove,
            modifier = Modifier
                .size(20.dp)
                .align(Alignment.TopEnd)
                .offset(x = 4.dp, y = (-4).dp)
                .background(AuroraColors.error, CircleShape)
        ) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Remove",
                tint = Color.White,
                modifier = Modifier.size(12.dp)
            )
        }
    }
}

@Composable
private fun AttachmentActionChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .clickable(onClick = onClick)
            .background(AuroraColors.hermesMercury.copy(alpha = 0.12f))
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = AuroraColors.hermesAureate
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        Text(
            text = label,
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.hermesAureate
        )
    }
}

private fun getFileName(context: android.content.Context, uri: Uri): String? {
    var result: String? = null
    if (uri.scheme == "content") {
        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (index >= 0) result = cursor.getString(index)
            }
        }
    }
    if (result == null) {
        result = uri.lastPathSegment
    }
    return result
}

/**
 * Build a fully-loaded [HermesAttachment] for the supplied content URI.
 *
 * Critically, this **materialises** the URI to an app-private cache
 * file so the encoder can read it without keeping a fragile URI
 * permission grant alive across process death. Without this step the
 * encoder falls back to `[unreadable attachment ...]` for every
 * attachment — silently breaking multimodal sends.
 */
private fun buildAttachment(
    context: android.content.Context,
    uri: Uri,
    fallbackName: String,
    fallbackMime: String
): HermesAttachment {
    val displayName = getFileName(context, uri) ?: fallbackName
    val mime = context.contentResolver.getType(uri) ?: fallbackMime
    val materialised = HermesAttachmentLoader.materialise(context, uri, displayName)
    val size = materialised?.let { runCatching { java.io.File(it).length() }.getOrNull() }
    return HermesAttachment(
        fileName = displayName,
        mimeType = mime,
        uriString = uri.toString(),
        absolutePath = materialised,
        sizeBytes = size
    )
}
