import OpenBurnBarCore
import SwiftUI
import WebKit

/// Backdrop activity policy. Normal launches derive activity from AppKit window
/// visibility. The DEBUG performance harness may supply an explicit visibility
/// override because virtual CI sessions do not reliably update
/// `NSWindow.occlusionState` even after CGWindow reports an on-screen window.
enum OcclusionVisibilityPolicy {
    /// Returns `true` (active) when the performance harness explicitly shows
    /// the dashboard, or when the ordinary AppKit window state is visible.
    @MainActor
    static func shouldBackdropBeActive(
        window: NSWindow?,
        performanceGateOverride: Bool? = nil
    ) -> Bool {
        guard let window else { return false }
        return shouldBackdropBeActive(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            occlusionState: window.occlusionState,
            performanceGateOverride: performanceGateOverride
        )
    }

    static func shouldBackdropBeActive(
        isVisible: Bool,
        isMiniaturized: Bool,
        occlusionState: NSWindow.OcclusionState,
        performanceGateOverride: Bool? = nil
    ) -> Bool {
        if let performanceGateOverride { return performanceGateOverride }
        return isVisible && !isMiniaturized && occlusionState.contains(.visible)
    }
}

/// Dashboard kernel frame budget. Thin wrapper over `KernelCinematicPresent`
/// so existing call sites keep a local name.
enum KernelBackdropFramePolicy {
    static func maxFrameRate(isPerformanceGateLaunch: Bool, refreshHz: Double = 60) -> Double {
        KernelCinematicPresent.maxFrameRate(
            isPerformanceGateLaunch: isPerformanceGateLaunch,
            refreshHz: refreshHz
        )
    }

    static func cinematicPresentFrameRate(refreshHz: Double) -> Double {
        KernelCinematicPresent.presentFps(refreshHz: refreshHz)
    }
}

/// Combined activity: window occlusion AND content coverage.
enum KernelBackdropActivityPolicy {
    static func shouldBackdropBeActive(
        isVisible: Bool,
        isMiniaturized: Bool,
        occlusionState: NSWindow.OcclusionState,
        opaqueCoverage: CGFloat,
        windowHasSheet: Bool,
        performanceGateOverride: Bool? = nil
    ) -> Bool {
        if let performanceGateOverride { return performanceGateOverride }
        let windowActive = OcclusionVisibilityPolicy.shouldBackdropBeActive(
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            occlusionState: occlusionState,
            performanceGateOverride: nil
        )
        return windowActive
            && !windowHasSheet
            && KernelContentOcclusionPolicy.isKernelExposed(opaqueCoverage: Double(opaqueCoverage))
    }
}

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

    /// Curated popular kernels for quick switching.
    static var curated: [KernelCatalogEntry] {
        let ids: Set<String> = ["fluid-aurora", "constellation", "swarmEmber", "boids", "aurora", "flow"]
        return all.filter { ids.contains($0.id) }
    }

    /// Atmospheric and fluid field shaders.
    static var atmospheric: [KernelCatalogEntry] {
        let ids: Set<String> = ["fluid-aurora", "aurora", "flow", "cloudfield", "lic", "plasma-orbs", "retro-plasma", "spectral-drift"]
        return all.filter { ids.contains($0.id) }
    }

    /// Lattice, mesh, and geometric shaders.
    static var geometry: [KernelCatalogEntry] {
        let ids: Set<String> = ["constellation", "inversion-lattice", "ripple-lattice", "aether-lattice", "moire", "origami", "volumetric", "blobs-mesh"]
        return all.filter { ids.contains($0.id) }
    }

    /// Living, dynamic, and organic simulation shaders.
    static var organic: [KernelCatalogEntry] {
        let ids: Set<String> = ["swarmEmber", "boids", "neural-bloom", "vogel-bloom", "mycelium-mesh", "ink-diffusion", "petroleum-sheen", "suminagashi-drift", "crystal-drift", "liquid-lumen", "oilfield", "kinetic-stipple", "agent1", "bat-signal", "storm-signal", "mesh"]
        return all.filter { ids.contains($0.id) }
    }

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
private struct KernelOpaqueChromeCoverageKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Fraction of the kernel covered by opaque dashboard chrome (0...1).
    /// Covering plates set this so the living field can freeze without a
    /// window-occlusion bit.
    var kernelOpaqueChromeCoverage: CGFloat {
        get { self[KernelOpaqueChromeCoverageKey.self] }
        set { self[KernelOpaqueChromeCoverageKey.self] = newValue }
    }
}

