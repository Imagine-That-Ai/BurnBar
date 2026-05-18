package com.openburnbar.ui.square

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.missions.ApprovalAsk
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Approval Inbox Strip (Android parity, Hermes Square §6.9)
//
// Sticky strip surfaced at the top of the Square when there are pending
// approval asks. Each row carries Approve / Deny / Always… affordances.
// Matches the iOS `ApprovalInboxStrip` layout 1:1.

@Composable
internal fun ApprovalInboxStrip(
    asks: List<ApprovalAsk>,
    onApprove: (ApprovalAsk) -> Unit,
    onDeny: (ApprovalAsk) -> Unit,
    onApproveAlways: (ApprovalAsk) -> Unit,
    onDenyAlways: (ApprovalAsk) -> Unit,
    modifier: Modifier = Modifier
) {
    if (asks.isEmpty()) return
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = AuroraColors.warning.copy(alpha = 0.10f),
        modifier = modifier
            .fillMaxWidth()
            .border(
                width = 0.5.dp,
                color = AuroraColors.warning.copy(alpha = 0.45f),
                shape = RoundedCornerShape(12.dp)
            )
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Filled.PanTool,
                    contentDescription = null,
                    tint = AuroraColors.warning,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    "Approvals waiting",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    "${asks.size}",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            for (ask in asks) {
                ApprovalAskRow(
                    ask = ask,
                    onApprove = { onApprove(ask) },
                    onDeny = { onDeny(ask) },
                    onApproveAlways = { onApproveAlways(ask) },
                    onDenyAlways = { onDenyAlways(ask) }
                )
            }
        }
    }
}

@Composable
private fun ApprovalAskRow(
    ask: ApprovalAsk,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
    onApproveAlways: () -> Unit,
    onDenyAlways: () -> Unit
) {
    var menuExpanded by remember { mutableStateOf(false) }
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(10.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    ask.title,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
                Surface(
                    shape = RoundedCornerShape(999.dp),
                    color = MaterialTheme.colorScheme.surface
                ) {
                    Text(
                        ask.runtimeDisplayLabel,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                    )
                }
            }
            Text(
                ask.message,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ApprovalActionPill(
                    label = "Approve",
                    color = AuroraColors.success,
                    contentColor = Color.White,
                    onClick = onApprove
                )
                ApprovalActionPill(
                    label = "Deny",
                    color = AuroraColors.error.copy(alpha = 0.18f),
                    contentColor = AuroraColors.error,
                    onClick = onDeny
                )
                Spacer(modifier = Modifier.weight(1f))
                Box {
                    Surface(
                        shape = RoundedCornerShape(999.dp),
                        color = MaterialTheme.colorScheme.surface,
                        modifier = Modifier.clickable { menuExpanded = true }
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.MoreVert,
                                contentDescription = null,
                                modifier = Modifier.size(12.dp),
                                tint = MaterialTheme.colorScheme.onSurface
                            )
                            Spacer(modifier = Modifier.width(3.dp))
                            Text(
                                "Always…",
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                    DropdownMenu(
                        expanded = menuExpanded,
                        onDismissRequest = { menuExpanded = false }
                    ) {
                        DropdownMenuItem(
                            text = { Text("Always approve this class") },
                            leadingIcon = {
                                Icon(
                                    imageVector = Icons.Filled.Check,
                                    contentDescription = null,
                                    tint = AuroraColors.success
                                )
                            },
                            onClick = {
                                menuExpanded = false
                                onApproveAlways()
                            }
                        )
                        DropdownMenuItem(
                            text = { Text("Always deny this class") },
                            leadingIcon = {
                                Icon(
                                    imageVector = Icons.Filled.Close,
                                    contentDescription = null,
                                    tint = AuroraColors.error
                                )
                            },
                            onClick = {
                                menuExpanded = false
                                onDenyAlways()
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ApprovalActionPill(
    label: String,
    color: Color,
    contentColor: Color,
    onClick: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = color,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = contentColor,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
        )
    }
}
