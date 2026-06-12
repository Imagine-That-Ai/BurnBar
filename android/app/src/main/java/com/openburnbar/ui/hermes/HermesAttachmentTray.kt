package com.openburnbar.ui.hermes

import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun HermesAttachmentTray(
    attachments: List<HermesAttachment>,
    onAddAttachment: (HermesAttachment) -> Unit,
    onRemoveAttachment: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current

    val photoPicker =
        rememberLauncherForActivityResult(
            contract = ActivityResultContracts.GetContent(),
        ) { uri: Uri? ->
            uri?.let { onAddAttachment(buildAttachment(context, it, fallbackName = "image.jpg", fallbackMime = "image/jpeg")) }
        }

    val filePicker =
        rememberLauncherForActivityResult(
            contract = ActivityResultContracts.OpenDocument(),
        ) { uri: Uri? ->
            uri?.let { onAddAttachment(buildAttachment(context, it, fallbackName = "file", fallbackMime = "application/octet-stream")) }
        }

    Column(modifier = modifier.fillMaxWidth()) {
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(attachments) { attachment ->
                AttachmentChip(
                    attachment = attachment,
                    onRemove = { onRemoveAttachment(attachment.id) },
                )
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

        Row(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            AttachmentActionChip(
                icon = Icons.Filled.Image,
                label = "Photo",
                onClick = { photoPicker.launch("image/*") },
            )
            AttachmentActionChip(
                icon = Icons.Filled.AttachFile,
                label = "File",
                onClick = { filePicker.launch(arrayOf("*/*")) },
            )
        }
    }
}

@Composable
private fun AttachmentChip(attachment: HermesAttachment, onRemove: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier) {
        AttachmentChipBody(attachment = attachment)
        IconButton(
            onClick = onRemove,
            modifier =
            Modifier
                .size(20.dp)
                .align(Alignment.TopEnd)
                .offset(x = 4.dp, y = (-4).dp)
                .background(AuroraColors.error, CircleShape),
        ) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Remove",
                tint = Color.White,
                modifier = Modifier.size(12.dp),
            )
        }
    }
}

@Composable
private fun AttachmentChipBody(attachment: HermesAttachment) {
    val isImage = attachment.mimeType.startsWith("image/")
    var thumbnail by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    val context = LocalContext.current

    LaunchedEffect(attachment.uriString) {
        if (isImage && attachment.uriString != null) {
            thumbnail = loadAttachmentThumbnail(context, attachment.uriString)
        }
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier =
        Modifier
            .width(80.dp)
            .clip(RoundedCornerShape(AuroraRadius.md.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.72f))
            .padding(AuroraSpacing.sm.dp),
    ) {
        AttachmentChipPreview(isImage = isImage, thumbnail = thumbnail)
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Text(
            text = attachment.fileName,
            fontSize = AuroraTypography.tiny.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AttachmentChipPreview(isImage: Boolean, thumbnail: androidx.compose.ui.graphics.ImageBitmap?) {
    if (thumbnail != null) {
        Image(
            bitmap = thumbnail,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier =
            Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(AuroraRadius.sm.dp)),
        )
    } else {
        Icon(
            imageVector = if (isImage) Icons.Filled.Image else Icons.AutoMirrored.Filled.InsertDriveFile,
            contentDescription = null,
            modifier = Modifier.size(32.dp),
            tint = AuroraColors.hermesMercury,
        )
    }
}

/**
 * Short-edge pixel target for the 48dp attachment chip: 48dp at 3x density.
 * Decoding to this size instead of full resolution keeps a 12MP photo's
 * thumbnail under ~200KB instead of ~48MB.
 */
internal const val ATTACHMENT_THUMBNAIL_TARGET_PX = 144

/**
 * Largest power-of-two [BitmapFactory.Options.inSampleSize] that keeps the
 * decoded short edge at or above [ATTACHMENT_THUMBNAIL_TARGET_PX], so the
 * `ContentScale.Crop` chip never upscales. Unknown bounds fall back to 1.
 */
internal fun attachmentThumbnailSampleSize(width: Int, height: Int): Int {
    if (width <= 0 || height <= 0) return 1
    var sampleSize = 1
    while (minOf(width, height) / (sampleSize * 2) >= ATTACHMENT_THUMBNAIL_TARGET_PX) {
        sampleSize *= 2
    }
    return sampleSize
}

private suspend fun loadAttachmentThumbnail(
    context: android.content.Context,
    uriString: String,
): androidx.compose.ui.graphics.ImageBitmap? = withContext(Dispatchers.IO) {
    try {
        val uri = Uri.parse(uriString)
        // Two-pass decode: read bounds only, then re-open the stream (content
        // streams are not rewindable) and decode at the sampled size.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, bounds)
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = attachmentThumbnailSampleSize(bounds.outWidth, bounds.outHeight)
        }
        context.contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, options)?.asImageBitmap()
        }
    } catch (_: Exception) {
        null
    }
}

@Composable
private fun AttachmentActionChip(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        modifier
            .clip(RoundedCornerShape(AuroraRadius.full.dp))
            .clickable(onClick = onClick)
            .background(AuroraColors.hermesMercury.copy(alpha = 0.12f))
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = AuroraColors.hermesAureate,
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        Text(
            text = label,
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.hermesAureate,
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
private fun buildAttachment(context: android.content.Context, uri: Uri, fallbackName: String, fallbackMime: String): HermesAttachment {
    val displayName = getFileName(context, uri) ?: fallbackName
    val mime = context.contentResolver.getType(uri) ?: fallbackMime
    val materialised = HermesAttachmentLoader.materialise(context, uri, displayName)
    val size = materialised?.let { runCatching { java.io.File(it).length() }.getOrNull() }
    return HermesAttachment(
        fileName = displayName,
        mimeType = mime,
        uriString = uri.toString(),
        absolutePath = materialised,
        sizeBytes = size,
    )
}