struct KernelBackdropView: NSViewRepresentable {
    static let readabilityMessageName = "backdropReadability"

    var colorSchemeOverride: ColorScheme?
    var onReadabilityChange: (BackdropReadabilityProfile) -> Void
    var wantsOpaqueLayer: Bool
    @AppStorage(KernelBackdropPreferences.kernelKey) private var backdropKernel: String = KernelCatalog.defaultID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.kernelOpaqueChromeCoverage) private var opaqueChromeCoverage

    init(
        colorSchemeOverride: ColorScheme? = nil,
        onReadabilityChange: @escaping (BackdropReadabilityProfile) -> Void = { _ in },
        wantsOpaqueLayer: Bool = true
    ) {
        self.colorSchemeOverride = colorSchemeOverride
        self.onReadabilityChange = onReadabilityChange
        self.wantsOpaqueLayer = wantsOpaqueLayer
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
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = context.coordinator
        webView.autoresizingMask = [.width, .height]
        context.coordinator.requestedKernel = resolvedKernelID
        context.coordinator.requestedTheme = themeName(for: effectiveColorScheme)
        context.coordinator.applyLayerOpacity(wantsOpaqueLayer, to: webView)
        context.coordinator.opaqueChromeCoverage = opaqueChromeCoverage
        webView.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.hostWindowChanged(for: $0)
        }
        context.coordinator.load(initialKernel: resolvedKernelID, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onReadabilityChange = onReadabilityChange
        context.coordinator.opaqueChromeCoverage = opaqueChromeCoverage
        context.coordinator.apply(
            kernel: resolvedKernelID,
            theme: themeName(for: effectiveColorScheme),
            wantsOpaqueLayer: wantsOpaqueLayer,
            to: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detachVisibilityObservers()
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
        if let override = OpenBurnBarRuntime.performanceGateBackdropKernelOverride(
            isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch,
            arguments: ProcessInfo.processInfo.arguments
        ),
           KernelCatalog.isValid(override) {
            return override
        }
        return KernelCatalog.isValid(backdropKernel) ? backdropKernel : KernelCatalog.defaultID
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
        var requestedMaxFrameRate: Double = KernelBackdropFramePolicy.maxFrameRate(
            isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch
        )
        var opaqueChromeCoverage: CGFloat = 0 {
            didSet {
                if oldValue != opaqueChromeCoverage {
                    syncOcclusionState()
                }
            }
        }
        private var isLoaded = false
        private weak var observedWebView: WKWebView?
        private var occlusionObservers: [NSObjectProtocol] = []
        private var performanceGateVisibilityObserver: NSObjectProtocol?
        private var performanceGateVisibilityOverride: Bool?
        /// Last state pushed to JS, so occlusion churn doesn't spam evaluateJavaScript.
        private var lastReportedActive: Bool?
        private var lastOpaqueLayer: Bool?

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
            detachVisibilityObservers()
            installPerformanceGateVisibilityObserverIfNeeded()
            guard let window = webView.window else {
                // Detached from any window: nothing can be seen; pause.
                pushBackdropActive(false, to: webView)
                return
            }
            let stateChangeNotifications: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.willBeginSheetNotification,
                NSWindow.didEndSheetNotification
            ]
            occlusionObservers = stateChangeNotifications.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncOcclusionState() }
                }
            }
            syncOcclusionState()
        }

        func detachVisibilityObservers() {
            for observer in occlusionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            occlusionObservers.removeAll()
            if let observer = performanceGateVisibilityObserver {
                DistributedNotificationCenter.default().removeObserver(observer)
                performanceGateVisibilityObserver = nil
            }
        }

        private func installPerformanceGateVisibilityObserverIfNeeded() {
            guard OpenBurnBarRuntime.isPerformanceGateLaunch else { return }
            performanceGateVisibilityObserver = DistributedNotificationCenter.default().addObserver(
                forName: OpenBurnBarRuntime.performanceGateVisibilityNotification,
                object: OpenBurnBarRuntime.currentPerformanceGateNotificationObject,
                queue: .main
            ) { [weak self] notification in
                guard let visible = notification.userInfo?["visible"] as? Bool else { return }
                MainActor.assumeIsolated {
                    self?.performanceGateVisibilityOverride = visible
                    self?.syncOcclusionState()
                }
            }
        }

        private func syncOcclusionState() {
            guard let webView = observedWebView else { return }
            refreshFrameRate(on: webView)
            let window = webView.window
            let visible = KernelBackdropActivityPolicy.shouldBackdropBeActive(
                isVisible: window?.isVisible ?? false,
                isMiniaturized: window?.isMiniaturized ?? false,
                occlusionState: window?.occlusionState ?? [],
                opaqueCoverage: opaqueChromeCoverage,
                windowHasSheet: window?.attachedSheet != nil,
                performanceGateOverride: performanceGateVisibilityOverride
            )
            pushBackdropActive(visible, to: webView)
        }

        private func refreshHz(for webView: WKWebView) -> Double {
            Double(webView.window?.screen?.maximumFramesPerSecond ?? 60)
        }

        private func targetFrameRate(for webView: WKWebView) -> Double {
            KernelBackdropFramePolicy.maxFrameRate(
                isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch,
                refreshHz: refreshHz(for: webView)
            )
        }

        private func refreshFrameRate(on webView: WKWebView) {
            let frameRate = targetFrameRate(for: webView)
            guard frameRate != requestedMaxFrameRate else { return }
            requestedMaxFrameRate = frameRate
            if isLoaded { evaluateSetMaxFrameRate(frameRate, on: webView) }
        }

        func applyLayerOpacity(_ opaque: Bool, to webView: WKWebView) {
            webView.wantsLayer = true
            // WebKit's view-opaque bit is `drawsBackground` (SPI via KVC).
            // WindowServer's blend skip is `layer.isOpaque`. Both must agree.
            // At clarity 0 the kernel fills the window, so we mark opaque and
            // back with black (or white on the light theme) instead of a
            // transparent IOSurface WindowServer would alpha-blend every vsync.
            let layerAlreadyOpaque = webView.layer?.isOpaque == opaque
            guard lastOpaqueLayer != opaque || !layerAlreadyOpaque else { return }
            lastOpaqueLayer = opaque
            webView.setValue(opaque, forKey: "drawsBackground")
            webView.layer?.isOpaque = opaque
            if let host = webView as? NonInteractiveWebView {
                host.treatAsOpaque = opaque
            }
            if opaque {
                let fill = requestedTheme == "light" ? NSColor.white : NSColor.black
                webView.layer?.backgroundColor = fill.cgColor
                webView.underPageBackgroundColor = fill
            } else {
                webView.layer?.backgroundColor = NSColor.clear.cgColor
                webView.underPageBackgroundColor = .clear
            }
        }

        private func pushBackdropActive(_ active: Bool, to webView: WKWebView) {
            let flag = active ? "true" : "false"
            guard OpenBurnBarRuntime.isPerformanceGateLaunch else {
                guard lastReportedActive != active else { return }
                lastReportedActive = active
                // Optional-call: before the bundle mounts this is a harmless no-op;
                // `didFinish` re-syncs the real state once the bridge exists.
                webView.evaluateJavaScript(
                    "window.__setBackdropActive && window.__setBackdropActive(\(flag));"
                )
                return
            }

            // The real-process performance gate needs an acknowledgement from
            // the actual engine. A visible NSWindow alone does not prove that a
            // notification sent during startup reached this late-bound WKWebView.
            let script = """
            (function () {
              if (window.__backdropReady !== true ||
                  typeof window.__setBackdropActive !== 'function' ||
                  typeof window.__getBackdropState !== 'function') {
                return { ready: false };
              }
              window.__setBackdropActive(\(flag));
              var state = window.__getBackdropState();
              return {
                ready: true,
                hostVisible: state.hostVisible === true,
                renderLoopScheduled: state.renderLoopScheduled === true,
                reducedMotion: state.reducedMotion === true,
                kernel: String(state.resolvedKernel || '')
              };
            })();
            """
            webView.evaluateJavaScript(
                script
            ) { [weak self] value, error in
                MainActor.assumeIsolated {
                    guard error == nil, let state = value as? [String: Any] else {
                        self?.lastReportedActive = nil
                        self?.postPerformanceGateBackdropState([
                            "ready": false,
                            "requestedVisible": active,
                            "diagnostic": error?.localizedDescription ?? "malformed JavaScript result"
                        ])
                        return
                    }

                    guard state["ready"] as? Bool == true,
                          let hostVisible = state["hostVisible"] as? Bool,
                          let renderLoopScheduled = state["renderLoopScheduled"] as? Bool,
                          let reducedMotion = state["reducedMotion"] as? Bool,
                          let kernel = state["kernel"] as? String
                    else {
                        self?.lastReportedActive = nil
                        self?.postPerformanceGateBackdropState([
                            "ready": false,
                            "requestedVisible": active,
                            "diagnostic": "backdrop bridge not ready"
                        ])
                        return
                    }

                    let commandApplied = hostVisible == active
                        && (active ? (renderLoopScheduled && !reducedMotion) : !renderLoopScheduled)
                    self?.lastReportedActive = commandApplied ? active : nil
                    self?.postPerformanceGateBackdropState([
                        "ready": true,
                        "requestedVisible": active,
                        "commandApplied": commandApplied,
                        "hostVisible": hostVisible,
                        "renderLoopScheduled": renderLoopScheduled,
                        "reducedMotion": reducedMotion,
                        "kernel": kernel
                    ])
                }
            }
        }

        private func postPerformanceGateBackdropState(_ userInfo: [String: Any]) {
            DistributedNotificationCenter.default().postNotificationName(
                OpenBurnBarRuntime.performanceGateBackdropStateNotification,
                object: OpenBurnBarRuntime.currentPerformanceGateNotificationObject,
                userInfo: userInfo,
                deliverImmediately: true
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
            let target = Self.loadURL(
                indexURL: indexURL,
                initialKernel: initialKernel,
                performanceGate: OpenBurnBarRuntime.isPerformanceGateLaunch,
                refreshHz: refreshHz(for: webView)
            )

            webView.loadFileURL(target, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }

        static func loadURL(
            indexURL: URL,
            initialKernel: String,
            performanceGate: Bool,
            refreshHz: Double = 60
        ) -> URL {
            var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)
            components?.fragment = initialKernel
            var items: [URLQueryItem] = [
                URLQueryItem(
                    name: "maxFps",
                    value: KernelCinematicPresent.bootMaxFpsQueryValue(
                        isPerformanceGateLaunch: performanceGate,
                        refreshHz: refreshHz
                    )
                )
            ]
            if performanceGate {
                items.append(URLQueryItem(name: "motion", value: "full"))
            }
            components?.queryItems = items
            return components?.url ?? indexURL
        }

        func apply(kernel: String, theme: String, wantsOpaqueLayer: Bool, to webView: WKWebView) {
            let kernelChanged = kernel != requestedKernel
            let themeChanged = theme != requestedTheme
            let frameRate = targetFrameRate(for: webView)
            let frameRateChanged = frameRate != requestedMaxFrameRate
            requestedKernel = kernel
            requestedTheme = theme
            requestedMaxFrameRate = frameRate
            applyLayerOpacity(wantsOpaqueLayer, to: webView)
            syncOcclusionState()
            guard isLoaded else { return }
            if themeChanged { evaluateSetTheme(theme, on: webView) }
            if kernelChanged { evaluateSetKernel(kernel, on: webView) }
            if frameRateChanged { evaluateSetMaxFrameRate(frameRate, on: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            // The bundle mounts asynchronously and only exposes the bridge once
            // `window.__backdropReady === true`, so poll briefly before driving.
            evaluateSetTheme(requestedTheme, on: webView)
            evaluateSetKernel(requestedKernel, on: webView)
            evaluateSetMaxFrameRate(requestedMaxFrameRate, on: webView)
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
/// never steals clicks from the dashboard content composited above it.
private final class NonInteractiveWebView: WKWebView {
    /// Fires whenever the view (re)attaches to a window, so the coordinator
    /// can re-bind its occlusion observer to the right `NSWindow`.
    var onWindowChange: ((WKWebView) -> Void)?
    /// AppKit `isOpaque` is a getter, not a setter. Mirror the compositor
    /// hint the coordinator just applied so WindowServer can skip the blend.
    var treatAsOpaque = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { treatAsOpaque }

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
