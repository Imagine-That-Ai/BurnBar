import Foundation
import OpenBurnBarCore

/// Pure open/close keyboard policy for Mercury screen-share auto-type.
enum ScreenShareAutoTypeFollowPolicy {
    static let staleAfter: TimeInterval = 1.5
    static let manualDismissHold: TimeInterval = 5.0
    static let minimumConfidence: Double = 0.5

    enum Action: Equatable, Sendable {
        case open
        case close
        case none
    }

    static func reduce(
        autoKeyboardEnabled: Bool,
        controlInputEnabled: Bool,
        isTyping: Bool,
        isCoPilotMode: Bool,
        context: ScreenShareSmartZoomContext?,
        selectedDisplayId: String?,
        manualDismissUntil: Date?,
        now: Date
    ) -> Action {
        if controlInputEnabled == false {
            return isTyping ? .close : .none
        }

        guard let context else {
            return isTyping ? .close : .none
        }

        let textFocusActive = isActiveTextFocus(
            context: context,
            selectedDisplayId: selectedDisplayId,
            now: now
        )

        if isTyping, textFocusActive == false {
            return .close
        }

        guard autoKeyboardEnabled else { return .none }
        guard isCoPilotMode == false else { return .none }
        guard isTyping == false else { return .none }
        if let manualDismissUntil, manualDismissUntil > now { return .none }
        guard textFocusActive else { return .none }

        return .open
    }

    static func isActiveTextFocus(
        context: ScreenShareSmartZoomContext,
        selectedDisplayId: String?,
        now: Date
    ) -> Bool {
        guard context.targetKind == .focusedElement else { return false }
        guard now.timeIntervalSince(context.receivedAt) <= staleAfter else { return false }
        if let target = context.displayId,
           let selected = selectedDisplayId,
           target != selected {
            return false
        }
        if let confidence = context.confidence, confidence < minimumConfidence {
            return false
        }
        return true
    }
}
