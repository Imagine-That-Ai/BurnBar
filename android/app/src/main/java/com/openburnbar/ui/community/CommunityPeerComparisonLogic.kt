package com.openburnbar.ui.community

import com.openburnbar.data.community.CommunityGeoTier
import com.openburnbar.data.models.generated.FirestorePercentileBands

private val regionDisplay =
    mapOf(
        "US-NY" to "New York",
        "US-IL" to "Illinois",
        "US-CO" to "Colorado",
        "US-CA" to "California",
        "US-AZ" to "Arizona",
        "US-AK" to "Alaska",
        "US-HI" to "Hawaii",
        "CA-ON" to "Ontario",
        "CA-BC" to "British Columbia",
        "CA-NS" to "Nova Scotia",
        "CA-AB" to "Alberta",
        "CA-MB" to "Manitoba",
        "AU-NSW" to "New South Wales",
        "AU-VIC" to "Victoria",
        "AU-QLD" to "Queensland",
        "AU-WA" to "Western Australia",
    )

private val countryDisplay =
    mapOf(
        "US" to "United States",
        "CA" to "Canada",
        "GB" to "United Kingdom",
        "DE" to "Germany",
        "FR" to "France",
        "AU" to "Australia",
        "JP" to "Japan",
    )

internal fun communityGeoDisplayLabel(tier: CommunityGeoTier, geoKey: String): String =
    when (tier) {
        CommunityGeoTier.CITY ->
            if (geoKey.isBlank() || geoKey == tier.wire) {
                "City unavailable — add a manual city label"
            } else {
                geoKey
            }
        CommunityGeoTier.REGION ->
            if (geoKey.isBlank() || geoKey == tier.wire) {
                "Region unavailable"
            } else {
                regionDisplay[geoKey] ?: geoKey
            }
        CommunityGeoTier.COUNTRY -> {
            val code = geoKey.trim().uppercase()
            if (code.isBlank() || code == tier.wire.uppercase()) {
                "Country unavailable"
            } else {
                countryDisplay[code] ?: code
            }
        }
        CommunityGeoTier.WORLD -> "Global"
    }

internal fun communityGeoConfidenceCopy(tier: CommunityGeoTier, geoKey: String): String =
    when (tier) {
        CommunityGeoTier.CITY ->
            if (geoKey.isBlank() || geoKey == tier.wire) {
                "City rank waits for explicit city consent and a manual label; no raw coordinates are used."
            } else {
                "Manual city label only; BurnBar stores a canonical city key, never raw coordinates."
            }
        CommunityGeoTier.REGION ->
            if (geoKey.isBlank() || geoKey == tier.wire) {
                "Region unavailable from this device locale/timezone."
            } else {
                "Coarse region inferred from device locale/timezone."
            }
        CommunityGeoTier.COUNTRY ->
            if (geoKey.isBlank() || geoKey == tier.wire) {
                "Country unavailable from this device locale/timezone."
            } else {
                "Coarse country inferred from device locale/timezone."
            }
        CommunityGeoTier.WORLD -> "World ranking uses no location signal."
    }

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