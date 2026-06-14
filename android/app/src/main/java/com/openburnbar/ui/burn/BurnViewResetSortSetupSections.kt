package com.openburnbar.ui.burn

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.UsageRollups
import com.openburnbar.data.models.nextResetDate
import com.openburnbar.data.models.pressure
import com.openburnbar.ui.components.ProviderAvatar
import com.openburnbar.ui.components.ShimmerCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

fun relativeTimeLabel(target: Instant, now: Instant = Instant.now()): String {
    val duration = Duration.between(now, target)
    val isFuture = !duration.isNegative
    val absDuration = duration.abs()

    val seconds = absDuration.seconds
    return when {
        seconds < RESET_SECONDS_PER_MINUTE -> "just now"
        seconds < RESET_SECONDS_PER_HOUR -> {
            val minutes = seconds / RESET_SECONDS_PER_MINUTE
            if (isFuture) "in ${minutes}m" else "${minutes}m ago"
        }
        seconds < RESET_SECONDS_PER_DAY -> {
            val hours = seconds / RESET_SECONDS_PER_HOUR
            val minutes = seconds % RESET_SECONDS_PER_HOUR / RESET_SECONDS_PER_MINUTE
            if (isFuture) "in ${hours}h ${minutes}m" else "${hours}h ${minutes}m ago"
        }
        else -> {
            val days = seconds / RESET_SECONDS_PER_DAY
            if (isFuture) "in ${days}d" else "${days}d ago"
        }
    }
}

@Composable
fun BurnViewLoadingShimmer() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
    ) {
        ShimmerCard(height = BURN_LOADING_HERO_HEIGHT_DP)
        ShimmerCard(height = BURN_LOADING_FILTER_HEIGHT_DP)
        repeat(BURN_LOADING_CARD_COUNT) {
            ShimmerCard(height = BURN_LOADING_CARD_HEIGHT_DP)
        }
    }
}

fun sortQuotaSnapshots(
    snapshots: List<ProviderQuotaSnapshot>,
    mode: QuotaSortMode,
    rollups: UsageRollups?,
    pinnedKeys: Set<String> = emptySet(),
): List<ProviderQuotaSnapshot> {
    val spendByID = rollups?.providerSummaries.orEmpty().associate { it.provider.lowercase() to it.totalCost }
    val baseComparator = quotaSnapshotComparator(mode, spendByID)
    return snapshots.sortedWith(pinnedQuotaComparator(pinnedKeys, baseComparator))
}

private fun quotaSnapshotComparator(mode: QuotaSortMode, spendByID: Map<String, Double>): Comparator<ProviderQuotaSnapshot> = Comparator { lhs, rhs ->
    when (mode) {
        QuotaSortMode.URGENCY -> compareQuotaUrgency(lhs, rhs)
        QuotaSortMode.SPEND -> compareQuotaSpend(lhs, rhs, spendByID)
        QuotaSortMode.ALPHABETICAL -> compareQuotaProviderName(lhs, rhs)
        QuotaSortMode.RECENTLY_REFRESHED -> (rhs.fetchedAt ?: "").compareTo(lhs.fetchedAt ?: "")
    }
}

private fun pinnedQuotaComparator(pinnedKeys: Set<String>, baseComparator: Comparator<ProviderQuotaSnapshot>): Comparator<ProviderQuotaSnapshot> =
    Comparator { lhs, rhs ->
        val lPinned = pinnedKeys.contains(lhs.quotaSortKey())
        val rPinned = pinnedKeys.contains(rhs.quotaSortKey())
        when {
            lPinned != rPinned -> if (lPinned) -1 else 1
            else -> baseComparator.compare(lhs, rhs)
        }
    }

private fun compareQuotaUrgency(lhs: ProviderQuotaSnapshot, rhs: ProviderQuotaSnapshot): Int = compareByDescending<ProviderQuotaSnapshot> { it.pressure }
    .thenBy { it.nextResetDate ?: Instant.MAX }
    .thenComparator(::compareQuotaProviderName)
    .compare(lhs, rhs)

