package com.openburnbar.ui.share

import com.openburnbar.ui.share.BurnbarShareInboxProcessor.UploadOnceResult
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BurnbarShareInboxProcessorTest {
    private fun tempInbox(): File {
        val root = File.createTempFile("share-inbox", "")
        root.delete()
        root.mkdirs()
        return root
    }

    @Test
    fun processPendingConsumesAfterSuccessAndDoesNotRebegin() = runBlocking {
        val root = tempInbox()
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
    fun twoStartsWithLockBeginOnce() = runBlocking {
        val root = tempInbox()
        val file = File(root, "share.bin")
        file.writeText("inbox")
        var begins = 0
        assertTrue(BurnbarShareInboxProcessor.tryAcquireUploadLock(file))
        val locked =
            BurnbarShareInboxProcessor.uploadOnce(file, "android-1") { _, _ -> begins += 1 }
        assertEquals(UploadOnceResult.LockedFresh, locked)
        assertEquals(0, begins)
        BurnbarShareInboxProcessor.releaseUploadLock(file)
        val first =
            BurnbarShareInboxProcessor.uploadOnce(file, "android-1") { _, _ -> begins += 1 }
        assertEquals(UploadOnceResult.Uploaded, first)
        assertEquals(1, begins)
        val second =
            BurnbarShareInboxProcessor.uploadOnce(file, "android-1") { _, _ -> begins += 1 }
        assertEquals(UploadOnceResult.Missing, second)
        assertEquals(1, begins)
    }

    @Test
    fun staleUploadingLockIsStolenAndUploads() = runBlocking {
        val root = tempInbox()
        val file = File(root, "share.bin")
        file.writeText("inbox")
        val lock = BurnbarShareInboxProcessor.lockFile(file)
        assertTrue(lock.createNewFile())
        val now = System.currentTimeMillis()
        assertTrue(lock.setLastModified(now - BurnbarShareInboxProcessor.STALE_LOCK_MS - 1_000L))
        var begins = 0
        val outcome =
            BurnbarShareInboxProcessor.uploadOnce(
                file = file,
                deviceId = "android-1",
                nowMs = now,
            ) { _, _ -> begins += 1 }
        assertEquals(UploadOnceResult.Uploaded, outcome)
        assertEquals(1, begins)
        assertFalse(file.exists())
        assertFalse(lock.exists())
    }

    @Test
    fun uniqueWorkerForceStealsLeftoverLock() = runBlocking {
        val root = tempInbox()
        val file = File(root, "share.bin")
        file.writeText("inbox")
        val lock = BurnbarShareInboxProcessor.lockFile(file)
        assertTrue(lock.createNewFile())
        var begins = 0
        val outcome =
            BurnbarShareInboxProcessor.uploadOnce(
                file = file,
                deviceId = "android-1",
                forceSteal = true,
            ) { _, _ -> begins += 1 }
        assertEquals(UploadOnceResult.Uploaded, outcome)
        assertEquals(1, begins)
        assertFalse(file.exists())
    }

    @Test
    fun traversalFilenameStaysInsideInbox() {
        val root = tempInbox()
        val dest = BurnbarShareInboxProcessor.containedDest(root, "../passwd", timestampMillis = 1)
        assertTrue(BurnbarShareInboxProcessor.isContained(dest, root))
        assertEquals("passwd", dest.name.substringAfter("-"))
        assertFalse(dest.canonicalPath.contains(".."))
        val slash = BurnbarShareInboxProcessor.containedDest(root, "/etc/passwd", timestampMillis = 2)
        assertTrue(BurnbarShareInboxProcessor.isContained(slash, root))
        assertEquals("passwd", slash.name.substringAfter("-"))
    }

    @Test
    fun uniqueWorkNameIsStableForSamePath() {
        val root = tempInbox()
        val file = File(root, "share.bin")
        file.writeText("x")
        assertEquals(
            BurnbarShareInboxProcessor.uniqueWorkName(file),
            BurnbarShareInboxProcessor.uniqueWorkName(file),
        )
    }

}
