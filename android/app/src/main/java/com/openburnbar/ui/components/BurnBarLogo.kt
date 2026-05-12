package com.openburnbar.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.R

@Composable
fun BurnBarLogo(
    size: Dp,
    modifier: Modifier = Modifier,
    showDisc: Boolean = true
) {
    val logoModifier = Modifier.size(size)
    if (showDisc) {
        Box(
            modifier = modifier
                .size(size)
                .clip(CircleShape)
                .background(Color(0xFF160B08)),
            contentAlignment = Alignment.Center
        ) {
            Image(
                painter = painterResource(R.mipmap.ic_launcher_foreground),
                contentDescription = "BurnBar logo",
                modifier = Modifier
                    .size(size)
                    .padding(size * 0.14f)
            )
        }
    } else {
        Image(
            painter = painterResource(R.mipmap.ic_launcher_foreground),
            contentDescription = "BurnBar logo",
            modifier = modifier.then(logoModifier)
        )
    }
}
