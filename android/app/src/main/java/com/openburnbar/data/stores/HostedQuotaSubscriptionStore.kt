package com.openburnbar.data.stores

import android.app.Activity
import android.content.Context
import android.util.Log
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
import com.openburnbar.ui.pro.CloudTier
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

data class HostedQuotaProductDetails(val formattedPrice: String)

enum class HostedQuotaStoreProductRole {
    CLOUD_SUBSCRIPTION,
    CLOUD_PRO_SUBSCRIPTION,
    CLOUD_ULTRA_SUBSCRIPTION,
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
        private const val LOG_TAG = "BurnBarBilling"

        const val PRODUCT_ID = "com.openburnbar.pro.monthly"
        const val CLOUD_ANNUAL_PRODUCT_ID = "com.openburnbar.pro.annual"
        const val CLOUD_PRO_MONTHLY_PRODUCT_ID = "com.openburnbar.promax.v2.monthly"
        const val CLOUD_PRO_ANNUAL_PRODUCT_ID = "com.openburnbar.promax.annual"

        // Cloud Ultra — the top tier (10× agent memory over Cloud Pro). These are
        // the Google Play SKUs the Cloud Functions config expects
        // (`googlePlayUltraMonthlyProductID` / `googlePlayUltraAnnualProductID`);
        // they verify into the server-reconciled `burnbar_ultra` entitlement,
        // which mirrors `burnbar_pro_max` so Ultra inherits every Cloud Pro gate.
        const val CLOUD_ULTRA_MONTHLY_PRODUCT_ID = "com.openburnbar.ultra.monthly"
        const val CLOUD_ULTRA_ANNUAL_PRODUCT_ID = "com.openburnbar.ultra.annual"

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
                    CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION,
                    "$59.99",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_ULTRA_ANNUAL_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION,
                    "$599",
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

        // ── Tier resolution (spec §4.2) ──
        //
        // The flat `isActive` Boolean loses the tier, so feature gating cannot
        // tell Cloud from Cloud Pro from Ultra. This maps the active product ID
        // (Play SKU, or the Apple SKU written to the Firestore entitlement doc
        // for cross-platform Cloud members) to the canonical `CloudTier` ladder:
        //   burnbar_ultra (…ultra…)          → ULTRA
        //   burnbar_pro_max / computer-use   → PRO
        //   hosted_quota_sync (Cloud)        → CLOUD
        // Higher tiers subsume lower gates via `CloudTier.satisfies`.

        /**
         * Resolve a [CloudTier] from the active product ID. Returns [CloudTier.NONE]
         * when nothing is active. Recognizes both the Android Play SKUs (via the
         * store-product role) and the Apple product IDs the verifier writes to the
         * `hosted_quota_sync` entitlement doc for users who paid on iOS/macOS.
         */
        internal fun tierForActiveProduct(active: Boolean, productID: String?): CloudTier {
            if (!active) return CloudTier.NONE
            val id = productID?.trim().orEmpty()
            // Fast path: a known Android store product maps via its role.
            when (STORE_PRODUCT_BY_ID[id]?.role) {
                HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION -> return CloudTier.ULTRA
                HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION -> return CloudTier.PRO
                HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION -> return CloudTier.CLOUD
                else -> Unit
            }
            // Cross-platform fallback: classify by the product-ID substring the
            // Apple/entitlement verifiers use (e.g. com.openburnbar.ultra.monthly,
            // com.openburnbar.promax.*, com.openburnbar.computer-use.*).
            val lower = id.lowercase()
            return when {
                lower.isEmpty() -> CloudTier.CLOUD // active but unlabeled ⇒ at least Cloud
                lower.contains("ultra") -> CloudTier.ULTRA
                lower.contains("promax") ||
                    lower.contains("pro_max") ||
                    lower.contains("pro.max") ||
                    lower.contains("computer-use") ||
                    lower.contains("computeruse") -> CloudTier.PRO
                else -> CloudTier.CLOUD
            }
        }
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

