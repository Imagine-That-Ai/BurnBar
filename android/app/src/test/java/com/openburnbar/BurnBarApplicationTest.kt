// epoch fixtures are literal by design.

package com.openburnbar

import com.google.firebase.firestore.DocumentSnapshot
import com.openburnbar.data.media.MediaControlStreamCoordinator
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-policy tests for the `BurnBarApplication` file: the Firestore document
 * → pairing-candidate mapping in [IrohPairingSelection.newest] (the snapshot
 * shape the live listener feeds it) and the
 * [MediaControlCoordinatorReusePolicy] edges the candidate-level suite in
 * [IrohPairingSelectionTest] does not cover.
 */
class BurnBarApplicationTest {
    private fun document(documentId: String, connectionId: String? = null, legacyId: String? = null, publishedAtMillis: Long? = null): DocumentSnapshot {
        val snapshot = mockk<DocumentSnapshot>()
        every { snapshot.getString("connectionId") } returns connectionId
        every { snapshot.getString("id") } returns legacyId
        every { snapshot.id } returns documentId
        every { snapshot.getLong("publishedAtMillis") } returns publishedAtMillis
        return snapshot
    }

    // ── document → candidate mapping ──

    @Test
    fun `newest reads connectionId with id field and document id fallbacks`() {
        val canonical = IrohPairingSelection.newest(
            listOf(document("doc-1", connectionId = "mac-conn", publishedAtMillis = 10L)),
        )
        assertEquals("mac-conn", canonical?.connectionId)

        val legacy = IrohPairingSelection.newest(
            listOf(document("doc-2", legacyId = "mac-legacy", publishedAtMillis = 10L)),
        )
        assertEquals("mac-legacy", legacy?.connectionId)

        val docIdOnly = IrohPairingSelection.newest(listOf(document("doc-3", publishedAtMillis = 10L)))
        assertEquals("doc-3", docIdOnly?.connectionId)
    }

    @Test
    fun `newest trims connection ids and drops blank records entirely`() {
        val selected = IrohPairingSelection.newest(
            listOf(
                document("doc-1", connectionId = "  mac-live  ", publishedAtMillis = 5L),
                document("doc-2", connectionId = "   ", publishedAtMillis = 99L),
            ),
        )
        // The blank record is excluded even though it is newest.
        assertEquals("mac-live", selected?.connectionId)
        assertNull(IrohPairingSelection.newest(emptyList()))
    }

    @Test
    fun `a missing publishedAtMillis sorts as epoch zero instead of crashing`() {
        val selected = IrohPairingSelection.newest(
            listOf(
                document("doc-1", connectionId = "mac-malformed", publishedAtMillis = null),
                document("doc-2", connectionId = "mac-stamped", publishedAtMillis = 1L),
            ),
        )
        assertEquals("mac-stamped", selected?.connectionId)
        assertEquals(0L, IrohPairingSelection.newest(listOf(document("doc-1", connectionId = "x")))?.publishedAtMillis)
    }

    @Test
    fun `equal timestamps tie break deterministically on connectionId`() {
        val selected = IrohPairingSelection.newestCandidates(
            listOf(
                IrohPairingSelection.Candidate("mac-a", 7L),
                IrohPairingSelection.Candidate("mac-b", 7L),
            ),
        )
        // compareBy(publishedAtMillis).thenBy(connectionId): the listener must
        // pick the same record no matter the snapshot order.
        assertEquals("mac-b", selected?.connectionId)
        val reversed = IrohPairingSelection.newestCandidates(
            listOf(
                IrohPairingSelection.Candidate("mac-b", 7L),
                IrohPairingSelection.Candidate("mac-a", 7L),
            ),
        )
        assertEquals("mac-b", reversed?.connectionId)
    }

    // ── coordinator reuse policy edges ──

    @Test
    fun `no coordinator phase always rebuilds`() {
        assertFalse(
            MediaControlCoordinatorReusePolicy.shouldReuse(
                activeConnectionID = "mac-1",
                phase = null,
                selection = IrohPairingSelection.Candidate("mac-1", 1L),
                forceRestart = false,
            ),
        )
    }

    @Test
    fun `failed and stopped coordinators are never reused`() {
        for (phase in listOf(
            MediaControlStreamCoordinator.Phase.Failed("dial timeout"),
            MediaControlStreamCoordinator.Phase.Stopped,
            MediaControlStreamCoordinator.Phase.Idle,
        )) {
            assertFalse(
                "phase $phase must rebuild",
                MediaControlCoordinatorReusePolicy.shouldReuse(
                    activeConnectionID = "mac-1",
                    phase = phase,
                    selection = IrohPairingSelection.Candidate("mac-1", 1L),
                    forceRestart = false,
                ),
            )
        }
    }

    @Test
    fun `force restart keeps live and dialing coordinators but not reconnecting`() {
        fun reuse(phase: MediaControlStreamCoordinator.Phase) = MediaControlCoordinatorReusePolicy.shouldReuse(
            activeConnectionID = "mac-1",
            phase = phase,
            selection = IrohPairingSelection.Candidate("mac-1", 1L),
            forceRestart = true,
        )
        assertTrue(reuse(MediaControlStreamCoordinator.Phase.Live))
        assertTrue(reuse(MediaControlStreamCoordinator.Phase.Dialing))
        assertFalse(reuse(MediaControlStreamCoordinator.Phase.Reconnecting(nextAttemptInMillis = 1_000L)))
    }

    @Test
    fun `pairing listener query window stays wide enough for corrupt newest fallback`() {
        // 3, not 1 — see IrohPairingSelection.QUERY_LIMIT docs: a corrupt
        // newest record must leave a valid record inside the server window.
        assertEquals(3L, IrohPairingSelection.QUERY_LIMIT)
    }
}
