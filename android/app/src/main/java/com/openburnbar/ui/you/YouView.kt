// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.CloudSyncHealthStore
import com.openburnbar.data.stores.DevicesStore
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.menubar.SuppressionStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.computeruse.ComputerUseAgentWatchScreen
import com.openburnbar.ui.settings.SettingsRootScreen
import com.openburnbar.ui.settings.rememberWebsiteBackground
import com.openburnbar.ui.smartdisplay.SmartDisplayView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

private enum class YouSubScreen { Root, SmartDisplays, MenuBarPrefs, ChatTiles, Settings, ComputerUse }

@Composable
fun YouView(
    userStore: UserStore = viewModel(),
    syncStore: CloudSyncHealthStore = viewModel(),
    devicesStore: DevicesStore = viewModel(),
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel(),
) {
    var subScreen by rememberSaveable { mutableStateOf(YouSubScreen.Root) }

    AnimatedContent(
        targetState = subScreen,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "you-subscreen",
    ) { screen ->
        when (screen) {
            YouSubScreen.Root ->
                YouRoot(
                    stores =
                    YouRootStores(
                        userStore = userStore,
                        syncStore = syncStore,
                        devicesStore = devicesStore,
                        subscriptionStore = subscriptionStore,
                    ),
                    navigation =
                    YouRootNavigation(
                        onOpenSmartDisplays = { subScreen = YouSubScreen.SmartDisplays },
                        onOpenMenuBarPrefs = { subScreen = YouSubScreen.MenuBarPrefs },
                        onOpenChatTiles = { subScreen = YouSubScreen.ChatTiles },
                        onOpenSettings = { subScreen = YouSubScreen.Settings },
                        onOpenControlCenter = youRootOpenControlCenterHandler(LocalContext.current),
                    ),
                )
            YouSubScreen.SmartDisplays -> SmartDisplayView(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.MenuBarPrefs -> MenuBarPrefsView(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.ChatTiles -> com.openburnbar.ui.hermes.ChatTilesSettingsScreen(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.Settings ->
                SettingsRootScreen(
                    onBack = { subScreen = YouSubScreen.Root },
                    onComputerUse = { subScreen = YouSubScreen.ComputerUse },
                    onMenuBarPrefs = { onBack -> MenuBarPrefsView(onBack = onBack) },
                )
            YouSubScreen.ComputerUse -> ComputerUseAgentWatchScreen()
        }
    }
}

private fun youRootOpenControlCenterHandler(context: android.content.Context): () -> Unit = {
    runCatching {
        val intent =
            android.content.Intent(android.content.Intent.ACTION_VIEW, "burnbar://data".toUri())
                .setPackage(context.packageName)
        context.startActivity(intent)
    }
}

@Composable
private fun MenuBarPrefsView(onBack: () -> Unit) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    val useWebsiteBackground by rememberWebsiteBackground()
    var suppressed by remember {
        mutableStateOf(SuppressionStore.suppressed(context))
    }

    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                if (useWebsiteBackground) {
                    androidx.compose.ui.graphics.Color.Transparent
                } else if (isDark) {
                    AuroraColors.darkBackground
                } else {
                    AuroraColors.lightBackground
                },
            )
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.LG.dp),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(AuroraSpacing.LG.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("Back") }
        }

        MenuBarPrefsCard(
            suppressed = suppressed,
            onSuppressedChange = { showOn ->
                suppressed = !showOn
                SuppressionStore.setSuppressed(context, suppressed)
            },
        )
    }
}

@Composable
private fun MenuBarPrefsCard(suppressed: Boolean, onSuppressedChange: (Boolean) -> Unit) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            "Quick-glance bar",
            style = AuroraType.title,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(AuroraSpacing.SM.dp))
        Text(
            text =
            "BurnBar runs a persistent notification with today's cost — the Android equivalent of the iOS " +
                "menu-bar label. Tap the notification to open the dashboard; pull down the Quick Settings tile " +
                "for an at-a-glance popover.",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(AuroraSpacing.MD.dp))

        AuroraSettingsToggle(
            icon = Icons.Filled.Notifications,
            label = "Show quick-glance notification",
            subtitle =
            if (suppressed) {
                "Hidden — re-enable to see today's cost in the shade"
            } else {
                "Live cost glance in the notification shade"
            },
            checked = !suppressed,
            onCheckedChange = onSuppressedChange,
        )
    }
}
