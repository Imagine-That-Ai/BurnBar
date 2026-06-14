// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures structure.

package com.openburnbar.ui.control

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.GppMaybe
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Access Audit Timeline — a tamper-evident, hash-chained log of who/what
 * touched your data. Each event links to the previous via prevHash; the
 * "Verify" action walks the chain server-side and reports whether it's intact
 * (and where it broke, if so). Pages forward via the opaque cursor.
 */
@Composable
internal fun AuditTimelineSection(
    events: List<AuditEvent>,
    loading: Boolean,
    hasMore: Boolean,
    verification: AuditVerification?,
    onVerify: () -> Unit,
    onLoadMore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AuroraGlassCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Access audit",
                    style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
                    color = PensieveControlTokens.mercuryBright,
                )
                Spacer(modifier = Modifier.weight(1f))
                if (loading) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = PensieveControlTokens.brassBright)
                }
            }
            Text(
                "A tamper-evident record of every access. Each entry is cryptographically chained to the one before it.",
                style = AuroraType.caption,
                color = PensieveControlTokens.textMute,
            )

            verification?.let { VerificationBanner(it) }

            ControlActionButton(
                label = "Verify the chain",
                icon = Icons.Filled.Verified,
                enabled = !loading,
                onClick = onVerify,
            )

            if (events.isEmpty() && !loading) {
                Text("No access events recorded yet.", style = AuroraType.body, color = PensieveControlTokens.textDim)
            } else {
                events.forEach { event -> AuditRow(event) }
            }

            if (hasMore) {
                Text(
                    "Load older events",
                    style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = PensieveControlTokens.brassBright,
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !loading) { onLoadMore() }
                        .padding(vertical = AuroraSpacing.SM.dp),
                )
            }
        }
    }
}

@Composable
private fun VerificationBanner(verification: AuditVerification) {
    val (icon, color, text) =
        if (verification.valid) {
            Triple(Icons.Filled.CheckCircle, PensieveControlTokens.tierEndToEnd, "Chain intact — nothing has been altered.")
        } else {
            Triple(
                Icons.Filled.GppMaybe,
                PensieveControlTokens.sealCrimson,
                verification.brokenAt?.let { "Chain broken at entry #$it." } ?: "Chain integrity could not be confirmed.",
            )
        }
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(color.copy(alpha = 0.10f), RoundedCornerShape(AuroraRadius.MD.dp))
            .border(0.75.dp, color.copy(alpha = 0.4f), RoundedCornerShape(AuroraRadius.MD.dp))
            .padding(AuroraSpacing.MD.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = color)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Text(text, style = AuroraType.caption, color = color)
    }
}

@Composable
private fun AuditRow(event: AuditEvent) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(28.dp)) {
            Box(modifier = Modifier.size(8.dp).background(PensieveControlTokens.mercuryDeep, CircleShape))
            Box(modifier = Modifier.width(1.dp).height(28.dp).background(PensieveControlTokens.glassLine))
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                "${event.actor} · ${event.action}",
                style = AuroraType.body.copy(fontWeight = FontWeight.Medium),
                color = PensieveControlTokens.mercuryBright,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
                Text(event.domainTitle, style = AuroraType.tiny, color = PensieveControlTokens.textMute)
                event.ts?.let { Text(formatTimestamp(it), style = AuroraType.tiny, color = PensieveControlTokens.textDim) }
            }
            event.hash?.let { hash ->
                Text(
                    "#${event.seq} · ${hash.take(12)}…",
                    style = AuroraType.monoTiny,
                    color = PensieveControlTokens.textDim,
                )
            }
        }
    }
}

private fun formatTimestamp(ms: Long): String = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault()).format(Date(ms))
