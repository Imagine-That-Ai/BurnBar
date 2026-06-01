@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.store

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.HostedQuotaProductDetails
import com.openburnbar.data.stores.HostedQuotaStoreProduct
import com.openburnbar.data.stores.HostedQuotaStoreProductRole
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore

// ── Plan tile (free users) ──

@Composable
internal fun CloudPlanGlassCard(priceText: String) {
    AuroraGlassCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CloudPlanMembershipHeader()
            CloudPlanPriceRow(priceText = priceText)
            Text(
                "Billed monthly through Google Play. Manage or cancel anytime in Play Store.",
                fontSize = 12.sp,
                color = CloudStorePal.textSecondary,
            )
        }
    }
}

@Composable
internal fun CloudPlanMembershipHeader() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "MEMBERSHIP",
            fontSize = 11.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.4.sp,
            color = CloudStorePal.ember,
        )
        Spacer(Modifier.weight(1f))
        Box(
            modifier =
            Modifier
                .clip(CircleShape)
                .background(CloudStorePal.surface.copy(alpha = 0.6f), CircleShape)
                .border(0.6.dp, CloudStorePal.border, CircleShape)
                .padding(horizontal = 10.dp, vertical = 4.dp),
        ) {
            Text(
                "MONTHLY",
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.4.sp,
                color = CloudStorePal.textSecondary,
            )
        }
    }
}

@Composable
internal fun CloudPlanPriceRow(priceText: String) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(
            priceText,
            style =
            TextStyle(
                fontFamily = FontFamily.SansSerif,
                fontWeight = FontWeight.Bold,
                fontSize = 32.sp,
                brush = Brush.linearGradient(listOf(CloudStorePal.ember, CloudStorePal.amber)),
            ),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            "/ month",
            fontSize = 14.sp,
            color = CloudStorePal.textSecondary,
            modifier = Modifier.padding(bottom = 4.dp),
        )
    }
}

@Composable
internal fun CloudPaidTierCard(isActive: Boolean, prices: Map<String, HostedQuotaProductDetails>, isLoading: Boolean, onPurchase: (String) -> Unit) {
    val products = HostedQuotaSubscriptionStore.STORE_PRODUCTS
    val cloud = products.filter { it.role == HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION }
    val cloudPro = products.filter { it.role == HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION }
    val topUps = products.filter { it.role == HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP }
    val hasPlayPrices = prices.isNotEmpty()

    AuroraGlassCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            PlanCardHeader(hasPlayPrices)
            CloudPaidTierPlans(
                args =
                CloudPaidTierPlansArgs(
                    cloud = cloud,
                    cloudPro = cloudPro,
                    topUps = topUps,
                    prices = prices,
                    isActive = isActive,
                    isLoading = isLoading,
                    onPurchase = onPurchase,
                ),
            )
        }
    }
}

internal data class CloudPaidTierPlansArgs(
    val cloud: List<HostedQuotaStoreProduct>,
    val cloudPro: List<HostedQuotaStoreProduct>,
    val topUps: List<HostedQuotaStoreProduct>,
    val prices: Map<String, HostedQuotaProductDetails>,
    val isActive: Boolean,
    val isLoading: Boolean,
    val onPurchase: (String) -> Unit,
)

@Composable
internal fun CloudPaidTierPlans(args: CloudPaidTierPlansArgs) {
    val cloud = args.cloud
    val cloudPro = args.cloudPro
    val topUps = args.topUps
    val prices = args.prices
    val isActive = args.isActive
    val isLoading = args.isLoading
    val onPurchase = args.onPurchase
    TierPlanCard(
        presentation =
        TierPlanPresentation(
            label = "Cloud",
            title = "BurnBar Cloud",
            summary = "Quota sync, encrypted history, search, and memory across every device.",
            icon = Icons.Filled.Cloud,
            accent = CloudStorePal.ember,
            featureChips = listOf("Quota sync", "History", "Memory"),
        ),
        commerce =
        TierPlanCommerce(
            products = cloud,
            prices = prices,
            enabled = !isLoading,
            onPurchase = onPurchase,
        ),
    )
    TierPlanCard(
        presentation =
        TierPlanPresentation(
            label = "Cloud Pro",
            title = "BurnBar Cloud Pro",
            summary = "Everything in Cloud, plus Floo, relay, and supervised Agent Control.",
            icon = Icons.Filled.AutoAwesome,
            accent = CloudStorePal.whimsy,
            featureChips = listOf("Floo", "Agent Control", "Relay"),
            featured = true,
        ),
        commerce =
        TierPlanCommerce(
            products = cloudPro,
            prices = prices,
            enabled = !isLoading,
            onPurchase = onPurchase,
        ),
    )
    if (isActive) {
        TopUpPlanRail(
            products = topUps,
            prices = prices,
            enabled = !isLoading,
            onPurchase = onPurchase,
        )
    }
}

