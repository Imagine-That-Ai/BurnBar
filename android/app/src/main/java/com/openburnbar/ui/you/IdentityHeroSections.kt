// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun IdentityHeroAvatarWithHalo(displayName: String, photoUrl: String?, haloRotation: Float) {
    Box(contentAlignment = Alignment.Center) {
        IdentityHeroHaloRing(haloRotation = haloRotation)
        Box(
            modifier =
            Modifier
                .size(92.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f))
                .border(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f), CircleShape),
        )
        IdentityHeroAvatarPhoto(displayName = displayName, photoUrl = photoUrl)
    }
}

@Composable
private fun IdentityHeroHaloRing(haloRotation: Float) {
    Box(
        modifier =
        Modifier
            .size(116.dp)
            .clip(CircleShape)
            .border(
                width = 2.dp,
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        AuroraColors.ember,
                        AuroraColors.amber,
                        AuroraColors.blaze,
                        AuroraColors.ember.copy(alpha = 0f),
                        AuroraColors.ember,
                    ),
                    start =
                    androidx.compose.ui.geometry.Offset(
                        kotlin.math.cos(Math.toRadians(haloRotation.toDouble())).toFloat() * 58f + 58f,
                        kotlin.math.sin(Math.toRadians(haloRotation.toDouble())).toFloat() * 58f + 58f,
                    ),
                    end =
                    androidx.compose.ui.geometry.Offset(
                        kotlin.math.cos(Math.toRadians((haloRotation + 180).toDouble())).toFloat() * 58f + 58f,
                        kotlin.math.sin(Math.toRadians((haloRotation + 180).toDouble())).toFloat() * 58f + 58f,
                    ),
                ),
                shape = CircleShape,
            ),
    )
}

@Composable
private fun IdentityHeroAvatarPhoto(displayName: String, photoUrl: String?) {
    if (photoUrl != null) {
        AsyncImage(
            model = photoUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier =
            Modifier
                .size(84.dp)
                .clip(CircleShape),
        )
    } else {
        IdentityHeroFallbackAvatar(name = displayName)
    }
}

@Composable
internal fun IdentityHeroIdentityBlock(
    displayName: String,
    email: String?,
    syncHealth: CloudSyncHealth,
    connectionsCount: Int,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = displayName,
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (email != null) {
            Text(
                text = email,
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        IdentityHeroStatusPill(syncHealth = syncHealth, connectionsCount = connectionsCount)
    }
}

@Composable
internal fun IdentityHeroHealthySyncLine(syncHealth: CloudSyncHealth) {
    if (syncHealth != CloudSyncHealth.HEALTHY) return
    val isDark = isSystemInDarkTheme()
    val successColor = if (isDark) AuroraColors.successDark else AuroraColors.success

    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = "✓",
            fontSize = 11.sp,
            color = successColor,
            fontWeight = FontWeight.Bold,
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = "Live cloud sync · App Check active",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        )
    }
}

@Composable
internal fun IdentityHeroFallbackAvatar(name: String) {
    val initials =
        name
            .split(" ")
            .take(2)
            .mapNotNull { it.firstOrNull()?.uppercase() }
            .joinToString("")
            .ifEmpty { "OB" }

    Box(
        modifier =
        Modifier
            .size(84.dp)
            .clip(CircleShape)
            .background(Brush.linearGradient(AuroraGradients.primaryGradient)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = initials,
            color = Color.White,
            fontSize = 32.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
internal fun IdentityHeroStatusPill(syncHealth: CloudSyncHealth, connectionsCount: Int) {
    val isDark = isSystemInDarkTheme()
    val successColor = if (isDark) AuroraColors.successDark else AuroraColors.success
    val warningColor = if (isDark) AuroraColors.warningDark else AuroraColors.warning
    val errorColor = if (isDark) AuroraColors.errorDark else AuroraColors.error

    val (statusText, statusColor) =
        when (syncHealth) {
            CloudSyncHealth.HEALTHY -> "Synced · $connectionsCount provider${if (connectionsCount == 1) "" else "s"}" to successColor
            CloudSyncHealth.SYNCING -> "Syncing…" to warningColor
            CloudSyncHealth.OFFLINE -> "Offline" to warningColor
            CloudSyncHealth.FIREBASE_UNAVAILABLE, CloudSyncHealth.APP_CHECK_BLOCKED -> "Cloud unreachable" to errorColor
            CloudSyncHealth.PERMISSION_DENIED -> "Access denied" to errorColor
            CloudSyncHealth.DEGRADED -> "Degraded" to warningColor
            CloudSyncHealth.UNKNOWN -> "Checking…" to MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
        }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .border(
                width = 0.5.dp,
                color = statusColor.copy(alpha = 0.4f),
                shape = CircleShape,
            )
            .background(statusColor.copy(alpha = 0.16f), CircleShape)
            .padding(horizontal = 12.dp, vertical = 5.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(statusColor),
        )
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = statusText,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = statusColor,
        )
    }
}

@Composable
internal fun IdentityHeroCardContent(
    displayName: String,
    email: String?,
    photoUrl: String?,
    syncHealth: CloudSyncHealth,
    connectionsCount: Int,
    haloRotation: Float,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp),
    ) {
        IdentityHeroAvatarWithHalo(displayName = displayName, photoUrl = photoUrl, haloRotation = haloRotation)
        IdentityHeroIdentityBlock(
            displayName = displayName,
            email = email,
            syncHealth = syncHealth,
            connectionsCount = connectionsCount,
        )
        IdentityHeroHealthySyncLine(syncHealth = syncHealth)
    }
}
