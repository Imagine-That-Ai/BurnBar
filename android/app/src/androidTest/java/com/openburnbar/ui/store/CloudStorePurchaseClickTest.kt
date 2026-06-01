package com.openburnbar.ui.store

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CloudStorePurchaseClickTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun lowerCloudStorePurchaseRowsDispatchProductIds() {
        val purchasedProductIDs = mutableListOf<String>()

        composeRule.setContent {
            MaterialTheme {
                CloudStoreLazyContent(
                    innerPadding = PaddingValues(),
                    state =
                    CloudStoreScreenState(
                        isActive = true,
                        isLoading = false,
                        error = null,
                        priceText = "$7.99",
                        expirationDateMs = null,
                        purchaseDateMs = null,
                        productDetailsByID = emptyMap(),
                        remoteMcpClients = emptyList(),
                        remoteMcpLoading = false,
                        remoteMcpError = null,
                        revokingRemoteMcpClientId = null,
                    ),
                    onPurchase = { purchasedProductIDs += it },
                    onRevoke = {},
                )
            }
        }

        clickPurchase(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        clickPurchase(HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID)
        clickPurchase(HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID)
        clickPurchase(HostedQuotaSubscriptionStore.FLOO_RELAY_TOP_UP_PRODUCT_ID)

        composeRule.runOnIdle {
            assertEquals(
                listOf(
                    HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
                    HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID,
                    HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID,
                    HostedQuotaSubscriptionStore.FLOO_RELAY_TOP_UP_PRODUCT_ID,
                ),
                purchasedProductIDs,
            )
        }
    }

    private fun clickPurchase(productID: String) {
        val tag = cloudStorePurchaseTag(productID)
        composeRule
            .onNodeWithTag(CLOUD_STORE_LIST_TAG)
            .performScrollToNode(hasTestTag(tag))
        composeRule
            .onNodeWithTag(tag, useUnmergedTree = true)
            .performScrollTo()
            .performClick()
    }
}
