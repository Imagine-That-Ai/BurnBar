package com.openburnbar.ui.burn

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.IdealPace
import com.openburnbar.data.models.ProviderAccount
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingFraction
import com.openburnbar.data.models.getRemainingText
import com.openburnbar.data.models.hourlyBucket
import com.openburnbar.data.models.idealPace
import com.openburnbar.data.models.label
import com.openburnbar.data.models.nextResetDate
import com.openburnbar.data.models.pressure
import com.openburnbar.data.models.primaryDisplayableBucket
import com.openburnbar.data.models.weeklyOrMonthlyBucket
import com.openburnbar.data.stores.QuotaWindowKind
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

@Composable
fun SubscriptionListRow(snapshot: ProviderQuotaSnapshot, accounts: List<ProviderAccount>, modifier: Modifier = Modifier) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(AuroraRadius.MD.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.5f))
            .border(0.75.dp, primaryColor.copy(alpha = 0.16f), RoundedCornerShape(AuroraRadius.MD.dp))
            .padding(horizontal = AuroraSpacing.MD.dp, vertical = AuroraSpacing.SM.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        SubscriptionRowAvatar(provider = provider, primaryColor = primaryColor)
        SubscriptionRowIdentity(snapshot = snapshot, provider = provider, accounts = accounts, primaryColor = primaryColor)

        QuotaDualWindowStrip(
            hourlyBucket = snapshot.hourlyBucket,
            weeklyBucket = snapshot.weeklyOrMonthlyBucket,
            fallbackBucket = snapshot.primaryDisplayableBucket(),
            provider = provider,
            isActive = false,
            modifier = Modifier.weight(1f),
        )

        val remainingPct = ((1.0 - snapshot.pressure) * 100).roundToInt()
        Text(
            text = "$remainingPct%",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = primaryColor,
            modifier = Modifier.width(60.dp),
            maxLines = 1,
        )
    }
}

@Composable
private fun SubscriptionRowAvatar(provider: AgentProvider, primaryColor: Color) {
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(32.dp)) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(primaryColor.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            ProviderAvatar(providerKey = provider.key, size = 16)
        }
        Canvas(modifier = Modifier.size(32.dp)) {
            drawCircle(
                color = primaryColor.copy(alpha = 0.35f),
                radius = size.minDimension / 2f - 1.dp.toPx(),
                style = Stroke(width = 1.dp.toPx()),
            )
        }
    }
}

@Composable
private fun SubscriptionRowIdentity(snapshot: ProviderQuotaSnapshot, provider: AgentProvider, accounts: List<ProviderAccount>, primaryColor: Color) {
    Column(modifier = Modifier.width(180.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(
                text = provider.displayName,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            val badgeText = if (snapshot.buckets.any { it.isEstimated }) "Estimated" else "Active"
            Text(
                text = badgeText.uppercase(Locale.getDefault()),
                fontSize = 8.sp,
                fontWeight = FontWeight.Bold,
                color = primaryColor,
                letterSpacing = 0.8.sp,
            )
        }
        val accountEmail = quotaAccountEmail(snapshot, accounts) ?: quotaAccountName(snapshot, accounts)
        Text(
            text = accountEmail,
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun QuotaDualWindowStrip(
    hourlyBucket: QuotaBucket?,
    weeklyBucket: QuotaBucket?,
    fallbackBucket: QuotaBucket?,
    provider: AgentProvider,
    isActive: Boolean,
    modifier: Modifier = Modifier,
) {
    val primaryColor = Color(provider.brandColor)
    val isDark = isSystemInDarkTheme()
    val trackBgColor = if (isDark) AuroraColors.darkSurfaceElevated.copy(alpha = 0.85f) else AuroraColors.lightSurfaceElevated.copy(alpha = 0.85f)

    val shortSlot = hourlyBucket ?: if (fallbackBucket?.let { QuotaWindowKind.infer(it) } == QuotaWindowKind.DAILY) fallbackBucket else null
    val longSlot = weeklyBucket ?: fallbackBucket

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(AuroraRadius.MD.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.82f))
            .border(1.dp, primaryColor.copy(alpha = 0.14f), RoundedCornerShape(AuroraRadius.MD.dp))
            .padding(AuroraSpacing.SM.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        if (shortSlot != null) {
            val label = when (QuotaWindowKind.infer(shortSlot)) {
                QuotaWindowKind.FIVE_HOUR -> "5h"
                QuotaWindowKind.DAILY -> "24h"
                else -> "5h"
            }
            WindowBar(bucket = shortSlot, label = label, icon = "clock.fill", provider = provider, trackBgColor = trackBgColor)
        } else {
            WindowBarPlaceholder(label = "5h", icon = "clock.fill", provider = provider, trackBgColor = trackBgColor, isActive = isActive)
        }

        if (longSlot != null) {
            val label = when (QuotaWindowKind.infer(longSlot)) {
                QuotaWindowKind.SEVEN_DAY -> "7d"
                QuotaWindowKind.MONTHLY -> "30d"
                else -> "7d"
            }
            WindowBar(bucket = longSlot, label = label, icon = "calendar", provider = provider, trackBgColor = trackBgColor)
        } else {
            WindowBarPlaceholder(label = "7d", icon = "calendar", provider = provider, trackBgColor = trackBgColor, isActive = isActive)
        }
    }
}

@Composable
fun WindowBar(bucket: QuotaBucket, label: String, icon: String, provider: AgentProvider, trackBgColor: Color) {
    val remainingFraction = bucket.displayRemainingFraction ?: 1.0
    val colors = windowBarColors(provider = provider, remainingFraction = remainingFraction)

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        WindowBarLabel(icon = icon, label = label, tint = colors.fill)
        WindowBarTrack(
            bucket = bucket,
            remainingFraction = remainingFraction,
            colors = colors,
            trackBgColor = trackBgColor,
            modifier = Modifier.weight(1f),
        )
        WindowBarValue(text = bucket.getRemainingText("absoluteValues"), fill = colors.fill)
    }
}

private data class WindowBarColors(val fill: Color, val brush: Brush)

private fun windowBarColors(provider: AgentProvider, remainingFraction: Double): WindowBarColors {
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)
    return when {
        remainingFraction >= QUOTA_REMAINING_HEALTHY -> WindowBarColors(primaryColor, Brush.horizontalGradient(listOf(primaryColor, accentColor)))
        remainingFraction >= QUOTA_REMAINING_WATCH ->
            WindowBarColors(
                primaryColor.copy(alpha = QUOTA_BAR_MEDIUM_ALPHA),
                Brush.horizontalGradient(
                    listOf(
                        primaryColor.copy(alpha = QUOTA_BAR_MEDIUM_ALPHA),
                        accentColor.copy(alpha = QUOTA_BAR_MEDIUM_ACCENT_ALPHA),
                    ),
                ),
            )
        remainingFraction >= QUOTA_REMAINING_WARN ->
            WindowBarColors(AuroraColors.amber, Brush.horizontalGradient(listOf(primaryColor.copy(alpha = QUOTA_BAR_WARNING_ALPHA), AuroraColors.amber)))
        else -> WindowBarColors(
            AuroraColors.warning,
            Brush.horizontalGradient(listOf(AuroraColors.warning, AuroraColors.warning.copy(alpha = QUOTA_BAR_EMPTY_ALPHA))),
        )
    }
}

@Composable
private fun WindowBarLabel(icon: String, label: String, tint: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier.width(34.dp),
    ) {
        Box(modifier = Modifier.width(12.dp), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = quotaWindowIcon(icon),
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(9.dp),
            )
        }
        Text(
            text = label,
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun WindowBarTrack(bucket: QuotaBucket, remainingFraction: Double, colors: WindowBarColors, trackBgColor: Color, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .height(10.dp)
            .clip(RoundedCornerShape(3.dp))
            .background(trackBgColor)
            .border(1.dp, colors.fill.copy(alpha = 0.18f), RoundedCornerShape(3.dp)),
    ) {
        if (remainingFraction > 0) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(remainingFraction.toFloat())
                    .fillMaxSize()
                    .background(colors.brush),
            )
        }
        WindowBarPaceTick(pace = bucket.idealPace())
    }
}

