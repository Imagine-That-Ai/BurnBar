package com.openburnbar.irohrelay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.Base64

class IrohPairingReplayGuardTest {
    @Test
    fun rejectsPresentingTheSameRecordTwiceInsideFreshnessWindow() {
        val guard = IrohPairingReplayGuard()
        val now = System.currentTimeMillis()
        val record =
            IrohPairingRecord(
                uid = "uid-1",
                connectionId = "conn-1",
                nodeId = "node-1",
                publishedAtMillis = now,
                signature = Base64.getEncoder().encodeToString(ByteArray(64) { 0x22 }),
            )

        guard.consume(record, now)
        assertThrows(IrohPairingReplayException::class.java) {
            guard.consume(record, now + 30_000)
        }
    }

    @Test
    fun allowsFreshHeartbeatWithNewSignature() {
        val guard = IrohPairingReplayGuard()
        val now = System.currentTimeMillis()
        val first =
            IrohPairingRecord(
                uid = "uid-1",
                connectionId = "conn-1",
                nodeId = "node-1",
                publishedAtMillis = now,
                signature = Base64.getEncoder().encodeToString(ByteArray(64) { 0x22 }),
            )
        val second =
            first.copy(
                publishedAtMillis = now + 60_000,
                signature = Base64.getEncoder().encodeToString(ByteArray(64) { 0x33 }),
            )

        guard.consume(first, now)
        guard.consume(second, now + 60_000)
    }
}