import SwiftUI
import WebKit

// MARK: - Mermaid Web View
//
// `UIViewRepresentable` wrapping a sandboxed `WKWebView` that loads our
// bundled `Mermaid/index.html` shell and renders a sanitized Mermaid source
// string. The HTML shell auto-themes via `prefers-color-scheme` so light /
// dark switching is automatic.
//
// We always sanitize the source again here (defense in depth) — the renderer
// already strips `<script>` / `javascript:` / inline event handlers.

struct MermaidWebView: UIViewRepresentable {
    let source: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.userContentController.add(context.coordinator, name: "mermaidStatus")

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.bounces = true
        view.scrollView.minimumZoomScale = 1.0
        view.scrollView.maximumZoomScale = 4.0
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        view.accessibilityLabel = "Mermaid diagram"
        view.accessibilityValue = source
        loadShell(into: view, coordinator: context.coordinator)
        context.coordinator.lastSourceLoaded = nil
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let sanitized = ChartSpecRenderer.sanitizeMermaid(source)
        uiView.accessibilityValue = sanitized
        if context.coordinator.shellLoaded {
            context.coordinator.render(source: sanitized, in: uiView)
        } else {
            context.coordinator.pendingSource = sanitized
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Loading

    private func loadShell(into view: WKWebView, coordinator: Coordinator) {
        guard let dir = Bundle.main.url(forResource: "Mermaid", withExtension: nil)
                ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Mermaid")?.deletingLastPathComponent() else {
            // Fall back to inline HTML shell if the resource folder isn't found.
            coordinator.loadInlineShell(into: view, source: ChartSpecRenderer.sanitizeMermaid(source))
            return
        }
        let indexURL = dir.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            coordinator.loadInlineShell(into: view, source: ChartSpecRenderer.sanitizeMermaid(source))
            return
        }
        coordinator.pendingSource = ChartSpecRenderer.sanitizeMermaid(source)
        view.loadFileURL(indexURL, allowingReadAccessTo: dir)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var shellLoaded: Bool = false
        var pendingSource: String?
        var lastSourceLoaded: String?

        func render(source: String, in webView: WKWebView) {
            guard source != lastSourceLoaded else { return }
            lastSourceLoaded = source
            let escaped = Self.escapeForJS(source)
            let script = "window._lastSource = \"\(escaped)\"; window.renderMermaid && window.renderMermaid(window._lastSource);"
            webView.evaluateJavaScript(script) { _, _ in }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellLoaded = true
            if let pending = pendingSource {
                render(source: pending, in: webView)
                pendingSource = nil
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Block off-app navigation. Mermaid SVG is rendered inline; no anchor-tap nav allowed.
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: Inline fallback

        func loadInlineShell(into webView: WKWebView, source: String) {
            let html = Self.inlineFallback(for: source)
            webView.loadHTMLString(html, baseURL: nil)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // We don't currently surface render errors to the SwiftUI layer
            // (the canvas already shows a fallback insight), but the channel
            // is wired so future versions can promote them.
            _ = message.body
        }

        // MARK: Helpers

        static func escapeForJS(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count)
            for ch in s {
                switch ch {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{2028}": out += "\\u2028"
                case "\u{2029}": out += "\\u2029"
                default: out.append(ch)
                }
            }
            return out
        }

        static func inlineFallback(for source: String) -> String {
            let escaped = source
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return """
            <!doctype html><html><body style="background:#171510;color:#F0EBE2;font-family:-apple-system,sans-serif;padding:16px">
            <h3 style="font-weight:600">Mermaid runtime missing</h3>
            <pre style="white-space:pre-wrap;background:rgba(255,255,255,0.06);padding:12px;border-radius:8px;">\(escaped)</pre>
            </body></html>
            """
        }
    }
}
