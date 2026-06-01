@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.store

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.RemoteMcpClientStore
import com.openburnbar.ui.components.AuroraBackdrop

// ── Cloud Store View (Android) ──
//
// Parity with the iOS `CloudStoreView`. Aurora language throughout — warm
// `AuroraBackdrop` over a `LazyColumn`, glass cards with ember-tinted
// hairlines, primary-gradient capsule CTAs, SF-Rounded-equivalent type.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudStoreView(
    onClose: () -> Unit = {},
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel(),
    remoteMcpClientStore: RemoteMcpClientStore = viewModel(),
) {
    val context = LocalContext.current
    val isActive by subscriptionStore.isActive.collectAsState()
    val isLoading by subscriptionStore.isLoading.collectAsState()
    val error by subscriptionStore.error.collectAsState()
    val productDetails by subscriptionStore.productDetails.collectAsState()
    val productDetailsByID by subscriptionStore.productDetailsByID.collectAsState()
    val expirationDate by subscriptionStore.expirationDate.collectAsState()
    val purchaseDate by subscriptionStore.purchaseDate.collectAsState()
    val remoteMcpClients by remoteMcpClientStore.clients.collectAsState()
    val remoteMcpLoading by remoteMcpClientStore.isLoading.collectAsState()
    val remoteMcpError by remoteMcpClientStore.error.collectAsState()
    val revokingRemoteMcpClientId by remoteMcpClientStore.revokingClientId.collectAsState()

    LaunchedEffect(context) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
    }

    DisposableEffect(isActive) {
        if (isActive) remoteMcpClientStore.startListening() else remoteMcpClientStore.stopListening()
        onDispose { remoteMcpClientStore.stopListening() }
    }

    val priceText = productDetails?.formattedPrice ?: "$7.99"
    val activity = context as? android.app.Activity

    Box(modifier = Modifier.fillMaxSize()) {
        AuroraBackdrop()
        CloudStoreScaffold(
            state =
            CloudStoreScreenState(
                isActive = isActive,
                isLoading = isLoading,
                error = error,
                priceText = priceText,
                expirationDateMs = expirationDate,
                purchaseDateMs = purchaseDate,
                productDetailsByID = productDetailsByID,
                remoteMcpClients = remoteMcpClients,
                remoteMcpLoading = remoteMcpLoading,
                remoteMcpError = remoteMcpError,
                revokingRemoteMcpClientId = revokingRemoteMcpClientId,
            ),
            actions =
            CloudStoreScreenActions(
                onClose = onClose,
                onPurchase = { productID -> activity?.let { subscriptionStore.purchase(it, productID) } },
                onRestore = { subscriptionStore.restorePurchases() },
                onDefaultPurchase = { activity?.let(subscriptionStore::purchase) },
                onRevoke = remoteMcpClientStore::revoke,
            ),
        )
    }
}
