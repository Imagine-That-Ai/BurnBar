import Foundation
import SafariServices

/// Safari's native-message entry point for the bundled OpenBurnBar web extension.
///
/// Scope: this handler exists so `OpenBurnBarSafariExtension.appex` is a real,
/// loadable Safari Web Extension that ships inside `OpenBurnBar.app`. It owns the
/// wire envelope only — it validates the request shape and answers with the
/// protocol's `native_bridge_unavailable` error until the native bridge that talks
/// to `OpenBurnBarDaemon` lands. `extensions/safari/dist/background.js` already
/// treats that code as a first-class degraded state (it clears the gateway client
/// and reports `connection: "disconnected"`), so the extension installs, enables,
/// and renders instead of hanging on an unanswered request.
///
/// Deliberately self-contained: it links no OpenBurnBar module. The full bridge
/// (`BurnBarSafariNativeBridgeController`) depends on Safari RPC methods and daemon
/// handlers that do not exist on `main`; wiring it here would drag the whole
/// unlanded Safari program — and its RPC-canon wire changes — into the release path.
///
/// The handler never logs message bodies, page text, screenshots, bearer tokens, or
/// filesystem references. The only request field it reads back is the correlation
/// id, and only after validating it.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// Wire version spoken by `extensions/safari/dist`. The extension rejects any
    /// response carrying a different value with `protocol_mismatch`, so this must
    /// stay in lockstep with the extension bundle's shared protocol module.
    private static let protocolVersion = 1

    /// Upper bound on the echoed correlation id, matching the extension's own
    /// envelope validation. Anything longer is answered as `unknown` rather than
    /// reflected back.
    private static let maximumIdentifierLength = 128

    private final class ExtensionContextBox: @unchecked Sendable {
        let context: NSExtensionContext

        init(_ context: NSExtensionContext) {
            self.context = context
        }
    }

    private final class MessageBox: @unchecked Sendable {
        let value: Any?

        init(_ value: Any?) {
            self.value = value
        }
    }

    /// Requests are answered off the extension host's main thread so a slow or
    /// malformed message cannot stall Safari's UI.
    private static let processingQueue = DispatchQueue(
        label: "com.openburnbar.safari-extension.native-message",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    func beginRequest(with context: NSExtensionContext) {
        let contextBox = ExtensionContextBox(context)
        let messageBox = MessageBox(Self.nativeMessage(from: context))

        Self.processingQueue.async {
            let item = NSExtensionItem()
            item.userInfo = [
                SFExtensionMessageKey: Self.unavailableResponse(for: messageBox.value)
            ]
            contextBox.context.completeRequest(
                returningItems: [item],
                completionHandler: nil
            )
        }
    }

    private static func nativeMessage(from context: NSExtensionContext) -> Any? {
        guard context.inputItems.count == 1,
              let item = context.inputItems.first as? NSExtensionItem,
              let userInfo = item.userInfo else {
            return nil
        }
        return userInfo[SFExtensionMessageKey]
    }

    private static func unavailableResponse(for message: Any?) -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "id": correlationIdentifier(from: message),
            "error": [
                "code": "native_bridge_unavailable",
                "message": "OpenBurnBar could not initialize its Safari bridge.",
                "retryable": true
            ]
        ]
    }

    /// Echoes the request's correlation id so the extension can settle the pending
    /// promise it belongs to. Falls back to `unknown` for anything absent, oversized,
    /// or carrying control characters, so a hostile page cannot smuggle bytes back
    /// through the envelope.
    private static func correlationIdentifier(from message: Any?) -> String {
        guard let object = message as? [String: Any],
              let candidate = object["id"] as? String,
              !candidate.isEmpty,
              candidate.utf8.count <= maximumIdentifierLength,
              !candidate.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              ) else {
            return "unknown"
        }
        return candidate
    }
}
