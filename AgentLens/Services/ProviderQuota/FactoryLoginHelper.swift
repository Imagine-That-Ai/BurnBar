import Foundation
#if os(macOS)
import AppKit
import WebKit

// MARK: - Provider Login Helper

/// Runs explicit provider login flows in an OpenBurnBar-owned WKWebView.
///
/// These methods are intentionally UI-callable only. Quota refresh paths must
/// never open login windows automatically; they read the app-owned Keychain
/// sessions captured by these flows and return a reconnect state when absent or
/// expired.
@MainActor
enum FactoryLoginHelper {

    static func runLoginFlow() async -> String? {
        await runCookieLogin(
            title: "Connect Factory",
            url: URL(string: "https://app.factory.ai")!,
            domainMatch: { $0.contains("factory.ai") },
            cookieMatch: { cookie in
                cookie.name == "wos-session"
                    || cookie.name == "__Secure-wos-session"
                    || cookie.name == "access-token"
                    || cookie.name == "__Secure-next-auth.session-token"
                    || cookie.name == "next-auth.session-token"
                    || cookie.name == "authjs.session-token"
                    || cookie.name == "__Secure-authjs.session-token"
            },
            // Factory also offers Google sign-in via window.open(...);
            // same popup-blocking issue as Kimi.
            allowsPopupNavigation: true
        )
    }

    static func runOllamaLoginFlow() async -> String? {
        // Ollama Cloud rotates cookie names between releases (Better Auth, NextAuth,
        // custom). Match any cookie whose name carries a `session`/`auth`/`token`
        // hint so the captured header includes whatever the active backend issues —
        // failing that, fall back to every ollama.com cookie so the scraper has at
        // least one valid jar to replay against `/settings`.
        await runCookieLogin(
            title: "Connect Ollama",
            url: URL(string: "https://ollama.com/settings")!,
            domainMatch: { $0.contains("ollama.com") },
            cookieMatch: { cookie in
                let name = cookie.name.lowercased()
                if name.contains("session") || name.contains("auth") || name.contains("token") {
                    return true
                }
                return cookie.name == "ollama_session"
                    || cookie.name == "__Host-ollama_session"
                    || cookie.name == "signed-in"
            },
            // Ollama supports Google / GitHub sign-in via window.open(...).
            allowsPopupNavigation: true
        )
    }

    static func runKimiLoginFlow() async -> String? {
        await runCookieLogin(
            title: "Connect Kimi",
            url: URL(string: "https://www.kimi.com/code/console")!,
            domainMatch: { $0.contains("kimi.com") },
            // Kimi's auth jar varies depending on which sign-in path the
            // user took (phone, Google, Apple). The primary cookie the
            // billing adapter cares about is `kimi-auth`, but on first
            // visit Kimi sometimes lands the user on a NextAuth session
            // before swapping in `kimi-auth`. Match both, then prefer
            // `kimi-auth` in the transform so the captured token works
            // with `KimiQuotaAdapter`'s `Bearer <jwt>` requirement.
            cookieMatch: { cookie in
                let name = cookie.name
                if name == "kimi-auth" { return true }
                if name == "__Secure-next-auth.session-token" { return true }
                if name == "next-auth.session-token" { return true }
                if name == "authjs.session-token" { return true }
                if name == "__Secure-authjs.session-token" { return true }
                // Defensive — Kimi has shipped variant names per release.
                let lower = name.lowercased()
                return lower.hasPrefix("kimi-") && lower.contains("auth")
            },
            transform: { cookies in
                // `KimiQuotaAdapter` requires a raw JWT (sent as both
                // `Authorization: Bearer <jwt>` and `Cookie: kimi-auth=<jwt>`).
                // Always prefer `kimi-auth` so the captured value is
                // immediately usable; NextAuth fallbacks return the raw
                // session token which the adapter can also forward.
                cookies.first(where: { $0.name == "kimi-auth" })?.value
                    ?? cookies.first(where: { $0.name == "__Secure-next-auth.session-token" })?.value
                    ?? cookies.first(where: { $0.name == "next-auth.session-token" })?.value
                    ?? cookies.first(where: { $0.name.lowercased().hasPrefix("kimi-") })?.value
            },
            // Kimi's "Sign in with Google" calls window.open(...) to launch
            // Google's OAuth consent page in a popup, which a default
            // WKWebView refuses (no `WKUIDelegate` ⇒ popup spinner hangs
            // forever on the modal). Letting the OAuth navigation run in
            // the main webview is the macOS-standard approach for in-app
            // OAuth and is what other quota providers (Factory, Ollama)
            // implicitly rely on for their session capture.
            allowsPopupNavigation: true
        )
    }

