package com.openburnbar.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing

/**
 * Aurora bottom sheet — wraps M3 ModalBottomSheet with our glass surface,
 * a brand-accent drag handle, and a `partialDetent` knob that maps onto the
 * material partial-expansion state for an iOS `.presentationDetent(.medium)`
 * style snap.
 *
 * Material3 currently exposes only partially-expanded vs fully-expanded
 * detents. The three-step detent table from the plan (0.3 / 0.6 / 1.0) is
 * approximated by:
 *   • PartialMedium → uses `partiallyExpanded` with default half height
 *   • Full → skips the partial state and goes straight to fullscreen
 * Both transitions still snap with M3 spring physics. Per-pixel snap heights
 * are not yet supported by the framework without re-implementing AnchoredDraggable.
 */
enum class AuroraSheetDetent { PartialMedium, Full }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun rememberAuroraSheetState(
    detent: AuroraSheetDetent = AuroraSheetDetent.PartialMedium
): SheetState = rememberModalBottomSheetState(
    skipPartiallyExpanded = detent == AuroraSheetDetent.Full
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AuroraBottomSheet(
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    detent: AuroraSheetDetent = AuroraSheetDetent.PartialMedium,
    sheetState: SheetState = rememberAuroraSheetState(detent),
    content: @Composable () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
        containerColor = Color.Transparent,
        scrimColor = MaterialTheme.colorScheme.scrim.copy(alpha = 0.45f),
        dragHandle = { AuroraDragHandle() },
        modifier = modifier
    ) {
        Box(
            Modifier
                .padding(horizontal = AuroraSpacing.lg.dp)
                .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.96f))
                .padding(bottom = AuroraSpacing.xxl.dp)
        ) {
            content()
        }
    }
}

@Composable
private fun AuroraDragHandle() {
    Box(
        modifier = Modifier
            .padding(vertical = AuroraSpacing.sm.dp)
            .size(width = 40.dp, height = 4.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(AuroraColors.hermesMercury.copy(alpha = 0.6f))
    )
}
