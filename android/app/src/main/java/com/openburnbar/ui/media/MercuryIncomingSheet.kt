package com.openburnbar.ui.media

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
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
import com.openburnbar.ui.theme.LocalAuroraReduceMotion

/**
 * Compose port of iOS `MercuryIncomingSheet.swift`. Rendered full-screen
 * by `IncomingCallActivity` when a Mercury call arrives. Pulses a
 * mercury-stroked circle around the caller initial; pulse is suppressed
 * under reduce-motion.
 */
@Composable
fun MercuryIncomingSheet(
    pairedDeviceName: String,
    callerInitial: String,
    onAccept: () -> Unit,
    onDecline: () -> Unit,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val infinite = rememberInfiniteTransition(label = "mercuryIncomingPulse")
    val scale by infinite.animateFloat(
        initialValue = 1f,
        targetValue = if (reduceMotion) 1f else 1.08f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "mercuryIncomingPulseScale",
    )

    val mercuryBrush = Brush.linearGradient(
        listOf(
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
            AuroraColors.hermesAureate.copy(alpha = 0.7f),
            AuroraColors.hermesMercury.copy(alpha = 0.85f),
        )
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .padding(36.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(Color(0xFF111111).copy(alpha = 0.92f))
                .border(width = 1.dp, brush = mercuryBrush, shape = RoundedCornerShape(18.dp))
                .padding(36.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(96.dp)) {
                Box(
                    modifier = Modifier
                        .size(96.dp)
                        .scale(scale)
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

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterHorizontally),
            ) {
                OutlinedButton(
                    onClick = onDecline,
                    modifier = Modifier.width(140.dp),
                ) { Text("Decline") }

                Button(
                    onClick = onAccept,
                    modifier = Modifier.width(140.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesAureate),
                ) { Text("Accept") }
            }
        }
    }
}
