package com.openburnbar.data.stores

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Google Play Billing integration for OpenBurnBar Cloud subscription.
 * Stub implementation — billing dependency will be added when Play Console is configured.
 */
class HostedQuotaSubscriptionStore : ViewModel() {

    private val _isActive = MutableStateFlow(false)
    val isActive: StateFlow<Boolean> = _isActive.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _productDetails = MutableStateFlow<StubProductDetails?>(null)
    val productDetails: StateFlow<StubProductDetails?> = _productDetails.asStateFlow()

    private val _expirationDate = MutableStateFlow<Long?>(null)
    val expirationDate: StateFlow<Long?> = _expirationDate.asStateFlow()

    private val _purchaseDate = MutableStateFlow<Long?>(null)
    val purchaseDate: StateFlow<Long?> = _purchaseDate.asStateFlow()

    fun initialize(context: android.content.Context) {
        // TODO: Integrate Google Play Billing when ready
    }

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            // TODO: query product details
            _isLoading.value = false
        }
    }

    fun loadProducts() {
        viewModelScope.launch {
            _isLoading.value = true
            // TODO: query product details
            _isLoading.value = false
        }
    }

    fun purchase(activity: android.app.Activity) {
        // TODO: launch billing flow
    }

    fun restorePurchases() {
        viewModelScope.launch {
            _isLoading.value = true
            // TODO: restore purchases
            _isLoading.value = false
        }
    }

    override fun onCleared() {
        super.onCleared()
    }

    /** Stub for Google Play Billing ProductDetails — replace with real type when billing-ktx is added. */
    data class StubProductDetails(
        val oneTimePurchaseOfferDetails: StubOfferDetails? = null
    ) {
        data class StubOfferDetails(
            val formattedPrice: String = "$4.99"
        )
    }
}
