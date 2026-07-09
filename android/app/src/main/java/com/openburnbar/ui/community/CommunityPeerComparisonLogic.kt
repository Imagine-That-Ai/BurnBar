package com.openburnbar.ui.community

import com.openburnbar.data.models.generated.FirestorePercentileBands

internal fun peerComparisonSparklineData(
    percentiles: FirestorePercentileBands,
    yourTokens: Long,
): List<Float>? {
    val bands =
        listOf(
            percentiles.p50,
            percentiles.p75,
            percentiles.p90,
            percentiles.p99,
            yourTokens.toDouble(),
        )
    if (bands.all { it <= 0.0 }) return null
    return bands.map { it.toFloat() }
}

internal fun shouldShowPeerComparisonChart(
    cohortSize: Long,
    percentiles: FirestorePercentileBands,
    yourTokens: Long,
): Boolean {
    if (cohortSize <= 0L) return false
    val hasPercentileSignal =
        percentiles.p50 > 0.0 ||
            percentiles.p75 > 0.0 ||
            percentiles.p90 > 0.0 ||
            percentiles.p99 > 0.0
    if (!hasPercentileSignal) return false
    return peerComparisonSparklineData(percentiles, yourTokens) != null
}

internal fun parseLookingGlassDownloadUrl(response: Map<String, Any>): String? {
    val download = response["downloadUrl"] as? String
    if (!download.isNullOrBlank() && download.startsWith("https://")) return download
    val signed = response["signedUrl"] as? String
    if (!signed.isNullOrBlank() && signed.startsWith("https://")) return signed
    return null
}