@Composable
internal fun PlanCardHeader(hasPlayPrices: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "GOOGLE PLAY PLANS",
            fontSize = 11.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.4.sp,
            color = CloudStorePal.ember,
        )
        Spacer(Modifier.weight(1f))
        Text(
            "PLAY BILLING",
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.2.sp,
            color = if (hasPlayPrices) CloudStorePal.success else CloudStorePal.textMuted,
            modifier =
            Modifier
                .clip(CircleShape)
                .background((if (hasPlayPrices) CloudStorePal.success else CloudStorePal.border).copy(alpha = 0.12f))
                .border(0.6.dp, (if (hasPlayPrices) CloudStorePal.success else CloudStorePal.border).copy(alpha = 0.34f), CircleShape)
                .padding(horizontal = 9.dp, vertical = 4.dp),
        )
    }
}

internal data class CloudPlanOption(
    val product: HostedQuotaStoreProduct,
    val periodLabel: String?,
    val saveLabel: String?,
    val cadenceLabel: String?,
)

internal fun cloudPlanOption(product: HostedQuotaStoreProduct): CloudPlanOption {
    val annual =
        product.id == HostedQuotaSubscriptionStore.CLOUD_ANNUAL_PRODUCT_ID ||
            product.id == HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID
    val pro = product.role == HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION
    return CloudPlanOption(
        product = product,
        periodLabel = if (annual) "Annual" else "Monthly",
        saveLabel = if (annual) if (pro) "Save 17%" else "Save 18%" else null,
        cadenceLabel = if (annual) "/yr" else "/mo",
    )
}

internal data class TierPlanPresentation(
    val label: String,
    val title: String,
    val summary: String,
    val icon: ImageVector,
    val accent: Color,
    val featureChips: List<String>,
    val featured: Boolean = false,
)

internal data class TierPlanCommerce(
    val products: List<HostedQuotaStoreProduct>,
    val prices: Map<String, HostedQuotaProductDetails>,
    val enabled: Boolean,
    val onPurchase: (String) -> Unit,
)

@Composable
internal fun TierPlanCard(presentation: TierPlanPresentation, commerce: TierPlanCommerce) {
    if (commerce.products.isEmpty()) return
    val shape = RoundedCornerShape(22.dp)
    val accent = presentation.accent
    val featured = presentation.featured
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(CloudStorePal.surface.copy(alpha = 0.80f), shape)
            .background(
                brush =
                Brush.radialGradient(
                    colors = listOf(accent.copy(alpha = if (featured) 0.30f else 0.20f), Color.Transparent),
                    center = androidx.compose.ui.geometry.Offset(100f, 40f),
                    radius = 520f,
                ),
                shape = shape,
            )
            .border(
                width = if (featured) 1.dp else 0.7.dp,
                brush =
                Brush.linearGradient(
                    listOf(accent.copy(alpha = if (featured) 0.60f else 0.36f), CloudStorePal.border.copy(alpha = 0.38f)),
                ),
                shape = shape,
            )
            .padding(16.dp),
    ) {
        TierPlanCardBody(
            presentation = presentation,
            commerce = commerce,
            options = commerce.products.map(::cloudPlanOption),
        )
    }
}

