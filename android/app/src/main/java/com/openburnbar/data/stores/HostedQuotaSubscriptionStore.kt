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
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
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

    // ── Cloud entitlement listener (cross-platform fallback) ──
    //
    // Cloud Members who buy on iOS (Apple subscription
    // `com.openburnbar.hostedQuotaSync.cloud.monthly`) have no Google Play
    // purchase locally. The Cloud Functions verify the Apple JWS and write
    // the canonical entitlement doc to Firestore at
    // `users/{uid}/entitlements/hosted_quota_sync`. We listen to that doc
    // here so the membership UI flips on for users who paid on another
    // platform. Firestore is the server's authoritative view; Play Billing
    // remains the local fast-path for users who purchased on Android.

    private val firestore: FirebaseFirestore by lazy { FirebaseFirestore.getInstance() }
    private val firebaseAuth: FirebaseAuth by lazy { FirebaseAuth.getInstance() }
    private var entitlementListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null

    fun initialize(context: Context) {
        if (billingClient == null) {
            billingClient = BillingClient.newBuilder(context.applicationContext)
                .setListener(this)
                .enablePendingPurchases(
                    PendingPurchasesParams.newBuilder()
                        .enableOneTimeProducts()
                        .build()
                )
                .build()
        }
        startListeningToCloudEntitlement()
    }

    /// Subscribe to the Firestore entitlement doc. Reattaches the listener
    /// every time the auth user changes. No-op if already running.
    private fun startListeningToCloudEntitlement() {
        if (authListener != null) return
        val listener = FirebaseAuth.AuthStateListener { auth ->
            entitlementListener?.remove()
            entitlementListener = null

            val uid = auth.currentUser?.uid
            if (uid == null) {
                _isActive.value = false
                _expirationDate.value = null
                _purchaseDate.value = null
                return@AuthStateListener
            }

            entitlementListener = firestore.collection("users")
                .document(uid)
                .collection("entitlements")
                .document("hosted_quota_sync")
                .addSnapshotListener { snap, _ ->
                    if (snap == null || !snap.exists()) {
                        // No entitlement on file. If Play Billing already
                        // unlocked locally, leave that state alone; otherwise
                        // the user is just a free user.
                        return@addSnapshotListener
                    }
                    applyEntitlementDoc(snap.data ?: emptyMap())
                }
        }
        firebaseAuth.addAuthStateListener(listener)
        authListener = listener
    }

    /// Apply a Firestore entitlement payload to local state. Server is the
    /// authoritative source — if it says `active = false`, we flip to false
    /// even if Play Billing previously showed a Pro purchase (revocation /
    /// refund / chargeback flows).
    private fun applyEntitlementDoc(data: Map<String, Any?>) {
        val active = (data["active"] as? Boolean) ?: false
        val expiresAtMs = parseTimestampMs(data["expiresAt"])
            ?: parseTimestampMs(data["expirationDate"])
        val purchaseMs = parseTimestampMs(data["originalPurchaseDate"])
            ?: parseTimestampMs(data["purchaseDate"])

        val notExpired = expiresAtMs == null || expiresAtMs > System.currentTimeMillis()
        _isActive.value = active && notExpired
        if (expiresAtMs != null) _expirationDate.value = expiresAtMs
        if (purchaseMs != null) _purchaseDate.value = purchaseMs
    }

    private fun parseTimestampMs(value: Any?): Long? = when (value) {
        is Timestamp -> value.toDate().time
        is Long      -> value
        is Number    -> value.toLong()
        is String    -> runCatching { java.time.Instant.parse(value).toEpochMilli() }.getOrNull()
        else         -> null
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
        entitlementListener?.remove()
        entitlementListener = null
        authListener?.let { firebaseAuth.removeAuthStateListener(it) }
        authListener = null
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
        // No local Play purchase doesn't necessarily mean inactive — the
        // user may be a Cloud Member via the iOS subscription. The Firestore
        // entitlement listener is the canonical source; only clear local
        // state when both Play Billing AND the entitlement doc agree the
        // user isn't active. We leave `_isActive` alone here so the
        // Firestore listener stays in charge.
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
