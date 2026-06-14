// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.TokenUsage
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun RecentSessionsStripCard(sessions: List<TokenUsage>, onSelect: (TokenUsage) -> Unit, onSeeAll: () -> Unit) {
    AuroraGlassCard(
        modifier = Modifier.padding(horizontal = AuroraSpacing.LG.dp),
        cornerRadius = AuroraRadius.XL,
    ) {
        Column {
            RecentSessionsStripHeader(sessionCount = sessions.size, onSeeAll = onSeeAll)
            Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))
            if (sessions.isEmpty()) {
                EmptyStateView(
                    title = "No sessions yet",
                    message = "Sessions will appear here as soon as your Mac syncs.",
                )
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(sessions.take(8)) { session ->
                        SessionTileMicro(usage = session, onClick = { onSelect(session) })
                    }
                }
            }
        }
    }
}

@Composable
private fun RecentSessionsStripHeader(sessionCount: Int, onSeeAll: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(
                text = "Recent",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.whimsy,
            )
            Text(
                text = if (sessionCount == 0) "Awaiting first session" else "Last $sessionCount sessions",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            text = "See all ›",
            fontSize = AuroraTypography.tiny.sp,
            fontWeight = FontWeight.SemiBold,
            color = AuroraColors.whimsy,
            modifier = Modifier.clickable { onSeeAll() },
        )
    }
}
