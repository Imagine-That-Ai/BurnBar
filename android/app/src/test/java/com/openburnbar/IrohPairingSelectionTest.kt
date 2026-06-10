@file:Suppress("MagicNumber")
// detekt: test fixtures use literal wire-format / timeout values.

package com.openburnbar

import com.openburnbar.data.media.MediaControlStreamCoordinator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IrohPairingSelectionTest {
    @Test
    fun newestCandidatesPicksFreshestPublishedPairingRecord() {
        val selected =
            IrohPairingSelection.newestCandidates(
                listOf(
                    IrohPairingSelection.Candidate("mac-old", 1_700_000_000_000),
                    IrohPairingSelection.Candidate("mac-new", 1_800_000_000_000),
                    IrohPairingSelection.Candidate("mac-middle", 1_750_000_000_000),
                ),
            )

        assertEquals("mac-new", selected?.connectionId)
        assertEquals(1_800_000_000_000, selected?.publishedAtMillis)
    }

    @Test
    fun newestCandidatesIgnoresBlankConnectionIds() {
        val selected =
            IrohPairingSelection.newestCandidates(
                listOf(
                    IrohPairingSelection.Candidate("   ", 1_900_000_000_000),
                    IrohPairingSelection.Candidate("mac-live", 1_800_000_000_000),
                ),
            )

        assertEquals("mac-live", selected?.connectionId)
    }

    @Test
    fun newestCandidatesRecoversValidRecordWithinServerLimitedWindow() {
        // The pairing listener queries with orderBy(publishedAtMillis DESC)
        // + limit(QUERY_LIMIT); a corrupt newest record inside that window
        // must still fall back to the next valid one — this is why the
        // server limit is 3, not 1.
        val serverWindow =
            listOf(
                IrohPairingSelection.Candidate("   ", 1_900_000_000_000),
                IrohPairingSelection.Candidate("mac-live", 1_800_000_000_000),
                IrohPairingSelection.Candidate("mac-old", 1_700_000_000_000),
            )
        assertEquals(IrohPairingSelection.QUERY_LIMIT, serverWindow.size.toLong())

        assertEquals("mac-live", IrohPairingSelection.newestCandidates(serverWindow)?.connectionId)
    }

    @Test
    fun newestCandidatesReturnsNullWhenNoUsablePairingRecordExists() {
        assertNull(IrohPairingSelection.newestCandidates(emptyList()))
        assertNull(IrohPairingSelection.newestCandidates(listOf(IrohPairingSelection.Candidate("", 1))))
    }

    @Test
    fun coordinatorReusePolicyRebuildsReconnectingCoordinatorForExplicitRecovery() {
        val selected = IrohPairingSelection.Candidate("relay-mac", 1_800_000_000_000)

        val shouldReuse =
            MediaControlCoordinatorReusePolicy.shouldReuse(
                activeConnectionID = "relay-mac",
                phase = MediaControlStreamCoordinator.Phase.Reconnecting(nextAttemptInMillis = 5_000),
                selection = selected,
                forceRestart = true,
            )

        assertFalse(shouldReuse)
    }

    @Test
    fun coordinatorReusePolicyKeepsPassiveReconnectSupervisorAlive() {
        val selected = IrohPairingSelection.Candidate("relay-mac", 1_800_000_000_000)

        val shouldReuse =
            MediaControlCoordinatorReusePolicy.shouldReuse(
                activeConnectionID = "relay-mac",
                phase = MediaControlStreamCoordinator.Phase.Reconnecting(nextAttemptInMillis = 5_000),
                selection = selected,
                forceRestart = false,
            )

        assertTrue(shouldReuse)
    }

    @Test
    fun coordinatorReusePolicyKeepsLiveCoordinatorAcrossPairingTimestampRefresh() {
        val refreshedSelection = IrohPairingSelection.Candidate("relay-mac", 1_800_000_060_000)

        val shouldReuse =
            MediaControlCoordinatorReusePolicy.shouldReuse(
                activeConnectionID = "relay-mac",
                phase = MediaControlStreamCoordinator.Phase.Live,
                selection = refreshedSelection,
                forceRestart = false,
            )

        assertTrue(shouldReuse)
    }

    @Test
    fun coordinatorReusePolicyRebuildsWhenConnectionIdChanges() {
        val selected = IrohPairingSelection.Candidate("relay-new-mac", 1_800_000_060_000)

        val shouldReuse =
            MediaControlCoordinatorReusePolicy.shouldReuse(
                activeConnectionID = "relay-old-mac",
                phase = MediaControlStreamCoordinator.Phase.Live,
                selection = selected,
                forceRestart = false,
            )

        assertFalse(shouldReuse)
    }
}
