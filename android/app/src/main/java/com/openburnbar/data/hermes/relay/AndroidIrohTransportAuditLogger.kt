package com.openburnbar.data.hermes.relay

import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.openburnbar.irohrelay.IrohTransportAuditEvent
import com.openburnbar.irohrelay.IrohTransportAuditLogging
import com.openburnbar.irohrelay.IrohTransportSelection
import java.util.Date
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
        val now = Date()
        val payload = mutableMapOf<String, Any>(
            "eventType" to event.raw,
            "connectionId" to connectionId,
            "platform" to "android",
            "observedAt" to Timestamp(now),
            "observedAtMillis" to now.time,
            "detail" to detail,
        )
        transport?.let { payload["transport"] = it.raw }
        rttMillis?.let { payload["rttMillis"] = it }

        firestore.collection("users").document(resolvedUid)
            .collection("iroh_audit_events").document()
            .set(payload)
            .await()
    }
}
