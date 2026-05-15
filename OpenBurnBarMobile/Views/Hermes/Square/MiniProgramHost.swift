import SwiftUI
import WebKit
import OpenBurnBarCore

// MARK: - Mini-Program Host (Hermes Square §6.6)
//
// Sandboxed WKWebView that renders a `custom` CardEnvelope. Strict CSP
// derived via `MiniProgramHostCallValidator.contentSecurityPolicy`, JS
// bridge allowlists exactly the 8 host primitives, per-call 16 KB
// payload cap.
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
    let onPrimitive: (MiniProgramHostCall) async -> MiniProgramHostResponse

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "burnbarHostInvoke")
        config.userContentController = userController

        // Strict CSP injected as a meta http-equiv into every loaded
        // document. Phase C ships this; Phase D wires per-message
        // permission prompts.
        let csp = MiniProgramHostCallValidator.contentSecurityPolicy(sandboxURL: payload.sandboxURL)
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
        webView.scrollView.bounces = false
        if let url = URL(string: payload.sandboxURL) {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.parent = self
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MiniProgramHostView

        init(parent: MiniProgramHostView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "burnbarHostInvoke" else { return }
            guard let dict = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict),
                  let call = try? JSONDecoder().decode(MiniProgramHostCall.self, from: data)
            else {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: "unknown",
                    success: false,
                    error: "Malformed bridge call payload."
                ))
                return
            }
            do {
                try MiniProgramHostCallValidator.validate(call, installedAgentURIs: parent.installedAgentURIs)
            } catch {
                postResponseToWebView(message.webView, MiniProgramHostResponse(
                    correlationID: call.correlationID,
                    success: false,
                    error: error.localizedDescription
                ))
                return
            }
            let parent = self.parent
            Task { @MainActor in
                let response = await parent.onPrimitive(call)
                postResponseToWebView(message.webView, response)
            }
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
}
