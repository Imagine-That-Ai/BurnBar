package com.openburnbar.data.stores

import android.app.Activity
import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.ProductDetailsResponseListener
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.openburnbar.data.firebase.FunctionsRepository
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

data class HostedQuotaProductDetails(val formattedPrice: String)

/**
 * Google Play Billing integration for BurnBar Pro.
 *
 * BurnBar Pro adds hosted quota, hosted MiniMax-backed LLM answers, and
 * encrypted searchable hosted session logs. Existing Hosted Quota users still
 * work; this Android store verifies the bundled Pro subscription through Cloud
 * Functions before enabling the entitlement locally.
 */
class HostedQuotaSubscriptionStore(
    private val functions: FunctionsRepository = FunctionsRepository()
) : ViewModel(), PurchasesUpdatedListener {
    companion object {
        const val PRODUCT_ID = "com.openburnbar.pro.monthly"
    }

    private val _isActive = MutableStateFlow(false)
    val isActive: StateFlow<Boolean> = _isActive.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _productDetails = MutableStateFlow<HostedQuotaProductDetails?>(null)
    val productDetails: StateFlow<HostedQuotaProductDetails?> = _productDetails.asStateFlow()

    private val _expirationDate = MutableStateFlow<Long?>(null)
    val expirationDate: StateFlow<Long?> = _expirationDate.asStateFlow()

    private val _purchaseDate = MutableStateFlow<Long?>(null)
    val purchaseDate: StateFlow<Long?> = _purchaseDate.asStateFlow()

    private var billingClient: BillingClient? = null
    private var rawProductDetails: ProductDetails? = null

    fun initialize(context: Context) {
        if (billingClient != null) return
        billingClient = BillingClient.newBuilder(context.applicationContext)
            .setListener(this)
            .enablePendingPurchases(
                PendingPurchasesParams.newBuilder()
                    .enableOneTimeProducts()
                    .build()
            )
            .build()
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                ensureReady()
                loadProductsInternal()
                restorePurchasesInternal()
            } catch (e: Exception) {
                _error.value = e.localizedMessage ?: "Could not load subscription status."
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun loadProducts() = load()

    fun purchase(activity: Activity) {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                ensureReady()
                val details = rawProductDetails ?: loadProductsInternal()
                val offerToken = details.subscriptionOfferDetails?.firstOrNull()?.offerToken
                    ?: throw IllegalStateException("No subscription offer is available.")
                val params = BillingFlowParams.newBuilder()
                    .setProductDetailsParamsList(
                        listOf(
                            BillingFlowParams.ProductDetailsParams.newBuilder()
                                .setProductDetails(details)
                                .setOfferToken(offerToken)
                                .build()
                        )
                    )
                    .build()
                val result = billingClient!!.launchBillingFlow(activity, params)
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    throw IllegalStateException(result.debugMessage.ifBlank { "Google Play Billing did not start." })
                }
            } catch (e: Exception) {
                _error.value = e.localizedMessage ?: "Could not start purchase."
                _isLoading.value = false
            }
        }
    }

    fun restorePurchases() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                ensureReady()
                restorePurchasesInternal()
            } catch (e: Exception) {
                _error.value = e.localizedMessage ?: "Could not restore purchases."
            } finally {
                _isLoading.value = false
            }
        }
    }

    override fun onPurchasesUpdated(billingResult: BillingResult, purchases: MutableList<Purchase>?) {
        if (billingResult.responseCode == BillingClient.BillingResponseCode.USER_CANCELED) {
            _isLoading.value = false
            return
        }
        if (billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
            _error.value = billingResult.debugMessage.ifBlank { "Google Play Billing failed." }
            _isLoading.value = false
            return
        }
        viewModelScope.launch {
            try {
                handlePurchases(purchases.orEmpty())
            } catch (e: Exception) {
                _error.value = e.localizedMessage ?: "Could not verify purchase."
            } finally {
                _isLoading.value = false
            }
        }
    }

    override fun onCleared() {
        billingClient?.endConnection()
        billingClient = null
        super.onCleared()
    }

    private suspend fun ensureReady() {
        val client = billingClient ?: throw IllegalStateException("Billing store was not initialized.")
        if (client.isReady) return
        suspendCancellableCoroutine<Unit> { continuation ->
            client.startConnection(object : BillingClientStateListener {
                override fun onBillingServiceDisconnected() = Unit
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                        continuation.resume(Unit)
                    } else {
                        continuation.resumeWithException(
                            IllegalStateException(result.debugMessage.ifBlank { "Google Play Billing unavailable." })
                        )
                    }
                }
            })
        }
    }

    private suspend fun loadProductsInternal(): ProductDetails {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                listOf(
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(PRODUCT_ID)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                )
            )
            .build()
        val details = suspendCancellableCoroutine<ProductDetails> { continuation ->
            billingClient!!.queryProductDetailsAsync(params, ProductDetailsResponseListener { result, products ->
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    continuation.resumeWithException(
                        IllegalStateException(result.debugMessage.ifBlank { "Could not load subscription product." })
                    )
                    return@ProductDetailsResponseListener
                }
                val product = products.getProductDetailsList().firstOrNull { it.productId == PRODUCT_ID }
                if (product == null) {
                    continuation.resumeWithException(IllegalStateException("BurnBar Pro is not configured in Google Play."))
                } else {
                    continuation.resume(product)
                }
            })
        }
        rawProductDetails = details
        _productDetails.value = HostedQuotaProductDetails(
            formattedPrice = details.subscriptionOfferDetails
                ?.firstOrNull()
                ?.pricingPhases
                ?.pricingPhaseList
                ?.firstOrNull()
                ?.formattedPrice
                ?: "$4.99"
        )
        return details
    }

    private suspend fun restorePurchasesInternal() {
        val purchases = querySubscriptionPurchases()
        handlePurchases(purchases)
        if (purchases.none { it.products.contains(PRODUCT_ID) }) {
            _isActive.value = false
            _expirationDate.value = null
            _purchaseDate.value = null
        }
    }

    private suspend fun handlePurchases(purchases: List<Purchase>) {
        val purchase = purchases.firstOrNull {
            it.products.contains(PRODUCT_ID) && it.purchaseState == Purchase.PurchaseState.PURCHASED
        } ?: return
        val response = functions.verifyGooglePlayBurnBarProSubscription(
            purchaseToken = purchase.purchaseToken,
            productID = PRODUCT_ID
        )
        if (!purchase.isAcknowledged) {
            acknowledge(purchase)
        }
        _isActive.value = response["active"] as? Boolean ?: true
        _purchaseDate.value = purchase.purchaseTime
        val expiresAt = response["expiresAt"] as? String
        _expirationDate.value = expiresAt?.let { java.time.Instant.parse(it).toEpochMilli() }
    }

    private suspend fun acknowledge(purchase: Purchase) {
        val params = AcknowledgePurchaseParams.newBuilder()
            .setPurchaseToken(purchase.purchaseToken)
            .build()
        suspendCancellableCoroutine<Unit> { continuation ->
            billingClient!!.acknowledgePurchase(params) { result ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    continuation.resume(Unit)
                } else {
                    continuation.resumeWithException(
                        IllegalStateException(result.debugMessage.ifBlank { "Could not acknowledge purchase." })
                    )
                }
            }
        }
    }

    private suspend fun querySubscriptionPurchases(): List<Purchase> {
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        return suspendCancellableCoroutine { continuation ->
            billingClient!!.queryPurchasesAsync(params) { result, purchases ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    continuation.resume(purchases)
                } else {
                    continuation.resumeWithException(
                        IllegalStateException(result.debugMessage.ifBlank { "Could not query purchases." })
                    )
                }
            }
        }
    }
}
