@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import android.annotation.SuppressLint
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.ui.theme.AuroraColors
import java.io.ByteArrayInputStream
import org.json.JSONObject

/**
 * Renders a Mermaid DSL spec inside a transparent `WebView` that loads
 * `assets/mermaid/index.html`. Pinch-to-zoom is enabled (1×–4×) via the
 * standard WebView zoom controls; we suppress the on-screen zoom widgets
 * since the Aurora composer bar is right below.
 *
 * Re-renders happen by sending a fresh `render(spec)` JS call through
 * `evaluateJavascript` whenever the source string changes — no full page
 * reload, so the JS state stays alive.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun MermaidCanvas(spec: MermaidSpec, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val sanitized = remember(spec.source) { spec.source.trim() }

    AndroidView(
        modifier = modifier.fillMaxSize(),
        factory = { ctx ->
            WebView(ctx).apply {
                settings.apply {
                    javaScriptEnabled = true
                    builtInZoomControls = true
                    displayZoomControls = false
                    loadWithOverviewMode = true
                    useWideViewPort = true
                    cacheMode = WebSettings.LOAD_NO_CACHE
                    domStorageEnabled = false
                    databaseEnabled = false
                    allowContentAccess = false
                    allowFileAccess = true
                    allowFileAccessFromFileURLs = false
                    allowUniversalAccessFromFileURLs = false
                    blockNetworkLoads = true
                    mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                }
                webViewClient = MermaidWebViewClient
                setBackgroundColor(0x00000000) // transparent so the Aurora gradient bleeds through
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                loadUrl("file:///android_asset/mermaid/index.html")
            }
        },
        update = { web ->
            // Wait for the bundled shell to finish booting; the JS exposes a
            // ready promise but here we simply throw render at it — the shell
            // queues calls before init completes.
            val payload =
                JSONObject().apply {
                    put("source", sanitized)
                    put("theme", spec.theme ?: "dark")
                    put("accent", "#${AuroraColors.ember.toArgb().toUInt().toString(16).takeLast(6)}")
                }
            web.evaluateJavascript(
                "window.__burnbar_render && window.__burnbar_render($payload)",
                null,
            )
        },
    )
}

private object MermaidWebViewClient : WebViewClient() {
    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true

    override fun shouldInterceptRequest(
        view: WebView?,
        request: WebResourceRequest?,
    ): WebResourceResponse? {
        val scheme = request?.url?.scheme?.lowercase() ?: return blocked()
        if (scheme == "http" || scheme == "https" || scheme == "data" || scheme == "javascript") {
            return blocked()
        }
        return null
    }

    private fun blocked(): WebResourceResponse =
        WebResourceResponse(
            "text/plain",
            "utf-8",
            ByteArrayInputStream(ByteArray(0)),
        )
}