@Composable
internal fun TierPlanCardBody(
    presentation: TierPlanPresentation,
    commerce: TierPlanCommerce,
    options: List<CloudPlanOption>,
) {
    val accent = presentation.accent
    val enabled = commerce.enabled
    val onPurchase = commerce.onPurchase
    val prices = commerce.prices
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        TierPlanCardHeader(presentation = presentation)
        Text(
            presentation.summary,
            fontSize = 13.sp,
            lineHeight = 18.sp,
            color = CloudStorePal.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            presentation.featureChips.forEach { chip ->
                PlanFeatureChip(chip, accent)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            options.forEach { option ->
                PlanPurchaseButton(
                    option = option,
                    price = prices[option.product.id]?.formattedPrice ?: option.product.fallbackPrice,
                    accent = accent,
                    enabled = enabled,
                    modifier = Modifier.weight(1f),
                    onClick = { onPurchase(option.product.id) },
                )
            }
        }
    }
}

@Composable
internal fun TierPlanCardHeader(presentation: TierPlanPresentation) {
    val accent = presentation.accent
    Row(verticalAlignment = Alignment.CenterVertically) {
        PlanIconChip(presentation.icon, accent)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                presentation.label.uppercase(),
                fontSize = 10.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 1.6.sp,
                color = accent,
            )
            Text(
                presentation.title,
                fontSize = 21.sp,
                fontWeight = FontWeight.Bold,
                color = CloudStorePal.textPrimary,
            )
        }
        if (presentation.featured) {
            PlanMetaChip("BEST", accent)
        }
    }
}

@Composable
internal fun PlanIconChip(icon: ImageVector, accent: Color) {
    Box(
        modifier =
        Modifier
            .size(46.dp)
            .clip(RoundedCornerShape(15.dp))
            .background(
                brush = Brush.linearGradient(listOf(accent.copy(alpha = 0.95f), accent.copy(alpha = 0.55f))),
            )
            .border(0.7.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(15.dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(21.dp))
    }
}

@Composable
internal fun PlanFeatureChip(text: String, color: Color) {
    Text(
        text,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        color = CloudStorePal.textSecondary,
        modifier =
        Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.08f))
            .border(0.5.dp, color.copy(alpha = 0.20f), CircleShape)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

@Composable
internal fun PlanPurchaseButton(option: CloudPlanOption, price: String, accent: Color, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier =
        modifier
            .height(112.dp)
            .clip(shape)
            .background(accent.copy(alpha = 0.10f), shape)
            .border(0.7.dp, accent.copy(alpha = 0.28f), shape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    option.periodLabel?.uppercase().orEmpty(),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 1.1.sp,
                    color = accent,
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Filled.ChevronRight,
                    contentDescription = null,
                    tint = accent.copy(alpha = 0.70f),
                    modifier = Modifier.size(16.dp),
                )
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(price, fontSize = 23.sp, fontWeight = FontWeight.Bold, color = CloudStorePal.textPrimary)
                option.cadenceLabel?.let {
                    Spacer(Modifier.width(2.dp))
                    Text(it, fontSize = 11.sp, color = CloudStorePal.textMuted, modifier = Modifier.padding(bottom = 3.dp))
                }
            }
            option.saveLabel?.let {
                Text(
                    it.uppercase(),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 0.9.sp,
                    color = CloudStorePal.success,
                )
            }
        }
    }
}

