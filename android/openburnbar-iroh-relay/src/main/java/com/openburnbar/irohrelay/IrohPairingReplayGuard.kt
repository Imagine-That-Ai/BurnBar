package com.openburnbar.irohrelay

import java.util.concurrent.ConcurrentHashMap

class IrohPairingReplayException : RuntimeException("pairing record replayed")

class IrohPairingReplayGuard {
    private val consumedAtMillis = ConcurrentHashMap<String, Long>()

    fun consume(
        record: IrohPairingRecord,
        nowMillis: Long = System.currentTimeMillis(),
    ) {
        pruneExpired(nowMillis)
        val key = "${record.uid}|${record.connectionId}|${record.signature}"
        if (consumedAtMillis.putIfAbsent(key, nowMillis) != null) {
            throw IrohPairingReplayException()
        }
    }

    private fun pruneExpired(nowMillis: Long) {
        val cutoff = nowMillis - IrohPairingFreshness.MAXIMUM_AGE_MILLIS
        val iterator = consumedAtMillis.entries.iterator()
        while (iterator.hasNext()) {
            if (iterator.next().value < cutoff) {
                iterator.remove()
            }
        }
    }
}

object IrohPairingReplayGuardShared {
    val session = IrohPairingReplayGuard()
}