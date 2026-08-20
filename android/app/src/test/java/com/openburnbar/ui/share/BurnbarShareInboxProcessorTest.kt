package com.openburnbar.ui.share

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BurnbarShareInboxProcessorTest {
    @Test
    fun processPendingConsumesAfterSuccessAndDoesNotRebegin() = runBlocking {
        val root = File.createTempFile("share-inbox", "").let {
            it.delete()
            it.mkdirs()
            it
        }
        val file = File(root, "share.bin")
        file.writeText("inbox")
        var begins = 0
        BurnbarShareInboxProcessor.processPending(root, "android-1") { _, _ -> begins += 1 }
        assertEquals(1, begins)
        assertFalse(file.exists())
        BurnbarShareInboxProcessor.processPending(root, "android-1") { _, _ -> begins += 1 }
        assertEquals(1, begins)
    }

    @Test
    fun processPendingConsumesPermanentFailures() = runBlocking {
        val root = File.createTempFile("share-inbox-fail", "").let {
            it.delete()
            it.mkdirs()
            it
        }
        val file = File(root, "gone.bin")
        file.writeText("x")
        BurnbarShareInboxProcessor.processPending(root, "android-1") { _, _ ->
            error("attachment file is missing")
        }
        assertFalse(file.exists())
    }
}
