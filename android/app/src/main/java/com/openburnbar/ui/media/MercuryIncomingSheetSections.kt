// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors

@Composable
internal fun MercuryIncomingSheetCard(
    pairedDeviceName: String,
    callerInitial: String,
    pulseScale: Float,
    mercuryBrush: Brush,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .padding(36.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFF111111).copy(alpha = 0.92f))
            .border(width = 1.dp, brush = mercuryBrush, shape = RoundedCornerShape(18.dp))
            .padding(36.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        MercuryIncomingCallerAvatar(callerInitial = callerInitial, pulseScale = pulseScale, mercuryBrush = mercuryBrush)
        MercuryIncomingCallerLabels(pairedDeviceName = pairedDeviceName)
        MercuryIncomingActionRow(onAccept = onAccept, onDecline = onDecline)
    }
}

@Composable
private fun MercuryIncomingCallerAvatar(callerInitial: String, pulseScale: Float, mercuryBrush: Brush) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(96.dp)) {
        Box(
            modifier =
            Modifier
                .size(96.dp)
                .scale(pulseScale)
                .clip(CircleShape)
                .border(width = 1.5.dp, brush = mercuryBrush, shape = CircleShape),
        )
        Text(
            text = callerInitial,
            fontSize = 36.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.hermesMercury,
        )
    }
}

@Composable
private fun MercuryIncomingCallerLabels(pairedDeviceName: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = pairedDeviceName,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            color = Color.White,
        )
        Text(
            text = "Pair-debug call",
            fontSize = 14.sp,
            color = AuroraColors.hermesMercury.copy(alpha = 0.85f),
        )
    }
}

@Composable
private fun MercuryIncomingActionRow(onAccept: () -> Unit, onDecline: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterHorizontally),
    ) {
        OutlinedButton(onClick = onDecline, modifier = Modifier.width(140.dp)) { Text("Decline") }
        Button(
            onClick = onAccept,
            modifier = Modifier.width(140.dp),
            colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesAureate),
        ) { Text("Accept") }
    }
}
