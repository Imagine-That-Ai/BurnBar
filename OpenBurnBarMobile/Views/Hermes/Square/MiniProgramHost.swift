import SwiftUI
import WebKit
import OpenBurnBarCore

// MARK: - Mini-Program Host (Hermes Square §6.6)
//
// Sandboxed WKWebView that renders a `custom` CardEnvelope. Strict CSP
// derived from an independently approved sandbox policy, JS bridge
// allowlists exactly the 8 host primitives, per-call 16 KB payload cap,
// per-field string caps, and per-action dispatch rate limits.
//
// The host exposes a single JS entry-point:
//
//     window.burnbarHostInvoke({
//         action: "dispatch",
//         correlationID: "abc-123",
//         payload: { "prompt": "Run the doc-writer" },
//         agentURI: "agent://third-party/foo/scout",
//         cardURI: "card://scout/dispatch-form"
//     })
//
// The bridge validates, dispatches into the host, and posts a
// `MiniProgramHostResponse` back via
// `webView.evaluateJavaScript("window.burnbarHostReceive(...)")`.

struct MiniProgramHostView: UIViewRepresentable {
    let payload: CardCustom
    let agentURI: String
    let installedAgentURIs: Set<String>
    let approvedSandboxOrigins: Set<String>
    let approvedPackageDirectoryURLs: [URL]
    let allowLocalDevelopmentSandbox: Bool
    let onPrimitive: (MiniProgramHostCall) async -> MiniProgramHostResponse

    func makeUIView(context: Context) -> WKWebView {
        let policy = approvedSandboxPolicy()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "burnbarHostInvoke")
        config.userContentController = userController

