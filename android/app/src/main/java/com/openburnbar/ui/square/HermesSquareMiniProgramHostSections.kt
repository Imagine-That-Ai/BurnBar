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
import java.net.IDN
import java.net.URI
import java.util.Locale
import kotlinx.coroutines.launch
import org.json.JSONObject

// reason: required JavaScript bridge is confined by CSP, iframe sandboxing, and custom URL dispatch.
@SuppressWarnings(
    "java/android/websettings-javascript-enabled",
    "java/android/websettings-allow-content-access",
    "java/android/webview-addjavascriptinterface",
)
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
            val sandboxOrigin = MiniProgramSandboxOrigin.parse(sandboxURL)
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
                            val target = request?.url?.toString() ?: return true
                            if (shouldHandleMiniProgramBridgeNavigation(target, request.isForMainFrame)) {
                                val uri = request.url
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
                            return !isAllowedMiniProgramNavigation(target, sandboxOrigin)
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
                if (sandboxOrigin == null) {
                    loadDataWithBaseURL(
                        "https://localhost/",
                        invalidMiniProgramHostHtml(),
                        "text/html",
                        "utf-8",
                        null,
                    )
                    return@apply
                }
                loadDataWithBaseURL(
                    sandboxOrigin.baseURL,
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

internal fun miniProgramHostHtml(sandboxURL: String, csp: String): String {
    val sandboxOrigin = MiniProgramSandboxOrigin.parse(sandboxURL)
    val bridgeOrigin = sandboxOrigin?.origin ?: "https://localhost"
    val iframeSource = sandboxOrigin?.let { sandboxURL } ?: "about:blank"
    return """
    <html><head>
      <meta http-equiv="Content-Security-Policy" content="${htmlAttributeEscape(csp)}">
    </head><body>
      <script>
        (function() {
        'use strict';
        var bridgeOrigin = ${JSONObject.quote(bridgeOrigin)};
        function invokeHost(call) {
          try {
            window.location.href = '$BRIDGE_SCHEME://$BRIDGE_HOST?$BRIDGE_PAYLOAD=' +
              encodeURIComponent(JSON.stringify(call));
          } catch (e) {
            window.burnbarHostReceive && window.burnbarHostReceive(
              { correlationID: (call && call.correlationID) || 'unknown',
                success: false,
                error: 'Bridge error: ' + e });
          }
        }
        window.addEventListener('message', function(event) {
          if (event.origin !== bridgeOrigin) return;
          var data = event.data || {};
          if (data.type !== 'burnbar-host-invoke') return;
          invokeHost(data.call);
        });
        window.burnbarHostInvoke = invokeHost;
        window.burnbarHostReceive = window.burnbarHostReceive || function() {};
        })();
      </script>
      <iframe src="${htmlAttributeEscape(iframeSource)}"
              sandbox="allow-scripts allow-same-origin"
              referrerpolicy="no-referrer"
              style="width:100%;height:100%;border:0"></iframe>
    </body></html>
    """.trimIndent()
}

private fun invalidMiniProgramHostHtml(): String = """
    <html><head>
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; frame-ancestors 'none'">
    </head><body></body></html>
""".trimIndent()

private const val MAX_CALL_PAYLOAD_BYTES = 16_384
private const val BRIDGE_SCHEME = "burnbar-host"
private const val BRIDGE_HOST = "invoke"
private const val BRIDGE_PAYLOAD = "payload"

internal data class MiniProgramSandboxOrigin(
    val scheme: String,
    val host: String,
    val port: Int,
) {
    val origin: String =
        buildString {
            append(scheme)
            append("://")
            append(host)
            if (port != defaultPort(scheme)) {
                append(":")
                append(port)
            }
        }

    val baseURL: String = "$origin/"

    fun matches(rawURL: String?): Boolean {
        val candidate = parse(rawURL) ?: return false
        return candidate.scheme == scheme &&
            candidate.host == host &&
            candidate.port == port
    }

    companion object {
        fun parse(rawURL: String?): MiniProgramSandboxOrigin? {
            val raw = rawURL?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val uri = runCatching { URI(raw) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
            if (scheme != "https" && scheme != "http") return null
            if (uri.rawUserInfo != null) return null
            val host = canonicalHost(uri.host ?: return null) ?: return null
            val port = uri.port.takeIf { it >= 0 } ?: defaultPort(scheme)
            if (port !in 1..65_535) return null
            return MiniProgramSandboxOrigin(scheme = scheme, host = host, port = port)
        }
    }
}

internal fun shouldHandleMiniProgramBridgeNavigation(rawURL: String?, isForMainFrame: Boolean): Boolean {
    if (!isForMainFrame) return false
    val uri = runCatching { URI(rawURL?.trim().orEmpty()) }.getOrNull() ?: return false
    return uri.scheme == BRIDGE_SCHEME &&
        uri.host == BRIDGE_HOST &&
        uri.rawUserInfo == null
}

internal fun isAllowedMiniProgramNavigation(rawURL: String?, sandboxOrigin: MiniProgramSandboxOrigin?): Boolean {
    return sandboxOrigin?.matches(rawURL) == true
}

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
    return MiniProgramSandboxOrigin.parse(sandboxURL)?.origin ?: "https://localhost"
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

private fun canonicalHost(host: String): String? {
    val normalized = host.trim().lowercase(Locale.ROOT)
    if (normalized.isEmpty()) return null
    return if (normalized.contains(":")) {
        "[${normalized.removePrefix("[").removeSuffix("]")}]"
    } else {
        runCatching { IDN.toASCII(normalized, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT) }.getOrNull()
    }
}

private fun defaultPort(scheme: String): Int = if (scheme == "https") 443 else 80

private fun htmlAttributeEscape(raw: String): String = raw
    .replace("&", "&amp;")
    .replace("\"", "&quot;")
    .replace("'", "&#39;")
    .replace("<", "&lt;")
    .replace(">", "&gt;")
