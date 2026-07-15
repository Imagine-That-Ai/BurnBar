package com.openburnbar.data

import android.content.Context
import com.openburnbar.data.cloud.CloudVaultDocumentRewrapDomainCore
import com.openburnbar.data.cloud.CloudVaultDomainCore
import com.openburnbar.data.cloud.CloudVaultSearchDomainCore
import com.openburnbar.data.cloud.CloudVaultShadowComparison
import com.openburnbar.data.hermes.relay.HermesDomainCoreAdapter
import com.openburnbar.data.hermes.relay.HermesShadowComparison
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import java.math.BigDecimal
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import java.time.Duration
import java.time.Instant
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DomainCoreShadowEvidenceTest {
    @Test
    fun `v3 sample map is exact and preserves explicit null mismatch category`() {
        val sample = sample().toMap()

        assertEquals(
            setOf(
                "schemaVersion", "sampleId", "domain", "slice", "consumer", "channel",
                "operation", "candidateCommit", "expectedCoreVersion", "expectedCoreAbiVersion",
                "expectedCoreSourceSha256", "loadedCoreVersion", "loadedCoreAbiVersion",
                "loadedCoreSourceSha256", "observedAt", "outcome", "mismatchCategory",
                "legacyMicros", "rustMicros",
            ),
            sample.keys,
        )
        assertEquals(3, sample["schemaVersion"])
        assertEquals(candidate.candidateCommit, sample["candidateCommit"])
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

            val first = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "internal", expectedCandidate = candidate))
            val retry = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "internal", expectedCandidate = candidate))
            assertEquals(first.file.name, retry.file.name)
            assertEquals(first.samples, retry.samples)

            spool.acknowledge(retry)
            assertEquals(null, spool.nextBatch(sealActive = true, expectedChannel = "internal", expectedCandidate = candidate))
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

            val batch = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "beta", expectedCandidate = candidate))
            assertEquals(1, batch.samples.size)
            assertEquals("beta", batch.samples.single()["channel"])
            spool.acknowledge(batch)
            assertEquals(null, spool.nextBatch(sealActive = true, expectedChannel = "beta", expectedCandidate = candidate))
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

            spool.prepareForCandidate("beta", candidate)
            spool.append(sample(channel = "beta", sampleId = "00000000-0000-4000-8000-000000000002"))

            val batch = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "beta", expectedCandidate = candidate))
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

            assertEquals(null, spool.nextBatch(sealActive = true, expectedChannel = "internal", expectedCandidate = candidate))
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
                    val batch = spool.nextBatch(sealActive = true, expectedChannel = "internal", expectedCandidate = candidate) ?: break
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
    fun `batch reader discards malformed partial and wrong-channel files`() {
        val directory = Files.createTempDirectory("domain-core-shadow-quarantine").toFile()
        try {
            directory.resolve(readyName(1, "malformed")).writeText("{not-json}\n")
            directory.resolve(readyName(2, "empty")).writeText("\n")
            directory.resolve(readyName(3, "mixed")).writeText(
                listOf(
                    sample(channel = "beta").toMap().toExactJSONObject().toString(),
                    sample(
                        channel = "beta",
                        sampleId = "00000000-0000-4000-8000-000000000002",
                    ).toMap().toExactJSONObject().toString(),
                ).joinToString(separator = "\n", postfix = "\n"),
            )
            directory.resolve(readyName(4, "partial")).writeText(
                (sample().toMap() + ("loadedCoreAbiVersion" to null)).toExactJSONObject().toString() + "\n",
            )
            directory.resolve(readyName(5, "valid")).writeText(
                sample(sampleId = "00000000-0000-4000-8000-000000000005").toMap().toExactJSONObject().toString() + "\n",
            )

            val spool = AndroidDomainCoreShadowSpool(directory)
            val batch = requireNotNull(spool.nextBatch(sealActive = false, expectedChannel = "internal", expectedCandidate = candidate))

            assertEquals("00000000-0000-4000-8000-000000000005", batch.samples.single()["sampleId"])
            assertEquals(listOf(batch.file.name), directory.listFiles().orEmpty().map { it.name })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `expired and future head files cannot block fresh later batch`() {
        val directory = Files.createTempDirectory("domain-core-shadow-expiry").toFile()
        val now = Instant.now().truncatedTo(ChronoUnit.MILLIS)
        try {
            val spool = AndroidDomainCoreShadowSpool(directory)
            spool.append(
                sample(
                    sampleId = "00000000-0000-4000-8000-000000000001",
                    observedAt = now.minus(Duration.ofDays(31)).minusMillis(1).toString(),
                ),
            )
            spool.append(
                sample(
                    sampleId = "00000000-0000-4000-8000-000000000002",
                    observedAt = now.plus(Duration.ofMinutes(5)).plusMillis(1).toString(),
                ),
            )
            spool.append(
                sample(
                    sampleId = "00000000-0000-4000-8000-000000000003",
                    observedAt = now.toString(),
                ),
            )

            val batch = requireNotNull(spool.nextBatch(true, "internal", candidate, now))

            assertEquals("00000000-0000-4000-8000-000000000003", batch.samples.single()["sampleId"])
            assertEquals(listOf(batch.file.name), directory.listFiles().orEmpty().map { it.name })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `transient ready file read failure is retained for retry`() {
        val directory = Files.createTempDirectory("domain-core-shadow-read-retry").toFile()
        val ready = directory.resolve(readyName(1, "unreadable"))
        try {
            ready.writeText(sample().toMap().toExactJSONObject().toString() + "\n")
            Files.setPosixFilePermissions(ready.toPath(), emptySet<PosixFilePermission>())
            val spool = AndroidDomainCoreShadowSpool(directory)

            assertThrows(Exception::class.java) {
                spool.nextBatch(false, "internal", candidate)
            }
            assertTrue(ready.exists())

            Files.setPosixFilePermissions(
                ready.toPath(),
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            )
            assertEquals(sample().sampleId, requireNotNull(spool.nextBatch(false, "internal", candidate)).samples.single()["sampleId"])
        } finally {
            runCatching {
                Files.setPosixFilePermissions(
                    ready.toPath(),
                    setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                )
            }
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
    fun `acknowledgement rejects negative fractional overbound and wrong sum counts`() {
        assertTrue(
            AndroidDomainCoreShadowEvidence.validAcknowledgement(
                mapOf("accepted" to 1L, "duplicates" to 0L),
                batchSize = 1,
            ),
        )
        listOf(
            mapOf("accepted" to -1L, "duplicates" to 2L),
            mapOf("accepted" to 0.5, "duplicates" to 0.5),
            mapOf("accepted" to BigDecimal("0.999999999999999999999"), "duplicates" to 0L),
            mapOf("accepted" to 2L, "duplicates" to 0L),
            mapOf("accepted" to 0L, "duplicates" to 0L),
        ).forEach { response ->
            assertFalse(AndroidDomainCoreShadowEvidence.validAcknowledgement(response, batchSize = 1))
        }
    }

    @Test
    fun `installed collector persists only promotion-safe cloudvault and hermes comparisons`() {
        val directory = Files.createTempDirectory("domain-core-shadow-collector").toFile()
        val activeFlush = Job()
        mockkObject(DomainCoreBuildProfile)
        every { DomainCoreBuildProfile.runtimeProfile() } returns signedProfile
        try {
            val spool = AndroidDomainCoreShadowSpool(directory)
            setEvidenceField("spool", spool)
            setEvidenceField("installedChannel", DomainCoreEvidenceChannel.INTERNAL)
            setEvidenceField("installedCandidate", candidate)
            setEvidenceField("flushJob", activeFlush)
            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = { loadedIdentity }

            invokeRecord(
                CloudVaultShadowComparison(
                    slice = "aes",
                    operation = "aes_open_combined",
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
                comparison(mismatchCategory = "native_error"),
                comparison(outcome = "mismatch"),
                comparison(outcome = "mismatch", mismatchCategory = "secret_detail"),
                comparison(outcome = "unknown", mismatchCategory = "native_error"),
                comparison(legacyMicros = -1),
                comparison(rustMicros = 600_000_001),
            ).forEach(::invokeRecord)

            val batch = requireNotNull(spool.nextBatch(sealActive = true, expectedChannel = "internal", expectedCandidate = candidate))
            assertEquals(2, batch.samples.size)
            assertEquals(listOf("cloudvault", "hermes"), batch.samples.map { it["domain"] })
            assertEquals(listOf("match", "mismatch"), batch.samples.map { it["outcome"] })
            assertEquals(listOf(null, "native_error"), batch.samples.map { it["mismatchCategory"] })
            assertTrue(batch.samples.all { it["channel"] == "internal" && it["consumer"] == "android" })
        } finally {
            activeFlush.cancel()
            setEvidenceField("spool", null)
            setEvidenceField("installedChannel", null)
            setEvidenceField("installedCandidate", null)
            setEvidenceField("flushJob", null)
            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = null
            unmockkObject(DomainCoreBuildProfile)
            directory.deleteRecursively()
        }
    }

    @Test
    fun `collector relabels loaded mismatch and normalizes missing identity to native unavailable`() {
        val directory = Files.createTempDirectory("domain-core-shadow-identity").toFile()
        val activeFlush = Job()
        mockkObject(DomainCoreBuildProfile)
        every { DomainCoreBuildProfile.runtimeProfile() } returns signedProfile
        try {
            val spool = AndroidDomainCoreShadowSpool(directory)
            setEvidenceField("spool", spool)
            setEvidenceField("installedChannel", DomainCoreEvidenceChannel.INTERNAL)
            setEvidenceField("installedCandidate", candidate)
            setEvidenceField("flushJob", activeFlush)

            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = {
                loadedIdentity.copy(coreVersion = "0.3.1")
            }
            invokeRecord(comparison())
            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = { loadedIdentity }
            invokeRecord(comparison(outcome = "mismatch", mismatchCategory = "native_unavailable"))
            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = {
                loadedIdentity.copy(abiVersion = 4)
            }
            invokeRecord(comparison(outcome = "mismatch", mismatchCategory = "native_unavailable"))
            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = { null }
            invokeRecord(comparison(outcome = "mismatch", mismatchCategory = "native_error"))

            val batch = requireNotNull(
                spool.nextBatch(true, DomainCoreEvidenceChannel.INTERNAL.wireValue, candidate),
            )
            assertEquals(
                listOf(
                    "loaded_identity_mismatch",
                    "native_error",
                    "loaded_identity_mismatch",
                    "native_unavailable",
                ),
                batch.samples.map { it["mismatchCategory"] },
            )
            assertEquals("0.3.1", batch.samples[0]["loadedCoreVersion"])
            assertEquals(3L, (batch.samples[1]["loadedCoreAbiVersion"] as Number).toLong())
            assertEquals(4L, (batch.samples[2]["loadedCoreAbiVersion"] as Number).toLong())
            assertEquals(null, batch.samples[3]["loadedCoreVersion"])
            assertEquals(null, batch.samples[3]["loadedCoreAbiVersion"])
            assertEquals(null, batch.samples[3]["loadedCoreSourceSha256"])
        } finally {
            activeFlush.cancel()
            setEvidenceField("spool", null)
            setEvidenceField("installedChannel", null)
            setEvidenceField("installedCandidate", null)
            setEvidenceField("flushJob", null)
            AndroidDomainCoreShadowEvidence.loadedIdentityOverride = null
            unmockkObject(DomainCoreBuildProfile)
            directory.deleteRecursively()
        }
    }

    @Test
    fun `candidate scoped spool never reads a prior candidate directory`() {
        val root = Files.createTempDirectory("domain-core-shadow-candidates").toFile()
        val priorCandidate = candidate.copy(candidateCommit = "c".repeat(40))
        try {
            val priorSpool = AndroidDomainCoreShadowSpool(root.resolve("prior"), maxSamplesPerFile = 1)
            priorSpool.append(sample(candidate = priorCandidate))
            val activeSpool = AndroidDomainCoreShadowSpool(root.resolve("active"), maxSamplesPerFile = 1)
            activeSpool.append(sample())

            val batch = requireNotNull(activeSpool.nextBatch(true, "internal", candidate))
            assertEquals(listOf(candidate.candidateCommit), batch.samples.map { it["candidateCommit"] })
            assertTrue(priorSpool.nextBatch(true, "internal", priorCandidate) != null)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `startup deletes legacy queues and stale candidate namespaces without relabeling`() {
        val root = Files.createTempDirectory("domain-core-shadow-startup").toFile()
        try {
            root.resolve("active.jsonl").writeText("{\"schemaVersion\":2}\n")
            root.resolve("ready-0000000000000000001.jsonl").writeText("{\"schemaVersion\":1}\n")
            root.resolve("v2-old-candidate").mkdirs()
            root.resolve("v3-old-candidate").mkdirs()
            val active = root.resolve(AndroidDomainCoreShadowEvidence.candidateNamespace(candidate))
            active.mkdirs()
            active.resolve("sentinel").writeText("keep")

            val prepared = AndroidDomainCoreShadowEvidence.prepareCandidateDirectory(root, candidate)

            assertEquals(active, prepared)
            assertFalse(root.resolve("active.jsonl").exists())
            assertFalse(root.resolve("ready-0000000000000000001.jsonl").exists())
            assertFalse(root.resolve("v2-old-candidate").exists())
            assertFalse(root.resolve("v3-old-candidate").exists())
            assertTrue(active.resolve("sentinel").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `install disables diagnostic evidence when spool setup fails`() {
        val parent = Files.createTempDirectory("domain-core-shadow-install-failure").toFile()
        val filesDir = parent.resolve("not-a-directory").apply { writeText("occupied") }
        val context = mockk<Context>()
        every { context.filesDir } returns filesDir
        mockkObject(DomainCoreBuildProfile)
        every { DomainCoreBuildProfile.runtimeProfile() } returns signedProfile
        try {
            setEvidenceField("installed", false)
            setEvidenceField("spool", null)
            setEvidenceField("installedChannel", null)
            setEvidenceField("installedCandidate", null)

            AndroidDomainCoreShadowEvidence.install(context, DomainCoreEvidenceChannel.INTERNAL)

            assertEquals(false, evidenceField("installed"))
            assertEquals(null, evidenceField("spool"))
            assertEquals(null, evidenceField("installedChannel"))
            assertEquals(null, evidenceField("installedCandidate"))
            assertEquals(null, CloudVaultDomainCore.comparisonOverride)
            assertEquals(null, CloudVaultDocumentRewrapDomainCore.comparisonOverride)
            assertEquals(null, CloudVaultSearchDomainCore.comparisonOverride)
            assertEquals(null, HermesDomainCoreAdapter.comparisonOverride)
        } finally {
            setEvidenceField("installed", false)
            setEvidenceField("spool", null)
            setEvidenceField("installedChannel", null)
            setEvidenceField("installedCandidate", null)
            unmockkObject(DomainCoreBuildProfile)
            parent.deleteRecursively()
        }
    }

    private fun sample(
        channel: String = "internal",
        sampleId: String = "00000000-0000-4000-8000-000000000001",
        candidate: AndroidDomainCoreCandidateIdentity = this.candidate,
        observedAt: String = Instant.now().truncatedTo(ChronoUnit.MILLIS).toString(),
    ) = AndroidDomainCoreShadowSampleV3(
        sampleId = sampleId,
        domain = "cloudvault",
        slice = "aes",
        channel = channel,
        operation = "cloudvault_aes_open_combined",
        candidateCommit = candidate.candidateCommit,
        expectedCoreVersion = candidate.coreVersion,
        expectedCoreAbiVersion = candidate.abiVersion,
        expectedCoreSourceSha256 = candidate.sourceSha256,
        loadedCoreVersion = candidate.coreVersion,
        loadedCoreAbiVersion = candidate.abiVersion,
        loadedCoreSourceSha256 = candidate.sourceSha256,
        observedAt = observedAt,
        outcome = "match",
        mismatchCategory = null,
        legacyMicros = 12,
        rustMicros = 8,
    )

    private fun readyName(ordinal: Int, suffix: String): String = "ready-${ordinal.toString().padStart(19, '0')}-$suffix.jsonl"

    private val candidate = AndroidDomainCoreCandidateIdentity(
        candidateCommit = "a".repeat(40),
        coreVersion = "0.3.0",
        abiVersion = 3,
        sourceSha256 = "b".repeat(64),
    )
    private val loadedIdentity = AndroidDomainCoreLoadedIdentity(
        coreVersion = candidate.coreVersion,
        abiVersion = candidate.abiVersion,
        sourceSha256 = candidate.sourceSha256,
    )
    private val signedProfile = AndroidDomainCoreRuntimeProfile(
        name = "internal",
        artifactAuthority = DomainCoreArtifactAuthority.SIGNED,
        distribution = "internal",
        evidenceChannel = DomainCoreEvidenceChannel.INTERNAL,
        candidateIdentity = candidate,
        modes = mapOf(
            "quota" to "shadow",
            "cloudVault" to "shadow",
            "cloudVaultRewrap" to "shadow",
            "cloudVaultSearch" to "shadow",
            "hermes" to "shadow",
            "pricing" to "shadow",
        ),
    )

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

    private fun evidenceField(name: String): Any? {
        val field = AndroidDomainCoreShadowEvidence::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(AndroidDomainCoreShadowEvidence)
    }

    private fun comparison(
        slice: String = "aes",
        operation: String = "aes_open_combined",
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
