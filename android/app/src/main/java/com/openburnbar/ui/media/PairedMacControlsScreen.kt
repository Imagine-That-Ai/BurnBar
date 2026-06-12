// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
fun PairedMacControlsScreen(connectionID: String? = null, modifier: Modifier = Modifier) {
    PairedMacControlsScreenContent(connectionID = connectionID, modifier = modifier)
}
