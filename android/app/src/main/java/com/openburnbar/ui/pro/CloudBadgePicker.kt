package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors

// ── Cloud Badge Picker (Android) ──
//
// Modal bottom sheet — parity with iOS CloudBadgePicker. Two-column grid
// of tiles. Tapping a tile updates the persisted selection immediately.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudBadgePickerSheet(
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = AuroraColors.darkSurface,
        dragHandle = null
    ) {
        CloudBadgePickerContent()
    }
}

@Composable
fun CloudBadgePickerContent() {
    val selection = rememberCloudBadgeSelection()

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 24.dp)
    ) {
        Spacer(Modifier.height(12.dp))
        Text(
            text = "PICK YOUR BADGE",
            color = AuroraColors.amber,
            fontWeight = FontWeight.Black,
            fontSize = 12.sp,
            letterSpacing = 2.sp
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Wear your fire.",
            color = AuroraColors.ember,
            fontFamily = FontFamily.SansSerif,
            fontWeight = FontWeight.Bold,
            fontSize = 28.sp
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Four to start — more arrive with each major Cloud release.",
            color = AuroraColors.darkTextSecondary,
            fontSize = 13.sp
        )
        Spacer(Modifier.height(20.dp))

        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(bottom = 16.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            items(CloudBadgeStyle.entries) { style ->
                CloudBadgePickerTile(
                    style = style,
                    isSelected = selection.value == style,
                    onClick = { selection.value = style }
                )
            }
        }
    }
}

@Composable
private fun CloudBadgePickerTile(
    style: CloudBadgeStyle,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    val shape = RoundedCornerShape(20.dp)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(170.dp)
                .shadow(
                    elevation = if (isSelected) 14.dp else 4.dp,
                    shape = shape,
                    ambientColor = AuroraColors.ember,
                    spotColor = AuroraColors.ember
                )
                .clip(shape)
                .background(
                    brush = Brush.linearGradient(
                        colors = listOf(
                            AuroraColors.ember.copy(alpha = if (isSelected) 0.34f else 0.16f),
                            AuroraColors.amber.copy(alpha = if (isSelected) 0.26f else 0.12f),
                            AuroraColors.blaze.copy(alpha = if (isSelected) 0.22f else 0.10f)
                        )
                    )
                )
                .border(
                    width = if (isSelected) 1.6.dp else 0.7.dp,
                    brush = if (isSelected) {
                        Brush.linearGradient(
                            colors = listOf(AuroraColors.amber, AuroraColors.ember, AuroraColors.amber)
                        )
                    } else {
                        Brush.linearGradient(
                            colors = listOf(
                                Color.White.copy(alpha = 0.12f),
                                Color.White.copy(alpha = 0.04f)
                            )
                        )
                    },
                    shape = shape
                ),
            contentAlignment = Alignment.Center
        ) {
            CloudBadge(size = CloudBadgeSize.Large, styleOverride = style)
        }
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (isSelected) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = AuroraColors.ember,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(Modifier.width(4.dp))
            }
            Text(
                text = style.title,
                color = AuroraColors.darkTextPrimary,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp
            )
        }
        Text(
            text = style.blurb,
            color = AuroraColors.darkTextMuted,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 2.dp, start = 4.dp, end = 4.dp)
        )
    }
}
