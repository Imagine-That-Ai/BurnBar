package com.openburnbar.data.insights

import kotlinx.serialization.Serializable

/**
 * Errors that can occur during an investigation. Mirrors Swift InsightGatewayError.
 */
@Serializable
sealed class InsightGatewayError {
    @Serializable data class NetworkError(val message: String, val statusCode: Int? = null) : InsightGatewayError()
    @Serializable data class RateLimited(val retryAfterSeconds: Int) : InsightGatewayError()
    @Serializable data class AuthenticationError(val message: String) : InsightGatewayError()
    @Serializable data class QuotaExceeded(val message: String) : InsightGatewayError()
    @Serializable data class ModelBusy(val message: String) : InsightGatewayError()
    @Serializable data class SchemaValidationFailed(val message: String) : InsightGatewayError()
    @Serializable data class ResponseMalformed(val message: String, val rawBody: String? = null) : InsightGatewayError()
    @Serializable data class Cancelled(val message: String = "Investigation cancelled") : InsightGatewayError()
    @Serializable data class Timeout(val message: String = "Investigation timed out") : InsightGatewayError()
    @Serializable data class Unknown(val message: String) : InsightGatewayError()
}
