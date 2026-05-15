package com.openburnbar.ui.store

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraGradients
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.text.SimpleDateFormat
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudStoreView(
    onClose: () -> Unit = {},
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel()
) {
    val context = LocalContext.current
    val isActive by subscriptionStore.isActive.collectAsState()
    val isLoading by subscriptionStore.isLoading.collectAsState()
    val error by subscriptionStore.error.collectAsState()
    val productDetails by subscriptionStore.productDetails.collectAsState()
    val expirationDate by subscriptionStore.expirationDate.collectAsState()
    val purchaseDate by subscriptionStore.purchaseDate.collectAsState()

    LaunchedEffect(context) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("OpenBurnBar Cloud", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onClose) { Icon(Icons.Filled.Close, null) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        containerColor = Color.Transparent
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.xl.dp)
        ) {
            item { CloudHeroSection() }

            item {
                if (isActive) {
                    MemberCard(expirationDate = expirationDate, purchaseDate = purchaseDate)
                } else {
                    PlanPicker(priceText = productDetails?.formattedPrice ?: "$4.99")
                }
            }

            item { CapabilitySection(isActive = isActive) }
            item { ComparisonCard() }
            item { TrustCard() }

            if (error != null) {
                item {
                    AuroraGlassCard {
                        Text(error!!, color = AuroraColors.error, fontSize = AuroraTypography.caption.sp)
                    }
                }
            }

            if (!isActive) {
                item {
                    val activity = context as? android.app.Activity
                    Button(
                        onClick = { activity?.let(subscriptionStore::purchase) },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !isLoading && activity != null,
                        colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.ember)
                    ) {
                        if (isLoading) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = Color.White)
                        } else {
                            Text("Subscribe — ${productDetails?.formattedPrice ?: "$4.99"}/mo")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CloudHeroSection() {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            "OpenBurnBar",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
        )
        Text(
            "Cloud",
            fontSize = AuroraTypography.displayHero.sp,
            fontWeight = FontWeight.Bold,
            color = AuroraColors.ember
        )
        Text(
            "Quota in your pocket. Hermes anywhere. Backups for every byte.",
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = AuroraSpacing.xl.dp)
        )
    }
}

@Composable
private fun PlanPicker(priceText: String) {
    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                PlanTile(
                    title = "Monthly",
                    priceText = priceText,
                    cadence = "/ month",
                    caption = "Most flexible",
                    isSelected = true,
                    modifier = Modifier.weight(1f)
                )
                PlanTile(
                    title = "Yearly",
                    priceText = "—",
                    cadence = "Coming soon",
                    caption = "Save more, billed yearly",
                    isSelected = false,
                    modifier = Modifier.weight(1f)
                )
            }
            Text(
                "Billed monthly through Google Play. Cancel anytime in Play Store.",
                fontSize = AuroraTypography.tiny.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                textAlign = TextAlign.Center
            )
        }
    }
}

