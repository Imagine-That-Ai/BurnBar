import Foundation
import SwiftUI

/// Tiny `UserDefaults`-backed store for the Mac-side Mercury consent
/// toggle: "Always allow my iPhone to mirror this Mac." Decoupled from
/// `SettingsManager` so Mercury internals don't bleed into the global
/// settings surface — the user-facing toggle in `MediaPermissionsView`
/// wires through here. Reads land in `MercuryRouter` on every inbound
/// `media.mirror.request`.
@MainActor
final class MercuryConsentStore: ObservableObject {
    static let key = "mercuryAlwaysAllowMyIPhoneToMirror"

    @Published var alwaysAllow: Bool {
        didSet {
            defaults.set(alwaysAllow, forKey: Self.key)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.alwaysAllow = defaults.bool(forKey: Self.key)
    }
}
