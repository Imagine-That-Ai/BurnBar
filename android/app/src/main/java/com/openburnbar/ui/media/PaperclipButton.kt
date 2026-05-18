package com.openburnbar.ui.media

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors

/**
 * Paperclip button for the chat composer. 1:1 port of iOS
 * `PaperclipButton.swift`. On tap, fires a unified picker
 * (`OpenDocument`) so the user can pick any file. Use the returned URI
 * with `AndroidFileTransferService.sendFile(...)`.
 *
 * Image-only pickers can swap in `PickVisualMedia` — pass the
 * `useImagePicker = true` parameter.
 */
@Composable
fun PaperclipButton(
    onPicked: (Uri) -> Unit,
    modifier: Modifier = Modifier,
    useImagePicker: Boolean = false,
) {
    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri -> uri?.let(onPicked) }

    val imagePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri -> uri?.let(onPicked) }

    IconButton(
        onClick = {
            if (useImagePicker) {
                imagePicker.launch(
                    androidx.activity.result.PickVisualMediaRequest(
                        ActivityResultContracts.PickVisualMedia.ImageAndVideo,
                    ),
                )
            } else {
                documentPicker.launch(arrayOf("*/*"))
            }
        },
        modifier = modifier.size(40.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.AttachFile,
            contentDescription = "Attach a file",
            tint = AuroraColors.darkTextSecondary,
        )
    }
}