private fun compareQuotaSpend(lhs: ProviderQuotaSnapshot, rhs: ProviderQuotaSnapshot, spendByID: Map<String, Double>): Int {
    val spendCompare = (spendByID[rhs.provider.lowercase()] ?: 0.0).compareTo(spendByID[lhs.provider.lowercase()] ?: 0.0)
    return if (spendCompare != 0) spendCompare else compareQuotaProviderName(lhs, rhs)
}

private fun compareQuotaProviderName(lhs: ProviderQuotaSnapshot, rhs: ProviderQuotaSnapshot): Int =
    lhs.quotaProviderDisplayName().compareTo(rhs.quotaProviderDisplayName(), ignoreCase = true)

private fun ProviderQuotaSnapshot.quotaProviderDisplayName(): String = AgentProvider.fromKey(provider)?.displayName ?: provider

internal fun ProviderQuotaSnapshot.quotaSortKey(): String = provider + "_" + (accountId ?: sourceId)

@Composable
fun QuotaResetAtlas(snapshots: List<ProviderQuotaSnapshot>, modifier: Modifier = Modifier) {
    val dayBuckets = rememberResetAtlasBuckets(snapshots)
    val totalResetCount = remember(dayBuckets) { dayBuckets.sumOf { it.snapshots.size } }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        QuotaResetAtlasHeader(totalResetCount = totalResetCount)
        QuotaResetAtlasDivider()
        QuotaResetAtlasGrid(dayBuckets = dayBuckets)
    }
}

@Composable
private fun rememberResetAtlasBuckets(snapshots: List<ProviderQuotaSnapshot>): List<DayBucketData> = remember(snapshots) {
    val zone = ZoneId.systemDefault()
    val today = ZonedDateTime.ofInstant(Instant.now(), zone).toLocalDate()
    val bucketsMap = resetAtlasBucketsByDay(snapshots, zone, today)
    (0..RESET_ATLAS_DAYS_FORWARD).map { offset ->
        val day = today.plusDays(offset.toLong())
        DayBucketData(
            day = day,
            isToday = offset == 0,
            snapshots = (bucketsMap[day] ?: emptyList()).sortedBy { it.nextResetDate ?: Instant.MAX },
        )
    }
}

private fun resetAtlasBucketsByDay(
    snapshots: List<ProviderQuotaSnapshot>,
    zone: ZoneId,
    today: java.time.LocalDate,
): Map<java.time.LocalDate, List<ProviderQuotaSnapshot>> {
    val bucketsMap = mutableMapOf<java.time.LocalDate, MutableList<ProviderQuotaSnapshot>>()
    for (snap in snapshots) {
        val resetDate = snap.nextResetDate?.let { ZonedDateTime.ofInstant(it, zone).toLocalDate() } ?: continue
        val daysBetween = java.time.temporal.ChronoUnit.DAYS.between(today, resetDate)
        if (daysBetween in 0..RESET_ATLAS_DAYS_FORWARD) bucketsMap.getOrPut(resetDate) { mutableListOf() }.add(snap)
    }
    return bucketsMap
}

@Composable
private fun QuotaResetAtlasHeader(totalResetCount: Int) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "RESET ATLAS · NEXT 7 DAYS",
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            letterSpacing = 1.0.sp,
        )
        Text(
            text = resetAtlasCountText(totalResetCount),
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (totalResetCount == 0) 0.5f else 1f),
        )
    }
}

private fun resetAtlasCountText(totalResetCount: Int): String = if (totalResetCount == 0) {
    "No resets scheduled in this window"
} else {
    "$totalResetCount reset event${if (totalResetCount == 1) "" else "s"}"
}

@Composable
private fun QuotaResetAtlasDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(
                Brush.horizontalGradient(
                    colors = listOf(
                        AuroraColors.hermesMercury.copy(alpha = 0f),
                        AuroraColors.hermesMercury.copy(alpha = 0.55f),
                        AuroraColors.hermesAureate.copy(alpha = 0.65f),
                        AuroraColors.hermesMercury.copy(alpha = 0.55f),
                        AuroraColors.hermesMercury.copy(alpha = 0f),
                    ),
                ),
            ),
    )
}

