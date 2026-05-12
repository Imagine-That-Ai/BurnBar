package com.openburnbar.ui.chartstudio

import android.annotation.SuppressLint
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.openburnbar.ui.theme.AuroraColors
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
fun MermaidCanvas(
    spec: MermaidSpec,
    modifier: Modifier = Modifier
) {
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
                    cacheMode = WebSettings.LOAD_DEFAULT
                    domStorageEnabled = true
                }
                setBackgroundColor(0x00000000)            // transparent so the Aurora gradient bleeds through
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                loadUrl("file:///android_asset/mermaid/index.html")
            }
        },
        update = { web ->
            // Wait for the bundled shell to finish booting; the JS exposes a
            // ready promise but here we simply throw render at it — the shell
            // queues calls before init completes.
            val payload = JSONObject().apply {
                put("source", sanitized)
                put("theme", spec.theme ?: "dark")
                put("accent", "#${AuroraColors.ember.toArgb().toUInt().toString(16).takeLast(6)}")
            }
            web.evaluateJavascript(
                "window.__burnbar_render && window.__burnbar_render(${payload})",
                null
            )
        }
    )
}
