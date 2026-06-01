@file:Suppress("FunctionNaming")
// detekt: JUnit backtick BDD test names intentionally contain spaces.

package com.openburnbar.data.stores

import android.app.Activity
import com.android.billingclient.api.AcknowledgePurchaseResponseListener
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.ProductDetailsResponseListener
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesResponseListener
import com.android.billingclient.api.QueryProductDetailsResult
import com.android.billingclient.api.UnfetchedProduct
import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.MainDispatcherRule
import com.openburnbar.data.firebase.FunctionsRepository
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.slot
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

private const val VAL_123456789_L = 123456789L

@OptIn(ExperimentalCoroutinesApi::class)
class HostedQuotaSubscriptionStoreTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val mockFunctions = mockk<FunctionsRepository>(relaxed = true)
    private val mockBillingClient = mockk<BillingClient>(relaxed = true)
    private val mockActivity = mockk<Activity>(relaxed = true)

    @Before
    fun setUp() {
        mockkStatic(FirebaseAuth::class)
        val mockAuth = mockk<FirebaseAuth>(relaxed = true)
        every { FirebaseAuth.getInstance() } returns mockAuth
        every { mockAuth.currentUser } returns null

        mockkStatic(android.text.TextUtils::class)
        every { android.text.TextUtils.isEmpty(any()) } answers {
            val arg = firstArg<CharSequence?>()
            arg.isNullOrEmpty()
        }
    }

    @After
    fun tearDown() {
        unmockkStatic(FirebaseAuth::class)
        unmockkStatic(android.text.TextUtils::class)
    }

    @Test
    fun `store product IDs match GTM master plan`() {
        assertEquals("com.openburnbar.pro.monthly", HostedQuotaSubscriptionStore.PRODUCT_ID)
        assertEquals("com.openburnbar.pro.annual", HostedQuotaSubscriptionStore.CLOUD_ANNUAL_PRODUCT_ID)
        assertEquals("com.openburnbar.proMax.v2.monthly", HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        assertEquals("com.openburnbar.proMax.annual", HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID)
        assertEquals("com.openburnbar.agentControl.actions100", HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID)
        assertEquals("com.openburnbar.floo.relay50gb", HostedQuotaSubscriptionStore.FLOO_RELAY_TOP_UP_PRODUCT_ID)

        assertEquals(
            setOf(
                HostedQuotaSubscriptionStore.PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_ANNUAL_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID,
                HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID,
                HostedQuotaSubscriptionStore.FLOO_RELAY_TOP_UP_PRODUCT_ID,
            ),
            HostedQuotaSubscriptionStore.STORE_PRODUCTS.map { it.id }.toSet(),
        )
    }

    @Test
    fun `loadProducts successfully populates details`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockProductDetails = mockk<ProductDetails>(relaxed = true)
        every { mockProductDetails.productId } returns HostedQuotaSubscriptionStore.PRODUCT_ID
        every { mockProductDetails.subscriptionOfferDetails } returns null
        every { mockProductDetails.oneTimePurchaseOfferDetails } returns null

        val mockQueryResult = mockk<QueryProductDetailsResult>()
        every { mockQueryResult.getProductDetailsList() } returns listOf(mockProductDetails)
        every { mockQueryResult.getUnfetchedProductList() } returns emptyList()

        val listenerSlot = slot<ProductDetailsResponseListener>()
        every { mockBillingClient.queryProductDetailsAsync(any(), capture(listenerSlot)) } answers {
            listenerSlot.captured.onProductDetailsResponse(mockResult, mockQueryResult)
        }

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.load()
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        val details = store.productDetailsByID.value[HostedQuotaSubscriptionStore.PRODUCT_ID]
        assertNotNull(details)
    }

    @Test
    fun `purchase throws detailed exception when product is unfetched`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockUnfetchedProduct = mockk<UnfetchedProduct>()
        every { mockUnfetchedProduct.productId } returns HostedQuotaSubscriptionStore.PRODUCT_ID
        every { mockUnfetchedProduct.statusCode } returns UnfetchedProduct.StatusCode.PRODUCT_NOT_FOUND

        val mockQueryResult = mockk<QueryProductDetailsResult>()
        every { mockQueryResult.getProductDetailsList() } returns emptyList()
        every { mockQueryResult.getUnfetchedProductList() } returns listOf(mockUnfetchedProduct)

        val listenerSlot = slot<ProductDetailsResponseListener>()
        every { mockBillingClient.queryProductDetailsAsync(any(), capture(listenerSlot)) } answers {
            listenerSlot.captured.onProductDetailsResponse(mockResult, mockQueryResult)
        }

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.purchase(mockActivity, HostedQuotaSubscriptionStore.PRODUCT_ID)
        advanceUntilIdle()

        // Assert
        val error = store.error.value
        assertNotNull(error)
        assertTrue(error!!.contains("BurnBar product is not configured in Google Play"))
        assertTrue(error.contains("PRODUCT_NOT_FOUND"))
    }

    @Test
    fun `purchase starts flow successfully for active product`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockPricingPhase = mockk<ProductDetails.PricingPhase>()
        every { mockPricingPhase.formattedPrice } returns "$7.99"

        val mockPricingPhases = mockk<ProductDetails.PricingPhases>()
        every { mockPricingPhases.pricingPhaseList } returns listOf(mockPricingPhase)

        val mockOfferDetails = mockk<ProductDetails.SubscriptionOfferDetails>()
        every { mockOfferDetails.offerToken } returns "mock-offer-token"
        every { mockOfferDetails.pricingPhases } returns mockPricingPhases

        val mockProductDetails = mockk<ProductDetails>(relaxed = true)
        every { mockProductDetails.productId } returns HostedQuotaSubscriptionStore.PRODUCT_ID
        every { mockProductDetails.subscriptionOfferDetails } returns listOf(mockOfferDetails)
        every { mockProductDetails.oneTimePurchaseOfferDetails } returns null

        val mockQueryResult = mockk<QueryProductDetailsResult>()
        every { mockQueryResult.getProductDetailsList() } returns listOf(mockProductDetails)
        every { mockQueryResult.getUnfetchedProductList() } returns emptyList()

        val listenerSlot = slot<ProductDetailsResponseListener>()
        every { mockBillingClient.queryProductDetailsAsync(any(), capture(listenerSlot)) } answers {
            listenerSlot.captured.onProductDetailsResponse(mockResult, mockQueryResult)
        }

        every { mockBillingClient.launchBillingFlow(any(), any()) } returns
            mockk {
                every { responseCode } returns BillingClient.BillingResponseCode.OK
            }

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.purchase(mockActivity, HostedQuotaSubscriptionStore.PRODUCT_ID)
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        verify { mockBillingClient.launchBillingFlow(mockActivity, any()) }
    }

    @Test
    fun `restorePurchases successfully verifies purchases via cloud functions`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockPurchase = mockk<Purchase>()
        every { mockPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { mockPurchase.products } returns listOf(HostedQuotaSubscriptionStore.PRODUCT_ID)
        every { mockPurchase.purchaseToken } returns "mock-purchase-token"
        every { mockPurchase.purchaseTime } returns VAL_123456789_L
        every { mockPurchase.isAcknowledged } returns true

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, listOf(mockPurchase))
        }

        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "mock-purchase-token",
                productID = HostedQuotaSubscriptionStore.PRODUCT_ID,
            )
        } returns
            mapOf(
                "active" to true,
                "expiresAt" to "2026-06-30T12:00:00Z",
            )

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.restorePurchases()
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.PRODUCT_ID, store.activeProductID.value)
        assertEquals(VAL_123456789_L, store.purchaseDate.value)
        assertEquals(java.time.Instant.parse("2026-06-30T12:00:00Z").toEpochMilli(), store.expirationDate.value)
    }

    @Test
    fun `restorePurchases acknowledges unacknowledged Google Play purchase`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK
        every { mockResult.debugMessage } returns ""

        val mockPurchase = mockk<Purchase>()
        every { mockPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { mockPurchase.products } returns listOf(HostedQuotaSubscriptionStore.PRODUCT_ID)
        every { mockPurchase.purchaseToken } returns "pending-ack-token"
        every { mockPurchase.purchaseTime } returns VAL_123456789_L
        every { mockPurchase.isAcknowledged } returns false

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, listOf(mockPurchase))
        }

        val acknowledgeListenerSlot = slot<AcknowledgePurchaseResponseListener>()
        every { mockBillingClient.acknowledgePurchase(any(), capture(acknowledgeListenerSlot)) } answers {
            acknowledgeListenerSlot.captured.onAcknowledgePurchaseResponse(mockResult)
        }

        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "pending-ack-token",
                productID = HostedQuotaSubscriptionStore.PRODUCT_ID,
            )
        } returns
            mapOf(
                "active" to true,
                "expiresAt" to "2026-06-30T12:00:00Z",
            )

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.restorePurchases()
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        assertTrue(store.isActive.value)
        verify { mockBillingClient.acknowledgePurchase(any(), any()) }
    }
}
