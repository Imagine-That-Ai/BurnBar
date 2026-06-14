// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
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

@Composable
internal fun ApprovalAskRow(ask: ApprovalAsk, onApprove: () -> Unit, onDeny: () -> Unit, onApproveAlways: () -> Unit, onDenyAlways: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(10.dp),
        ) {
            ApprovalAskHeader(ask = ask)
            Text(
                ask.message,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            ApprovalAskActions(
                onApprove = onApprove,
                onDeny = onDeny,
                onApproveAlways = onApproveAlways,
                onDenyAlways = onDenyAlways,
            )
        }
    }
}

@Composable
private fun ApprovalAskHeader(ask: ApprovalAsk) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            ask.title,
            fontSize = 13.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Surface(
            shape = RoundedCornerShape(999.dp),
            color = MaterialTheme.colorScheme.surface,
        ) {
            Text(
                ask.runtimeDisplayLabel,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
            )
        }
    }
}

@Composable
private fun ApprovalAskActions(onApprove: () -> Unit, onDeny: () -> Unit, onApproveAlways: () -> Unit, onDenyAlways: () -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ApprovalActionPill(label = "Approve", color = AuroraColors.success, contentColor = Color.White, onClick = onApprove)
        ApprovalActionPill(label = "Deny", color = AuroraColors.error.copy(alpha = 0.18f), contentColor = AuroraColors.error, onClick = onDeny)
        Spacer(modifier = Modifier.weight(1f))
        ApprovalAlwaysMenu(onApproveAlways = onApproveAlways, onDenyAlways = onDenyAlways)
    }
}

@Composable
private fun ApprovalAlwaysMenu(onApproveAlways: () -> Unit, onDenyAlways: () -> Unit) {
    var menuExpanded by remember { mutableStateOf(false) }
    Box {
        ApprovalAlwaysMenuTrigger(onClick = { menuExpanded = true })
        ApprovalAlwaysDropdown(
            expanded = menuExpanded,
            onDismiss = { menuExpanded = false },
            onApproveAlways = {
                menuExpanded = false
                onApproveAlways()
            },
            onDenyAlways = {
                menuExpanded = false
                onDenyAlways()
            },
        )
    }
}

@Composable
private fun ApprovalAlwaysMenuTrigger(onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = MaterialTheme.colorScheme.surface,
        modifier = Modifier.clickable(onClick = onClick),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            Icon(Icons.Filled.MoreVert, contentDescription = null, modifier = Modifier.size(12.dp), tint = MaterialTheme.colorScheme.onSurface)
            Spacer(modifier = Modifier.width(3.dp))
            Text("Always…", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun ApprovalAlwaysDropdown(expanded: Boolean, onDismiss: () -> Unit, onApproveAlways: () -> Unit, onDenyAlways: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text("Always approve this class") },
            leadingIcon = { Icon(Icons.Filled.Check, contentDescription = null, tint = AuroraColors.success) },
            onClick = onApproveAlways,
        )
        DropdownMenuItem(
            text = { Text("Always deny this class") },
            leadingIcon = { Icon(Icons.Filled.Close, contentDescription = null, tint = AuroraColors.error) },
            onClick = onDenyAlways,
        )
    }
}

@Composable
internal fun ApprovalActionPill(label: String, color: Color, contentColor: Color, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = color,
        modifier =
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .clickable(onClick = onClick),
    ) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = contentColor,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}
