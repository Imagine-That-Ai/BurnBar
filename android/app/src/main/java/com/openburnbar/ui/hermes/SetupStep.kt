package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

data class SetupStep(
    val number: Int,
    val title: String,
    val detail: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
)

private val setupSteps =
    listOf(
        SetupStep(
            1,
            "Keep your Mac ready",
            "OpenBurnBar on macOS should be signed in, running, and set to allow Hermes Remote Relay.",
            Icons.Filled.Computer,
        ),
        SetupStep(
            2,
            "Pick a Hermes host",
            "Use Remote Relay away from home; use a direct LAN/VPN URL only when your device can reach the Mac.",
            Icons.Filled.WifiTethering,
        ),
        SetupStep(
            3,
            "Start chatting",
            "Ask about spend, sessions, quota pressure, or anything your connected Hermes runtime can answer.",
            Icons.Filled.ChatBubble,
        ),
    )

@Composable
fun HermesSetupWizard(onComplete: () -> Unit, onOpenConnections: () -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier =
        modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(AuroraSpacing.lg.dp),
    ) {
        HermesSetupWizardToolbar(onDismiss = onDismiss)
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        HermesSetupWizardHeader()
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        HermesSetupWizardSteps()
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        HermesSetupWizardActions(onComplete = onComplete, onOpenConnections = onOpenConnections)
    }
}

@Composable
private fun HermesSetupWizardToolbar(onDismiss: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        IconButton(onClick = onDismiss) {
            Icon(Icons.Filled.Close, contentDescription = "Close")
        }
        Text(
            text = "Hermes Setup",
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun HermesSetupWizardHeader() {
    AuroraGlassCard(cornerRadius = AuroraRadius.xl) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "☿",
                    fontSize = 38.sp,
                    fontWeight = FontWeight.Bold,
                    color = AuroraColors.hermesAureate,
                )
                Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
                Column {
                    Text(
                        text = "Hermes in 1-2-3",
                        fontSize = AuroraTypography.title.sp,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "One Mac host. One connection. One chat.",
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            Text(
                text = "For Android, Hermes works by talking to your Mac's local runtime directly on LAN/VPN or through your private Remote Relay.",
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun HermesSetupWizardSteps() {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        setupSteps.forEach { step -> SetupStepRow(step = step) }
    }
}

@Composable
private fun HermesSetupWizardActions(onComplete: () -> Unit, onOpenConnections: () -> Unit) {
    Button(
        onClick = onComplete,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesAureate),
    ) {
        Text("Start Chatting", fontWeight = FontWeight.SemiBold)
    }
    Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
    TextButton(onClick = onOpenConnections, modifier = Modifier.fillMaxWidth()) {
        Icon(Icons.Filled.NetworkCheck, contentDescription = null, modifier = Modifier.size(16.dp))
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text("Open Connections", color = AuroraColors.hermesAureate)
    }
}

@Composable
private fun SetupStepRow(step: SetupStep) {
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.78f))
            .border(0.5.dp, AuroraColors.hermesAureate.copy(alpha = 0.22f), RoundedCornerShape(16.dp))
            .padding(14.dp),
    ) {
        Box(
            modifier =
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(Brush.linearGradient(AuroraGradients.mercuryFoil)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = step.number.toString(),
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = step.icon,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = step.title,
                    fontSize = AuroraTypography.body.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
            Text(
                text = step.detail,
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
