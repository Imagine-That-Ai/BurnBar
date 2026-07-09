package com.openburnbar.data.community

import org.junit.Assert.assertEquals
import org.junit.Test

class CommunityCityKeyTest {
    data class Golden(
        val name: String,
        val cityName: String,
        val countryCode: String,
        val regionCode: String,
        val expected: String,
    )

    // Mirrors tests/fixtures/city-key-goldens.json — every platform must produce
    // byte-identical output for every entry, including edge-case region codes.
    private val goldens = listOf(
        Golden("ascii-clean", "San Francisco", "US", "CA", "US-CA-san-francisco"),
        Golden("decomposable-umlaut", "München", "DE", "BY", "DE-BY-munchen"),
        Golden("decomposable-tilde", "São Paulo", "BR", "SP", "BR-SP-sao-paulo"),
        Golden("decomposable-caron", "České Budějovice", "CZ", "JC", "CZ-JC-ceske-budejovice"),
        Golden("non-decomposable-oslash", "Tromsø", "NO", "19", "NO-19-tromso"),
        Golden("non-decomposable-l-slash", "Łódź", "PL", "LD", "PL-LD-lodz"),
        Golden("non-decomposable-dotted-i", "İstanbul", "TR", "34", "TR-34-istanbul"),
        Golden("non-decomposable-eth", "Reykjavík", "IS", "1", "IS-1-reykjavik"),
        Golden("non-decomposable-thorn", "Þorlákshöfn", "IS", "23", "IS-23-torlakshofn"),
        Golden("eszett", "Straße", "DE", "BY", "DE-BY-strasse"),
        Golden("non-decomposable-d-stroke", "Hà Nội", "VN", "HN", "VN-HN-ha-noi"),
        Golden("cjk-japanese-empty-slug", "東京", "JP", "13", "JP-13-"),
        Golden("doc-id-unsafe-chars", "St. John's / Québec", "CA", "QC", "CA-QC-st-john-s-quebec"),
        Golden("hyphenated-name", "Winston-Salem", "US", "NC", "US-NC-winston-salem"),
        Golden(
            "long-name-truncation",
            "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch",
            "GB",
            "WLS",
            "GB-WLS-llanfairpwllgwyngyllgogerychwyrndrobwlll",
        ),
        Golden("prefixed-region-code", "San Francisco", "US", "US-CA", "US-CA-san-francisco"),
        Golden(
            "nonmatching-trailing-region-prefix",
            "Boundary City",
            "US",
            "CA-FOO-",
            "US-CA-FOO--boundary-city",
        ),
        Golden(
            "truncation-trailing-hyphen",
            "alpha-beta-gamma-delta-epsilon-zeta-eta-theta-iota-kappa",
            "US",
            "CA",
            "US-CA-alpha-beta-gamma-delta-epsilon-zeta-eta",
        ),
    )

    @Test
    fun canonicalizeCityKey_allGoldens() {
        for (g in goldens) {
            assertEquals(
                "golden '${g.name}' failed",
                g.expected,
                CommunityCityKey.canonicalizeCityKey(g.cityName, g.countryCode, g.regionCode),
            )
        }
    }

    @Test
    fun slugifyCity_matchesGeoTsExamples() {
        assertEquals("san-francisco", CommunityCityKey.slugifyCity("San Francisco"))
        assertEquals("munchen", CommunityCityKey.slugifyCity("München"))
        assertEquals("sao-paulo", CommunityCityKey.slugifyCity("São Paulo"))
    }

    @Test
    fun canonicalizeCityKey_stripsCountryPrefixFromRegionCode() {
        assertEquals(
            "US-CA-san-francisco",
            CommunityCityKey.canonicalizeCityKey("San Francisco", "us", "US-CA"),
        )
    }

    @Test
    fun slugifyCity_truncationDoesNotEndWithHyphen() {
        val long = "alpha-beta-gamma-delta-epsilon-zeta-eta-theta-iota-kappa"
        val slug = CommunityCityKey.slugifyCity(long)
        org.junit.Assert.assertFalse(slug.endsWith("-"))
        org.junit.Assert.assertTrue(slug.length <= 40)
    }

    @Test
    fun normalizeRegionCode_mapsCommonRegionNamesToIsoCodes() {
        assertEquals("CA", CommunityLocationResolver.normalizeRegionCode("California", null, "US"))
        assertEquals("QC", CommunityLocationResolver.normalizeRegionCode("Québec", null, "CA"))
    }

    @Test
    fun normalizeRegionCode_returnsNullWhenRegionCannotMatchIso() {
        assertEquals(null, CommunityLocationResolver.normalizeRegionCode("Bavaria", null, "DE"))
    }

    @Test
    fun canonicalCityKeyFromComponents_requiresCityName() {
        assertEquals(
            null,
            CommunityLocationResolver.canonicalCityKeyFromComponents(
                cityName = null,
                subLocality = null,
                countryCode = "US",
                adminArea = "California",
                subAdminArea = null,
            ),
        )
    }
}
