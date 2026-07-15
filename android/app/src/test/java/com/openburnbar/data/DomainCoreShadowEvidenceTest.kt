package com.openburnbar.data

import com.openburnbar.data.cloud.CloudVaultShadowComparison
import com.openburnbar.data.hermes.relay.HermesShadowComparison
import io.mockk.every
import io.mockk.mockkObject
import io.mockk.unmockkObject
import java.nio.file.Files
import kotlinx.coroutines.Job
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
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

    @Test
    fun `spool rejects invalid bounds and samples larger than one durable file`() {
        val directory = Files.createTempDirectory("domain-core-shadow-bounds").toFile()
        try {
            assertThrows(IllegalArgumentException::class.java) {
                AndroidDomainCoreShadowSpool(directory, maxFileBytes = 0)
            }
            assertThrows(IllegalArgumentException::class.java) {
                AndroidDomainCoreShadowSpool(directory, maxReadyFiles = 0)
            }
            assertThrows(IllegalArgumentException::class.java) {
                AndroidDomainCoreShadowSpool(directory, maxSamplesPerFile = 0)
            }

            val spool = AndroidDomainCoreShadowSpool(directory, maxFileBytes = 32)
            assertThrows(IllegalArgumentException::class.java) {
                spool.append(sample())
            }
            assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `ready file retention drops oldest evidence without disturbing newest batches`() {
        val directory = Files.createTempDirectory("domain-core-shadow-retention").toFile()
        try {
            val spool = AndroidDomainCoreShadowSpool(
                directory,
                maxReadyFiles = 2,
                maxSamplesPerFile = 1,
            )
            val ids = (1..3).map { "00000000-0000-4000-8000-${it.toString().padStart(12, '0')}" }
            ids.forEach { spool.append(sample(sampleId = it)) }

            val retained = buildList {
                while (true) {
                    val batch = spool.nextBatch(sealActive = true, expectedChannel = "internal") ?: break
                    add(batch.samples.single()["sampleId"])
                    spool.acknowledge(batch)
                }
            }

            assertEquals(ids.drop(1), retained)
            assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `batch reader quarantines malformed empty and mixed-channel files`() {
        val directory = Files.createTempDirectory("domain-core-shadow-quarantine").toFile()
        try {
            directory.resolve(readyName(1, "malformed")).writeText("{not-json}\n")
            directory.resolve(readyName(2, "empty")).writeText("\n")
            directory.resolve(readyName(3, "mixed")).writeText(
                listOf(
                    JSONObject(sample(channel = "internal").toMap()).toString(),
                    JSONObject(
                        sample(
                            channel = "beta",
                            sampleId = "00000000-0000-4000-8000-000000000002",
                        ).toMap(),
                    ).toString(),
                ).joinToString(separator = "\n", postfix = "\n"),
            )
            directory.resolve(readyName(4, "valid")).writeText(
                JSONObject(
                    sample(sampleId = "00000000-0000-4000-8000-000000000004").toMap() +
                        ("metadata" to mapOf("authority" to "signed")),
                ).toString() + "\n",
            )

            val spool = AndroidDomainCoreShadowSpool(directory)
            val batch = requireNotNull(spool.nextBatch(sealActive = false, expectedChannel = "internal"))

            assertEquals("00000000-0000-4000-8000-000000000004", batch.samples.single()["sampleId"])
            assertEquals(mapOf("authority" to "signed"), batch.samples.single()["metadata"])
            assertEquals(listOf(batch.file.name), directory.listFiles().orEmpty().map { it.name })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `acknowledgement accepts only ready batches owned by the spool directory`() {
        val directory = Files.createTempDirectory("domain-core-shadow-ack").toFile()
        val foreignDirectory = Files.createTempDirectory("domain-core-shadow-foreign").toFile()
        try {
            val spool = AndroidDomainCoreShadowSpool(directory)
            val foreign = foreignDirectory.resolve(readyName(1, "foreign")).apply { writeText("{}\n") }
            val wrongName = directory.resolve("active-copy.jsonl").apply { writeText("{}\n") }

            assertThrows(IllegalStateException::class.java) {
                spool.acknowledge(AndroidDomainCoreShadowSpool.Batch(foreign, emptyList()))
            }
            assertThrows(IllegalStateException::class.java) {
                spool.acknowledge(AndroidDomainCoreShadowSpool.Batch(wrongName, emptyList()))
            }
            assertTrue(foreign.exists())
            assertTrue(wrongName.exists())

            spool.discardAll()
            assertFalse(directory.resolve("active.jsonl").exists())
        } finally {
            directory.deleteRecursively()
            foreignDirectory.deleteRecursively()
        }
    }

    @Test
    fun `installed collector persists only promotion-safe cloudvault and hermes comparisons`() {
        val directory = Files.createTempDirectory("domain-core-shadow-collector").toFile()
        val activeFlush = Job()
        mockkObject(DomainCoreBuildProfile)
        every { DomainCoreBuildProfile.evidenceChannel() } returns DomainCoreEvidenceChannel.INTERNAL
        try {
            val spool = AndroidDomainCoreShadowSpool(directory)
            setEvidenceField("spool", spool)
            setEvidenceField("installedChannel", DomainCoreEvidenceChannel.INTERNAL)
            setEvidenceField("flushJob", activeFlush)

            invokeRecord(
                CloudVaultShadowComparison(
                    slice = "aes",
                    operation = "aes_open",
                    coreVersion = "1.2.3-beta.1",
                    outcome = "match",
                    mismatchCategory = null,
                    legacyMicros = 600_000_000,
                    rustMicros = 0,
                ),
            )
            invokeRecord(
                HermesShadowComparison(
                    slice = "hpke-info",
                    operation = "hpke_v3_info",
                    coreVersion = "1.2.3",
                    outcome = "mismatch",
                    mismatchCategory = "native_error",
                    legacyMicros = 12,
                    rustMicros = 8,
                ),
            )

            listOf(
                comparison(slice = "unknown"),
                comparison(operation = "INVALID OP"),
                comparison(coreVersion = "not-semver"),
                comparison(mismatchCategory = "native_error"),
                comparison(outcome = "mismatch"),
                comparison(outcome = "mismatch", mismatchCategory = "secret_detail"),
                comparison(outcome = "unknown", mismatchCategory = "native_error"),
                comparison(legacyMicros = -1),
                comparison(rustMicros = 600_000_001),
            ).forEach(::invokeRecord)

            val batch = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "internal"))
            assertEquals(2, batch.samples.size)
            assertEquals(listOf("cloudvault", "hermes"), batch.samples.map { it["domain"] })
            assertEquals(listOf("match", "mismatch"), batch.samples.map { it["outcome"] })
            assertEquals(listOf(null, "native_error"), batch.samples.map { it["mismatchCategory"] })
            assertTrue(batch.samples.all { it["channel"] == "internal" && it["consumer"] == "android" })
        } finally {
            activeFlush.cancel()
            setEvidenceField("spool", null)
            setEvidenceField("installedChannel", null)
            setEvidenceField("flushJob", null)
            unmockkObject(DomainCoreBuildProfile)
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

    private fun readyName(ordinal: Int, suffix: String): String = "ready-${ordinal.toString().padStart(19, '0')}-$suffix.jsonl"

    private fun invokeRecord(comparison: CloudVaultShadowComparison) {
        val method = AndroidDomainCoreShadowEvidence::class.java.getDeclaredMethod(
            "record",
            CloudVaultShadowComparison::class.java,
        )
        method.isAccessible = true
        method.invoke(AndroidDomainCoreShadowEvidence, comparison)
    }

    private fun invokeRecord(comparison: HermesShadowComparison) {
        val method = AndroidDomainCoreShadowEvidence::class.java.getDeclaredMethod(
            "record",
            HermesShadowComparison::class.java,
        )
        method.isAccessible = true
        method.invoke(AndroidDomainCoreShadowEvidence, comparison)
    }

    private fun setEvidenceField(name: String, value: Any?) {
        val field = AndroidDomainCoreShadowEvidence::class.java.getDeclaredField(name)
        field.isAccessible = true
        field.set(AndroidDomainCoreShadowEvidence, value)
    }

    private fun comparison(
        slice: String = "aes",
        operation: String = "aes_open",
        coreVersion: String = "1.2.3",
        outcome: String = "match",
        mismatchCategory: String? = null,
        legacyMicros: Long = 1,
        rustMicros: Long = 1,
    ) = CloudVaultShadowComparison(
        slice = slice,
        operation = operation,
        coreVersion = coreVersion,
        outcome = outcome,
        mismatchCategory = mismatchCategory,
        legacyMicros = legacyMicros,
        rustMicros = rustMicros,
    )
}
