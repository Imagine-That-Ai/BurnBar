package com.openburnbar.ui.you

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.AuthStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.SectionHeader
import com.openburnbar.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun YouView(
    authStore: AuthStore = viewModel()
) {
    val isDark = isSystemInDarkTheme()
    val isSignedIn by authStore.isSignedIn.collectAsState()
    val userDisplayName by authStore.userDisplayName.collectAsState()
    val userEmail by authStore.userEmail.collectAsState()

    val context = LocalContext.current

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = "You",
                        fontWeight = FontWeight.Bold,
                        fontSize = AuroraTypography.title.sp
                    )
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent,
                    scrolledContainerColor = Color.Transparent
                )
            )
        },
        containerColor = Color.Transparent
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(
                start = AuroraSpacing.lg.dp,
                end = AuroraSpacing.lg.dp,
                top = AuroraSpacing.sm.dp,
                bottom = AuroraSpacing.xxxl.dp
            ),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
        ) {
            // ── Identity Hero ──
            item(key = "identity") {
                IdentityHeroCard(
                    displayName = userDisplayName,
                    email = userEmail,
                    isSignedIn = isSignedIn,
                    isDark = isDark
                )
            }

            // ── Connected Devices ──
            item(key = "devices") {
                ConnectedDevicesRow()
            }

            // ── Settings ──
            item(key = "settings_header") {
                SectionHeader(title = "Settings")
            }

            // ── Account Management ──
            item(key = "account") {
                AuroraGlassCard {
                    SettingsRow(
                        icon = Icons.Filled.Person,
                        title = "Account",
                        subtitle = if (isSignedIn) userEmail ?: "Signed in" else "Not signed in",
                        label = if (isSignedIn) "Sign Out" else "Sign In",
                        onClick = {
                            if (isSignedIn) {
                                authStore.signOut()
                            }
                        }
                    )
                }
            }

            // ── Sync Health ──
            item(key = "sync") {
                AuroraGlassCard {
                    SettingsRow(
                        icon = Icons.Filled.Sync,
                        title = "Sync Health",
                        subtitle = "Last synced: moments ago",
                        label = "",
                        onClick = { /* placeholder */ }
                    )
                }
            }

            // ── Credential Transfer ──
            item(key = "credential") {
                AuroraGlassCard {
                    SettingsRow(
                        icon = Icons.Filled.VpnKey,
                        title = "Credential Transfer",
                        subtitle = "Export or import your API keys",
                        label = "",
                        onClick = { /* placeholder */ }
                    )
                }
            }

            // ── Cloud Subscription ──
            item(key = "cloud") {
                AuroraGlassCard {
                    SettingsRow(
                        icon = Icons.Filled.Cloud,
                        title = "Cloud Subscription",
                        subtitle = "Unlock premium sync and backup",
                        label = "Coming Soon",
                        labelTint = AuroraColors.whimsy,
                        onClick = { /* placeholder */ }
                    )
                }
            }

            // ── About ──
            item(key = "about_header") {
                SectionHeader(title = "About")
            }

            item(key = "about") {
                AboutSection(context = context)
            }
        }
    }
}

// ── Identity Hero Card ──
@Composable
fun IdentityHeroCard(
    displayName: String?,
    email: String?,
    isSignedIn: Boolean,
    isDark: Boolean
) {
    val name = displayName ?: "User"
    val initials = name
        .split(" ")
        .take(2)
        .mapNotNull { it.firstOrNull()?.uppercase() }
        .joinToString("")
        .ifEmpty { "U" }

    val avatarGradient = if (isDark) {
        listOf(AuroraColors.ember, AuroraColors.amber)
    } else {
        listOf(AuroraColors.ember, AuroraColors.blaze)
    }

    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(60.dp)
                    .clip(CircleShape)
                    .background(Brush.linearGradient(avatarGradient)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = initials,
                    color = Color.White,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold
                )
            }

            Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = if (isSignedIn) name else "Welcome to BurnBar",
                    fontSize = AuroraTypography.title.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(modifier = Modifier.height(AuroraSpacing.xxs.dp))
                Text(
                    text = if (isSignedIn) (email ?: "No email") else "Sign in to personalize your experience",
                    fontSize = AuroraTypography.body.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            if (isSignedIn) {
                Icon(
                    imageVector = Icons.Filled.CheckCircle,
                    contentDescription = "Signed in",
                    tint = AuroraColors.success,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

// ── Connected Devices Row ──
@Composable
fun ConnectedDevicesRow() {
    val deviceCount = 0

    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Filled.Devices,
                contentDescription = null,
                modifier = Modifier.size(22.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Connected Devices",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "$deviceCount device${if (deviceCount != 1) "s" else ""} connected",
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                imageVector = Icons.Filled.ChevronRight,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            )
        }
    }
}

// ── Settings Row ──
@Composable
fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    label: String,
    onClick: () -> Unit,
    labelTint: Color = MaterialTheme.colorScheme.onSurfaceVariant
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = AuroraSpacing.xs.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(22.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = subtitle,
                fontSize = AuroraTypography.caption.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        if (label.isNotEmpty()) {
            Text(
                text = label,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = labelTint
            )
        }
    }
}

// ── About Section ──
@Composable
fun AboutSection(context: android.content.Context) {
    val packageInfo = try {
        context.packageManager.getPackageInfo(context.packageName, 0)
    } catch (_: Exception) { null }
    val versionName = packageInfo?.versionName ?: "1.0.0"

    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "BurnBar",
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = "v$versionName",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = AuroraColors.whimsy
            )
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        HorizontalDivider(
            color = MaterialTheme.colorScheme.outlineVariant,
            thickness = 0.5.dp
        )

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        AboutLinkRow(icon = Icons.Filled.Description, label = "Terms of Service")
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        AboutLinkRow(icon = Icons.Filled.Security, label = "Privacy Policy")
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        AboutLinkRow(icon = Icons.Filled.Code, label = "Open Source Licenses")

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        HorizontalDivider(
            color = MaterialTheme.colorScheme.outlineVariant,
            thickness = 0.5.dp
        )

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        Text(
            text = "Made with 🔥 by the BurnBar team",
            fontSize = AuroraTypography.tiny.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.Center
        )
    }
}

// ── About Link Row ──
@Composable
fun AboutLinkRow(
    icon: ImageVector,
    label: String
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { /* placeholder: open URL */ }
            .padding(vertical = AuroraSpacing.xs.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
        Text(
            text = label,
            fontSize = AuroraTypography.body.sp,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.weight(1f))
        Icon(
            imageVector = Icons.Filled.OpenInNew,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
        )
    }
}
