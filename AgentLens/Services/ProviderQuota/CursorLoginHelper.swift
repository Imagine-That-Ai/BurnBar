import Foundation
#if os(macOS)
import AppKit
#endif
import WebKit

// MARK: - Cursor Login Helper

/// Opens a WKWebView pointed at cursor.com so the user can sign in
/// via Google, GitHub, or email. After successful authentication, the
/// `WorkosCursorSessionToken` cookie is captured and stored in Keychain
/// for use by `CursorQuotaAdapter`.
///
/// Cursor uses WorkOS for authentication. The actual OAuth PKCE flow
/// is handled by WorkOS/Google/GitHub — we only need to open cursor.com
/// and capture the resulting session cookies.

@MainActor
final class CursorLoginHelper: NSObject, WKNavigationDelegate, Sendable {
    private static var activeHelpers: [ObjectIdentifier: CursorLoginHelper] = [:]

    // MARK: - Types

    struct LoginResult: Sendable {
        let cookieHeader: String
        let cookies: [HTTPCookie]
    }

    // MARK: - Public API

    /// Opens a Cursor login window and waits for the user to authenticate.
    ///
    /// - Returns: The captured cookie header, or throws if the user cancels
    ///   or authentication fails.
    /// - Throws: `CursorLoginError` on failure or user cancellation.
    static func login() async throws -> LoginResult {
        try await withCheckedThrowingContinuation { continuation in
            let helper = CursorLoginHelper(continuation: continuation)
            activeHelpers[ObjectIdentifier(helper)] = helper
            helper.start()
        }
    }

    /// Compatibility wrapper for quota code that treats cancelled login as
    /// missing credentials.
    static func runLoginFlow() async -> String? {
        try? await login().cookieHeader
    }

    // MARK: - Private

    private var continuation: CheckedContinuation<LoginResult, any Error>?
    private var webView: WKWebView?
    private var windowDelegate: WindowDelegate?

    private init(continuation: CheckedContinuation<LoginResult, any Error>) {
        self.continuation = continuation
        super.init()
    }

    private func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Cursor"
        window.contentView = webView
        window.center()

        // Close window → user cancelled
        let windowDelegate = WindowDelegate(onClose: { [weak self] in
            self?.finish(.failure(CursorLoginError.userCancelled))
        })
        self.windowDelegate = windowDelegate
        window.delegate = windowDelegate

        window.makeKeyAndOrderFront(nil)

        guard let url = URL(string: "https://cursor.com") else {
            finish(.failure(CursorLoginError.invalidURL))
            return
        }
        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let currentURL = webView.url?.absoluteString.lowercased() else { return }

        // Successful login indicators:
        // - cursor.com/dashboard (post-login landing)
        // - cursor.com/settings (account page)
        // - cursor.com/? (home with auth query params stripped, user is logged in)
        let isPostLogin = currentURL.contains("cursor.com/dashboard")
            || currentURL.contains("cursor.com/settings")
            || (currentURL.contains("cursor.com") && !currentURL.contains("login") && !currentURL.contains("signin"))

        guard isPostLogin else { return }

        // Give cookies a moment to settle, then capture them
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            await self?.captureCookies()
        }
    }

    private func captureCookies() async {
        guard let webView else { return }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()

        // Find Cursor session cookies
        let cursorCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.hasSuffix("cursor.com") || domain == "cursor.sh"
        }

        guard !cursorCookies.isEmpty else { return }

        let cookieHeader = cursorCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        guard !cookieHeader.isEmpty else { return }

        // Store in Keychain
        storeInKeychain(cookieHeader: cookieHeader)

        // Close window
        webView.window?.close()

        let result = LoginResult(
            cookieHeader: cookieHeader,
            cookies: cursorCookies
        )
        finish(.success(result))
    }

    private func finish(_ result: Result<LoginResult, any Error>) {
        guard let continuation else { return }
        self.continuation = nil

        let window = webView?.window
        webView?.navigationDelegate = nil
        webView = nil
        window?.delegate = nil
        window?.close()
        windowDelegate = nil
        Self.activeHelpers.removeValue(forKey: ObjectIdentifier(self))

        switch result {
        case let .success(loginResult):
            continuation.resume(returning: loginResult)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func storeInKeychain(cookieHeader: String) {
        let keychain = KeychainStore()
        do {
            try keychain.set(cookieHeader, for: "cursor_cookie")
        } catch {
            // Non-fatal: cookie works for this session even without keychain persistence
            AppLogger.dataStore.silentFailure("CursorLoginHelper: Failed to store cookie in keychain", error: error)
        }
    }
}

// MARK: - Window Delegate

private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Error

enum CursorLoginError: LocalizedError {
    case userCancelled
    case invalidURL
    case noCookiesFound

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Sign in was cancelled."
        case .invalidURL:
            return "Could not open Cursor login page."
        case .noCookiesFound:
            return "Authentication succeeded but no Cursor session cookies were found."
        }
    }
}
