import Foundation
import OpenBurnBarKernel
import SafariServices

/// Safari's native-message entry point.
///
/// Each request is processed away from the extension host's main thread. The
/// handler never logs message bodies, screenshots, page text, bearer tokens, or
/// filesystem references. All protocol validation and error sanitization live
/// in the shared, directly testable bridge controller.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
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

    private static let processingQueue = DispatchQueue(
        label: "com.openburnbar.safari-extension.native-message",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    private static let controller: BurnBarSafariNativeBridgeController? = {
        try? BurnBarSafariNativeBridgeController.live()
    }()

    func beginRequest(with context: NSExtensionContext) {
        let contextBox = ExtensionContextBox(context)
        let messageBox = MessageBox(Self.nativeMessage(from: context))

        Self.processingQueue.async {
            let response: Any
            if let controller = Self.controller {
                response = controller.handle(
                    propertyList: messageBox.value ?? NSNull()
                )
            } else {
                response = Self.unavailableResponse(for: messageBox.value)
            }

            let item = NSExtensionItem()
            item.userInfo = [SFExtensionMessageKey: response]
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
        let id: String
        if let object = message as? [String: Any],
           let candidate = object["id"] as? String,
           !candidate.isEmpty,
           candidate.utf8.count <= BurnBarSafariBridgeWire.maximumIdentifierLength,
           !candidate.unicodeScalars.contains(
               where: CharacterSet.controlCharacters.contains
           ) {
            id = candidate
        } else {
            id = "unknown"
        }
        return [
            "protocolVersion": BurnBarSafariBridgeWire.protocolVersion,
            "id": id,
            "error": [
                "code": "native_bridge_unavailable",
                "message": "OpenBurnBar could not initialize its Safari bridge.",
                "retryable": true
            ]
        ]
    }
}
