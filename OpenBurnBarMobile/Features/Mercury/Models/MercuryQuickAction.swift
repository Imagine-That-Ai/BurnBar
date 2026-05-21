import Foundation

/// The three primary actions surfaced in `MercuryActionStack`. Ordering
/// inside `MercuryDevicePersonalization.actionOrder` defines both the
/// vertical order and the visibility — actions absent from the array are
/// hidden from the main stack.
enum MercuryQuickAction: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case mirror
    case call
    case sendFile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mirror:   return "Ask to Mirror"
        case .call:     return "Call Mac"
        case .sendFile: return "Send File…"
        }
    }

    /// SF Symbol used in both the main stack and the visibility picker.
    var icon: String {
        switch self {
        case .mirror:   return "rectangle.on.rectangle.angled"
        case .call:     return "phone.fill"
        case .sendFile: return "paperclip"
        }
    }

    /// VoiceOver phrasing.
    var accessibilityLabel: String {
        switch self {
        case .mirror:   return "Ask to mirror Mac screen"
        case .call:     return "Call paired Mac"
        case .sendFile: return "Send file to paired Mac"
        }
    }
}
