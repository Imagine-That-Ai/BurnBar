package com.openburnbar.ui.pro

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors

// ── Cloud Badge Picker (Android) ──
//
// Modal bottom sheet — parity with iOS CloudBadgePicker. Two-column grid
// of tiles. Tapping a tile updates the persisted selection immediately.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudBadgePickerSheet(onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = AuroraColors.darkSurface,
        dragHandle = null,
    ) {
        CloudBadgePickerContent()
    }
}

@Composable
fun CloudBadgePickerContent() {
    val selection = rememberCloudBadgeSelection()

    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp),
    ) {
        Spacer(Modifier.height(12.dp))
        Text(
            text = "PICK YOUR BADGE",
            color = AuroraColors.amber,
            fontWeight = FontWeight.Black,
            fontSize = 12.sp,
            letterSpacing = 2.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Wear your fire.",
            color = AuroraColors.ember,
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 28.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Four to start — more arrive with each major Cloud release.",
            color = AuroraColors.darkTextSecondary,
            fontSize = 13.sp,
        )
        Spacer(Modifier.height(20.dp))

        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(bottom = 16.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(CloudBadgeStyle.entries) { style ->
                CloudBadgePickerTile(
                    style = style,
                    isSelected = selection.value == style,
                    onClick = { selection.value = style },
                )
            }
        }
    }
}
