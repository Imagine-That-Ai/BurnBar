import SwiftUI
import WebKit

/// One shared `WKWebView` per process for the KernelBackdrop bundle so tab
/// switches reparent instead of rebooting WebGL.
@MainActor
final class SharedWebGLBackdropHost {
    static let shared = SharedWebGLBackdropHost()

    private(set) var webView: NonInteractiveWebView?
    private var loadGeneration = 0

    private init() {}

    func borrowWebView(coordinator: MobileWebGLKernelBackdropView.Coordinator, initialKernel: String) -> NonInteractiveWebView {
        if let webView {
            coordinator.attach(to: webView)
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let bridge = WKUserScript(
            source: Self.rafBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(bridge)

        let view = NonInteractiveWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = false
        view.navigationDelegate = coordinator
        webView = view
        coordinator.attach(to: view)
        coordinator.load(initialKernel: initialKernel, into: view)
        return view
    }

    func releaseWebView(_ view: WKWebView) {
        guard webView === view else { return }
        // Pause the shared rAF loop while no host is attached so tab
        // teardown does not leave WebGL spinning in the background.
        applyRenderPolicy(paused: true, maxFrameRate: nil)
        view.removeFromSuperview()
    }

    func applyRenderPolicy(paused: Bool, maxFrameRate: Double?) {
        guard let webView else { return }
        let fps = maxFrameRate.map { Int(max(1, $0.rounded())) } ?? 0
        let script = """
        (function () {
          if (typeof window.__setPaused === 'function') { window.__setPaused(\(paused ? "true" : "false")); }
          if (typeof window.__setFrameCap === 'function') { window.__setFrameCap(\(fps)); }
        })();
        """
        webView.evaluateJavaScript(script)
    }

    var rafBridgeScriptForInjection: String { Self.rafBridgeScript }

    private static let rafBridgeScript = """
    (function () {
      if (window.__openBurnBarRAFBridgeInstalled) return;
      window.__openBurnBarRAFBridgeInstalled = true;
      var paused = false;
      var frameCapMs = null;
      var lastFrame = 0;
      var nativeRAF = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = function (cb) {
        return nativeRAF(function (ts) {
          if (paused) { window.requestAnimationFrame(cb); return; }
          if (frameCapMs !== null && ts - lastFrame < frameCapMs) {
            window.requestAnimationFrame(cb);
            return;
          }
          lastFrame = ts;
          cb(ts);
        });
      };
      window.__setPaused = function (p) { paused = !!p; };
      window.__setFrameCap = function (fps) {
        frameCapMs = fps > 0 ? (1000 / fps) : null;
      };
    })();
    """
}

private struct WebGLBackdropAncestorActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var webglBackdropAncestorActive: Bool {
        get { self[WebGLBackdropAncestorActiveKey.self] }
        set { self[WebGLBackdropAncestorActiveKey.self] = newValue }
    }

    /// When true, nav-tray decorative `TimelineView` loops should pause to
    /// save battery (scene inactive, Low Power Mode, etc.).
    var navDecorativeAnimationsPaused: Bool {
        get { self[NavDecorativeAnimationsPausedKey.self] }
        set { self[NavDecorativeAnimationsPausedKey.self] = newValue }
    }
}

private struct NavDecorativeAnimationsPausedKey: EnvironmentKey {
    static let defaultValue = false
}
