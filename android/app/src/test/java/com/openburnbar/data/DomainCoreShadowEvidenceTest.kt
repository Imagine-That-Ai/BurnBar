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

            val first = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "internal"))
            val retry = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "internal"))
            assertEquals(first.file.name, retry.file.name)
            assertEquals(first.samples, retry.samples)

            spool.acknowledge(retry)
            assertEquals(null, spool.nextBatch(sealActive = true, expectedChannel = "internal"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `stale mismatched channel is discarded without leaking or wedging`() {
        val directory = Files.createTempDirectory("domain-core-shadow-channel").toFile()
        try {
            val spool = AndroidDomainCoreShadowSpool(directory, maxSamplesPerFile = 1)
            spool.append(sample(channel = "internal"))
            spool.append(sample(channel = "beta", sampleId = "00000000-0000-4000-8000-000000000002"))

            val batch = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "beta"))
            assertEquals(1, batch.samples.size)
            assertEquals("beta", batch.samples.single()["channel"])
            spool.acknowledge(batch)
            assertEquals(null, spool.nextBatch(sealActive = true, expectedChannel = "beta"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `channel preparation drops stale active samples before new collection`() {
        val directory = Files.createTempDirectory("domain-core-shadow-prepare").toFile()
        try {
            val spool = AndroidDomainCoreShadowSpool(directory)
            spool.append(sample(channel = "internal"))

            spool.prepareForChannel("beta")
            spool.append(sample(channel = "beta", sampleId = "00000000-0000-4000-8000-000000000002"))

            val batch = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "beta"))
            assertEquals(listOf("beta"), batch.samples.map { it["channel"] })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `disabled profile cleanup discards active and ready samples`() {
        val directory = Files.createTempDirectory("domain-core-shadow-disabled").toFile()
        try {
            val spool = AndroidDomainCoreShadowSpool(directory, maxSamplesPerFile = 1)
            spool.append(sample(channel = "internal"))
            spool.append(sample(channel = "beta", sampleId = "00000000-0000-4000-8000-000000000002"))

            spool.discardAll()

            assertEquals(null, spool.nextBatch(sealActive = true, expectedChannel = "internal"))
            assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun sample(channel: String = "internal", sampleId: String = "00000000-0000-4000-8000-000000000001") = AndroidDomainCoreShadowSampleV2(
        sampleId = sampleId,
        domain = "cloudvault",
        slice = "aes",
        channel = channel,
        operation = "cloudvault_aes_open",
        coreVersion = "0.1.0",
        outcome = "match",
        mismatchCategory = null,
        legacyMicros = 12,
        rustMicros = 8,
    )
}
