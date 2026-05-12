package com.openburnbar.ui.you

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.openburnbar.data.stores.CloudSyncHealth
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun IdentityHero(
    displayName: String,
    email: String?,
    photoUrl: String?,
    syncHealth: CloudSyncHealth,
    connectionsCount: Int,
    modifier: Modifier = Modifier
) {
    val infiniteTransition = rememberInfiniteTransition(label = "halo")
    val haloRotation by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(18000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "rotation"
    )

    AuroraGlassCard(modifier = modifier) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
        ) {
            // Avatar with animated halo
            Box(contentAlignment = Alignment.Center) {
                // Rotating halo ring
                Box(
                    modifier = Modifier
                        .size(116.dp)
                        .clip(CircleShape)
                        .border(
                            width = 2.dp,
                            brush = Brush.linearGradient(
                                colors = listOf(
                                    AuroraColors.ember,
                                    AuroraColors.amber,
                                    AuroraColors.blaze,
                                    AuroraColors.ember.copy(alpha = 0f),
                                    AuroraColors.ember
                                ),
                                start = androidx.compose.ui.geometry.Offset(
                                    kotlin.math.cos(Math.toRadians(haloRotation.toDouble())).toFloat() * 58f + 58f,
                                    kotlin.math.sin(Math.toRadians(haloRotation.toDouble())).toFloat() * 58f + 58f
                                ),
                                end = androidx.compose.ui.geometry.Offset(
                                    kotlin.math.cos(Math.toRadians((haloRotation + 180).toDouble())).toFloat() * 58f + 58f,
                                    kotlin.math.sin(Math.toRadians((haloRotation + 180).toDouble())).toFloat() * 58f + 58f
                                )
                            ),
                            shape = CircleShape
                        )
                )

                // Inner circle background
                Box(
                    modifier = Modifier
                        .size(92.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f))
                        .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f), CircleShape)
                )

                // Photo or fallback
                if (photoUrl != null) {
                    AsyncImage(
                        model = photoUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(84.dp)
                            .clip(CircleShape)
                    )
                } else {
                    FallbackAvatar(name = displayName)
                }
            }

            // Identity
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = displayName,
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                if (email != null) {
                    Text(
                        text = email,
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                StatusPill(syncHealth = syncHealth, connectionsCount = connectionsCount)
            }

            // Sync detail line
            if (syncHealth == CloudSyncHealth.HEALTHY) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = "✓",
                        fontSize = 11.sp,
                        color = AuroraColors.success,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = "Live cloud sync · App Check active",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                    )
                }
            }
        }
    }
}

@Composable
private fun FallbackAvatar(name: String) {
    val initials = name
        .split(" ")
        .take(2)
        .mapNotNull { it.firstOrNull()?.uppercase() }
        .joinToString("")
        .ifEmpty { "OB" }

    Box(
        modifier = Modifier
            .size(84.dp)
            .clip(CircleShape)
            .background(Brush.linearGradient(AuroraGradients.primaryGradient)),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = initials,
            color = Color.White,
            fontSize = 32.sp,
            fontWeight = FontWeight.Bold
        )
    }
}

@Composable
private fun StatusPill(syncHealth: CloudSyncHealth, connectionsCount: Int) {
    val (statusText, statusColor) = when (syncHealth) {
        CloudSyncHealth.HEALTHY -> "Synced · $connectionsCount provider${if (connectionsCount == 1) "" else "s"}" to AuroraColors.success
        CloudSyncHealth.SYNCING -> "Syncing…" to AuroraColors.amber
        CloudSyncHealth.OFFLINE -> "Offline" to AuroraColors.warning
        CloudSyncHealth.FIREBASE_UNAVAILABLE, CloudSyncHealth.APP_CHECK_BLOCKED -> "Cloud unreachable" to AuroraColors.error
        CloudSyncHealth.PERMISSION_DENIED -> "Access denied" to AuroraColors.error
        CloudSyncHealth.DEGRADED -> "Degraded" to AuroraColors.warning
        CloudSyncHealth.UNKNOWN -> "Checking…" to MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .border(
                width = 0.5.dp,
                color = statusColor.copy(alpha = 0.4f),
                shape = androidx.compose.foundation.shape.CircleShape
            )
            .background(statusColor.copy(alpha = 0.16f), CircleShape)
            .padding(horizontal = 12.dp, vertical = 5.dp)
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(statusColor)
        )
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = statusText,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = statusColor
        )
    }
}
