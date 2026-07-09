package com.openburnbar.ui.community

import com.openburnbar.data.community.CommunityGeoTier
import com.openburnbar.data.models.generated.FirestorePercentileBands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CommunityPeerComparisonLogicTest {
    @Test
    fun sparkline_usesPercentileBandsAndUserValue() {
        val percentiles =
            FirestorePercentileBands(
                p50 = 100.0,
                p75 = 200.0,
                p90 = 300.0,
                p99 = 400.0,
            )
        val data = peerComparisonSparklineData(percentiles, yourTokens = 250L)
        assertEquals(listOf(100f, 200f, 300f, 400f, 250f), data)
    }

    @Test
    fun sparkline_returnsNullWhenAllBandsZero() {
        assertNull(peerComparisonSparklineData(FirestorePercentileBands(), yourTokens = 0L))
    }

    @Test
    fun shouldShow_falseWhenCohortSizeZero() {
        val bands = FirestorePercentileBands(p50 = 10.0)
        assertFalse(shouldShowPeerComparisonChart(cohortSize = 0, percentiles = bands, yourTokens = 5))
    }

    @Test
    fun shouldShow_falseWhenAllPercentilesZero() {
        assertFalse(shouldShowPeerComparisonChart(cohortSize = 12, percentiles = FirestorePercentileBands(), yourTokens = 99))
    }

    @Test
    fun shouldShow_trueWithCohortAndPercentileSignal() {
        val bands = FirestorePercentileBands(p75 = 50.0)
        assertTrue(shouldShowPeerComparisonChart(cohortSize = 10, percentiles = bands, yourTokens = 60))
    }

    @Test
    fun geoDisplayLabel_usesManualCityAndCoarseDisplayNames() {
        assertEquals("Berlin", communityGeoDisplayLabel(CommunityGeoTier.CITY, "Berlin"))
        assertEquals("California", communityGeoDisplayLabel(CommunityGeoTier.REGION, "US-CA"))
        assertEquals("United States", communityGeoDisplayLabel(CommunityGeoTier.COUNTRY, "us"))
        assertEquals("Global", communityGeoDisplayLabel(CommunityGeoTier.WORLD, "world"))
    }

    @Test
    fun geoConfidenceCopy_isHonestAboutUnavailableAndDerivedPrecision() {
        assertTrue(
            communityGeoConfidenceCopy(CommunityGeoTier.CITY, "city")
                .contains("manual label"),
        )
        assertTrue(
            communityGeoConfidenceCopy(CommunityGeoTier.REGION, "US-CA")
                .contains("locale/timezone"),
        )
        assertTrue(
            communityGeoConfidenceCopy(CommunityGeoTier.WORLD, "world")
                .contains("no location"),
        )
    }

    @Test
    fun parseLookingGlassDownloadUrl_prefersDownloadUrl() {
        val url =
            parseLookingGlassDownloadUrl(
                mapOf(
                    "downloadUrl" to "https://storage.example/export.jsonl",
                    "signedUrl" to "https://storage.example/other.jsonl",
                ),
            )
        assertEquals("https://storage.example/export.jsonl", url)
    }

    @Test
    fun parseLookingGlassDownloadUrl_rejectsNonHttps() {
        assertNull(parseLookingGlassDownloadUrl(mapOf("downloadUrl" to "http://insecure.example/x")))
    }
}