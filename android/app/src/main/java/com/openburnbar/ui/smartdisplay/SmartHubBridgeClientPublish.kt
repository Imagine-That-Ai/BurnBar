@file:Suppress("MagicNumber")

package com.openburnbar.ui.smartdisplay

import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.delay
import kotlinx.coroutines.tasks.await

internal object SmartHubBridgeClientPublish {
    private val db get() = Firebase.firestore

    suspend fun publish(collection: String, payload: Map<String, Any?>, timeoutMs: Long): SmartHubBridgeClient.ActionResult {
        val snapshot = SmartHubBridgeClient.currentSnapshot()
        if (!snapshot.bridgeIsLive) {
            return SmartHubBridgeClient.ActionResult(error = snapshot.bridgeFreshnessMessage)
        }
        val uid =
            com.google.firebase.auth.FirebaseAuth.getInstance().currentUser?.uid
                ?: return SmartHubBridgeClient.ActionResult(error = "Sign in to manage smart displays.")
        return runCatching {
            val actionId = java.util.UUID.randomUUID().toString()
            val actionRef =
                db.collection("users").document(uid)
                    .collection(collection)
                    .document(actionId)
            val data =
                payload.toMutableMap().apply {
                    this["status"] = "pending"
                    this["requestedAt"] = smartHubNowIso()
                    this["requestedBy"] = "android"
                }
            actionRef.set(data).await()
            waitForAction(actionRef, timeoutMs).copy(actionId = actionId)
        }.getOrElse {
            SmartHubBridgeClient.ActionResult(error = it.localizedMessage ?: "Smart display action failed.")
        }
    }

    private suspend fun waitForAction(actionRef: DocumentReference, timeoutMs: Long): SmartHubBridgeClient.ActionResult {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            delay(700)
            val data = actionRef.get().await().data.orEmpty()
            when (data["status"] as? String) {
                "completed" ->
                    return SmartHubBridgeClient.ActionResult(
                        message =
                        data["message"] as? String
                            ?: data["proof"] as? String
                            ?: "Completed.",
                    )
                "failed" ->
                    return SmartHubBridgeClient.ActionResult(
                        error =
                        data["errorMessage"] as? String
                            ?: data["message"] as? String
                            ?: "The Mac reported failure.",
                    )
            }
        }
        return SmartHubBridgeClient.ActionResult(error = "Timed out waiting for the Mac smart display agent.")
    }
}
