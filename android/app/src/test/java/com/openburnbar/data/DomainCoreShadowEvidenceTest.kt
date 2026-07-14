package com.openburnbar.data

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DomainCoreShadowEvidenceTest {
    @Test
    fun `v2 sample map is exact and preserves explicit null mismatch category`() {
        val sample = sample().toMap()

        assertEquals(
            setOf(
                "schemaVersion", "sampleId", "domain", "slice", "consumer", "channel",
                "operation", "coreVersion", "observedAt", "outcome", "mismatchCategory",
                "legacyMicros", "rustMicros",
            ),
            sample.keys,
        )
        assertEquals(2, sample["schemaVersion"])
        assertEquals("android", sample["consumer"])
        assertTrue(sample.containsKey("mismatchCategory"))
        assertEquals(null, sample["mismatchCategory"])
    }

    @Test
    fun `durable batch is stable until acknowledged`() {
        val directory = Files.createTempDirectory("domain-core-shadow").toFile()
        try {
            val spool = AndroidDomainCoreShadowSpool(directory, maxSamplesPerFile = 1)
            spool.append(sample())

            val first = requireNotNull(spool.nextBatch(sealActive = true))
            val retry = requireNotNull(spool.nextBatch(sealActive = true))
            assertEquals(first.file.name, retry.file.name)
            assertEquals(first.samples, retry.samples)

            spool.acknowledge(retry)
            assertEquals(null, spool.nextBatch(sealActive = true))
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun sample() = AndroidDomainCoreShadowSampleV2(
        sampleId = "00000000-0000-4000-8000-000000000001",
        domain = "cloudvault",
        slice = "aes",
        channel = "internal",
        operation = "cloudvault_aes_open",
        coreVersion = "0.1.0",
        outcome = "match",
        mismatchCategory = null,
        legacyMicros = 12,
        rustMicros = 8,
    )
}