@Composable
private fun WindowBarPaceTick(pace: IdealPace?) {
    if (pace == null) return
    Box(
        modifier = Modifier
            .fillMaxWidth((1.0f - pace.elapsedFraction.toFloat()).coerceIn(0f, 1f))
            .fillMaxSize(),
        contentAlignment = Alignment.CenterEnd,
    ) {
        Box(
            modifier = Modifier
                .width(1.5.dp)
                .fillMaxSize()
                .background(Color.White),
        )
    }
}

@Composable
private fun WindowBarValue(text: String, fill: Color) {
    Text(
        text = text,
        fontSize = AuroraTypography.tiny.sp,
        fontFamily = FontFamily.Monospace,
        color = fill,
        modifier = Modifier.width(36.dp),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

private fun quotaWindowIcon(icon: String) = when (icon) {
    "clock.fill", "clock" -> Icons.Default.Schedule
    "calendar" -> Icons.Default.DateRange
    else -> Icons.Default.DateRange
}

@Composable
fun WindowBarPlaceholder(label: String, icon: String, provider: AgentProvider, trackBgColor: Color, isActive: Boolean) {
    val primaryColor = Color(provider.brandColor)

    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            modifier = Modifier.width(34.dp),
        ) {
            Box(
                modifier = Modifier.width(12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = when (icon) {
                        "clock.fill", "clock" -> Icons.Default.Schedule
                        "calendar" -> Icons.Default.DateRange
                        else -> Icons.Default.DateRange
                    },
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                    modifier = Modifier.size(9.dp),
                )
            }
            Text(
                text = label,
                fontSize = AuroraTypography.tiny.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
            )
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .height(10.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(trackBgColor)
                .border(
                    width = 1.dp,
                    color = primaryColor.copy(alpha = if (isActive) 0.18f else 0.08f),
                ),
        )

        Text(
            text = "—",
            fontSize = AuroraTypography.tiny.sp,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
            modifier = Modifier.width(36.dp),
        )
    }
}

@Composable
fun ResetCell(snapshot: ProviderQuotaSnapshot, zone: ZoneId) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)

    val timeText = snapshot.nextResetDate?.let {
        val formatter = DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault()).withZone(zone)
        formatter.format(it).replace("am", "AM").replace("pm", "PM")
    } ?: "—"

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            primaryColor.copy(alpha = 0.22f),
                            accentColor.copy(alpha = 0.10f),
                        ),
                    ),
                )
                .border(0.75.dp, primaryColor.copy(alpha = 0.34f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            ProviderAvatar(providerKey = provider.key, size = 14)
        }

        Text(
            text = timeText,
            fontSize = 8.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