    /**
     * The member's resolved subscription tier (spec §4.2). Derived live from
     * [isActive] + [activeProductID] so all Cloud / Cloud Pro / Ultra feature
     * gates resolve correctly. [isActive] still works for the simple "any paid
     * plan?" check; `currentTier.satisfies(...)` answers "which gate passes?".
     */
    val currentTier: StateFlow<CloudTier> =
        combine(_isActive, _activeProductID) { active, productID ->
            tierForActiveProduct(active, productID)
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = CloudTier.NONE,
        )

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
        applyFallbackProductDetails()
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

    private fun applyFallbackProductDetails() {
        if (_productDetailsByID.value.isNotEmpty()) return
        _productDetailsByID.value =
            STORE_PRODUCTS.associate { storeProduct ->
                storeProduct.id to HostedQuotaProductDetails(formattedPrice = storeProduct.fallbackPrice)
            }
        _productDetails.value = _productDetailsByID.value[PRODUCT_ID]
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
            } catch (e: IllegalStateException) {
                Log.w(LOG_TAG, "Google Play Billing unavailable during load: ${e.localizedMessage}")
                applyFallbackProductDetails()
                _error.value = e.localizedMessage ?: "Google Play Billing is unavailable on this device."
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
                applyFallbackProductDetails()
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
            } catch (e: IllegalStateException) {
                Log.w(LOG_TAG, "Google Play Billing unavailable during restore: ${e.localizedMessage}")
                applyFallbackProductDetails()
                _error.value = e.localizedMessage ?: "Google Play Billing is unavailable on this device."
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
            } catch (e: IllegalStateException) {
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
        val subscriptionPurchases = HostedQuotaBillingSupport.queryPurchases(client, BillingClient.ProductType.SUBS)
        val topUpPurchases = HostedQuotaBillingSupport.queryPurchases(client, BillingClient.ProductType.INAPP)
        Log.i(
            LOG_TAG,
            "restorePurchases queried subscriptions=${subscriptionPurchases.size} topUps=${topUpPurchases.size} " +
                "products=${purchaseProductSummary(subscriptionPurchases + topUpPurchases)}",
        )
        handlePurchases(subscriptionPurchases + topUpPurchases)
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

        var lastInactiveSubscription: VerifiedSubscription? = null
        var lastVerificationError: Throwable? = null
        val subscriptionCandidates = subscriptionPurchaseCandidates(purchases)
        Log.i(
            LOG_TAG,
            "handlePurchases eligibleSubscriptions=${subscriptionCandidates.map { it.productID }}",
        )
        for (candidate in subscriptionCandidates) {
            try {
                Log.i(LOG_TAG, "verifySubscription productID=${candidate.productID}")
                val response =
                    functions.verifyGooglePlayBurnBarProSubscription(
                        purchaseToken = candidate.purchase.purchaseToken,
                        productID = candidate.productID,
                    )
                Log.i(
                    LOG_TAG,
                    "verifiedSubscription productID=${candidate.productID} active=${response["active"]} " +
                        "expiresAt=${response["expiresAt"] ?: response["expireAt"]}",
                )
                val verified =
                    VerifiedSubscription(
                        purchase = candidate.purchase,
                        productID = candidate.productID,
                        response = response,
                )
                if (isVerifiedSubscriptionActive(response)) {
                    if (!candidate.purchase.isAcknowledged) {
                        val acknowledged = acknowledge(candidate.purchase)
                        if (!acknowledged) {
                            _error.value = "Your subscription is active, but Google Play acknowledgement is still pending."
                        }
                    }
                    applyVerifiedSubscription(verified)
                    return
                }
                lastInactiveSubscription = verified
            } catch (error: FirebaseFunctionsException) {
                Log.w(LOG_TAG, "verifySubscription failed productID=${candidate.productID}: ${error.localizedMessage}")
                lastVerificationError = error
            } catch (error: IllegalStateException) {
                Log.w(LOG_TAG, "verifySubscription failed productID=${candidate.productID}: ${error.localizedMessage}")
                lastVerificationError = error
            }
        }
        if (lastInactiveSubscription != null) {
            applyVerifiedSubscription(lastInactiveSubscription)
            return
        }
        lastVerificationError?.let { throw it }
    }

