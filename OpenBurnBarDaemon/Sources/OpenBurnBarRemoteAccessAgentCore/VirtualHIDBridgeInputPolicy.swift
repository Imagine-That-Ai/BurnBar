import Foundation

/// Fail-closed gate for the Virtual HID bridge `"input"` operation until WS2 capability tokens ship.
///
/// Remote Unlock and locked-screen phone control only need pointer motion, clicks, and a small set
/// of focus keys — not arbitrary typing, scrolling, or shortcuts.
public enum VirtualHIDBridgeInputPolicy {
    public enum RejectionReason: String, Sendable, Equatable, Error {
        case missingKind = "missing_input_kind"
        case disallowedKind = "disallowed_input_kind"
        case disallowedTypeOperation = "disallowed_type_operation"
        case disallowedScroll = "disallowed_scroll"
        case disallowedDragDrop = "disallowed_drag_drop"
        case disallowedKey = "disallowed_key"
        case disallowedShortcut = "disallowed_shortcut"
        case emptyText = "empty_text"
    }

    public struct Request: Sendable, Equatable {
        public var kind: String?
        public var text: String?
        public var key: String?
        public var modifiers: [String]?

        public init(kind: String?, text: String?, key: String?, modifiers: [String]?) {
            self.kind = kind
            self.text = text
            self.key = key
            self.modifiers = modifiers
        }
    }

    /// Keys allowed for Remote Unlock focus / submission sequences (matches
    /// `RemoteAccessVirtualHIDReportPlanner` escape/delete/return helpers).
    private static let certifiedKeyNames: Set<String> = [
        "escape", "esc",
        "delete",
        "return", "enter",
        "tab"
    ]

    private static let allowedKinds: Set<String> = [
        "click",
        "pointer_move"
    ]

    public static func validate(_ request: Request) -> Result<Void, RejectionReason> {
        guard let kind = request.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !kind.isEmpty else {
            return .failure(.missingKind)
        }

        switch kind {
        case "type":
            return .failure(.disallowedTypeOperation)
        case "scroll":
            return .failure(.disallowedScroll)
        case "drag_drop":
            return .failure(.disallowedDragDrop)
        case "key":
            return validateKey(request.key)
        case "shortcut":
            return validateShortcut(key: request.key, modifiers: request.modifiers ?? [])
        default:
            guard allowedKinds.contains(kind) else {
                return .failure(.disallowedKind)
            }
            return .success(())
        }
    }

    private static func validateKey(_ key: String?) -> Result<Void, RejectionReason> {
        guard let key,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.disallowedKey)
        }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard certifiedKeyNames.contains(normalized) else {
            return .failure(.disallowedKey)
        }
        return .success(())
    }

    private static func validateShortcut(
        key: String?,
        modifiers: [String]
    ) -> Result<Void, RejectionReason> {
        guard modifiers.isEmpty else {
            return .failure(.disallowedShortcut)
        }
        return validateKey(key)
    }
}
