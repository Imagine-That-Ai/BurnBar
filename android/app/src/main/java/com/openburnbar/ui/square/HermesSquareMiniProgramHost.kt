package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import org.json.JSONObject

// MARK: - Mini-Program Host (Hermes Square §6.6, Android parity)
//
// Compose mirror of `MiniProgramHostView.swift`. Sandboxed WebView with
// strict CSP injected at document start + JS bridge for the 8 host
// primitives (dispatch / approve / fork / forward / delegate / pin /
// subscribe / rollback).

@Composable
fun HermesSquareMiniProgramHost(
    sandboxURL: String,
    agentURI: String,
    heightHintDp: Int = 240,
    installedAgentURIs: Set<String>,
    onPrimitive: suspend (AndroidMiniProgramCall) -> AndroidMiniProgramResponse,
    modifier: Modifier = Modifier,
) {
    val csp = remember(sandboxURL) { contentSecurityPolicy(sandboxURL) }

    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .height(heightHintDp.dp)
            .clip(RoundedCornerShape(10.dp)),
    ) {
        MiniProgramWebView(
            sandboxURL = sandboxURL,
            agentURI = agentURI,
            heightHintDp = heightHintDp,
            installedAgentURIs = installedAgentURIs,
            csp = csp,
            onPrimitive = onPrimitive,
        )
    }
}

// MARK: - Wire types (Kotlin parity of MiniProgramHostContracts)

data class AndroidMiniProgramCall(
    val action: String,
    val correlationID: String,
    val payload: Map<String, String>,
    val agentURI: String,
    val cardURI: String,
) {
    companion object {
        val ALLOWED_ACTIONS =
            setOf(
                "dispatch",
                "approve",
                "fork",
                "forward",
                "delegate",
                "pin",
                "subscribe",
                "rollback",
            )

        fun fromJsonString(raw: String): AndroidMiniProgramCall? {
            val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return null
            val action = obj.optString("action")
            if (action !in ALLOWED_ACTIONS) return null
            val payloadObj = obj.optJSONObject("payload") ?: JSONObject()
            val payload = mutableMapOf<String, String>()
            val keys = payloadObj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                payload[k] = payloadObj.optString(k)
            }
            return AndroidMiniProgramCall(
                action = action,
                correlationID = obj.optString("correlationID", "unknown"),
                payload = payload,
                agentURI = obj.optString("agentURI"),
                cardURI = obj.optString("cardURI"),
            )
        }
    }
}

data class AndroidMiniProgramResponse(
    val correlationID: String,
    val success: Boolean,
    val resultJSON: String? = null,
    val error: String? = null,
) {
    fun toJsonString(): String {
        val obj = JSONObject()
        obj.put("correlationID", correlationID)
        obj.put("success", success)
        resultJSON?.let { obj.put("resultJSON", it) }
        error?.let { obj.put("error", it) }
        return obj.toString()
    }
}