        // Strict CSP injected as a meta http-equiv into every loaded
        // document. Phase C ships this; Phase D wires per-message
        // permission prompts.
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(policy: policy)
        let cspScript = WKUserScript(
            source: """
            (function() {
              var meta = document.createElement('meta');
              meta.httpEquiv = 'Content-Security-Policy';
              meta.content = \(quote(csp));
              document.head && document.head.appendChild(meta);
              window.burnbarHostReceive = window.burnbarHostReceive || function() {};
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userController.addUserScript(cspScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        if let policy {
            webView.load(URLRequest(url: policy.url))
        }
        context.coordinator.parent = self
        context.coordinator.approvedPolicy = policy
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let previousURL = context.coordinator.approvedPolicy?.url
        let policy = approvedSandboxPolicy()
        context.coordinator.parent = self
        context.coordinator.approvedPolicy = policy
        if previousURL != policy?.url {
            if let policy {
                webView.load(URLRequest(url: policy.url))
            } else {
                webView.stopLoading()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private func approvedSandboxPolicy() -> MiniProgramSandboxPolicy? {
        MiniProgramHostCallValidator.approvedSandboxPolicy(
            sandboxURL: payload.sandboxURL,
            approvedOrigins: approvedSandboxOrigins,
            approvedPackageDirectoryURLs: approvedPackageDirectoryURLs,
            allowLocalDevelopment: allowLocalDevelopmentSandbox
        )
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MiniProgramHostView
        var approvedPolicy: MiniProgramSandboxPolicy?
        private var rateLimiter = MiniProgramHostBridgeRateLimiter()

        init(parent: MiniProgramHostView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "burnbarHostInvoke" else { return }
            guard let policy = approvedPolicy,
                  MiniProgramHostCallValidator.isAllowedBridgeOrigin(currentURL: message.webView?.url, policy: policy),
                  isAllowedMessageFrame(message.frameInfo, policy: policy)
            else {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: "unknown",
                    success: false,
                    error: MiniProgramHostCallValidator.ValidationError.unauthorisedOrigin(
                        message.webView?.url?.absoluteString ?? "unknown"
                    ).localizedDescription
                ))
                return
            }
            do {
                try MiniProgramHostCallValidator.validateRawBridgeMessageBody(message.body)
            } catch {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: safeCorrelationID(from: message.body),
                    success: false,
                    error: error.localizedDescription
                ))
                return
            }
            guard let dict = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict)
            else {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: "unknown",
                    success: false,
                    error: "Malformed bridge call payload."
                ))
                return
            }
            do {
                try MiniProgramHostCallValidator.validateRawBridgePayload(data)
            } catch {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: (dict["correlationID"] as? String) ?? "unknown",
                    success: false,
                    error: error.localizedDescription
                ))
                return
            }
            guard let call = try? JSONDecoder().decode(MiniProgramHostCall.self, from: data) else {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: (dict["correlationID"] as? String) ?? "unknown",
                    success: false,
                    error: "Malformed bridge call payload."
                ))
                return
            }
            do {
                try MiniProgramHostCallValidator.validate(
                    call,
                    installedAgentURIs: parent.installedAgentURIs,
                    expectedAgentURI: parent.agentURI
                )
            } catch {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: call.correlationID,
                    success: false,
                    error: error.localizedDescription
                ))
                return
            }
            guard rateLimiter.allow(call.action) else {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: call.correlationID,
                    success: false,
                    error: MiniProgramHostCallValidator.ValidationError.rateLimited(
                        action: call.action.rawValue,
                        limit: rateLimiter.maxCallsPerAction,
                        windowSeconds: rateLimiter.windowSeconds
                    ).localizedDescription
                ))
                return
            }
            let parent = self.parent
            Task { @MainActor in
                let response = await parent.onPrimitive(call)
                postResponseToWebView(message.webView, response)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let policy = approvedPolicy,
                  MiniProgramHostCallValidator.isAllowedBridgeOrigin(currentURL: navigationAction.request.url, policy: policy)
            else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func isAllowedMessageFrame(_ frameInfo: WKFrameInfo, policy: MiniProgramSandboxPolicy) -> Bool {
            guard frameInfo.isMainFrame else { return false }
            if policy.isPackageFile { return true }
            let origin = frameInfo.securityOrigin
            return MiniProgramHostCallValidator.isAllowedBridgeOrigin(
                scheme: origin.protocol,
                host: origin.host,
                port: origin.port,
                policy: policy
            )
        }

        private func safeCorrelationID(from body: Any) -> String {
            guard let dict = body as? [String: Any],
                  let correlationID = dict["correlationID"] as? String,
                  correlationID.utf8.count <= MiniProgramHostCallValidator.maxCorrelationIDBytes
            else { return "unknown" }
            return correlationID
        }

        @MainActor
        private func postResponseToWebView(_ webView: WKWebView?, _ response: MiniProgramHostResponse) {
            guard let webView,
                  let data = try? JSONEncoder().encode(response),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.burnbarHostReceive && window.burnbarHostReceive(\(json));", completionHandler: nil)
        }
    }
}

// MARK: - Card glue

/// Wraps `MiniProgramHostView` with the chrome the Hermes Square inbox
/// expects (rounded corner, height hint, agent palette accent).
struct MiniProgramCard: View {
    let card: CardCustom
    let agent: AgentIdentity
    let installedAgentURIs: Set<String>
    let onPrimitive: (MiniProgramHostCall) async -> MiniProgramHostResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(Color(hex: agent.paletteHex))
                Text(agent.displayName + " · mini-program")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
            }
            MiniProgramHostView(
                payload: card,
                agentURI: agent.id,
                installedAgentURIs: installedAgentURIs,
                approvedSandboxOrigins: MiniProgramHostCallValidator.approvedSandboxOrigins(for: agent),
                approvedPackageDirectoryURLs: approvedPackageDirectoryURLs,
                allowLocalDevelopmentSandbox: allowLocalDevelopmentSandbox,
                onPrimitive: onPrimitive
            )
            .frame(height: CGFloat(card.heightHint))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: agent.paletteHex).opacity(0.4),
                        style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
        )
    }

    private var approvedPackageDirectoryURLs: [URL] {
        Bundle.main.resourceURL.map { [$0] } ?? []
    }

    private var allowLocalDevelopmentSandbox: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["OPENBURNBAR_MINIPROGRAM_ALLOW_LOCAL_DEV"] == "1"
        #else
        false
        #endif
    }
}
