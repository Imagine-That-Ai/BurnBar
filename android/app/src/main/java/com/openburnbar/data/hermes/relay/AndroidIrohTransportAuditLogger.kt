package com.openburnbar.data.hermes.relay

import android.util.Log
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.irohrelay.IrohTransportAuditEvent
import com.openburnbar.irohrelay.IrohTransportAuditLogging
import com.openburnbar.irohrelay.IrohTransportSelection
import java.util.Date
import java.util.UUID
import java.time.Instant
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.tasks.await

class AndroidIrohTransportAuditLogger(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) : IrohTransportAuditLogging {
    override suspend fun record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: Map<String, String>,
    ) {
        val resolvedUid = uid.takeIf { it.isNotBlank() } ?: auth.currentUser?.uid ?: return
        val eventId = UUID.randomUUID().toString()
        val now = Date()
        val expireAt = Date(now.time + AUDIT_TTL_MILLIS)
        val payload = mutableMapOf<String, Any>(
            "id" to eventId,
            "eventType" to event.raw,
            "connectionId" to connectionId,
            "observedAt" to DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(now.time)),
            "schemaVersion" to 1,
            "expireAt" to Timestamp(expireAt),
        )
        transport?.let { payload["transport"] = it.raw }
        rttMillis?.let { payload["rttMillis"] = it }
        if (detail.isNotEmpty()) payload["detail"] = detail

        runCatching {
            firestore.collection("users").document(resolvedUid)
                .collection("iroh_audit_events").document(eventId)
                .set(payload)
                .await()
        }.onFailure { error ->
            Log.d(TAG, "hermes_iroh_audit_write_failed: ${error.message}")
        }
    }

    companion object {
        private const val TAG = "IrohAudit"
        private const val AUDIT_TTL_MILLIS = 30L * 24L * 60L * 60L * 1_000L
    }
}