    private static var activeRunners: [ObjectIdentifier: LoginRunner] = [:]

    private static func runCookieLogin(
        title: String,
        url: URL,
        domainMatch: @escaping @Sendable (String) -> Bool,
        cookieMatch: @escaping @Sendable (HTTPCookie) -> Bool,
        transform: @escaping @Sendable ([HTTPCookie]) -> String? = { cookies in
            let header = cookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            return header.isEmpty ? nil : header
        },
        allowsPopupNavigation: Bool = false
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let runner = LoginRunner(
                title: title,
                url: url,
                domainMatch: domainMatch,
                cookieMatch: cookieMatch,
                transform: transform,
                allowsPopupNavigation: allowsPopupNavigation,
                continuation: continuation
            )
            activeRunners[ObjectIdentifier(runner)] = runner
            runner.onComplete = { runner in
                activeRunners[ObjectIdentifier(runner)] = nil
            }
            runner.start()
        }
    }

    private final class LoginRunner: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
        let title: String
        let url: URL
        let domainMatch: @Sendable (String) -> Bool
        let cookieMatch: @Sendable (HTTPCookie) -> Bool
        let transform: @Sendable ([HTTPCookie]) -> String?
        let allowsPopupNavigation: Bool
        let continuation: CheckedContinuation<String?, Never>
        var onComplete: ((LoginRunner) -> Void)?

        private var webView: WKWebView?
        private var window: NSWindow?
        private var hasCompleted = false

        init(
            title: String,
            url: URL,
            domainMatch: @escaping @Sendable (String) -> Bool,
            cookieMatch: @escaping @Sendable (HTTPCookie) -> Bool,
            transform: @escaping @Sendable ([HTTPCookie]) -> String?,
            allowsPopupNavigation: Bool,
            continuation: CheckedContinuation<String?, Never>
        ) {
            self.title = title
            self.url = url
            self.domainMatch = domainMatch
            self.cookieMatch = cookieMatch
            self.transform = transform
            self.allowsPopupNavigation = allowsPopupNavigation
            self.continuation = continuation
            super.init()
        }

        func start() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            // Kimi (and any OAuth-enabled provider) opens Google/Apple
            // sign-in via window.open(...). WKWebView blocks popups by
            // default — a `WKUIDelegate.createWebViewWith` that loads the
            // request in the main webview is the only thing standing
            // between the user and a hung loading spinner.
            if allowsPopupNavigation {
                config.preferences.javaScriptCanOpenWindowsAutomatically = true
            }

            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                configuration: config
            )
            webView.navigationDelegate = self
            // The UI delegate handles popup creation so OAuth flows that
            // call `window.open()` don't dead-end. Wired for every login
            // — providers that don't use popups simply never reach it.
            webView.uiDelegate = self
            // Mac Safari UA — some IdPs (Google) refuse to render their
            // consent screen inside generic embedded WebKit. Setting a
            // Safari UA before any navigation runs avoids the
            // "This browser or app may not be secure" rejection that
            // would otherwise wedge the popup-replaced navigation.
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
            self.webView = webView

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = title
            window.contentView = webView
            window.center()
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            self.window = window

            webView.load(URLRequest(url: url))
        }

        // MARK: - WKUIDelegate

        /// Routes popup-opening navigations (window.open, target=_blank)
        /// into the main WKWebView so OAuth consent screens render
        /// in-place. Returning `nil` declines the popup; we manually
        /// load the request so the user sees the next step instead of a
        /// silent dead-end.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let captured = await captureSession() {
                    complete(with: captured)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let captured = await captureSession() {
                    complete(with: captured)
                }
            }
        }

        func windowWillClose(_ notification: Notification) {
            if !hasCompleted {
                complete(with: nil)
            }
        }

        private func captureSession() async -> String? {
            guard let webView else { return nil }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { domainMatch($0.domain) && cookieMatch($0) }
            guard !cookies.isEmpty else { return nil }
            return transform(cookies)
        }

        private func complete(with sessionValue: String?) {
            guard !hasCompleted else { return }
            hasCompleted = true
            window?.close()
            continuation.resume(returning: sessionValue)
            onComplete?(self)
        }
    }
}

#else

enum FactoryLoginHelper {
    static func runLoginFlow() async -> String? { nil }
    static func runOllamaLoginFlow() async -> String? { nil }
    static func runKimiLoginFlow() async -> String? { nil }
}

#endif
