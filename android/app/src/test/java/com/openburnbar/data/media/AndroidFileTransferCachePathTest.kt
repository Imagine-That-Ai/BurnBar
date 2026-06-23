package com.openburnbar.data.media

import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AndroidFileTransferCachePathTest {
    private lateinit var tempRoot: File
    private lateinit var cacheRoot: File

    @Before
    fun setUp() {
        tempRoot = createTempDirectory("mercury-cache-path").toFile()
        cacheRoot = File(tempRoot, "outbox").also { it.mkdirs() }
    }

    @After
    fun tearDown() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun targetFileCollapsesProviderDisplayNameToDirectCacheChild() {
        val target = AndroidFileTransferCachePath.targetFile(
            cacheRoot = cacheRoot,
            displayName = "../outside/../../secret\\avatar.png",
        )

        assertEquals(cacheRoot.canonicalFile, target.parentFile?.canonicalFile)
        assertFalse(target.name.contains('/'))
        assertFalse(target.name.contains('\\'))
        assertFalse(target.name.contains(".."))
        assertTrue(target.name.endsWith(".png"))
    }

    @Test
    fun safeDisplayNameFallsBackWhenProviderOnlySuppliesUnsafeSegments() {
        val target = AndroidFileTransferCachePath.targetFile(
            cacheRoot = cacheRoot,
            displayName = "../../..",
        )

        assertEquals(cacheRoot.canonicalFile, target.parentFile?.canonicalFile)
        assertEquals("attachment", target.name)
    }

    @Test
    fun safeDisplayNameBoundsProviderControlledLength() {
        val safeName = AndroidFileTransferCachePath.safeDisplayName("a".repeat(200) + ".jpg")

        assertEquals(96, safeName.length)
        assertTrue(safeName.endsWith(".jpg"))
    }

    @Test
    fun targetFileCanDisambiguateProviderNamesThatSanitizeToTheSameLeaf() {
        val first = AndroidFileTransferCachePath.targetFile(
            cacheRoot = cacheRoot,
            displayName = "a?b.png",
            uniqueSuffix = "first",
        )
        val second = AndroidFileTransferCachePath.targetFile(
            cacheRoot = cacheRoot,
            displayName = "a*b.png",
            uniqueSuffix = "second",
        )

        assertEquals(cacheRoot.canonicalFile, first.parentFile?.canonicalFile)
        assertEquals(cacheRoot.canonicalFile, second.parentFile?.canonicalFile)
        assertEquals("a_b-first.png", first.name)
        assertEquals("a_b-second.png", second.name)
    }

    @Test
    fun safeDisplayNamePlacesUniqueSuffixBeforePreservedExtension() {
        val safeName = AndroidFileTransferCachePath.safeDisplayName(
            displayName = "a".repeat(200) + ".jpg",
            uniqueSuffix = "send-1",
        )

        assertEquals(96, safeName.length)
        assertTrue(safeName.endsWith("-send-1.jpg"))
    }
}
