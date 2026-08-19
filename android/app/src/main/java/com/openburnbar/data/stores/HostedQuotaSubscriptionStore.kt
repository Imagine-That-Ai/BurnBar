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
import com.openburnbar.data.policy.MobileStoreEntitlementPolicy
import com.openburnbar.data.policy.UidScopedCacheRegistry
import com.openburnbar.ui.pro.CloudTier
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Job
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
    val basePlanID: String? = null,
    val offerID: String? = null,
)

internal data class HostedQuotaSubscriptionReplacement(
    val oldProductID: String,
    val oldPurchaseToken: String,
    val replacementMode: Int,
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
    initialFirestore: FirebaseFirestore? = null,
    initialFirebaseAuth: FirebaseAuth? = null,
    private val scopedCaches: UidScopedCacheRegistry = UidScopedCacheRegistry.shared,
) : ViewModel(), PurchasesUpdatedListener {
    companion object {
        private const val LOG_TAG = "BurnBarBilling"
        private const val FALLBACK_SUBSCRIPTION_PRODUCT_PRIORITY = 3

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
        const val FUSION_SEARCH_100_TOP_UP_PRODUCT_ID = "com.openburnbar.elderwand.searches100"
        const val FUSION_SEARCH_500_TOP_UP_PRODUCT_ID = "com.openburnbar.elderwand.searches500"

        val STORE_PRODUCTS =
            listOf(
                HostedQuotaStoreProduct(
                    PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION,
                    basePlanID = "monthly",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_ANNUAL_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION,
                    basePlanID = "annual",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_PRO_MONTHLY_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION,
                    basePlanID = "monthly",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_PRO_ANNUAL_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION,
                    basePlanID = "annual",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_ULTRA_MONTHLY_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION,
                    basePlanID = "p1m",
                ),
                HostedQuotaStoreProduct(
                    CLOUD_ULTRA_ANNUAL_PRODUCT_ID,
                    BillingClient.ProductType.SUBS,
                    HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION,
                    basePlanID = "p1y",
                ),
                HostedQuotaStoreProduct(
                    AGENT_CONTROL_TOP_UP_PRODUCT_ID,
                    BillingClient.ProductType.INAPP,
                    HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP,
                ),
                HostedQuotaStoreProduct(FLOO_RELAY_TOP_UP_PRODUCT_ID, BillingClient.ProductType.INAPP, HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP),
                HostedQuotaStoreProduct(
                    FUSION_SEARCH_100_TOP_UP_PRODUCT_ID,
                    BillingClient.ProductType.INAPP,
                    HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP,
                ),
                HostedQuotaStoreProduct(
                    FUSION_SEARCH_500_TOP_UP_PRODUCT_ID,
                    BillingClient.ProductType.INAPP,
                    HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP,
                ),
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
        internal val CANONICAL_ENTITLEMENT_DOCUMENTS =
            listOf(
                CanonicalEntitlementDocument("burnbar_ultra", CLOUD_ULTRA_MONTHLY_PRODUCT_ID),
                CanonicalEntitlementDocument("burnbar_pro_max", CLOUD_PRO_MONTHLY_PRODUCT_ID),
                CanonicalEntitlementDocument("burnbar_pro", PRODUCT_ID),
                CanonicalEntitlementDocument("hosted_quota_sync", "com.openburnbar.hostedQuotaSync.cloud.monthly"),
            )

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
        internal fun tierForActiveProduct(active: Boolean, productID: String?): CloudTier =
            if (active) tierForProductID(productID?.trim().orEmpty()) else CloudTier.NONE

        internal fun subscriptionReplacementMode(oldProductID: String, newProductID: String): Int {
            val oldTier = tierForProductID(oldProductID)
            val newTier = tierForProductID(newProductID)
            return if (newTier.rank > oldTier.rank) {
                BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams
                    .ReplacementMode.CHARGE_PRORATED_PRICE
            } else {
                // Downgrades and same-tier cadence changes take effect at the
                // next renewal. This preserves already-paid access and avoids
                // invalid immediate-proration combinations (for example,
                // switching from monthly to a lower per-month annual price).
                BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams
                    .ReplacementMode.DEFERRED
            }
        }

        internal fun selectSubscriptionReplacement(newProductID: String, purchases: List<Purchase>): HostedQuotaSubscriptionReplacement? = purchases
            .asSequence()
            .filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
            .flatMap { purchase ->
                purchase.products
                    .filter { existingProductID ->
                        existingProductID in SUBSCRIPTION_PRODUCT_IDS &&
                            existingProductID != newProductID &&
                            purchase.purchaseToken.isNotBlank()
                    }
                    .map { existingProductID -> existingProductID to purchase }
            }
            .sortedBy { (existingProductID, _) ->
                hostedQuotaSubscriptionProductPriority(
                    productID = existingProductID,
                    productsById = STORE_PRODUCT_BY_ID,
                    fallbackPriority = FALLBACK_SUBSCRIPTION_PRODUCT_PRIORITY,
                )
            }
            .map { (existingProductID, purchase) ->
                HostedQuotaSubscriptionReplacement(
                    oldProductID = existingProductID,
                    oldPurchaseToken = purchase.purchaseToken,
                    replacementMode = subscriptionReplacementMode(existingProductID, newProductID),
                )
            }
            .firstOrNull()

        private fun tierForProductID(id: String): CloudTier = STORE_PRODUCT_BY_ID[id]?.role?.subscriptionTier()
            ?: fallbackTierForProductID(id)

        private fun HostedQuotaStoreProductRole.subscriptionTier(): CloudTier? = when (this) {
            HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION -> CloudTier.ULTRA
            HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION -> CloudTier.PRO
            HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION -> CloudTier.CLOUD
            HostedQuotaStoreProductRole.CLOUD_PRO_TOP_UP -> null
        }

        private fun fallbackTierForProductID(id: String): CloudTier {
            // Cross-platform fallback: classify by the product-ID substring the
            // Apple/entitlement verifiers use (e.g. com.openburnbar.ultra.monthly,
            // com.openburnbar.promax.*, com.openburnbar.computer-use.*).
            val lower = id.lowercase()
            return when {
                lower.isEmpty() -> CloudTier.CLOUD // active but unlabeled => at least Cloud
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
    // Members who buy on Apple or the web have no Google Play purchase locally.
    // Cloud Functions reconcile every paid tier into one of the canonical
    // Firestore docs below. Listen to the collection as one atomic snapshot so
    // a missing legacy doc can never erase an active Pro or Ultra entitlement.
    // Firestore is authoritative; Play Billing remains the Android fast-path.

    private val firestore: FirebaseFirestore by lazy { initialFirestore ?: FirebaseFirestore.getInstance() }
    private val firebaseAuth: FirebaseAuth by lazy { initialFirebaseAuth ?: FirebaseAuth.getInstance() }
    private var entitlementListener: ListenerRegistration? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null
    private var firestoreEntitlementActive: Boolean? = null
    private var entitlementWork: Job? = null
    private val uidClearer = { clearCache() }

    init {
        scopedCaches.register(uidClearer)
    }

    /**
     * Drop UID-scoped entitlement StateFlows and Firestore listeners so an
     * A→B account switch cannot keep serving A's tier. Play catalog prices
     * stay; they are device-level, not account-level.
     */
    fun clearCache() {
        entitlementWork?.cancel()
        entitlementWork = null
        entitlementListener?.remove()
        entitlementListener = null
        firestoreEntitlementActive = null
        _error.value = null
        _lastTopUpCredit.value = null
        _isLoading.value = false
        clearSubscriptionState()
        firebaseAuth.currentUser?.uid?.let { attachEntitlementListener(it) }
    }

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
                    firestoreEntitlementActive = null
                    clearSubscriptionState()
                    return@AuthStateListener
                }

                attachEntitlementListener(uid)
            }
        firebaseAuth.addAuthStateListener(listener)
        authListener = listener
    }

    private fun attachEntitlementListener(uid: String) {
        entitlementListener?.remove()
        entitlementListener =
            firestore.collection("users")
                .document(uid)
                .collection("entitlements")
                .addSnapshotListener { snap, error ->
                    if (firebaseAuth.currentUser?.uid != uid) {
                        return@addSnapshotListener
                    }
                    if (error != null) {
                        Log.w(LOG_TAG, "cloud entitlement listener failed: ${error.localizedMessage}")
                        return@addSnapshotListener
                    }
                    if (snap == null) {
                        Log.w(LOG_TAG, "cloud entitlement listener returned no snapshot")
                        return@addSnapshotListener
                    }
                    applyEntitlementDocs(
                        snap.documents.associate { document ->
                            document.id to (document.data ?: emptyMap())
                        },
                    )
                }
    }

    // / Resolve all canonical Firestore entitlement documents highest-tier
    // / first. Server state remains authoritative for refund, revocation, and
    // / cross-platform restore flows.
    private fun applyEntitlementDocs(documentsByID: Map<String, Map<String, Any?>>) {
        val entitlement = resolveCanonicalEntitlement(documentsByID)
        firestoreEntitlementActive = entitlement?.active ?: false
        if (entitlement == null) {
            clearSubscriptionState()
            return
        }
        _isActive.value = entitlement.active
        _activeProductID.value = entitlement.productID.takeIf { entitlement.active }
        _expirationDate.value = entitlement.expiresAtMs
        _purchaseDate.value = entitlement.purchaseAtMs
    }

    private fun clearSubscriptionState() {
        _isActive.value = false
        _activeProductID.value = null
        _expirationDate.value = null
        _purchaseDate.value = null
    }

    private fun applyFallbackProductDetails() {
        if (_productDetailsByID.value.isNotEmpty()) return
        _productDetailsByID.value =
            STORE_PRODUCTS.associate { storeProduct ->
                storeProduct.id to HostedQuotaProductDetails(
                    formattedPrice = MobileStoreEntitlementPolicy.UNAVAILABLE_PRICE_LABEL,
                )
            }
        _productDetails.value = _productDetailsByID.value[PRODUCT_ID]
    }

    fun load() {
        entitlementWork?.cancel()
        entitlementWork = viewModelScope.launch {
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

    fun purchase(activity: Activity, productID: String) {
        entitlementWork?.cancel()
        entitlementWork = viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                ensureReady()
                val client = requireBillingClient()
                val storeProduct =
                    STORE_PRODUCT_BY_ID[productID]
                        ?: error("Unsupported BurnBar product.")
                val details =
                    rawProductDetailsByID[productID] ?: loadProductsInternal()[productID]
                        ?: error("BurnBar product is not configured in Google Play.")
                val flowParams =
                    billingFlowParams(
                        storeProduct = storeProduct,
                        details = details,
                        replacement = subscriptionReplacement(productID, storeProduct),
                        accountUID = firebaseAuth.currentUser?.uid,
                    )
                val result = client.launchBillingFlow(activity, flowParams)
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

    private suspend fun subscriptionReplacement(productID: String, storeProduct: HostedQuotaStoreProduct): HostedQuotaSubscriptionReplacement? {
        if (storeProduct.productType != BillingClient.ProductType.SUBS) return null
        return selectSubscriptionReplacement(
            newProductID = productID,
            purchases = HostedQuotaBillingSupport.queryPurchases(requireBillingClient(), BillingClient.ProductType.SUBS),
        )
    }

    fun restorePurchases() {
        entitlementWork?.cancel()
        entitlementWork = viewModelScope.launch {
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
        entitlementWork?.cancel()
        entitlementWork = viewModelScope.launch {
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
        scopedCaches.unregister(uidClearer)
        entitlementWork?.cancel()
        entitlementWork = null
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
                val formattedPrice =
                    detailsByID[storeProduct.id]?.let {
                        HostedQuotaBillingSupport.formattedPrice(it, storeProduct)
                    } ?: MobileStoreEntitlementPolicy.UNAVAILABLE_PRICE_LABEL
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
        val hadSubscriptionPurchase = handlePurchases(subscriptionPurchases + topUpPurchases)
        if (!hadSubscriptionPurchase && firestoreEntitlementActive != true) {
            clearSubscriptionState()
        }
    }

    private suspend fun handlePurchases(purchases: List<Purchase>): Boolean {
        verifyHostedQuotaTopUpPurchases(purchases, TOP_UP_PRODUCT_IDS, functions).lastOrNull()?.let { _lastTopUpCredit.value = it }

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
                if (hostedQuotaSubscriptionIsActive(response)) {
                    if (!candidate.purchase.isAcknowledged && !acknowledge(candidate.purchase)) {
                        _error.value = "Your subscription is active, but Google Play acknowledgement is still pending."
                    }
                    applyVerifiedSubscription(verified)
                    return true
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
            return true
        }
        lastVerificationError?.let { throw it }
        return subscriptionCandidates.isNotEmpty()
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
                compareBy<SubscriptionPurchaseCandidate> {
                    hostedQuotaSubscriptionProductPriority(
                        productID = it.productID,
                        productsById = STORE_PRODUCT_BY_ID,
                        fallbackPriority = FALLBACK_SUBSCRIPTION_PRODUCT_PRIORITY,
                    )
                }
                    .thenByDescending { it.purchase.purchaseTime },
            )
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

private fun parseTimestampMs(value: Any?): Long? = when (value) {
    is Timestamp -> value.toDate().time
    is Long -> value
    is Number -> value.toLong()
    is String -> runCatching { java.time.Instant.parse(value).toEpochMilli() }.getOrNull()
    else -> null
}

internal data class CanonicalEntitlementDocument(
    val id: String,
    val fallbackProductID: String,
)

private data class ResolvedCanonicalEntitlement(
    val active: Boolean,
    val productID: String,
    val expiresAtMs: Long?,
    val purchaseAtMs: Long?,
)

private fun resolveCanonicalEntitlement(
    documentsByID: Map<String, Map<String, Any?>>,
    nowMillis: Long = System.currentTimeMillis(),
): ResolvedCanonicalEntitlement? {
    var highestPriorityInactive: ResolvedCanonicalEntitlement? = null
    for (source in HostedQuotaSubscriptionStore.CANONICAL_ENTITLEMENT_DOCUMENTS) {
        val data = documentsByID[source.id] ?: continue
        val expiresAtMs =
            parseTimestampMs(data["expireAt"])
                ?: parseTimestampMs(data["expiresAt"])
                ?: parseTimestampMs(data["expirationDate"])
        val purchaseAtMs =
            parseTimestampMs(data["originalPurchaseDate"])
                ?: parseTimestampMs(data["purchaseDate"])
        val active =
            (data["active"] as? Boolean ?: false) &&
                (expiresAtMs == null || expiresAtMs > nowMillis)
        val productID =
            ((data["productID"] as? String) ?: (data["productId"] as? String))
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: source.fallbackProductID
        val resolved =
            ResolvedCanonicalEntitlement(
                active = active,
                productID = productID,
                expiresAtMs = expiresAtMs,
                purchaseAtMs = purchaseAtMs,
            )
        if (active) return resolved
        if (highestPriorityInactive == null) {
            highestPriorityInactive = resolved
        }
    }
    return highestPriorityInactive
}

private suspend fun verifyHostedQuotaTopUpPurchases(
    purchases: List<Purchase>,
    topUpProductIds: Set<String>,
    functions: FunctionsRepository,
): List<Map<String, Any>> {
    val credits = mutableListOf<Map<String, Any>>()
    purchases
        .filter { purchase ->
            purchase.purchaseState == Purchase.PurchaseState.PURCHASED &&
                purchase.products.any { productID -> productID in topUpProductIds }
        }
        .forEach { purchase ->
            purchase.products
                .filter { it in topUpProductIds }
                .forEach { productID ->
                    credits +=
                        functions.verifyGooglePlayCloudProTopUp(
                            purchaseToken = purchase.purchaseToken,
                            productID = productID,
                        )
                }
        }
    return credits
}

private fun billingFlowParams(
    storeProduct: HostedQuotaStoreProduct,
    details: ProductDetails,
    replacement: HostedQuotaSubscriptionReplacement?,
    accountUID: String?,
): BillingFlowParams {
    val productDetailsBuilder =
        BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(details)
    if (storeProduct.productType == BillingClient.ProductType.SUBS) {
        val offerToken =
            HostedQuotaBillingSupport.subscriptionOffer(details, storeProduct)?.offerToken
                ?: error(
                    "Google Play base plan ${storeProduct.basePlanID} " +
                        "is unavailable for ${storeProduct.id}.",
                )
        productDetailsBuilder.setOfferToken(offerToken)
        replacement?.let {
            productDetailsBuilder.setSubscriptionProductReplacementParams(
                BillingFlowParams.ProductDetailsParams.SubscriptionProductReplacementParams.newBuilder()
                    .setOldProductId(it.oldProductID)
                    .setReplacementMode(it.replacementMode)
                    .build(),
            )
        }
    }
    val flowBuilder =
        BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(
                listOf(
                    productDetailsBuilder.build(),
                ),
            )
    if (storeProduct.productType == BillingClient.ProductType.SUBS) {
        replacement?.let {
            flowBuilder.setSubscriptionUpdateParams(
                BillingFlowParams.SubscriptionUpdateParams.newBuilder()
                    .setOldPurchaseToken(it.oldPurchaseToken)
                    .build(),
            )
        }
    }
    accountUID?.let { uid ->
        flowBuilder.setObfuscatedAccountId(HostedQuotaBillingSupport.sha256Hex(uid))
    }
    return flowBuilder.build()
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

private fun hostedQuotaSubscriptionProductPriority(productID: String, productsById: Map<String, HostedQuotaStoreProduct>, fallbackPriority: Int): Int {
    return when (productsById[productID]?.role) {
        HostedQuotaStoreProductRole.CLOUD_ULTRA_SUBSCRIPTION -> 0
        HostedQuotaStoreProductRole.CLOUD_PRO_SUBSCRIPTION -> 1
        HostedQuotaStoreProductRole.CLOUD_SUBSCRIPTION -> 2
        else -> fallbackPriority
    }
}

private fun hostedQuotaSubscriptionIsActive(response: Map<String, Any>): Boolean {
    val expiresAtMs =
        parseTimestampMs(response["expiresAt"])
            ?: parseTimestampMs(response["expireAt"])
    val active = response["active"] as? Boolean ?: false
    return active && expiresAtMs != null && expiresAtMs > System.currentTimeMillis()
}
