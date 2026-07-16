import SwiftUI
import WebKit

/// iOS port of the macOS `KernelBackdropView`
/// (`AgentLens/Views/Dashboard/Components/KernelBackdropView.swift`).
///
/// Full-screen, transparent, click-through WebGL2 backdrop that hosts the SAME
/// offline `KernelBackdrop` bundle the Mac uses (`Resources/KernelBackdrop/`,
/// shared verbatim from the `AgentLens` target via a folder-reference resource).
/// It paints the live kernel field into a `WKWebView` and switches the kernel /
/// theme by calling `window.__setKernel('<id>')` / `window.__setTheme('<light|dark>')`
/// through the same ready-gated `Coordinator` (`WKNavigationDelegate`) pattern.
///
/// The web view never draws its own background and never intercepts touches, so
/// the dashboard content (and, when enabled, the transparent
/// `SwarmCanvasView` + substrate layered above) composites cleanly on top —
/// mirroring the macOS `DashboardToolbarAndBackdrop` ZStack.
///
/// Unlike the macOS view, the selection is NOT read from `@AppStorage`: the
/// caller passes a concrete `kernelID` and `theme`, so iOS routing can drive the
/// base WebGL layer however it likes.
struct MobileWebGLKernelBackdropView: UIViewRepresentable {
    /// A raw kernel id (e.g. `"fluid-aurora"`). Clamped to the default if the id
    /// is not one of the bundled kernels.
    let kernelID: String
    /// `"light"` or `"dark"`. Anything else normalizes to `"dark"`.
    let theme: String
    let maxFrameRate: Double

