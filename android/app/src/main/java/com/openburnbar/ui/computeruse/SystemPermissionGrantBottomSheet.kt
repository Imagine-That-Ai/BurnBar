@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.computeruse

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import com.openburnbar.data.computeruse.PhoneControlSystemPermissionRequest
import com.openburnbar.data.computeruse.SystemPermissionItem

/**
 * Phase 14 — Android counterpart of `SystemPermissionGrantSheet`. Same
 * three CTAs, same numbered footer, same hero copy keyed off the
 * `PhoneControlSystemPermissionKind`. `sendPermissionRequest` is
 * injected so tests can drive the sheet without a live iroh stream.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SystemPermissionGrantBottomSheet(
    item: SystemPermissionItem,
    onDismiss: () -> Unit,
    sendPermissionRequest: suspend (PhoneControlSystemPermissionRequest) -> Result<Unit>,
) {
    SystemPermissionGrantBottomSheetContent(
        item = item,
        onDismiss = onDismiss,
        sendPermissionRequest = sendPermissionRequest,
    )
}
