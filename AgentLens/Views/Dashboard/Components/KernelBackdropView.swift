import OpenBurnBarCore
import SwiftUI
import WebKit

/// One selectable WebGL2 backdrop "kernel" from the self-contained bundle that
/// ships at `Resources/KernelBackdrop/`. Mirrors the `KERNEL_META` registry in
/// `apps/console/lib/gl/engine/registry.ts` so the native picker can be built
/// without parsing the JS bundle.
struct KernelCatalogEntry: Identifiable, Hashable {
    let id: String
    let label: String
}

/// The 32 bundled kernels, in registry order. Hardcoded (rather than read back
/// from `window.__kernels`) so the picker renders instantly and offline. Keep
/// in sync with the engine's `KERNEL_META`.
enum KernelCatalog {
    /// Matches the bundle's own fallback when no `#hash`/`?kernel=` is supplied.
    static let defaultID = SwarmSubstratePreferences.defaultKernelID

    static let all: [KernelCatalogEntry] = [
        KernelCatalogEntry(id: "constellation", label: "Constellation"),
        KernelCatalogEntry(id: "flow", label: "Flow Field"),
        KernelCatalogEntry(id: "aurora", label: "Aurora"),
        KernelCatalogEntry(id: "mesh", label: "Iridescent Mesh"),
        KernelCatalogEntry(id: "moire", label: "Moiré"),
        KernelCatalogEntry(id: "volumetric", label: "Volumetric"),
        KernelCatalogEntry(id: "lic", label: "Flow Imaging"),
        KernelCatalogEntry(id: "fluid-aurora", label: "Fluid Aurora"),
        KernelCatalogEntry(id: "cloudfield", label: "Cloud Field"),
        KernelCatalogEntry(id: "plasma-orbs", label: "Plasma Orbs"),
        KernelCatalogEntry(id: "blobs-mesh", label: "Blobs Mesh"),
        KernelCatalogEntry(id: "retro-plasma", label: "Retro Plasma"),
        KernelCatalogEntry(id: "inversion-lattice", label: "Inversion Lattice"),
        KernelCatalogEntry(id: "vogel-bloom", label: "Vogel Bloom"),
        KernelCatalogEntry(id: "crystal-drift", label: "Crystal Drift"),
        KernelCatalogEntry(id: "ripple-lattice", label: "Ripple Lattice"),
        KernelCatalogEntry(id: "liquid-lumen", label: "Liquid Lumen"),
        KernelCatalogEntry(id: "spectral-drift", label: "Spectral Drift"),
        KernelCatalogEntry(id: "mycelium-mesh", label: "Mycelium Mesh"),
        KernelCatalogEntry(id: "oilfield", label: "Oilfield"),
        KernelCatalogEntry(id: "suminagashi-drift", label: "Suminagashi Drift"),
        KernelCatalogEntry(id: "kinetic-stipple", label: "Kinetic Stipple"),
        KernelCatalogEntry(id: "agent1", label: "Agent 1"),
        KernelCatalogEntry(id: "neural-bloom", label: "Neural Bloom"),
        KernelCatalogEntry(id: "aether-lattice", label: "Aether Lattice"),
        KernelCatalogEntry(id: "bat-signal", label: "Beacon"),
        KernelCatalogEntry(id: "storm-signal", label: "Tempest"),
        KernelCatalogEntry(id: "origami", label: "Origami"),
        KernelCatalogEntry(id: "ink-diffusion", label: "Ink Diffusion"),
        KernelCatalogEntry(id: "petroleum-sheen", label: "Petroleum Sheen"),
        KernelCatalogEntry(id: "boids", label: "Boids"),
        KernelCatalogEntry(id: "swarmEmber", label: "Swarm Ember")
    ]

    /// Whether `id` names a real kernel; guards the JS bridge against junk.
    static func isValid(_ id: String) -> Bool {
        all.contains { $0.id == id }
    }

    static func label(for id: String) -> String {
        all.first { $0.id == id }?.label ?? id
    }
}

/// Full-window, transparent, click-through WebGL2 backdrop. Hosts the offline
/// `KernelBackdrop` bundle in a `WKWebView` and switches the live kernel by
/// calling `window.__setKernel('<id>')` whenever the persisted selection
/// changes. The web view never draws its own background and never intercepts
/// clicks, so the dashboard content composites cleanly on top.
struct KernelBackdropView: NSViewRepresentable {
    static let readabilityMessageName = "backdropReadability"

    var colorSchemeOverride: ColorScheme?
    var onReadabilityChange: (BackdropReadabilityProfile) -> Void
    @AppStorage(KernelBackdropPreferences.kernelKey) private var backdropKernel: String = KernelCatalog.defaultID
    @Environment(\.colorScheme) private var colorScheme

