package com.openburnbar.ui.square

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.ApprovalAsk
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Approval Inbox Strip (Android parity, Hermes Square §6.9)
//
// Sticky strip surfaced at the top of the Square when there are pending
// approval asks. Each row carries Approve / Deny / Always… affordances.

@Composable
internal fun ApprovalInboxStrip(
    asks: List<ApprovalAsk>,
    onApprove: (ApprovalAsk) -> Unit,
    onDeny: (ApprovalAsk) -> Unit,
    onApproveAlways: (ApprovalAsk) -> Unit,
    onDenyAlways: (ApprovalAsk) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (asks.isEmpty()) return
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AuroraColors.warning.copy(alpha = 0.10f),
        modifier =
        modifier
            .fillMaxWidth()
            .border(
                width = 0.5.dp,
                color = AuroraColors.warning.copy(alpha = 0.45f),
                shape = RoundedCornerShape(12.dp),
            ),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.PanTool,
                    contentDescription = null,
                    tint = AuroraColors.warning,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    "Approvals waiting",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    "${asks.size}",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            for (ask in asks) {
                ApprovalAskRow(
                    ask = ask,
                    onApprove = { onApprove(ask) },
                    onDeny = { onDeny(ask) },
                    onApproveAlways = { onApproveAlways(ask) },
                    onDenyAlways = { onDenyAlways(ask) },
                )
            }
        }
    }
}