@Composable
internal fun PlanMetaChip(text: String, color: Color) {
    Text(
        text,
        fontSize = 9.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.8.sp,
        color = color,
        modifier =
        Modifier
            .clip(RoundedCornerShape(5.dp))
            .background(color.copy(alpha = 0.12f))
            .border(0.6.dp, color.copy(alpha = 0.32f), RoundedCornerShape(5.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

@Composable
internal fun TopUpPlanRail(
    products: List<HostedQuotaStoreProduct>,
    prices: Map<String, HostedQuotaProductDetails>,
    enabled: Boolean,
    onPurchase: (String) -> Unit,
) {
    if (products.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Text(
            "TOP-UPS · PREPAID",
            fontSize = 10.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 1.6.sp,
            color = CloudStorePal.textMuted,
        )
        products.forEach { product ->
            val agentControl = product.id == HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID
            TopUpPurchaseRow(
                title = if (agentControl) "100 Agent Control actions" else "50 GB Floo relay",
                detail = "One-time Cloud Pro top-up",
                icon = if (agentControl) Icons.Filled.Bolt else Icons.Filled.Wifi,
                price = prices[product.id]?.formattedPrice ?: product.fallbackPrice,
                enabled = enabled,
                onClick = { onPurchase(product.id) },
            )
        }
    }
}

@Composable
internal fun TopUpPurchaseRow(title: String, detail: String, icon: ImageVector, price: String, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(16.dp)
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(CloudStorePal.amberDark.copy(alpha = 0.08f), shape)
            .border(0.7.dp, CloudStorePal.amberDark.copy(alpha = 0.22f), shape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PlanIconChip(icon, CloudStorePal.amberDark)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = CloudStorePal.textPrimary)
            Text(detail, fontSize = 12.sp, color = CloudStorePal.textSecondary)
        }
        Text(price, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = CloudStorePal.amberDark)
    }
}

// ── Aurora buttons ──

@Composable
internal fun AuroraPrimaryButton(text: String, icon: ImageVector? = null, isLoading: Boolean = false, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        contentAlignment = Alignment.Center,
        modifier =
        modifier
            .height(46.dp)
            .shadow(
                elevation = 14.dp,
                shape = CircleShape,
                ambientColor = CloudStorePal.ember,
                spotColor = CloudStorePal.ember,
            )
            .clip(CircleShape)
            .background(
                brush = Brush.linearGradient(listOf(CloudStorePal.ember, CloudStorePal.amber)),
                shape = CircleShape,
            )
            .border(
                width = 1.dp,
                color = CloudStorePal.amber.copy(alpha = 0.55f),
                shape = CircleShape,
            )
            .clickable(enabled = !isLoading, onClick = onClick)
            .padding(horizontal = 18.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(8.dp))
            } else if (icon != null) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
            }
            Text(
                text,
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
            )
        }
    }
}

@Composable
internal fun AuroraSecondaryButton(text: String, icon: ImageVector? = null, onClick: () -> Unit, modifier: Modifier = Modifier) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(46.dp),
        shape = CircleShape,
        colors =
        ButtonDefaults.outlinedButtonColors(
            contentColor = CloudStorePal.textPrimary,
            containerColor = CloudStorePal.surface.copy(alpha = 0.55f),
        ),
        border =
        androidx.compose.foundation.BorderStroke(
            width = 0.6.dp,
            color = CloudStorePal.border,
        ),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 0.dp),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

// ── Capability lineup ──

@Composable
internal fun CloudCapabilityLineup(isActive: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "WHAT'S INCLUDED",
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.4.sp,
                color = CloudStorePal.ember,
            )
            Spacer(Modifier.weight(1f))
            if (isActive) {
                Icon(
                    Icons.Filled.VerifiedUser,
                    null,
                    tint = CloudStorePal.amber,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        CapabilityRow(
            icon = Icons.Filled.Cloud,
            tint = CloudStorePal.ember,
            title = "Hosted Codex quota",
            detail = "Refresh Codex quota from any signed-in device. We run the runner; you get the dial.",
            isActive = isActive,
        )
        CapabilityRow(
            icon = Icons.Filled.Sync,
            tint = CloudStorePal.amber,
            title = "Conversation backup & resume",
            detail = "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off.",
            isActive = isActive,
        )
        CapabilityRow(
            icon = Icons.Filled.Description,
            tint = CloudStorePal.blaze,
            title = "Full session-log sync",
            detail = "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device.",
            isActive = isActive,
        )
        CapabilityRow(
            icon = Icons.Filled.Wifi,
            tint = CloudStorePal.whimsy,
            title = "Hermes remote relay",
            detail = "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end.",
            isActive = isActive,
        )
    }
}

@Composable
internal fun CapabilityRow(icon: ImageVector, tint: Color, title: String, detail: String, isActive: Boolean) {
    AuroraGlassCard(cornerRadius = 16) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(14.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier =
                Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        brush = Brush.linearGradient(listOf(tint, tint.copy(alpha = 0.7f))),
                    ),
            ) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = CloudStorePal.textPrimary,
                    )
                    if (isActive) {
                        Spacer(Modifier.width(6.dp))
                        Icon(
                            Icons.Filled.VerifiedUser,
                            null,
                            tint = CloudStorePal.success,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
                Spacer(Modifier.height(2.dp))
                Text(
                    detail,
                    fontSize = 12.sp,
                    color = CloudStorePal.textSecondary,
                )
            }
        }
    }
}