    init(kernelID: String, theme: String, maxFrameRate: Double = 20) {
        self.kernelID = kernelID
        self.theme = theme
        self.maxFrameRate = maxFrameRate
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false

        let webView = NonInteractiveWebView(frame: .zero, configuration: configuration)
        // Let whatever is behind us (dashboard surface, substrate, blur) show
        // through — the kernels paint their own field; we don't want
        // WKWebView's opaque default backing. On iOS this is the opacity trio
        // rather than the macOS `drawsBackground` KVC.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        // Without this, UIKit insets the web layout viewport by the enclosing
        // safe area / navigation bar, so the WebGL canvas starts ~100pt down and
        // the uncovered strip renders as a black band with a hard edge (the
        // "break" at the top of Pulse/Agents). The backdrop must be edge-to-edge:
        // the bundle already declares `viewport-fit=cover` and pins #host to
        // `inset: 0`, so zeroing the native adjustment is the missing half.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Belt-and-suspenders click-through alongside the hitTest override.
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = context.coordinator

        context.coordinator.requestedKernel = resolvedKernelID
        context.coordinator.requestedTheme = themeName
        context.coordinator.requestedMaxFrameRate = resolvedMaxFrameRate
        context.coordinator.load(
            initialKernel: resolvedKernelID,
            maxFrameRate: resolvedMaxFrameRate,
            into: webView
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(
            kernel: resolvedKernelID,
            theme: themeName,
            maxFrameRate: resolvedMaxFrameRate,
            to: webView
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.evaluateJavaScript("window.__setBackdropActive && window.__setBackdropActive(false)")
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    /// Clamp junk back to the default so a stale/removed id never leaves a blank
    /// canvas.
    private var resolvedKernelID: String {
        MobileKernelCatalogIDs.isValid(kernelID) ? kernelID : MobileKernelCatalogIDs.defaultID
    }

    private var themeName: String {
        theme == "light" ? "light" : "dark"
    }

    private var resolvedMaxFrameRate: Double {
        guard maxFrameRate.isFinite, maxFrameRate > 0 else { return 20 }
        return min(maxFrameRate, 60)
    }

    static func supports(kernelID: String) -> Bool {
        MobileKernelCatalogIDs.isValid(kernelID)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var requestedKernel: String = MobileKernelCatalogIDs.defaultID
        var requestedTheme: String = "dark"
        var requestedMaxFrameRate: Double = 20
        private var isLoaded = false

        func load(initialKernel: String, maxFrameRate: Double, into webView: WKWebView) {
            guard
                let indexURL = Bundle.main.url(
                    forResource: "index",
                    withExtension: "html",
                    subdirectory: "KernelBackdrop"
                )
            else { return }

            // Seed the initial kernel via the URL fragment the bundle reads on
            // boot (`location.hash` first), avoiding a flash of the default
            // before our JS bridge fires.
            var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)
            components?.fragment = initialKernel
            components?.queryItems = [
                URLQueryItem(name: "maxFps", value: String(Int(maxFrameRate)))
            ]
            let target = components?.url ?? indexURL

            webView.loadFileURL(target, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }

        func apply(kernel: String, theme: String, maxFrameRate: Double, to webView: WKWebView) {
            let kernelChanged = kernel != requestedKernel
            let themeChanged = theme != requestedTheme
            let frameRateChanged = maxFrameRate != requestedMaxFrameRate
            requestedKernel = kernel
            requestedTheme = theme
            requestedMaxFrameRate = maxFrameRate
            guard isLoaded else { return }
            if themeChanged { evaluateSetTheme(theme, on: webView) }
            if kernelChanged { evaluateSetKernel(kernel, on: webView) }
            if frameRateChanged { evaluateSetMaxFrameRate(maxFrameRate, on: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            // The bundle mounts asynchronously and only exposes the bridge once
            // `window.__backdropReady === true`, so poll briefly before driving.
            evaluateSetTheme(requestedTheme, on: webView)
            evaluateSetKernel(requestedKernel, on: webView)
            evaluateSetMaxFrameRate(requestedMaxFrameRate, on: webView)
            webView.evaluateJavaScript("window.__setBackdropActive && window.__setBackdropActive(true)")
        }

        private func evaluateSetKernel(_ kernel: String, on webView: WKWebView) {
            guard MobileKernelCatalogIDs.isValid(kernel) else { return }
            webView.evaluateJavaScript(Self.readyGatedCall("window.__setKernel('\(kernel)')"))
        }

        private func evaluateSetTheme(_ theme: String, on webView: WKWebView) {
            let normalized = theme == "light" ? "light" : "dark"
            webView.evaluateJavaScript(Self.readyGatedCall("window.__setTheme('\(normalized)')"))
        }

        private func evaluateSetMaxFrameRate(_ maxFrameRate: Double, on webView: WKWebView) {
            let resolved = max(1, min(maxFrameRate, 60))
            webView.evaluateJavaScript(Self.readyGatedCall("window.__setMaxFps(\(resolved))"))
        }

        /// Defers `call` until the bundle signals readiness. Kernel ids and the
        /// theme literal are validated above and constrained to `[a-z-]`, so
        /// the interpolation can't break out of the string.
        private static func readyGatedCall(_ call: String) -> String {
            """
            (function () {
              var tries = 0;
              function go() {
                if (window.__backdropReady === true && typeof window.__setKernel === 'function') {
                  try { \(call); } catch (e) {}
                  return;
                }
                if (tries++ < 120) { setTimeout(go, 50); }
              }
              go();
            })();
            """
        }
    }
}

/// A `WKWebView` that is invisible to the hit-testing system, so the backdrop
/// never steals touches from the dashboard content composited above it. UIKit's
/// `hitTest(_:with:)` signature (vs the macOS `hitTest(_:)`).
private final class NonInteractiveWebView: WKWebView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The bundled kernel ids, inlined because `KernelCatalog` lives in the macOS
/// `AgentLens` target and is not compiled into the iOS app. Keep in sync with
/// `KernelCatalog.all` in
/// `AgentLens/Views/Dashboard/Components/KernelBackdropView.swift` (which in turn
/// mirrors the engine's `KERNEL_META`). Only ids are needed here — the iOS host
/// receives its label/selection from the caller, not a native picker.
private enum MobileKernelCatalogIDs {
    /// Matches the bundle's own fallback when no `#hash`/`?kernel=` is supplied.
    static let defaultID = "fluid-aurora"

    static let all: Set<String> = [
        "constellation",
        "flow",
        "aurora",
        "mesh",
        "moire",
        "volumetric",
        "lic",
        "fluid-aurora",
        "cloudfield",
        "plasma-orbs",
        "blobs-mesh",
        "retro-plasma",
        "inversion-lattice",
        "vogel-bloom",
        "crystal-drift",
        "ripple-lattice",
        "liquid-lumen",
        "spectral-drift",
        "mycelium-mesh",
        "oilfield",
        "suminagashi-drift",
        "kinetic-stipple",
        "agent1",
        "neural-bloom",
        "aether-lattice",
        "bat-signal",
        "storm-signal",
        "origami",
        "ink-diffusion",
        "petroleum-sheen",
        "boids"
    ]

    /// Whether `id` names a real kernel; guards the JS bridge against junk.
    static func isValid(_ id: String) -> Bool {
        all.contains(id)
    }
}
