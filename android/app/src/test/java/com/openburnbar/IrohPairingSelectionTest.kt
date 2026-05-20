package com.openburnbar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IrohPairingSelectionTest {
    @Test
    fun newestCandidatesPicksFreshestPublishedPairingRecord() {
        val selected = IrohPairingSelection.newestCandidates(
            listOf(
                IrohPairingSelection.Candidate("mac-old", 1_700_000_000_000),
                IrohPairingSelection.Candidate("mac-new", 1_800_000_000_000),
                IrohPairingSelection.Candidate("mac-middle", 1_750_000_000_000),
            )
        )

        assertEquals("mac-new", selected?.connectionId)
        assertEquals(1_800_000_000_000, selected?.publishedAtMillis)
    }

    @Test
    fun newestCandidatesIgnoresBlankConnectionIds() {
        val selected = IrohPairingSelection.newestCandidates(
            listOf(
                IrohPairingSelection.Candidate("   ", 1_900_000_000_000),
                IrohPairingSelection.Candidate("mac-live", 1_800_000_000_000),
            )
        )

        assertEquals("mac-live", selected?.connectionId)
    }

    @Test
    fun newestCandidatesReturnsNullWhenNoUsablePairingRecordExists() {
        assertNull(IrohPairingSelection.newestCandidates(emptyList()))
        assertNull(IrohPairingSelection.newestCandidates(listOf(IrohPairingSelection.Candidate("", 1))))
    }
}
