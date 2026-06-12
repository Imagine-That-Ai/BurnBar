// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.cloud.CloudTranscriptCache
import com.openburnbar.data.cloud.CloudTranscriptCacheSettings
import com.openburnbar.data.cloud.CloudTranscriptCacheSnapshot
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography
import kotlin.math.roundToInt

internal class TranscriptCacheSettingsState(
    val limitMegabytes: Int,
    val snapshot: CloudTranscriptCacheSnapshot,
    val status: String?,
    val setLimit: (Int) -> Unit,
    val clearCache: () -> Unit,
    val resetToDefault: () -> Unit,
)

@Composable
internal fun rememberTranscriptCacheSettingsState(): TranscriptCacheSettingsState {
    var limitMegabytes by rememberSaveable { mutableStateOf(CloudTranscriptCacheSettings.maxMegabytes()) }
    var snapshot by remember { mutableStateOf(CloudTranscriptCache.snapshot()) }
    var status by remember { mutableStateOf<String?>(null) }

    fun refreshSnapshot() {
        snapshot = CloudTranscriptCache.snapshot()
    }

    fun setLimit(value: Int) {
        val clamped = CloudTranscriptCacheSettings.clampMegabytes(value)
        limitMegabytes = clamped
        CloudTranscriptCacheSettings.setMaxMegabytes(clamped)
        CloudTranscriptCache.trimToLimit()
        refreshSnapshot()
        status = if (clamped <= 0) "Cache off" else "Cache limit saved"
    }

    return TranscriptCacheSettingsState(
        limitMegabytes = limitMegabytes,
        snapshot = snapshot,
        status = status,
        setLimit = ::setLimit,
        clearCache = {
            CloudTranscriptCache.clear()
            refreshSnapshot()
            status = "Cache cleared"
        },
        resetToDefault = { setLimit(CloudTranscriptCacheSettings.DEFAULT_MAX_MEGABYTES) },
    )
}

@Composable
internal fun TranscriptCacheSettingsTopBar(
    onBack: () -> Unit,
    useWebsiteBackground: Boolean,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = "Transcript Cache",
            style = AuroraType.displayLarge,
            color = if (useWebsiteBackground) Color.White else MaterialTheme.colorScheme.onSurface
        )
    }
}

internal fun cacheLimitLabel(limitMegabytes: Int): String {
    if (limitMegabytes <= 0) return "Off"
    return CloudTranscriptCacheSettings.formatBytes(
        limitMegabytes.toLong() * CloudTranscriptCacheSettings.BYTES_PER_MEGABYTE
    )
}

internal fun cacheUsageLabel(snapshot: CloudTranscriptCacheSnapshot): String {
    val used = CloudTranscriptCacheSettings.formatBytes(snapshot.usageBytes)
    if (snapshot.isDisabled) return "$used / Off"
    return "$used / ${CloudTranscriptCacheSettings.formatBytes(snapshot.maxBytes)}"
}

@Composable
internal fun TranscriptCacheLimitHeader(limitMegabytes: Int) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = Icons.Filled.Storage,
            contentDescription = null,
            tint = AuroraColors.blaze,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Cache limit",
                fontSize = AuroraTypography.body.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = cacheLimitLabel(limitMegabytes),
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
internal fun TranscriptCacheLimitSlider(state: TranscriptCacheSettingsState) {
    Slider(
        value = state.limitMegabytes.toFloat(),
        onValueChange = { raw ->
            val rounded = ((raw / 50f).roundToInt() * 50)
                .coerceIn(0, CloudTranscriptCacheSettings.MAXIMUM_MEGABYTES)
            if (rounded != state.limitMegabytes) state.setLimit(rounded)
        },
        valueRange = 0f..CloudTranscriptCacheSettings.MAXIMUM_MEGABYTES.toFloat()
    )
}

@Composable
internal fun TranscriptCacheUsageRow(snapshot: CloudTranscriptCacheSnapshot) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = "Used",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = cacheUsageLabel(snapshot),
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
internal fun TranscriptCacheActionButtons(state: TranscriptCacheSettingsState) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        TextButton(onClick = state.clearCache, enabled = state.snapshot.usageBytes > 0L) {
            Text("Clear cache")
        }
        TextButton(
            onClick = state.resetToDefault,
            enabled = state.limitMegabytes != CloudTranscriptCacheSettings.DEFAULT_MAX_MEGABYTES
        ) {
            Text("Use 250 MB")
        }
    }
}

@Composable
internal fun TranscriptCacheSettingsCard(
    state: TranscriptCacheSettingsState,
    haloColor: Color,
    useWebsiteBackground: Boolean,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = if (useWebsiteBackground) 0.35f else 0.6f)
    ) {
        Surface(color = haloColor, shape = RoundedCornerShape(AuroraRadius.lg.dp)) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(AuroraSpacing.md.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
            ) {
                TranscriptCacheLimitHeader(state.limitMegabytes)
                TranscriptCacheLimitSlider(state)
                TranscriptCacheUsageRow(state.snapshot)
                TranscriptCacheActionButtons(state)
                state.status?.let {
                    Text(
                        text = it,
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    text = "Encrypted on this device. Off downloads transcripts only when opened.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f)
                )
            }
        }
    }
}

@Composable
internal fun TranscriptCacheSettingsScreen(
    router: SettingsRouter,
    onBack: () -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val useWebsiteBackground by rememberWebsiteBackground()
    val state = rememberTranscriptCacheSettingsState()

    LaunchedEffect(router.pendingAnchor) {
        val pending = router.pendingAnchor
        if (pending == SettingsAnchor.TRANSCRIPT_CACHE) {
            router.consumePendingAnchor(pending)
            kotlinx.coroutines.delay(1_400)
            router.clearHighlight(pending)
        }
    }

    val haloColor by animateColorAsState(
        targetValue = if (router.highlightedAnchor == SettingsAnchor.TRANSCRIPT_CACHE) {
            Color(0xFFFFA800).copy(alpha = 0.18f)
        } else {
            Color.Transparent
        },
        animationSpec = tween(durationMillis = 350),
        label = "transcript-cache-halo"
    )

    Box(modifier = Modifier.fillMaxSize()) {
        if (useWebsiteBackground) {
            WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .background(
                    if (useWebsiteBackground) Color.Transparent
                    else if (isDark) AuroraColors.darkBackground
                    else AuroraColors.lightBackground
                )
                .padding(horizontal = AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
            TranscriptCacheSettingsTopBar(onBack = onBack, useWebsiteBackground = useWebsiteBackground)
            TranscriptCacheSettingsCard(state, haloColor, useWebsiteBackground)
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        }
    }
}
