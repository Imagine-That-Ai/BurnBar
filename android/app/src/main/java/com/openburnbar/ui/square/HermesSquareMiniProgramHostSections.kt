// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch

@Composable
internal fun MiniProgramWebView(
    sandboxURL: String,
    agentURI: String,
    heightHintDp: Int,
    installedAgentURIs: Set<String>,
    csp: String,
    onPrimitive: suspend (AndroidMiniProgramCall) -> AndroidMiniProgramResponse,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.mediaPlaybackRequiresUserGesture = true
                webChromeClient = WebChromeClient()
                webViewClient =
                    object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                            val target = request?.url?.toString() ?: return true
                            return !target.startsWith(originPrefix(sandboxURL))
                        }

                        override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                            view?.evaluateJavascript(
                                """(function() {
                                  var meta = document.createElement('meta');
                                  meta.httpEquiv = 'Content-Security-Policy';
                                  meta.content = ${quote(csp)};
                                  if (document.head) document.head.appendChild(meta);
                                  window.burnbarHostReceive = window.burnbarHostReceive || function() {};
                                })();""",
                                null,
                            )
                        }
                    }
                addJavascriptInterface(
                    MiniProgramJSBridge(
                        hostAgentURI = agentURI,
                        installedAgentURIs = installedAgentURIs,
                        postBack = { json ->
                            evaluateJavascript(
                                "window.burnbarHostReceive && window.burnbarHostReceive($json);",
                                null,
                            )
                        },
                        onCall = { call ->
                            scope.launch {
                                val response = onPrimitive(call)
                                val json = response.toJsonString()
                                post {
                                    evaluateJavascript(
                                        "window.burnbarHostReceive && window.burnbarHostReceive($json);",
                                        null,
                                    )
                                }
                            }
                        },
                    ),
                    "burnbarHostBridge",
                )
                loadDataWithBaseURL(
                    originPrefix(sandboxURL),
                    miniProgramHostHtml(sandboxURL, csp),
                    "text/html",
                    "utf-8",
                    null,
                )
            }
        },
        modifier = modifier.fillMaxWidth().height(heightHintDp.dp),
    )
}

private fun miniProgramHostHtml(sandboxURL: String, csp: String): String = """
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
""".trimIndent()

private const val MAX_CALL_PAYLOAD_BYTES = 16_384

private class MiniProgramJSBridge(
    private val hostAgentURI: String,
    private val installedAgentURIs: Set<String>,
    private val postBack: WebView.(String) -> Unit,
    private val onCall: (AndroidMiniProgramCall) -> Unit,
) {
    @JavascriptInterface
    fun invoke(json: String) {
        if (json.toByteArray(Charsets.UTF_8).size > MAX_CALL_PAYLOAD_BYTES) return
        val call = AndroidMiniProgramCall.fromJsonString(json) ?: return
        val claimedAgentURI = call.agentURI.ifBlank { hostAgentURI }
        if (claimedAgentURI != hostAgentURI || claimedAgentURI !in installedAgentURIs) return
        onCall(call.copy(agentURI = claimedAgentURI))
    }
}

internal fun originPrefix(sandboxURL: String): String {
    val match = Regex("^(https?://[^/]+)").find(sandboxURL) ?: return "https://localhost"
    return match.groupValues[1]
}

internal fun contentSecurityPolicy(sandboxURL: String): String {
    val origin = originPrefix(sandboxURL)
    return listOf(
        "default-src 'self' $origin",
        "script-src 'self' 'unsafe-inline' $origin",
        "style-src 'self' 'unsafe-inline' $origin",
        "img-src 'self' data: $origin",
        "connect-src $origin",
        "object-src 'none'",
        "base-uri 'self'",
        "frame-ancestors 'none'",
    ).joinToString("; ")
}

private fun quote(s: String): String {
    val escaped = s.replace("\\", "\\\\").replace("'", "\\'")
    return "'$escaped'"
}
