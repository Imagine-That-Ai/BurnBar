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
            }
        )
    }

    static func runOllamaLoginFlow() async -> String? {
        await runCookieLogin(
            title: "Connect Ollama",
            url: URL(string: "https://ollama.com/settings")!,
            domainMatch: { $0.contains("ollama.com") },
            cookieMatch: { cookie in
                cookie.name == "session"
                    || cookie.name == "__Secure-session"
                    || cookie.name == "ollama_session"
                    || cookie.name == "__Host-ollama_session"
                    || cookie.name == "__Secure-next-auth.session-token"
                    || cookie.name == "next-auth.session-token"
                    || cookie.name.hasPrefix("__Secure-next-auth.session-token.")
                    || cookie.name.hasPrefix("next-auth.session-token.")
            }
        )
    }

    static func runKimiLoginFlow() async -> String? {
        await runCookieLogin(
            title: "Connect Kimi",
            url: URL(string: "https://www.kimi.com/code/console")!,
            domainMatch: { $0.contains("kimi.com") },
            cookieMatch: { cookie in
                cookie.name == "kimi-auth"
                    || cookie.name == "__Secure-next-auth.session-token"
            },
            transform: { cookies in
                cookies.first(where: { $0.name == "kimi-auth" })?.value
                    ?? cookies.first(where: { $0.name == "__Secure-next-auth.session-token" })?.value
            }
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
        }
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let runner = LoginRunner(
                title: title,
                url: url,
                domainMatch: domainMatch,
                cookieMatch: cookieMatch,
                transform: transform,
                continuation: continuation
            )
            activeRunners[ObjectIdentifier(runner)] = runner
            runner.onComplete = { runner in
                activeRunners[ObjectIdentifier(runner)] = nil
            }
            runner.start()
        }
    }

    private final class LoginRunner: NSObject, WKNavigationDelegate, NSWindowDelegate {
        let title: String
        let url: URL
        let domainMatch: @Sendable (String) -> Bool
        let cookieMatch: @Sendable (HTTPCookie) -> Bool
        let transform: @Sendable ([HTTPCookie]) -> String?
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
            continuation: CheckedContinuation<String?, Never>
        ) {
            self.title = title
            self.url = url
            self.domainMatch = domainMatch
            self.cookieMatch = cookieMatch
            self.transform = transform
            self.continuation = continuation
            super.init()
        }

        func start() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()

            let webView = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                configuration: config
            )
            webView.navigationDelegate = self
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
