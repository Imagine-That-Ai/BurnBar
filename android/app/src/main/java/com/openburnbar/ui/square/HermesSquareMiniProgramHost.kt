package com.openburnbar.ui.square

import android.annotation.SuppressLint
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import org.json.JSONObject

// MARK: - Mini-Program Host (Hermes Square §6.6, Android parity)
//
// Compose mirror of `MiniProgramHostView.swift`. Sandboxed WebView with
// strict CSP injected at document start + JS bridge for the 8 host
// primitives (dispatch / approve / fork / forward / delegate / pin /
// subscribe / rollback). Per-call 16 KB payload cap enforced before
// dispatch.
//
// Wire format (JS → host): the page calls
//
//     window.burnbarHostInvoke({
//       action: "dispatch",
//       correlationID: "abc",
//       payload: {...},
//       agentURI: "agent://third-party/foo/scout",
//       cardURI: "card://scout/dispatch"
//     });
//
// The host validates, dispatches, and posts a result back via
// `window.burnbarHostReceive({correlationID, success, resultJSON?, error?})`.

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun HermesSquareMiniProgramHost(
    sandboxURL: String,
    agentURI: String,
    heightHintDp: Int = 240,
    installedAgentURIs: Set<String>,
    onPrimitive: suspend (AndroidMiniProgramCall) -> AndroidMiniProgramResponse,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val csp = remember(sandboxURL) { contentSecurityPolicy(sandboxURL) }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(heightHintDp.dp)
            .clip(RoundedCornerShape(10.dp))
    ) {
        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.mediaPlaybackRequiresUserGesture = true
                    webChromeClient = WebChromeClient()
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?
                        ): Boolean {
                            // Lock navigation to the sandbox origin only.
                            val target = request?.url?.toString() ?: return true
                            return !target.startsWith(originPrefix(sandboxURL))
                        }

                        override fun onPageStarted(
                            view: WebView?,
                            url: String?,
                            favicon: android.graphics.Bitmap?
                        ) {
                            // Inject CSP + JS bridge stub at document start.
                            view?.evaluateJavascript(
                                """(function() {
                                  var meta = document.createElement('meta');
                                  meta.httpEquiv = 'Content-Security-Policy';
                                  meta.content = ${quote(csp)};
                                  if (document.head) document.head.appendChild(meta);
                                  window.burnbarHostReceive = window.burnbarHostReceive || function() {};
                                })();""", null
                            )
                        }
                    }
                    addJavascriptInterface(
                        MiniProgramJSBridge(
                            installedAgentURIs = installedAgentURIs,
                            postBack = { json ->
                                evaluateJavascript(
                                    "window.burnbarHostReceive && window.burnbarHostReceive($json);",
                                    null
                                )
                            },
                            onCall = { call ->
                                scope.launch {
                                    val response = onPrimitive(call)
                                    val json = response.toJsonString()
                                    post {
                                        evaluateJavascript(
                                            "window.burnbarHostReceive && window.burnbarHostReceive($json);",
                                            null
                                        )
                                    }
                                }
                            }
                        ),
                        "burnbarHostBridge"
                    )
                    // Patch the JS-side entry point to call into the
                    // bridge (one extra hop so the `burnbarHostInvoke`
                    // shim can normalize the call shape).
                    loadDataWithBaseURL(
                        originPrefix(sandboxURL),
                        """
                        <html><head>
                          <meta http-equiv="Content-Security-Policy" content="$csp">
                        </head><body>
                          <script>
                            window.burnbarHostInvoke = function(call) {
                              try {
                                window.burnbarHostBridge.invoke(JSON.stringify(call));
                              } catch (e) {
                                window.burnbarHostReceive && window.burnbarHostReceive(
                                  { correlationID: (call && call.correlationID) || 'unknown',
                                    success: false,
                                    error: 'Bridge error: ' + e });
                              }
                            };
                            window.burnbarHostReceive = window.burnbarHostReceive || function() {};
                          </script>
                          <iframe src="$sandboxURL"
                                  sandbox="allow-scripts allow-same-origin"
                                  style="width:100%;height:100%;border:0"></iframe>
                        </body></html>
                        """.trimIndent(),
                        "text/html",
                        "utf-8",
                        null
                    )
                }
            },
            modifier = Modifier.fillMaxWidth().height(heightHintDp.dp)
        )
    }
}

// MARK: - Wire types (Kotlin parity of MiniProgramHostContracts)

data class AndroidMiniProgramCall(
    val action: String,
    val correlationID: String,
    val payload: Map<String, String>,
    val agentURI: String,
    val cardURI: String
) {
    companion object {
        val ALLOWED_ACTIONS = setOf(
            "dispatch", "approve", "fork", "forward",
            "delegate", "pin", "subscribe", "rollback"
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
                cardURI = obj.optString("cardURI")
            )
        }
    }
}

data class AndroidMiniProgramResponse(
    val correlationID: String,
    val success: Boolean,
    val resultJSON: String? = null,
    val error: String? = null
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

private const val MAX_CALL_PAYLOAD_BYTES = 16_384

private class MiniProgramJSBridge(
    private val installedAgentURIs: Set<String>,
    private val postBack: WebView.(String) -> Unit,
    private val onCall: (AndroidMiniProgramCall) -> Unit
) {
    @JavascriptInterface
    fun invoke(json: String) {
        if (json.toByteArray(Charsets.UTF_8).size > MAX_CALL_PAYLOAD_BYTES) {
            // Drop the call; the JS side will time out / surface its own
            // error. We don't tip the page off about the cap.
            return
        }
        val call = AndroidMiniProgramCall.fromJsonString(json) ?: return
        if (call.agentURI !in installedAgentURIs) {
            // Reject — unknown agent.
            return
        }
        onCall(call)
    }
}

private fun originPrefix(sandboxURL: String): String {
    val match = Regex("^(https?://[^/]+)").find(sandboxURL) ?: return "https://localhost"
    return match.groupValues[1]
}

private fun contentSecurityPolicy(sandboxURL: String): String {
    val origin = originPrefix(sandboxURL)
    return listOf(
        "default-src 'self' $origin",
        "script-src 'self' 'unsafe-inline' $origin",
        "style-src 'self' 'unsafe-inline' $origin",
        "img-src 'self' data: $origin",
        "connect-src $origin",
        "object-src 'none'",
        "base-uri 'self'",
        "frame-ancestors 'none'"
    ).joinToString("; ")
}

private fun quote(s: String): String {
    val escaped = s.replace("\\", "\\\\").replace("'", "\\'")
    return "'$escaped'"
}
