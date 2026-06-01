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
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.google.firebase.FirebaseException
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.functions.FirebaseFunctionsException
import com.openburnbar.data.firebase.FunctionsRepository
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

data class HostedQuotaProductDetails(val formattedPrice: String)

enum class HostedQuotaStoreProductRole {
    CLOUD_SUBSCRIPTION,
    CLOUD_PRO_SUBSCRIPTION,
    CLOUD_PRO_TOP_UP,
}

data class HostedQuotaStoreProduct(
    val id: String,
    val productType: String,
    val role: HostedQuotaStoreProductRole,
    val fallbackPrice: String,
)

/**
 * Google Play Billing integration for BurnBar Pro.
 *
 * BurnBar Pro adds hosted quota, hosted MiniMax-backed LLM answers, and
 * encrypted searchable hosted session logs. Existing Hosted Quota users still
 * work; this Android store verifies the bundled Pro subscription through Cloud
 * Functions before enabling the entitlement locally.
 */
class HostedQuotaSubscriptionStore(
    private val functions: FunctionsRepository = FunctionsRepository(),
    initialBillingClient: BillingClient? = null,
) : ViewModel(), PurchasesUpdatedListener {
    companion object {
        const val PRODUCT_ID = "com.openburnbar.pro.monthly"
        const val CLOUD_ANNUAL_PRODUCT_ID = "com.openburnbar.pro.annual"
        const val CLOUD_PRO_MONTHLY_PRODUCT_ID = "com.openburnbar.promax.v2.monthly"
        const val CLOUD_PRO_ANNUAL_PRODUCT_ID = "com.openburnbar.promax.annual"
        const val AGENT_CONTROL_TOP_UP_PRODUCT_ID = "com.openburnbar.agentcontrol.actions100"
        const val FLOO_RELAY_TOP_UP_PRODUCT_ID = "com.openburnbar.floo.relay50gb"

        val STORE_PRODUCTS =
            listOf(
                HostedQuotaStoreProduct(PRODUCT_ID, BillingClient.ProductType.SUBS, HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION, "$7.99"),
                HostedQuotaStoreProduct(CLOUD_ANNUAL_PRODUCT_ID, BillingClient.ProductType.SUBS, HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION, "$79"),
                HostedQuotaStoreProduct(
                    CLOUD_PRO_MONTHLY_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION,
                    "$24.99",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_PRO_ANNUAL_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION,
                    "$249",
                ),
                HostedQuotaStoreProduct(
                    AGENT_CONTROL_TOP_UP_PRODUCT_ID,
                    BillingClient.ProductType.INAPP,
                    HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP,
                    "$4.99",
                ),
                HostedQuotaStoreProduct(FLOO_RELAY_TOP_UP_PRODUCT_ID, BillingClient.ProductType.INAPP, HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP, "$4.99"),
            )
        private val STORE_PRODUCT_BY_ID = STORE_PRODUCTS.associateBy { it.id }
        private val SUBSCRIPTION_PRODUCT_IDS =
            STORE_PRODUCTS
                .filter { it.productType == BillingClient.ProductType.SUBS }
                .map { it.id }
                .toSet()
        private val TOP_UP_PRODUCT_IDS =
            STORE_PRODUCTS
                .filter { it.productType == BillingClient.ProductType.INAPP }
                .map { it.id }
                .toSet()
    }

    private val _isActive = MutableStateFlow(false)
    val isActive: StateFlow<Boolean> = _isActive.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _productDetails = MutableStateFlow<HostedQuotaProductDetails?>(null)
    val productDetails: StateFlow<HostedQuotaProductDetails?> = _productDetails.asStateFlow()

    private val _productDetailsByID = MutableStateFlow<Map<String, HostedQuotaProductDetails>>(emptyMap())
    val productDetailsByID: StateFlow<Map<String, HostedQuotaProductDetails>> = _productDetailsByID.asStateFlow()

    private val _activeProductID = MutableStateFlow<String?>(null)
    val activeProductID: StateFlow<String?> = _activeProductID.asStateFlow()

    private val _lastTopUpCredit = MutableStateFlow<Map<String, Any>?>(null)
    val lastTopUpCredit: StateFlow<Map<String, Any>?> = _lastTopUpCredit.asStateFlow()

    private val _expirationDate = MutableStateFlow<Long?>(null)
    val expirationDate: StateFlow<Long?> = _expirationDate.asStateFlow()

    private val _purchaseDate = MutableStateFlow<Long?>(null)
    val purchaseDate: StateFlow<Long?> = _purchaseDate.asStateFlow()

    private var billingClient: BillingClient? = initialBillingClient
    private var rawProductDetailsByID: Map<String, ProductDetails> = emptyMap()

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
            billingClient =
                BillingClient.newBuilder(context.applicationContext)
                    .setListener(this)
                    .enablePendingPurchases(
                        PendingPurchasesParams.newBuilder()
                            .enableOneTimeProducts()
                            .build(),
                    )
                    .build()
        }
        startListeningToCloudEntitlement()
    }

    // / Subscribe to the Firestore entitlement doc. Reattaches the listener
    // / every time the auth user changes. No-op if already running.
    private fun startListeningToCloudEntitlement() {
        if (authListener != null) return
        val listener =
            FirebaseAuth.AuthStateListener { auth ->
                entitlementListener?.remove()
                entitlementListener = null

                val uid = auth.currentUser?.uid
                if (uid == null) {
                    _isActive.value = false
                    _expirationDate.value = null
                    _purchaseDate.value = null
                    return@AuthStateListener
                }

                entitlementListener =
                    firestore.collection("users")
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

    // / Apply a Firestore entitlement payload to local state. Server is the
    // / authoritative source — if it says `active = false`, we flip to false
    // / even if Play Billing previously showed a Pro purchase (revocation /
    // / refund / chargeback flows).
    private fun applyEntitlementDoc(data: Map<String, Any?>) {
        val active = data["active"] as? Boolean ?: false
        val expiresAtMs =
            parseTimestampMs(data["expiresAt"])
                ?: parseTimestampMs(data["expirationDate"])
        val purchaseMs =
            parseTimestampMs(data["originalPurchaseDate"])
                ?: parseTimestampMs(data["purchaseDate"])

        val notExpired = expiresAtMs == null || expiresAtMs > System.currentTimeMillis()
        _isActive.value = active && notExpired
        if (_isActive.value) {
            _activeProductID.value = data["productID"] as? String ?: data["productId"] as? String ?: _activeProductID.value
        } else {
            _activeProductID.value = null
        }
        if (expiresAtMs != null) _expirationDate.value = expiresAtMs
        if (purchaseMs != null) _purchaseDate.value = purchaseMs
    }

    private fun parseTimestampMs(value: Any?): Long? = when (value) {
        is Timestamp -> value.toDate().time
        is Long -> value
        is Number -> value.toLong()
        is String -> runCatching { java.time.Instant.parse(value).toEpochMilli() }.getOrNull()
        else -> null
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                ensureReady()
                loadProductsInternal()
                restorePurchasesInternal()
            } catch (e: FirebaseException) {
                _error.value = e.localizedMessage ?: "Could not load subscription status."
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun loadProducts() = load()

    fun purchase(activity: Activity) {
        purchase(activity, PRODUCT_ID)
    }

    fun purchase(activity: Activity, productID: String) {
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                ensureReady()
                val storeProduct =
                    STORE_PRODUCT_BY_ID[productID]
                        ?: error("Unsupported BurnBar product.")
                val details =
                    rawProductDetailsByID[productID] ?: loadProductsInternal()[productID]
                        ?: error("BurnBar product is not configured in Google Play.")
                val productDetailsBuilder =
                    BillingFlowParams.ProductDetailsParams.newBuilder()
                        .setProductDetails(details)
                if (storeProduct.productType == BillingClient.ProductType.SUBS) {
                    val offerToken =
                        details.subscriptionOfferDetails?.firstOrNull()?.offerToken
                            ?: error("No subscription offer is available.")
                    productDetailsBuilder.setOfferToken(offerToken)
                }
                val flowBuilder =
                    BillingFlowParams.newBuilder()
                        .setProductDetailsParamsList(
                            listOf(
                                productDetailsBuilder.build(),
                            ),
                        )
                firebaseAuth.currentUser?.uid?.let { uid ->
                    flowBuilder.setObfuscatedAccountId(HostedQuotaBillingSupport.sha256Hex(uid))
                }
                val params = flowBuilder.build()
                val result = requireBillingClient().launchBillingFlow(activity, params)
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    error(result.debugMessage.ifBlank { "Google Play Billing did not start." })
                }
            } catch (e: FirebaseFunctionsException) {
                _error.value = e.localizedMessage ?: "Could not start purchase."
                _isLoading.value = false
            } catch (e: IllegalStateException) {
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
            } catch (e: FirebaseFunctionsException) {
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
            } catch (e: FirebaseFunctionsException) {
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
        val client = billingClient ?: error("Billing store was not initialized.")
        if (client.isReady) return
        suspendCancellableCoroutine<Unit> { continuation ->
            client.startConnection(
                object : BillingClientStateListener {
                    override fun onBillingServiceDisconnected() = Unit

                    override fun onBillingSetupFinished(result: BillingResult) {
                        if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                            continuation.resume(Unit)
                        } else {
                            continuation.resumeWithException(
                                IllegalStateException(result.debugMessage.ifBlank { "Google Play Billing unavailable." }),
                            )
                        }
                    }
                },
            )
        }
    }

    private suspend fun loadProductsInternal(): Map<String, ProductDetails> {
        val client = requireBillingClient()
        val subscriptions =
            HostedQuotaBillingSupport.queryProductDetails(
                client,
                BillingClient.ProductType.SUBS,
                STORE_PRODUCTS.filter { it.productType == BillingClient.ProductType.SUBS }.map { it.id },
            )
        val topUps =
            HostedQuotaBillingSupport.queryProductDetails(
                client,
                BillingClient.ProductType.INAPP,
                STORE_PRODUCTS.filter { it.productType == BillingClient.ProductType.INAPP }.map { it.id },
            )
        val detailsByID = subscriptions + topUps
        rawProductDetailsByID = detailsByID
        _productDetailsByID.value =
            STORE_PRODUCTS.associate { storeProduct ->
                val formattedPrice = detailsByID[storeProduct.id]?.let { HostedQuotaBillingSupport.formattedPrice(it) } ?: storeProduct.fallbackPrice
                storeProduct.id to HostedQuotaProductDetails(formattedPrice = formattedPrice)
            }
        _productDetails.value = _productDetailsByID.value[PRODUCT_ID]
        return detailsByID
    }

    private suspend fun restorePurchasesInternal() {
        val client = requireBillingClient()
        handlePurchases(
            HostedQuotaBillingSupport.queryPurchases(client, BillingClient.ProductType.SUBS) +
                HostedQuotaBillingSupport.queryPurchases(client, BillingClient.ProductType.INAPP),
        )
        // No local Play purchase doesn't necessarily mean inactive — the
        // user may be a Cloud Member via the iOS subscription. The Firestore
        // entitlement listener is the canonical source; only clear local
        // state when both Play Billing AND the entitlement doc agree the
        // user isn't active. We leave `_isActive` alone here so the
        // Firestore listener stays in charge.
    }

    private suspend fun handlePurchases(purchases: List<Purchase>) {
        val topUpPurchase =
            purchases.firstOrNull {
                it.purchaseState == Purchase.PurchaseState.PURCHASED && it.products.any { productID -> productID in TOP_UP_PRODUCT_IDS }
            }
        if (topUpPurchase != null) {
            val productID = topUpPurchase.products.first { it in TOP_UP_PRODUCT_IDS }
            _lastTopUpCredit.value =
                functions.verifyGooglePlayCloudProTopUp(
                    purchaseToken = topUpPurchase.purchaseToken,
                    productID = productID,
                )
        }

        val purchase =
            purchases.firstOrNull {
                it.purchaseState == Purchase.PurchaseState.PURCHASED && it.products.any { productID -> productID in SUBSCRIPTION_PRODUCT_IDS }
            } ?: return
        val productID = purchase.products.first { it in SUBSCRIPTION_PRODUCT_IDS }
        val response =
            functions.verifyGooglePlayBurnBarProSubscription(
                purchaseToken = purchase.purchaseToken,
                productID = productID,
            )
        if (!purchase.isAcknowledged) {
            acknowledge(purchase)
        }
        _isActive.value = response["active"] as? Boolean ?: true
        _activeProductID.value = productID
        _purchaseDate.value = purchase.purchaseTime
        val expiresAt = response["expiresAt"] as? String
        _expirationDate.value = expiresAt?.let { java.time.Instant.parse(it).toEpochMilli() }
    }

    private suspend fun acknowledge(purchase: Purchase) {
        val params =
            AcknowledgePurchaseParams.newBuilder()
                .setPurchaseToken(purchase.purchaseToken)
                .build()
        suspendCancellableCoroutine<Unit> { continuation ->
            requireBillingClient().acknowledgePurchase(params) { result ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    continuation.resume(Unit)
                } else {
                    continuation.resumeWithException(
                        IllegalStateException(result.debugMessage.ifBlank { "Could not acknowledge purchase." }),
                    )
                }
            }
        }
    }

    private fun requireBillingClient(): BillingClient = checkNotNull(billingClient) { "Google Play Billing client is not ready." }
}
