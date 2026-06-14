package com.openburnbar.data.stores

import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.UnfetchedProduct
import java.security.MessageDigest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

internal object HostedQuotaBillingSupport {
    fun formattedPrice(details: ProductDetails): String? {
        return details.subscriptionOfferDetails
            ?.firstOrNull()
            ?.pricingPhases
            ?.pricingPhaseList
            ?.firstOrNull()
            ?.formattedPrice
            ?: details.oneTimePurchaseOfferDetails?.formattedPrice
    }

    fun unfetchedProductStatusName(statusCode: Int): String = when (statusCode) {
        UnfetchedProduct.StatusCode.INVALID_PRODUCT_ID_FORMAT -> "INVALID_PRODUCT_ID_FORMAT"
        UnfetchedProduct.StatusCode.PRODUCT_NOT_FOUND -> "PRODUCT_NOT_FOUND"
        UnfetchedProduct.StatusCode.NO_ELIGIBLE_OFFER -> "NO_ELIGIBLE_OFFER"
        UnfetchedProduct.StatusCode.UNKNOWN -> "UNKNOWN"
        else -> "UNKNOWN_$statusCode"
    }

    suspend fun queryProductDetails(billingClient: BillingClient, productType: String, productIDs: List<String>): Map<String, ProductDetails> {
        if (productIDs.isEmpty()) return emptyMap()
        val params =
            QueryProductDetailsParams.newBuilder()
                .setProductList(
                    productIDs.map { productID ->
                        QueryProductDetailsParams.Product.newBuilder()
                            .setProductId(productID)
                            .setProductType(productType)
                            .build()
                    },
                )
                .build()
        return suspendCancellableCoroutine { continuation ->
            billingClient.queryProductDetailsAsync(
                params,
            ) { result, products ->
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    continuation.resumeWithException(
                        IllegalStateException(result.debugMessage.ifBlank { "Could not load BurnBar products." }),
                    )
                    return@queryProductDetailsAsync
                }
                val unfetchedProducts =
                    products
                        .getUnfetchedProductList()
                        .filter { it.productId in productIDs }
                if (unfetchedProducts.isNotEmpty()) {
                    val details =
                        unfetchedProducts.joinToString(", ") { unfetchedProduct ->
                            "${unfetchedProduct.productId} (${unfetchedProductStatusName(unfetchedProduct.statusCode)})"
                        }
                    continuation.resumeWithException(
                        IllegalStateException("BurnBar product is not configured in Google Play: $details"),
                    )
                    return@queryProductDetailsAsync
                }
                continuation.resume(products.getProductDetailsList().associateBy { it.productId })
            }
        }
    }

    suspend fun queryPurchases(billingClient: BillingClient, productType: String): List<Purchase> {
        val params =
            QueryPurchasesParams.newBuilder()
                .setProductType(productType)
                .build()
        return suspendCancellableCoroutine { continuation ->
            billingClient.queryPurchasesAsync(params) { result, purchases ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    continuation.resume(purchases)
                } else {
                    continuation.resumeWithException(
                        IllegalStateException(result.debugMessage.ifBlank { "Could not query purchases." }),
                    )
                }
            }
        }
    }

    fun sha256Hex(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }
}
