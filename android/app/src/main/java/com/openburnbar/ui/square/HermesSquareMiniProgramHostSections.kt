// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
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
                settings.allowFileAccessFromFileURLs = false
                settings.allowUniversalAccessFromFileURLs = false
                settings.javaScriptCanOpenWindowsAutomatically = false
                settings.mediaPlaybackRequiresUserGesture = true
                settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                settings.safeBrowsingEnabled = true
                settings.setSupportMultipleWindows(false)
                webChromeClient = WebChromeClient()
                webViewClient =
                    object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                            val uri = request?.url ?: return true
                            if (uri.scheme == BRIDGE_SCHEME && uri.host == BRIDGE_HOST) {
                                val payload = uri.getQueryParameter(BRIDGE_PAYLOAD) ?: return true
                                handleMiniProgramBridgeCall(
                                    payload = payload,
                                    hostAgentURI = agentURI,
                                    installedAgentURIs = installedAgentURIs,
                                    webView = view,
                                    scope = scope,
                                    onPrimitive = onPrimitive,
                                )
                                return true
                            }
                            val target = uri.toString()
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
            window.location.href = '$BRIDGE_SCHEME://$BRIDGE_HOST?$BRIDGE_PAYLOAD=' +
              encodeURIComponent(JSON.stringify(call));
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
private const val BRIDGE_SCHEME = "burnbar-host"
private const val BRIDGE_HOST = "invoke"
private const val BRIDGE_PAYLOAD = "payload"

private fun handleMiniProgramBridgeCall(
    payload: String,
    hostAgentURI: String,
    installedAgentURIs: Set<String>,
    webView: WebView?,
    scope: kotlinx.coroutines.CoroutineScope,
    onPrimitive: suspend (AndroidMiniProgramCall) -> AndroidMiniProgramResponse,
) {
    if (payload.toByteArray(Charsets.UTF_8).size > MAX_CALL_PAYLOAD_BYTES) return
    val call = AndroidMiniProgramCall.fromJsonString(payload) ?: return
    val claimedAgentURI = call.agentURI.ifBlank { hostAgentURI }
    if (claimedAgentURI != hostAgentURI || claimedAgentURI !in installedAgentURIs) return
    scope.launch {
        val response = onPrimitive(call.copy(agentURI = claimedAgentURI))
        val json = response.toJsonString()
        webView?.post {
            webView.evaluateJavascript(
                "window.burnbarHostReceive && window.burnbarHostReceive($json);",
                null,
            )
        }
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
