import Foundation
#if os(macOS)
import AppKit
import WebKit

// MARK: - Factory Login Helper

/// Opens a WKWebView window at `app.factory.ai` so the user can sign in.
/// After successful authentication, captures the session cookies and returns
/// them as a cookie header string for use with Factory's API.
///
/// Factory uses WorkOS-based auth. After signing in at app.factory.ai, the
/// session cookies (`wos-session`, `access-token`, `__Secure-next-auth.session-token`)
/// are captured from the WKWebView cookie store.
///
/// ## Usage
///
/// Called from `FactoryQuotaAdapter.loadFactoryCredentials()` as a last-resort
/// credential source when no env vars or browser cookies are available:
///
/// ```swift
/// if let cookieHeader = await FactoryLoginHelper.runLoginFlow() {
///     return FactorySessionCredentialEnvelope(cookieHeader: cookieHeader, ...)
/// }
/// ```
///
/// Reference: CodexBar `CursorLoginRunner.swift` — same WKWebView pattern.

@MainActor
enum FactoryLoginHelper {

    // MARK: - Constants

    private static let dashboardURL = URL(string: "https://app.factory.ai")!
    private static let loginURLPattern = "authenticator.factory.ai"
    private static let successURLPattern = "app.factory.ai"

    /// Session cookie names to capture.
    private static let sessionCookieNames: Set<String> = [
        "wos-session",
        "__Secure-wos-session",
        "access-token",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "authjs.session-token",
        "__Secure-authjs.session-token",
    ]

    // MARK: - Public API

    /// Runs the Factory login flow in a browser window.
    ///
    /// - Returns: A cookie header string (e.g., `wos-session=...; access-token=...`)
    ///   if login was successful, or `nil` if the user cancelled or an error occurred.
    static func runLoginFlow() async -> String? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let runner = LoginRunner(continuation: continuation)
                runner.start()
                // Keep a strong reference until the flow completes
                objc_setAssociatedObject(
                    continuation as AnyObject,
                    Unmanaged.passRetained(runner).toOpaque(),
                    runner,
                    .OBJC_ASSOCIATION_RETAIN
                )
            }
        }
    }

    // MARK: - Login Runner

    private final class LoginRunner: NSObject, WKNavigationDelegate, NSWindowDelegate {
        private let continuation: CheckedContinuation<String?, Never>
        private var webView: WKWebView?
        private var window: NSWindow?
        private var hasCompleted = false

        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
            super.init()
        }

        func start() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 480, height: 640),
                configuration: config
            )
            webView.navigationDelegate = self
            self.webView = webView

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Factory Login"
            window.contentView = webView
            window.center()
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            self.window = window

            let request = URLRequest(url: FactoryLoginHelper.dashboardURL)
            webView.load(request)
        }

        private func complete(with cookieHeader: String?) {
            guard !hasCompleted else { return }
            hasCompleted = true

            DispatchQueue.main.async { [weak self] in
                self?.window?.close()
            }

            continuation.resume(returning: cookieHeader)
        }

        // MARK: - Cookie Capture

        private func captureCookies() async -> String? {
            guard let webView else { return nil }

            let dataStore = webView.configuration.websiteDataStore
            let cookies = await dataStore.httpCookieStore.allCookies()

            let factoryCookies = cookies.filter { cookie in
                cookie.domain.contains("factory.ai")
            }

            guard !factoryCookies.isEmpty else { return nil }

            let header = factoryCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            return header.isEmpty ? nil : header
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url?.absoluteString else { return }

            // Detect successful login: redirect from authenticator to app
            if url.contains(FactoryLoginHelper.successURLPattern), !hasCompleted {
                Task { @MainActor in
                    // Brief delay to let cookies settle
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let header = await self.captureCookies()
                    self.complete(with: header)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            guard let url = webView.url?.absoluteString else { return }

            // Detect redirect to app after login
            if url.contains(FactoryLoginHelper.successURLPattern), !hasCompleted {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let header = await self.captureCookies()
                    self.complete(with: header)
                }
            }
        }

        // MARK: - NSWindowDelegate

        func windowWillClose(_ notification: Notification) {
            if !hasCompleted {
                complete(with: nil) // User cancelled
            }
        }
    }
}

#else

// MARK: - Factory Login (Unsupported on non-macOS)

enum FactoryLoginHelper {
    static func runLoginFlow() async -> String? { nil }
}

#endif
