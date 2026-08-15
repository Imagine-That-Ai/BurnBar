package com.openburnbar.ui.store

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MemoryBoostWalletCopyTest {
    @Test
    fun formatsSpendableAndPendingBalances() {
        val lines =
            memoryBoostWalletLines(
                MemoryBoostWalletUi(
                    textTokens = 1_000_000,
                    visionTokens = 0,
                    pendingTextTokens = 0,
                    pendingVisionTokens = 1_000_000,
                ),
            )
        assertTrue(lines[0].contains("1,000,000") || lines[0].contains("1000000"))
        assertTrue(lines.any { it.startsWith("Waiting:") })
        assertTrue(lines.any { it.contains("12 months") })
    }

    @Test
    fun surfacesALoadFailureInsteadOfAZeroWallet() {
        val lines = memoryBoostWalletLines(MemoryBoostWalletUi(loadFailed = true))
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("Could not load"))
    }
}
