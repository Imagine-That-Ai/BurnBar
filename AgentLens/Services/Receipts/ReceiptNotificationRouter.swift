import Foundation
import OpenBurnBarKernel
import UserNotifications

/// System-banner payload for a printed receipt. The UN delegate is owned by
/// the agent-reply listener; this type is the receipts side of that door so
/// a tap opens `openburnbar://receipts/{id}` on the slip itself.
enum ReceiptNotificationRouter: Sendable {
    static let payloadType = "receipt_printed"
    static let categoryID = "openburnbar.receipt"
    static let openActionID = "openburnbar.receipt.open"

    /// Foreground presentation. The thermal-printer sample is the product
    /// sound — do not also ask UN for `.sound` or the default ping doubles it.
    static var foregroundPresentationOptions: UNNotificationPresentationOptions {
        [.banner, .list]
    }

    static var category: UNNotificationCategory {
        let open = UNNotificationAction(
            identifier: openActionID,
            title: "Open",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: categoryID,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
    }

    struct Payload: Equatable, Sendable {
        let receiptID: String
        let sessionID: String
        let deepLink: URL
    }

    /// Banner copy. Title is the chat summary so the notification is about
    /// the conversation, not just the repo folder.
    static func bannerCopy(for receipt: ReceiptRecord) -> (title: String, body: String) {
        let preview = ReceiptChatBridge.listPreview(receipt: receipt)
        return (
            preview,
            "\(receipt.harness) · \(receipt.projectName) · \(receipt.formattedCost) · \(receipt.formattedDuration)"
        )
    }

    static func userInfo(for receipt: ReceiptRecord) -> [String: String] {
        let link = ReceiptChatBridge.receiptURL(receiptID: receipt.id)?.absoluteString
            ?? sessionURL(for: receipt)?.absoluteString
            ?? "openburnbar://receipts"
        return [
            "type": payloadType,
            "receipt_id": receipt.id,
            "session_id": receipt.sessionId,
            "deep_link": link
        ]
    }

    static func sessionURL(for receipt: ReceiptRecord) -> URL? {
        ReceiptChatBridge.sessionURL(
            conversationID: ReceiptChatBridge.conversationID(receipt: receipt, overlay: nil)
        )
    }

    static func payload(from userInfo: [AnyHashable: Any]) -> Payload? {
        guard string(userInfo["type"]) == payloadType else { return nil }
        let receiptID = string(userInfo["receipt_id"]) ?? ""
        let sessionID = string(userInfo["session_id"]) ?? ""
        guard let raw = string(userInfo["deep_link"]),
              let url = URL(string: raw),
              url.scheme?.lowercased() == "openburnbar"
        else { return nil }
        return Payload(receiptID: receiptID, sessionID: sessionID, deepLink: url)
    }

    /// Returns true when this was a receipt banner and the open callback ran.
    @discardableResult
    static func handleTap(
        userInfo: [AnyHashable: Any],
        open: (URL) -> Bool
    ) -> Bool {
        guard let payload = payload(from: userInfo) else { return false }
        return open(payload.deepLink)
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
