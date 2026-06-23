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
    }
}
