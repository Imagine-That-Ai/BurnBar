package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionKind
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionStatus
import com.openburnbar.irohrelay.HermesRealtimeRelaySystemPermissionStatusKind
import org.junit.Assert.assertEquals
import org.junit.Test

class SystemPermissionInboxStoreTest {
    @Test
    fun `ingest parses the canonical Swift dateIso lastChangedAt to millis`() {
        val store = SystemPermissionInboxStore()
        store.ingest(
            HermesRealtimeRelaySystemPermissionStatus(
                kind = HermesRealtimeRelaySystemPermissionKind.SCREEN_RECORDING,
                status = HermesRealtimeRelaySystemPermissionStatusKind.NEEDS_ACCESS,
                lastChangedAt = "2023-11-14T22:13:20.000Z",
            ),
            threadId = "t1",
        )
        assertEquals(1_700_000_000_000L, store.itemsForThread("t1").single().lastChangedAtMillis)
    }

    @Test
    fun `ingest does not throw on a malformed lastChangedAt (defensive fallback)`() {
        val store = SystemPermissionInboxStore()
        // A conformant Mac always emits ISO-8601, but a non-conformant/malformed peer value
        // must not throw out of the inbound read loop (that would tear the stream down to
        // Reconnecting). The item must still surface via the now() fallback.
        store.ingest(
            HermesRealtimeRelaySystemPermissionStatus(
                kind = HermesRealtimeRelaySystemPermissionKind.CAMERA,
                status = HermesRealtimeRelaySystemPermissionStatusKind.NEEDS_ACCESS,
                lastChangedAt = "not-a-timestamp",
            ),
            threadId = "t2",
        )
        assertEquals(1, store.itemsForThread("t2").size)
    }

    @Test
    fun `ingest accepts every relay system permission kind without name-based crashes`() {
        val store = SystemPermissionInboxStore()

        for (kind in HermesRealtimeRelaySystemPermissionKind.values()) {
            store.ingest(
                HermesRealtimeRelaySystemPermissionStatus(
                    kind = kind,
                    status = HermesRealtimeRelaySystemPermissionStatusKind.NEEDS_ACCESS,
                    lastChangedAt = "2023-11-14T22:13:20.000Z",
                ),
                threadId = "thread-${kind.name}",
            )
            assertEquals(
                PhoneControlSystemPermissionKind.fromRelayKind(kind),
                store.itemsForThread("thread-${kind.name}").single().kind,
            )
        }
    }
}