    private data class SubscriptionPurchaseCandidate(
        val purchase: Purchase,
        val productID: String,
    )

    private data class VerifiedSubscription(
        val purchase: Purchase,
        val productID: String,
        val response: Map<String, Any>,
    )

    private fun subscriptionPurchaseCandidates(purchases: List<Purchase>): List<SubscriptionPurchaseCandidate> {
        return purchases
            .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
            .flatMap { purchase ->
                purchase.products
                    .filter { productID -> productID in SUBSCRIPTION_PRODUCT_IDS }
                    .map { productID ->
                        SubscriptionPurchaseCandidate(
                            purchase = purchase,
                            productID = productID,
                        )
                    }
            }
            .distinctBy { "${it.purchase.purchaseToken}:${it.productID}" }
            .sortedWith(
                compareBy<SubscriptionPurchaseCandidate> { subscriptionProductPriority(it.productID) }
                    .thenByDescending { it.purchase.purchaseTime },
            )
    }

    private fun purchaseProductSummary(purchases: List<Purchase>): List<String> {
        return purchases.map { purchase ->
            val state =
                when (purchase.purchaseState) {
                    Purchase.PurchaseState.PURCHASED -> "purchased"
                    Purchase.PurchaseState.PENDING -> "pending"
                    Purchase.PurchaseState.UNSPECIFIED_STATE -> "unspecified"
                    else -> "state-${purchase.purchaseState}"
                }
            "${purchase.products.joinToString("+")}:$state:ack=${purchase.isAcknowledged}"
        }
    }

    private fun subscriptionProductPriority(productID: String): Int {
        return when (STORE_PRODUCT_BY_ID[productID]?.role) {
            HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION -> 0
            HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION -> 1
            HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION -> 2
            else -> 3
        }
    }

    private fun isVerifiedSubscriptionActive(response: Map<String, Any>): Boolean {
        val expiresAtMs =
            parseTimestampMs(response["expiresAt"])
                ?: parseTimestampMs(response["expireAt"])
        val active = response["active"] as? Boolean ?: false
        return active && expiresAtMs != null && expiresAtMs > System.currentTimeMillis()
    }

    private fun applyVerifiedSubscription(verified: VerifiedSubscription) {
        applyVerifiedSubscription(
            productID = verified.productID,
            purchaseTime = verified.purchase.purchaseTime,
            response = verified.response,
        )
    }

    private fun applyVerifiedSubscription(productID: String, purchaseTime: Long, response: Map<String, Any>) {
        val expiresAtMs =
            parseTimestampMs(response["expiresAt"])
                ?: parseTimestampMs(response["expireAt"])
        val active = response["active"] as? Boolean ?: false
        val notExpired = expiresAtMs != null && expiresAtMs > System.currentTimeMillis()

        _isActive.value = active && notExpired
        _activeProductID.value = productID.takeIf { _isActive.value }
        _purchaseDate.value = purchaseTime
        _expirationDate.value = expiresAtMs
    }

    private suspend fun acknowledge(purchase: Purchase): Boolean {
        val params =
            AcknowledgePurchaseParams.newBuilder()
                .setPurchaseToken(purchase.purchaseToken)
                .build()
        return suspendCancellableCoroutine { continuation ->
            requireBillingClient().acknowledgePurchase(params) { result ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    continuation.resume(true)
                } else {
                    val message = result.debugMessage.ifBlank { "Could not acknowledge purchase." }
                    Log.w(
                        LOG_TAG,
                        "acknowledgePurchase failed code=${result.responseCode}: $message",
                    )
                    continuation.resume(false)
                }
            }
        }
    }

    private fun requireBillingClient(): BillingClient = checkNotNull(billingClient) { "Google Play Billing client is not ready." }
}
