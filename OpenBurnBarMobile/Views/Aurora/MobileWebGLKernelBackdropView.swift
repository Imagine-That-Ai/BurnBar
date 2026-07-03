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
    var paused: Bool = false
    var maxFrameRate: Double? = nil
    var useSharedHost: Bool = true

    init(kernelID: String, theme: String, paused: Bool = false, maxFrameRate: Double? = nil, useSharedHost: Bool = true) {
        self.kernelID = kernelID
        self.theme = theme
        self.paused = paused
        self.maxFrameRate = maxFrameRate
        self.useSharedHost = useSharedHost
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.requestedKernel = resolvedKernelID
        context.coordinator.requestedTheme = themeName
        context.coordinator.paused = paused
        context.coordinator.maxFrameRate = maxFrameRate
        if useSharedHost {
            return SharedWebGLBackdropHost.shared.borrowWebView(
                coordinator: context.coordinator,
                initialKernel: resolvedKernelID
            )
        }
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let bridge = WKUserScript(
            source: SharedWebGLBackdropHost.shared.rafBridgeScriptForInjection,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(bridge)

        let webView = NonInteractiveWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(to: webView)
        context.coordinator.load(initialKernel: resolvedKernelID, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.paused = paused
        context.coordinator.maxFrameRate = maxFrameRate
        context.coordinator.apply(
            kernel: resolvedKernelID,
            theme: themeName,
            to: webView
        )
        SharedWebGLBackdropHost.shared.applyRenderPolicy(paused: paused, maxFrameRate: maxFrameRate)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        SharedWebGLBackdropHost.shared.releaseWebView(webView)
    }

    /// Clamp junk back to the default so a stale/removed id never leaves a blank
    /// canvas.
    private var resolvedKernelID: String {
        MobileKernelCatalogIDs.isValid(kernelID) ? kernelID : MobileKernelCatalogIDs.defaultID
    }

    private var themeName: String {
        theme == "light" ? "light" : "dark"
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var requestedKernel: String = MobileKernelCatalogIDs.defaultID
        var requestedTheme: String = "dark"
        var paused = false
        var maxFrameRate: Double?
        private var isLoaded = false
        private weak var attachedWebView: WKWebView?

        func attach(to webView: WKWebView) {
            attachedWebView = webView
            webView.navigationDelegate = self
        }

        func load(initialKernel: String, into webView: WKWebView) {
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
            let target = components?.url ?? indexURL

            webView.loadFileURL(target, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }

        func apply(kernel: String, theme: String, to webView: WKWebView) {
            let kernelChanged = kernel != requestedKernel
            let themeChanged = theme != requestedTheme
            requestedKernel = kernel
            requestedTheme = theme
            guard isLoaded else { return }
            if themeChanged { evaluateSetTheme(theme, on: webView) }
            if kernelChanged { evaluateSetKernel(kernel, on: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            evaluateSetTheme(requestedTheme, on: webView)
            evaluateSetKernel(requestedKernel, on: webView)
            SharedWebGLBackdropHost.shared.applyRenderPolicy(paused: paused, maxFrameRate: maxFrameRate)
        }

        private func evaluateSetKernel(_ kernel: String, on webView: WKWebView) {
            guard MobileKernelCatalogIDs.isValid(kernel) else { return }
            webView.evaluateJavaScript(Self.readyGatedCall("window.__setKernel('\(kernel)')"))
        }

        private func evaluateSetTheme(_ theme: String, on webView: WKWebView) {
            let normalized = theme == "light" ? "light" : "dark"
            webView.evaluateJavaScript(Self.readyGatedCall("window.__setTheme('\(normalized)')"))
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
final class NonInteractiveWebView: WKWebView {
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