    init(
        colorSchemeOverride: ColorScheme? = nil,
        onReadabilityChange: @escaping (BackdropReadabilityProfile) -> Void = { _ in }
    ) {
        self.colorSchemeOverride = colorSchemeOverride
        self.onReadabilityChange = onReadabilityChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReadabilityChange: onReadabilityChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(
            context.coordinator,
            name: Self.readabilityMessageName
        )

        let webView = NonInteractiveWebView(frame: .zero, configuration: configuration)
        // Let the dashboard surface (and any window blur) show through — the
        // kernels paint their own dark field; we don't want WKWebView's opaque
        // default backing.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.autoresizingMask = [.width, .height]

        context.coordinator.requestedKernel = resolvedKernelID
        context.coordinator.requestedTheme = themeName(for: effectiveColorScheme)
        webView.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.hostWindowChanged(for: $0)
        }
        context.coordinator.load(initialKernel: resolvedKernelID, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onReadabilityChange = onReadabilityChange
        context.coordinator.apply(
            kernel: resolvedKernelID,
            theme: themeName(for: effectiveColorScheme),
            to: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detachOcclusionObserver()
        (webView as? NonInteractiveWebView)?.onWindowChange = nil
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.readabilityMessageName
        )
        webView.stopLoading()
    }

    /// Clamp persisted junk back to the default so a stale/removed id never
    /// leaves a blank canvas.
    private var resolvedKernelID: String {
        KernelCatalog.isValid(backdropKernel) ? backdropKernel : KernelCatalog.defaultID
    }

    private var effectiveColorScheme: ColorScheme {
        colorSchemeOverride ?? colorScheme
    }

    private func themeName(for scheme: ColorScheme) -> String {
        scheme == .light ? "light" : "dark"
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onReadabilityChange: (BackdropReadabilityProfile) -> Void
        var requestedKernel: String = KernelCatalog.defaultID
        var requestedTheme: String = "dark"
        private var isLoaded = false
        private weak var observedWebView: WKWebView?
        private var occlusionObserver: NSObjectProtocol?
        /// Last state pushed to JS, so occlusion churn doesn't spam evaluateJavaScript.
        private var lastReportedActive: Bool?

        init(onReadabilityChange: @escaping (BackdropReadabilityProfile) -> Void) {
            self.onReadabilityChange = onReadabilityChange
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                message.name == KernelBackdropView.readabilityMessageName,
                let profile = BackdropReadabilityProfile.decode(messageBody: message.body)
            else { return }
            onReadabilityChange(profile)
        }

        // MARK: Occlusion → render-loop gating
        //
        // `document.hidden` inside the WKWebView never flips when the hosting
        // window is merely covered by another window, minimized, or the app is
        // hidden — so without this bridge the WebGL loop burns GPU/CPU behind
        // fully occluded windows. Mirror the window's occlusion state into the
        // bundle's `window.__setBackdropActive` hook (a full rAF stop/start).

        func hostWindowChanged(for webView: WKWebView) {
            observedWebView = webView
            detachOcclusionObserver()
            guard let window = webView.window else {
                // Detached from any window: nothing can be seen; pause.
                pushBackdropActive(false, to: webView)
                return
            }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncOcclusionState() }
            }
            syncOcclusionState()
        }

        func detachOcclusionObserver() {
            if let observer = occlusionObserver {
                NotificationCenter.default.removeObserver(observer)
                occlusionObserver = nil
            }
        }

        private func syncOcclusionState() {
            guard let webView = observedWebView else { return }
            let visible = webView.window?.occlusionState.contains(.visible) ?? false
            pushBackdropActive(visible, to: webView)
        }

        private func pushBackdropActive(_ active: Bool, to webView: WKWebView) {
            guard lastReportedActive != active else { return }
            lastReportedActive = active
            // Optional-call: before the bundle mounts this is a harmless no-op;
            // `didFinish` re-syncs the real state once the bridge exists.
            let flag = active ? "true" : "false"
            webView.evaluateJavaScript(
                "window.__setBackdropActive && window.__setBackdropActive(\(flag));"
            )
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
            // The bundle mounts asynchronously and only exposes the bridge once
            // `window.__backdropReady === true`, so poll briefly before driving.
            evaluateSetTheme(requestedTheme, on: webView)
            evaluateSetKernel(requestedKernel, on: webView)
            // Re-push the occlusion state now that the bridge is (about to be)
            // live — the pre-load push was a no-op if the bundle wasn't mounted.
            lastReportedActive = nil
            hostWindowChanged(for: webView)
        }

        private func evaluateSetKernel(_ kernel: String, on webView: WKWebView) {
            guard KernelCatalog.isValid(kernel) else { return }
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
/// never steals clicks from the dashboard content composited above it.
private final class NonInteractiveWebView: WKWebView {
    /// Fires whenever the view (re)attaches to a window, so the coordinator
    /// can re-bind its occlusion observer to the right `NSWindow`.
    var onWindowChange: ((WKWebView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(self)
    }
}

/// Shared `@AppStorage` keys for the kernel backdrop so the renderer and the
/// settings picker bind to the exact same `UserDefaults` entries.
enum KernelBackdropPreferences {
    /// Selected kernel id. Default `KernelCatalog.defaultID` ("fluid-aurora").
    static let kernelKey = SwarmSubstratePreferences.backdropKernelKey
    /// Master gate: when on, the dashboard backdrop renders the kernel field
    /// instead of the ember swarm.
    static let enabledKey = "useKernelBackdrop"
}