@Composable
private fun PlanTile(
    title: String,
    priceText: String,
    cadence: String,
    caption: String,
    isSelected: Boolean,
    modifier: Modifier = Modifier
) {
    val borderColor = if (isSelected) AuroraColors.ember else MaterialTheme.colorScheme.outline.copy(alpha = 0.5f)
    val bgAlpha = if (isSelected) 0.1f else 0.05f

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(AuroraRadius.lg.dp))
            .background(AuroraColors.ember.copy(alpha = bgAlpha))
            .border(1.dp, borderColor, RoundedCornerShape(AuroraRadius.lg.dp))
            .padding(AuroraSpacing.md.dp)
    ) {
        Row {
            Text(title, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.SemiBold)
            Spacer(modifier = Modifier.weight(1f))
            if (isSelected) {
                Text(
                    "CURRENT",
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    color = AuroraColors.success,
                    modifier = Modifier
                        .background(AuroraColors.success.copy(alpha = 0.18f), CircleShape)
                        .padding(horizontal = 6.dp, vertical = 3.dp)
                )
            } else {
                Icon(Icons.Filled.Lock, null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
            }
        }
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        Text(priceText, fontSize = 30.sp, fontWeight = FontWeight.Bold, color = if (isSelected) AuroraColors.ember else MaterialTheme.colorScheme.onSurfaceVariant)
        Text(cadence, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(caption, fontSize = AuroraTypography.tiny.sp, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
    }
}

@Composable
private fun MemberCard(expirationDate: Long?, purchaseDate: Long?) {
    val sdf = SimpleDateFormat("MMM d", Locale.getDefault())
    AuroraGlassCard {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("CLOUD", fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = AuroraColors.hermesAureate)
            }
            Text("Member", fontSize = AuroraTypography.display.sp, fontWeight = FontWeight.Bold)

            if (expirationDate != null) {
                Text("Renews ${sdf.format(java.util.Date(expirationDate))}", fontSize = AuroraTypography.body.sp)
            } else {
                Text("Active", fontSize = AuroraTypography.body.sp, color = AuroraColors.success)
            }

            if (purchaseDate != null) {
                Text("Member since ${SimpleDateFormat("MMM yyyy", Locale.getDefault()).format(java.util.Date(purchaseDate))}", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun CapabilitySection(isActive: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("What's Included".uppercase(), fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
            Spacer(modifier = Modifier.weight(1f))
            if (isActive) {
                Text("Active", fontSize = AuroraTypography.tiny.sp, color = AuroraColors.success)
            }
        }

        CapabilityCard(
            icon = "☁",
            title = "Hosted Codex Quota",
            details = "Refresh Codex quota from any signed-in device with one tap.",
            isActive = isActive
        )
        CapabilityCard(
            icon = "↻",
            title = "Conversation Backup & Resume",
            details = "Back up chat titles, previews, and message bodies — encrypted in transit.",
            isActive = isActive
        )
        CapabilityCard(
            icon = "≡",
            title = "Full Session-Log Sync",
            details = "Mirror complete agent runs into the cloud — searchable on every device.",
            isActive = isActive
        )
        CapabilityCard(
            icon = "📡",
            title = "Hermes Remote Relay",
            details = "Reach your Mac's Hermes from anywhere over a verified WebSocket.",
            isActive = isActive
        )
    }
}

@Composable
private fun CapabilityCard(icon: String, title: String, details: String, isActive: Boolean) {
    AuroraGlassCard {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .background(Brush.linearGradient(AuroraGradients.primaryGradient), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center
            ) {
                Text(icon, fontSize = 18.sp)
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.headline.sp)
                    if (isActive) {
                        Icon(Icons.Filled.CheckCircle, null, modifier = Modifier.size(16.dp).padding(start = 4.dp), tint = AuroraColors.success)
                    }
                }
                Text(details, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun ComparisonCard() {
    val rows = listOf(
        Triple("Quota refresh", "Local-only", "On-demand, anywhere"),
        Triple("Chat backup", "Metadata only", "Full content"),
        Triple("Session logs", "Manifest only", "Search metadata"),
        Triple("Hermes Remote Relay", "Local network", "Anywhere")
    )

    AuroraGlassCard {
        Column {
            Text("Free vs Cloud".uppercase(), fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
            Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
            Row {
                Text("Capability", fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text("Free", fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(80.dp), textAlign = TextAlign.End)
                Text("Cloud", fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.Bold, color = AuroraColors.ember, modifier = Modifier.width(90.dp), textAlign = TextAlign.End)
            }
            HorizontalDivider(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp))
            rows.forEach { (label, free, cloud) ->
                Row(modifier = Modifier.padding(vertical = AuroraSpacing.sm.dp)) {
                    Text(label, fontSize = AuroraTypography.body.sp, modifier = Modifier.weight(1f))
                    Text(free, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(80.dp), textAlign = TextAlign.End)
                    Text(cloud, fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(90.dp), textAlign = TextAlign.End)
                }
            }
        }
    }
}

@Composable
private fun TrustCard() {
    val bullets = listOf(
        Triple("✓", "Google-verified", "Every purchase verified through Google Play."),
        Triple("✓", "UID-bound", "Each purchase is bound to your Firebase UID."),
        Triple("✓", "Cancel anytime", "Managed by Google Play. We never store payment details.")
    )

    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            Text("The Trust Model".uppercase(), fontSize = AuroraTypography.tiny.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
            bullets.forEach { (icon, title, detail) ->
                Row(verticalAlignment = Alignment.Top) {
                    Text(icon, color = AuroraColors.success, fontWeight = FontWeight.Bold, modifier = Modifier.width(22.dp))
                    Column {
                        Text(title, fontWeight = FontWeight.SemiBold, fontSize = AuroraTypography.body.sp)
                        Text(detail, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}
