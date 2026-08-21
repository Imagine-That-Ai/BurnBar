
package com.openburnbar.data.stores

import android.app.Activity
import android.content.Context
import android.util.Log
import com.android.billingclient.api.AcknowledgePurchaseResponseListener
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.ProductDetailsResponseListener
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesResponseListener
import com.android.billingclient.api.QueryProductDetailsResult
import com.android.billingclient.api.UnfetchedProduct
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.EventListener
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.QuerySnapshot
import com.openburnbar.MainDispatcherRule
import com.openburnbar.data.firebase.FunctionsRepository
import com.openburnbar.data.policy.MobileStoreEntitlementPolicy
import io.mockk.coEvery
import io.mockk.coVerify
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class HostedQuotaSubscriptionStoreTest {
    companion object {
        private const val ACTIVE_SUBSCRIPTION_EXPIRES_AT = "2099-06-30T12:00:00Z"
        private val ACTIVE_SUBSCRIPTION_EXPIRES_AT_MS =
            java.time.Instant.parse(ACTIVE_SUBSCRIPTION_EXPIRES_AT).toEpochMilli()
    }

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

        mockkStatic(Log::class)
        every { Log.i(any(), any()) } returns 0
        every { Log.w(any(), any<String>()) } returns 0
    }

    @After
    fun tearDown() {
        unmockkStatic(FirebaseAuth::class)
        unmockkStatic(android.text.TextUtils::class)
        unmockkStatic(Log::class)
    }

    @Test
    fun `store product IDs match GTM master plan`() {
        assertEquals("com.openburnbar.pro.monthly", HostedQuotaSubscriptionStore.PRODUCT_ID)
        assertEquals("com.openburnbar.pro.annual", HostedQuotaSubscriptionStore.CLOUD_ANNUAL_PRODUCT_ID)
        assertEquals("com.openburnbar.promax.v2.monthly", HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        assertEquals("com.openburnbar.promax.annual", HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID)
        assertEquals("com.openburnbar.ultra.monthly", HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID)
        assertEquals("com.openburnbar.ultra.annual", HostedQuotaSubscriptionStore.CLOUD_ULTRA_ANNUAL_PRODUCT_ID)
        assertEquals("com.openburnbar.agentcontrol.actions100", HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID)
        assertEquals("com.openburnbar.floo.relay50gb", HostedQuotaSubscriptionStore.FLOO_RELAY_TOP_UP_PRODUCT_ID)
        assertEquals("com.openburnbar.elderwand.searches100", HostedQuotaSubscriptionStore.FUSION_SEARCH_100_TOP_UP_PRODUCT_ID)
        assertEquals("com.openburnbar.elderwand.searches500", HostedQuotaSubscriptionStore.FUSION_SEARCH_500_TOP_UP_PRODUCT_ID)
        HostedQuotaSubscriptionStore.STORE_PRODUCTS.forEach { product ->
            assertEquals(product.id.lowercase(), product.id)
        }

        assertEquals(
            setOf(
                HostedQuotaSubscriptionStore.PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_ANNUAL_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_ULTRA_ANNUAL_PRODUCT_ID,
                HostedQuotaSubscriptionStore.AGENT_CONTROL_TOP_UP_PRODUCT_ID,
                HostedQuotaSubscriptionStore.FLOO_RELAY_TOP_UP_PRODUCT_ID,
                HostedQuotaSubscriptionStore.FUSION_SEARCH_100_TOP_UP_PRODUCT_ID,
                HostedQuotaSubscriptionStore.FUSION_SEARCH_500_TOP_UP_PRODUCT_ID,
            ),
            HostedQuotaSubscriptionStore.STORE_PRODUCTS.map { it.id }.toSet(),
        )
    }

    @Test
    fun `currentTier resolves Cloud Pro from the Play Cloud Pro SKU`() = runTest {
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK
        every { mockResult.debugMessage } returns ""

        val proPurchase = mockk<Purchase>()
        every { proPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { proPurchase.products } returns listOf(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        every { proPurchase.purchaseToken } returns "pro-token"
        every { proPurchase.purchaseTime } returns 123456789L
        every { proPurchase.isAcknowledged } returns true

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, listOf(proPurchase))
        }

        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "pro-token",
                productID = HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
            )
        } returns mapOf("active" to true, "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT)

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        store.restorePurchases()
        advanceUntilIdle()

        assertTrue(store.isActive.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.PRO, store.currentTier.value)
        assertTrue(store.currentTier.value.satisfies(com.openburnbar.ui.pro.CloudTier.CLOUD))
        assertTrue(store.currentTier.value.satisfies(com.openburnbar.ui.pro.CloudTier.PRO))
        assertFalse(store.currentTier.value.satisfies(com.openburnbar.ui.pro.CloudTier.ULTRA))
    }

    @Test
    fun `tierForActiveProduct maps every Play SKU and Apple substring`() {
        // Inactive ⇒ NONE regardless of product.
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.NONE,
            HostedQuotaSubscriptionStore.tierForActiveProduct(false, HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID),
        )
        // Known Android Play SKUs map via role.
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.ULTRA,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID),
        )
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.PRO,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID),
        )
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.CLOUD,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, HostedQuotaSubscriptionStore.PRODUCT_ID),
        )
        // Cross-platform Apple product IDs classify by substring.
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.ULTRA,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, "com.openburnbar.ultra.monthly"),
        )
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.PRO,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, "com.openburnbar.promax.cloud.monthly"),
        )
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.PRO,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, "com.openburnbar.computer-use.monthly"),
        )
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.CLOUD,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, "com.openburnbar.hostedQuotaSync.cloud.monthly"),
        )
        // Active but unlabeled ⇒ at least Cloud (never falsely NONE).
        assertEquals(
            com.openburnbar.ui.pro.CloudTier.CLOUD,
            HostedQuotaSubscriptionStore.tierForActiveProduct(true, null),
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
    fun `load falls back when Google Play Billing is unavailable`() = runTest {
        every { mockBillingClient.isReady } returns false

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.BILLING_UNAVAILABLE
        every { mockResult.debugMessage } returns "Billing service unavailable on device."

        val listenerSlot = slot<BillingClientStateListener>()
        every { mockBillingClient.startConnection(capture(listenerSlot)) } answers {
            listenerSlot.captured.onBillingSetupFinished(mockResult)
        }

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        store.load()
        advanceUntilIdle()

        assertFalse(store.isLoading.value)
        assertFalse(store.isActive.value)
        assertTrue(store.error.value?.contains("Billing service unavailable") == true)
        assertEquals(
            MobileStoreEntitlementPolicy.UNAVAILABLE_PRICE_LABEL,
            store.productDetailsByID.value[HostedQuotaSubscriptionStore.PRODUCT_ID]?.formattedPrice,
        )
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
        val error = requireNotNull(store.error.value)
        assertTrue(error.contains("BurnBar product is not configured in Google Play"))
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
        every { mockOfferDetails.basePlanId } returns "monthly"
        every { mockOfferDetails.offerId } returns null
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

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, emptyList())
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
    fun `subscription offer selection matches the configured base plan and standard offer`() {
        val promotionalPhase = mockk<ProductDetails.PricingPhase>()
        every { promotionalPhase.formattedPrice } returns "$0.00"
        val promotionalPhases = mockk<ProductDetails.PricingPhases>()
        every { promotionalPhases.pricingPhaseList } returns listOf(promotionalPhase)
        val promotionalOffer = mockk<ProductDetails.SubscriptionOfferDetails>()
        every { promotionalOffer.basePlanId } returns "monthly"
        every { promotionalOffer.offerId } returns "intro"
        every { promotionalOffer.offerToken } returns "intro-token"
        every { promotionalOffer.pricingPhases } returns promotionalPhases

        val wrongBasePlanOffer = mockk<ProductDetails.SubscriptionOfferDetails>()
        every { wrongBasePlanOffer.basePlanId } returns "annual"
        every { wrongBasePlanOffer.offerId } returns null
        every { wrongBasePlanOffer.offerToken } returns "annual-token"

        val recurringPhase = mockk<ProductDetails.PricingPhase>()
        every { recurringPhase.formattedPrice } returns "$7.99"
        val recurringPhases = mockk<ProductDetails.PricingPhases>()
        every { recurringPhases.pricingPhaseList } returns listOf(recurringPhase)
        val configuredOffer = mockk<ProductDetails.SubscriptionOfferDetails>()
        every { configuredOffer.basePlanId } returns "monthly"
        every { configuredOffer.offerId } returns null
        every { configuredOffer.offerToken } returns "monthly-token"
        every { configuredOffer.pricingPhases } returns recurringPhases

        val productDetails = mockk<ProductDetails>()
        every { productDetails.subscriptionOfferDetails } returns
            listOf(promotionalOffer, wrongBasePlanOffer, configuredOffer)
        every { productDetails.oneTimePurchaseOfferDetails } returns null
        val storeProduct =
            HostedQuotaSubscriptionStore.STORE_PRODUCTS.first {
                it.id == HostedQuotaSubscriptionStore.PRODUCT_ID
            }

        assertEquals(
            configuredOffer,
            HostedQuotaBillingSupport.subscriptionOffer(productDetails, storeProduct),
        )
        assertEquals(
            "$7.99",
            HostedQuotaBillingSupport.formattedPrice(productDetails, storeProduct),
        )
    }

    @Test
    fun `subscription replacement modes charge prorated upgrades and defer downgrades`() {
        assertEquals(
            BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode
                .CHARGE_PRORATED_PRICE,
            HostedQuotaSubscriptionStore.subscriptionReplacementMode(
                HostedQuotaSubscriptionStore.PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
            ),
        )
        assertEquals(
            BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode
                .DEFERRED,
            HostedQuotaSubscriptionStore.subscriptionReplacementMode(
                HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
            ),
        )
        assertEquals(
            BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode
                .DEFERRED,
            HostedQuotaSubscriptionStore.subscriptionReplacementMode(
                HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
                HostedQuotaSubscriptionStore.CLOUD_PRO_ANNUAL_PRODUCT_ID,
            ),
        )
    }

    @Test
    fun `subscription replacement carries the highest active tier purchase token`() {
        val cloudPurchase = mockk<Purchase>()
        every { cloudPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { cloudPurchase.products } returns listOf(HostedQuotaSubscriptionStore.PRODUCT_ID)
        every { cloudPurchase.purchaseToken } returns "cloud-token"

        val proPurchase = mockk<Purchase>()
        every { proPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { proPurchase.products } returns listOf(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        every { proPurchase.purchaseToken } returns "cloud-pro-token"

        val replacement =
            HostedQuotaSubscriptionStore.selectSubscriptionReplacement(
                newProductID = HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                purchases = listOf(cloudPurchase, proPurchase),
            )

        assertEquals(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID, replacement?.oldProductID)
        assertEquals("cloud-pro-token", replacement?.oldPurchaseToken)
        assertEquals(
            BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.ReplacementMode
                .CHARGE_PRORATED_PRICE,
            replacement?.replacementMode,
        )
    }

    @Test
    fun `purchase includes existing subscription when upgrading to Ultra`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockPricingPhase = mockk<ProductDetails.PricingPhase>()
        every { mockPricingPhase.formattedPrice } returns "$59.99"

        val mockPricingPhases = mockk<ProductDetails.PricingPhases>()
        every { mockPricingPhases.pricingPhaseList } returns listOf(mockPricingPhase)

        val mockOfferDetails = mockk<ProductDetails.SubscriptionOfferDetails>()
        every { mockOfferDetails.basePlanId } returns "p1m"
        every { mockOfferDetails.offerId } returns null
        every { mockOfferDetails.offerToken } returns "ultra-offer-token"
        every { mockOfferDetails.pricingPhases } returns mockPricingPhases

        val mockProductDetails = mockk<ProductDetails>(relaxed = true)
        every { mockProductDetails.productId } returns HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID
        every { mockProductDetails.subscriptionOfferDetails } returns listOf(mockOfferDetails)
        every { mockProductDetails.oneTimePurchaseOfferDetails } returns null

        val mockQueryResult = mockk<QueryProductDetailsResult>()
        every { mockQueryResult.getProductDetailsList() } returns listOf(mockProductDetails)
        every { mockQueryResult.getUnfetchedProductList() } returns emptyList()

        val productDetailsListenerSlot = slot<ProductDetailsResponseListener>()
        every { mockBillingClient.queryProductDetailsAsync(any(), capture(productDetailsListenerSlot)) } answers {
            productDetailsListenerSlot.captured.onProductDetailsResponse(mockResult, mockQueryResult)
        }

        val cloudProPurchase = mockk<Purchase>()
        every { cloudProPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { cloudProPurchase.products } returns listOf(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        every { cloudProPurchase.purchaseToken } returns "cloud-pro-token"

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, listOf(cloudProPurchase))
        }

        every { mockBillingClient.launchBillingFlow(any(), any()) } returns
            mockk {
                every { responseCode } returns BillingClient.BillingResponseCode.OK
            }

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.purchase(mockActivity, HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID)
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        verify { mockBillingClient.queryPurchasesAsync(any(), any()) }
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
        every { mockPurchase.purchaseTime } returns 123456789L
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
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.restorePurchases()
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.PRODUCT_ID, store.activeProductID.value)
        assertEquals(123456789L, store.purchaseDate.value)
        assertEquals(ACTIVE_SUBSCRIPTION_EXPIRES_AT_MS, store.expirationDate.value)
    }

    @Test
    fun `restorePurchases treats expired Google Play verifier response as inactive`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockPurchase = mockk<Purchase>()
        every { mockPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { mockPurchase.products } returns listOf(HostedQuotaSubscriptionStore.PRODUCT_ID)
        every { mockPurchase.purchaseToken } returns "expired-purchase-token"
        every { mockPurchase.purchaseTime } returns 123456789L
        every { mockPurchase.isAcknowledged } returns true

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, listOf(mockPurchase))
        }

        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "expired-purchase-token",
                productID = HostedQuotaSubscriptionStore.PRODUCT_ID,
            )
        } returns
            mapOf(
                "active" to true,
                "expiresAt" to "2020-01-01T00:00:00Z",
            )

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.restorePurchases()
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        assertFalse(store.isActive.value)
        assertNull(store.activeProductID.value)
        assertEquals(123456789L, store.purchaseDate.value)
        assertEquals(java.time.Instant.parse("2020-01-01T00:00:00Z").toEpochMilli(), store.expirationDate.value)
    }

    @Test
    fun `restorePurchases clears stale Android entitlement when Play returns no subscription`() = runTest {
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK

        val mockPurchase = mockk<Purchase>()
        every { mockPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { mockPurchase.products } returns listOf(HostedQuotaSubscriptionStore.PRODUCT_ID)
        every { mockPurchase.purchaseToken } returns "active-then-gone-token"
        every { mockPurchase.purchaseTime } returns 123456789L
        every { mockPurchase.isAcknowledged } returns true

        val queryResponses =
            mutableListOf(
                listOf(mockPurchase),
                emptyList<Purchase>(),
                emptyList(),
                emptyList(),
            )
        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            val purchases = if (queryResponses.isEmpty()) emptyList() else queryResponses.removeAt(0)
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, purchases)
        }

        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "active-then-gone-token",
                productID = HostedQuotaSubscriptionStore.PRODUCT_ID,
            )
        } returns
            mapOf(
                "active" to true,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        store.restorePurchases()
        advanceUntilIdle()

        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.PRODUCT_ID, store.activeProductID.value)

        store.restorePurchases()
        advanceUntilIdle()

        assertFalse(store.isActive.value)
        assertNull(store.activeProductID.value)
        assertNull(store.purchaseDate.value)
        assertNull(store.expirationDate.value)
    }

    @Test
    fun `account switch drops the previous UID entitlement before the new UID snapshot arrives`() = runTest {
        every { mockBillingClient.isReady } returns true

        val context = mockk<Context>(relaxed = true)
        val firestore = mockk<FirebaseFirestore>()
        val usersCollection = mockk<CollectionReference>()
        val documentA = mockk<DocumentReference>()
        val documentB = mockk<DocumentReference>()
        val entitlementsA = mockk<CollectionReference>()
        val entitlementsB = mockk<CollectionReference>()
        val registrationA = mockk<ListenerRegistration>(relaxed = true)
        val registrationB = mockk<ListenerRegistration>(relaxed = true)
        val listenerSlotA = slot<EventListener<QuerySnapshot>>()
        every { firestore.collection("users") } returns usersCollection
        every { usersCollection.document("user-a") } returns documentA
        every { usersCollection.document("user-b") } returns documentB
        every { documentA.collection("entitlements") } returns entitlementsA
        every { documentB.collection("entitlements") } returns entitlementsB
        every { entitlementsA.addSnapshotListener(capture(listenerSlotA)) } returns registrationA
        every { entitlementsB.addSnapshotListener(any()) } returns registrationB

        val userA = mockk<FirebaseUser>()
        every { userA.uid } returns "user-a"
        val userB = mockk<FirebaseUser>()
        every { userB.uid } returns "user-b"

        val firebaseAuth = mockk<FirebaseAuth>(relaxed = true)
        every { firebaseAuth.currentUser } returns userA
        val authListenerSlot = slot<FirebaseAuth.AuthStateListener>()
        every { firebaseAuth.addAuthStateListener(capture(authListenerSlot)) } answers {
            authListenerSlot.captured.onAuthStateChanged(firebaseAuth)
        }

        val store =
            HostedQuotaSubscriptionStore(
                functions = mockFunctions,
                initialBillingClient = mockBillingClient,
                initialFirestore = firestore,
                initialFirebaseAuth = firebaseAuth,
            )
        store.initialize(context)

        val ultraDoc = mockk<DocumentSnapshot>()
        every { ultraDoc.id } returns "burnbar_ultra"
        every { ultraDoc.data } returns
            mapOf(
                "active" to true,
                "productID" to HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        val snapshotA = mockk<QuerySnapshot>()
        every { snapshotA.documents } returns listOf(ultraDoc)
        listenerSlotA.captured.onEvent(snapshotA, null)

        assertTrue(store.isActive.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.ULTRA, store.currentTier.value)

        // Direct signed-in A -> B switch. B's first entitlement read has not
        // landed yet (and may never, if the device is offline), so nothing of
        // A's paid state may survive the flip.
        every { firebaseAuth.currentUser } returns userB
        authListenerSlot.captured.onAuthStateChanged(firebaseAuth)

        verify { registrationA.remove() }
        verify { entitlementsB.addSnapshotListener(any()) }
        assertFalse(store.isActive.value)
        assertNull(store.activeProductID.value)
        assertNull(store.expirationDate.value)
        assertNull(store.purchaseDate.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.NONE, store.currentTier.value)

        val onCleared = androidx.lifecycle.ViewModel::class.java.getDeclaredMethod("onCleared")
        onCleared.isAccessible = true
        onCleared.invoke(store)
    }

    @Test
    fun `sign out drops the previous UID entitlement`() = runTest {
        every { mockBillingClient.isReady } returns true

        val context = mockk<Context>(relaxed = true)
        val firestore = mockk<FirebaseFirestore>()
        val usersCollection = mockk<CollectionReference>()
        val documentA = mockk<DocumentReference>()
        val entitlementsA = mockk<CollectionReference>()
        val registrationA = mockk<ListenerRegistration>(relaxed = true)
        val listenerSlotA = slot<EventListener<QuerySnapshot>>()
        every { firestore.collection("users") } returns usersCollection
        every { usersCollection.document("user-a") } returns documentA
        every { documentA.collection("entitlements") } returns entitlementsA
        every { entitlementsA.addSnapshotListener(capture(listenerSlotA)) } returns registrationA

        val userA = mockk<FirebaseUser>()
        every { userA.uid } returns "user-a"
        val firebaseAuth = mockk<FirebaseAuth>(relaxed = true)
        every { firebaseAuth.currentUser } returns userA
        val authListenerSlot = slot<FirebaseAuth.AuthStateListener>()
        every { firebaseAuth.addAuthStateListener(capture(authListenerSlot)) } answers {
            authListenerSlot.captured.onAuthStateChanged(firebaseAuth)
        }

        val store =
            HostedQuotaSubscriptionStore(
                functions = mockFunctions,
                initialBillingClient = mockBillingClient,
                initialFirestore = firestore,
                initialFirebaseAuth = firebaseAuth,
            )
        store.initialize(context)

        val proDoc = mockk<DocumentSnapshot>()
        every { proDoc.id } returns "burnbar_pro_max"
        every { proDoc.data } returns
            mapOf(
                "active" to true,
                "productID" to HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        val snapshotA = mockk<QuerySnapshot>()
        every { snapshotA.documents } returns listOf(proDoc)
        listenerSlotA.captured.onEvent(snapshotA, null)
        assertTrue(store.isActive.value)

        every { firebaseAuth.currentUser } returns null
        authListenerSlot.captured.onAuthStateChanged(firebaseAuth)

        assertFalse(store.isActive.value)
        assertNull(store.activeProductID.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.NONE, store.currentTier.value)

        val onCleared = androidx.lifecycle.ViewModel::class.java.getDeclaredMethod("onCleared")
        onCleared.isAccessible = true
        onCleared.invoke(store)
    }

    @Test
    fun `a repeat auth callback for the same UID keeps the published entitlement`() = runTest {
        every { mockBillingClient.isReady } returns true

        val context = mockk<Context>(relaxed = true)
        val firestore = mockk<FirebaseFirestore>()
        val usersCollection = mockk<CollectionReference>()
        val documentA = mockk<DocumentReference>()
        val entitlementsA = mockk<CollectionReference>()
        val listenerSlotA = slot<EventListener<QuerySnapshot>>()
        every { firestore.collection("users") } returns usersCollection
        every { usersCollection.document("user-a") } returns documentA
        every { documentA.collection("entitlements") } returns entitlementsA
        every { entitlementsA.addSnapshotListener(capture(listenerSlotA)) } returns mockk<ListenerRegistration>(relaxed = true)

        val userA = mockk<FirebaseUser>()
        every { userA.uid } returns "user-a"
        val firebaseAuth = mockk<FirebaseAuth>(relaxed = true)
        every { firebaseAuth.currentUser } returns userA
        val authListenerSlot = slot<FirebaseAuth.AuthStateListener>()
        every { firebaseAuth.addAuthStateListener(capture(authListenerSlot)) } answers {
            authListenerSlot.captured.onAuthStateChanged(firebaseAuth)
        }

        val store =
            HostedQuotaSubscriptionStore(
                functions = mockFunctions,
                initialBillingClient = mockBillingClient,
                initialFirestore = firestore,
                initialFirebaseAuth = firebaseAuth,
            )
        store.initialize(context)

        val ultraDoc = mockk<DocumentSnapshot>()
        every { ultraDoc.id } returns "burnbar_ultra"
        every { ultraDoc.data } returns
            mapOf(
                "active" to true,
                "productID" to HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        val snapshotA = mockk<QuerySnapshot>()
        every { snapshotA.documents } returns listOf(ultraDoc)
        listenerSlotA.captured.onEvent(snapshotA, null)
        assertTrue(store.isActive.value)

        // Token refresh style re-fire for the same account must not blank the UI.
        authListenerSlot.captured.onAuthStateChanged(firebaseAuth)

        assertTrue(store.isActive.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.ULTRA, store.currentTier.value)

        val onCleared = androidx.lifecycle.ViewModel::class.java.getDeclaredMethod("onCleared")
        onCleared.isAccessible = true
        onCleared.invoke(store)
    }

    @Test
    fun `cloud entitlement resolves all canonical documents by tier until server state is empty`() = runTest {
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK
        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, emptyList())
        }

        val context = mockk<Context>(relaxed = true)
        val firestore = mockk<FirebaseFirestore>()
        val usersCollection = mockk<CollectionReference>()
        val userDocument = mockk<DocumentReference>()
        val entitlementsCollection = mockk<CollectionReference>()
        val entitlementRegistration = mockk<ListenerRegistration>(relaxed = true)
        val entitlementListenerSlot = slot<EventListener<QuerySnapshot>>()
        every { firestore.collection("users") } returns usersCollection
        every { usersCollection.document("user-123") } returns userDocument
        every { userDocument.collection("entitlements") } returns entitlementsCollection
        every { entitlementsCollection.addSnapshotListener(capture(entitlementListenerSlot)) } returns entitlementRegistration

        val firebaseUser = mockk<FirebaseUser>()
        every { firebaseUser.uid } returns "user-123"
        val firebaseAuth = mockk<FirebaseAuth>(relaxed = true)
        every { firebaseAuth.currentUser } returns firebaseUser
        every { firebaseAuth.addAuthStateListener(any()) } answers {
            firstArg<FirebaseAuth.AuthStateListener>().onAuthStateChanged(firebaseAuth)
        }

        val store =
            HostedQuotaSubscriptionStore(
                functions = mockFunctions,
                initialBillingClient = mockBillingClient,
                initialFirestore = firestore,
                initialFirebaseAuth = firebaseAuth,
            )
        store.initialize(context)

        val legacyCloudDoc = mockk<DocumentSnapshot>()
        every { legacyCloudDoc.id } returns "hosted_quota_sync"
        every { legacyCloudDoc.data } returns
            mapOf(
                "active" to true,
                "productID" to "com.openburnbar.hostedQuotaSync.cloud.monthly",
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        val cloudProDoc = mockk<DocumentSnapshot>()
        every { cloudProDoc.id } returns "burnbar_pro_max"
        every { cloudProDoc.data } returns
            mapOf(
                "active" to true,
                "productID" to HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        val ultraDoc = mockk<DocumentSnapshot>()
        every { ultraDoc.id } returns "burnbar_ultra"
        every { ultraDoc.data } returns
            mapOf(
                "active" to true,
                "productID" to HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        val activeSnapshot = mockk<QuerySnapshot>()
        every { activeSnapshot.documents } returns listOf(legacyCloudDoc, cloudProDoc, ultraDoc)

        entitlementListenerSlot.captured.onEvent(activeSnapshot, null)
        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID, store.activeProductID.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.ULTRA, store.currentTier.value)

        store.restorePurchases()
        advanceUntilIdle()

        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.CLOUD_ULTRA_MONTHLY_PRODUCT_ID, store.activeProductID.value)

        val downgradedSnapshot = mockk<QuerySnapshot>()
        every { downgradedSnapshot.documents } returns listOf(legacyCloudDoc, cloudProDoc)
        entitlementListenerSlot.captured.onEvent(downgradedSnapshot, null)

        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID, store.activeProductID.value)
        assertEquals(com.openburnbar.ui.pro.CloudTier.PRO, store.currentTier.value)

        val emptySnapshot = mockk<QuerySnapshot>()
        every { emptySnapshot.documents } returns emptyList()

        entitlementListenerSlot.captured.onEvent(emptySnapshot, null)

        assertFalse(store.isActive.value)
        assertNull(store.activeProductID.value)
        assertNull(store.purchaseDate.value)
        assertNull(store.expirationDate.value)
    }

    @Test
    fun `restorePurchases verifies Cloud Pro when stale Cloud purchase is also returned`() = runTest {
        // Arrange
        every { mockBillingClient.isReady } returns true

        val mockResult = mockk<BillingResult>()
        every { mockResult.responseCode } returns BillingClient.BillingResponseCode.OK
        every { mockResult.debugMessage } returns ""

        val staleCloudPurchase = mockk<Purchase>()
        every { staleCloudPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { staleCloudPurchase.products } returns listOf(HostedQuotaSubscriptionStore.PRODUCT_ID)
        every { staleCloudPurchase.purchaseToken } returns "stale-cloud-token"
        every { staleCloudPurchase.purchaseTime } returns 123456789L
        every { staleCloudPurchase.isAcknowledged } returns true

        val cloudProPurchase = mockk<Purchase>()
        every { cloudProPurchase.purchaseState } returns Purchase.PurchaseState.PURCHASED
        every { cloudProPurchase.products } returns listOf(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID)
        every { cloudProPurchase.purchaseToken } returns "cloud-pro-token"
        every { cloudProPurchase.purchaseTime } returns 123456789L + 1
        every { cloudProPurchase.isAcknowledged } returns false

        val purchasesListenerSlot = slot<PurchasesResponseListener>()
        every { mockBillingClient.queryPurchasesAsync(any(), capture(purchasesListenerSlot)) } answers {
            purchasesListenerSlot.captured.onQueryPurchasesResponse(mockResult, listOf(staleCloudPurchase, cloudProPurchase))
        }

        val acknowledgeListenerSlot = slot<AcknowledgePurchaseResponseListener>()
        every { mockBillingClient.acknowledgePurchase(any(), capture(acknowledgeListenerSlot)) } answers {
            acknowledgeListenerSlot.captured.onAcknowledgePurchaseResponse(mockResult)
        }

        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "cloud-pro-token",
                productID = HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
            )
        } returns
            mapOf(
                "active" to true,
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
            )
        coEvery {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "stale-cloud-token",
                productID = HostedQuotaSubscriptionStore.PRODUCT_ID,
            )
        } returns
            mapOf(
                "active" to true,
                "expiresAt" to "2020-01-01T00:00:00Z",
            )

        val store = HostedQuotaSubscriptionStore(mockFunctions, mockBillingClient)

        // Act
        store.restorePurchases()
        advanceUntilIdle()

        // Assert
        assertNull(store.error.value)
        assertTrue(store.isActive.value)
        assertEquals(HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID, store.activeProductID.value)
        assertEquals(123456789L + 1, store.purchaseDate.value)
        assertEquals(ACTIVE_SUBSCRIPTION_EXPIRES_AT_MS, store.expirationDate.value)
        coVerify(exactly = 1) {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "cloud-pro-token",
                productID = HostedQuotaSubscriptionStore.CLOUD_PRO_MONTHLY_PRODUCT_ID,
            )
        }
        coVerify(exactly = 0) {
            mockFunctions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = "stale-cloud-token",
                productID = HostedQuotaSubscriptionStore.PRODUCT_ID,
            )
        }
        verify { mockBillingClient.acknowledgePurchase(any(), any()) }
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
        every { mockPurchase.purchaseTime } returns 123456789L
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
                "expiresAt" to ACTIVE_SUBSCRIPTION_EXPIRES_AT,
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

    // A signed-in cold start must not have its in-flight load cancelled.
    //
    // `entitlementUID` starts null and FirebaseAuth posts its first callback on a
    // later main-looper turn, so that callback lands while `load()` is still
    // suspended in `ensureReady()` waiting on Play. If null -> uid counts as an
    // account change, `clearEntitlementStateForUidChange` cancels `entitlementWork`
    // mid-flight: the catalog is never queried (prices render unavailable) and
    // `restorePurchasesInternal` never runs, so Play is never reconciled against
    // Firestore and purchases go unacknowledged — Google auto-refunds those after
    // three days.
    //
    // The suspension is the whole point of the setup: `isReady` is false and the
    // connection callback is held until after the auth callback fires. With
    // `isReady = true` the load completes before the callback arrives and this test
    // passes against the defect.
    @Test
    fun `first auth callback after a signed-in cold start does not cancel the in-flight load`() = runTest {
        every { mockBillingClient.isReady } returns false

        val context = mockk<Context>(relaxed = true)
        val firestore = mockk<FirebaseFirestore>()
        val usersCollection = mockk<CollectionReference>()
        val document = mockk<DocumentReference>()
        val entitlements = mockk<CollectionReference>()
        val registration = mockk<ListenerRegistration>(relaxed = true)
        every { firestore.collection("users") } returns usersCollection
        every { usersCollection.document("user-a") } returns document
        every { document.collection("entitlements") } returns entitlements
        every { entitlements.addSnapshotListener(any<EventListener<QuerySnapshot>>()) } returns registration

        val user = mockk<FirebaseUser>()
        every { user.uid } returns "user-a"
        val firebaseAuth = mockk<FirebaseAuth>(relaxed = true)
        every { firebaseAuth.currentUser } returns user

        // Captured but NOT fired at registration: FirebaseAuth's UiExecutor posts
        // unconditionally, so the first callback always lands on a later turn.
        val authListenerSlot = slot<FirebaseAuth.AuthStateListener>()
        every { firebaseAuth.addAuthStateListener(capture(authListenerSlot)) } answers { }

        // Hold the Play connection open so `load()` is genuinely suspended when the
        // auth callback arrives.
        val connectionSlot = slot<BillingClientStateListener>()
        every { mockBillingClient.startConnection(capture(connectionSlot)) } answers { }

        val okResult = mockk<BillingResult>()
        every { okResult.responseCode } returns BillingClient.BillingResponseCode.OK
        val mockProductDetails = mockk<ProductDetails>(relaxed = true)
        every { mockProductDetails.productId } returns HostedQuotaSubscriptionStore.PRODUCT_ID
        every { mockProductDetails.subscriptionOfferDetails } returns null
        every { mockProductDetails.oneTimePurchaseOfferDetails } returns null
        val mockQueryResult = mockk<QueryProductDetailsResult>()
        every { mockQueryResult.getProductDetailsList() } returns listOf(mockProductDetails)
        every { mockQueryResult.getUnfetchedProductList() } returns emptyList()
        val detailsSlot = slot<ProductDetailsResponseListener>()
        every { mockBillingClient.queryProductDetailsAsync(any(), capture(detailsSlot)) } answers {
            detailsSlot.captured.onProductDetailsResponse(okResult, mockQueryResult)
        }

        val store =
            HostedQuotaSubscriptionStore(
                functions = mockFunctions,
                initialBillingClient = mockBillingClient,
                initialFirestore = firestore,
                initialFirebaseAuth = firebaseAuth,
            )
        store.initialize(context)
        store.load()
        advanceUntilIdle()

        // Auth callback lands while the load is parked on the Play round-trip.
        authListenerSlot.captured.onAuthStateChanged(firebaseAuth)
        advanceUntilIdle()

        // Play connects only now.
        every { mockBillingClient.isReady } returns true
        connectionSlot.captured.onBillingSetupFinished(okResult)
        advanceUntilIdle()

        // The load survived: the catalog was queried and prices resolved.
        verify(atLeast = 1) { mockBillingClient.queryProductDetailsAsync(any(), any()) }
        assertNotNull(store.productDetailsByID.value[HostedQuotaSubscriptionStore.PRODUCT_ID])

        val onCleared = androidx.lifecycle.ViewModel::class.java.getDeclaredMethod("onCleared")
        onCleared.isAccessible = true
        onCleared.invoke(store)
    }
}
