package com.openburnbar.data.firebase

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FirestoreQuotaBucketParserTest {
    @Test
    fun parseRejectsMapsWithoutANameOrValues() {
        assertNull(emptyMap<String, Any>().toQuotaBucket())
        assertNull(mapOf("used" to 1, "limit" to 10).toQuotaBucket())
        assertNull(mapOf("name" to "requests").toQuotaBucket())
    }

    @Test
    fun parseMapsUsedLimitAndName() {
        val bucket = mapOf(
            "name" to "requests",
            "used" to 3,
            "limit" to 10,
            "window" to "day",
        ).toQuotaBucket()

        requireNotNull(bucket)
        assertEquals("requests", bucket.name)
        assertEquals(3.0, bucket.used, 0.0)
        assertEquals(10.0, bucket.limit, 0.0)
        assertEquals("day", bucket.window)
    }

    @Test
    fun parseMergesUnitLabelAndPercentIntoMeta() {
        val bucket = mapOf(
            "label" to "Requests",
            "unit" to "count",
            "used" to 2,
            "limit" to 8,
            "usedPercent" to "25%",
            "isEstimated" to true,
        ).toQuotaBucket()

        requireNotNull(bucket)
        assertEquals("Requests", bucket.name)
        assertEquals("count", bucket.meta?.get("unit"))
        assertEquals("Requests", bucket.meta?.get("label"))
        assertEquals(25.0, bucket.meta?.get("usedPercent"))
        assertEquals("true", bucket.meta?.get("isEstimated"))
    }
}