@Composable
private fun QuotaResetAtlasGrid(dayBuckets: List<DayBucketData>) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.MD.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f)),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.40f)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.SM.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Top,
        ) {
            dayBuckets.forEachIndexed { index, bucket ->
                DayColumn(bucket = bucket, modifier = Modifier.weight(1f), showLeadingDivider = index > 0)
            }
        }
    }
}

private const val RESET_ATLAS_DAYS_FORWARD = 7

private data class DayBucketData(
    val day: java.time.LocalDate,
    val isToday: Boolean,
    val snapshots: List<ProviderQuotaSnapshot>,
)

@Composable
private fun DayColumn(bucket: DayBucketData, modifier: Modifier = Modifier, showLeadingDivider: Boolean = false) {
    Box(modifier = modifier) {
        if (showLeadingDivider) {
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .width(0.5.dp)
                    .height(60.dp)
                    .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
            )
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 2.dp, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            val dayLabel = if (bucket.isToday) {
                "TODAY"
            } else {
                val formatter = java.time.format.DateTimeFormatter.ofPattern("E d", Locale.getDefault())
                bucket.day.format(formatter).uppercase(Locale.getDefault())
            }
            Text(
                text = dayLabel,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                color = if (bucket.isToday) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            )

            Box(
                modifier = Modifier
                    .size(4.dp)
                    .clip(CircleShape)
                    .background(
                        if (bucket.isToday) {
                            AuroraColors.ember.copy(alpha = 0.85f)
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
                        },
                    ),
            )

            if (bucket.snapshots.isEmpty()) {
                Text(
                    text = "—",
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f),
                    modifier = Modifier.padding(top = 4.dp),
                )
            } else {
                Column(
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(top = 2.dp),
                ) {
                    bucket.snapshots.forEach { snap ->
                        ResetCell(snapshot = snap)
                    }
                }
            }
        }
    }
}

@Composable
private fun ResetCell(snapshot: ProviderQuotaSnapshot) {
    val provider = AgentProvider.fromKey(snapshot.provider) ?: return
    val primaryColor = Color(provider.brandColor)
    val accentColor = Color(provider.accentColor)

    val timeLabel = remember(snapshot.nextResetDate) {
        val date = snapshot.nextResetDate ?: return@remember "—"
        val zone = ZoneId.systemDefault()
        val zdt = ZonedDateTime.ofInstant(date, zone)
        val formatter = java.time.format.DateTimeFormatter.ofPattern("h:mm a", Locale.US)
        zdt.format(formatter)
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(24.dp),
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
            )
            ProviderAvatar(providerKey = provider.key, size = 14)
        }

        Text(
            text = timeLabel,
            fontSize = 8.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
        )
    }
}

@Composable
fun QuotaSetupSuggestionsStrip(slots: List<AgentProvider>, onConnectClick: (AgentProvider) -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "✨",
                    fontSize = 11.sp,
                )
                val s = if (slots.size == 1) "" else "S"
                Text(
                    text = "READY TO ADD · ${slots.size} PROVIDER$s",
                    fontSize = AuroraTypography.tiny.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    letterSpacing = 1.0.sp,
                )
            }
        }

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
            modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
        ) {
            items(slots) { provider ->
                SlotChip(provider = provider, onClick = { onConnectClick(provider) })
            }
        }
    }
}

@Composable
private fun SlotChip(provider: AgentProvider, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val primaryColor = Color(provider.brandColor)
    Card(
        modifier = modifier.width(232.dp),
        shape = RoundedCornerShape(AuroraRadius.MD.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)),
        border = androidx.compose.foundation.BorderStroke(0.75.dp, primaryColor.copy(alpha = 0.20f)),
    ) {
        Column(
            modifier = Modifier
                .clickable { onClick() }
                .padding(AuroraSpacing.MD.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(primaryColor.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) {
                    ProviderAvatar(providerKey = provider.key, size = 18)
                }

                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(
                        text = provider.displayName,
                        fontSize = AuroraTypography.body.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Not connected",
                        fontSize = AuroraTypography.tiny.sp,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    )
                }
            }

            Text(
                text = "Tap to configure tracking settings for ${provider.displayName}.",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(200.dp),
            )
        }
    }
}
