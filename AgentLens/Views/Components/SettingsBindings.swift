import SwiftUI

// MARK: - Settings Bindings
//
// Shared binding adapters for settings that have **behaviour around the write**
// — an optional-to-bool shape, a composite facade, a re-clamp, a consent gate.
//
// Two homes for one setting drift when the *shape* of the write is retyped at
// each site rather than shared. The Control Deck renders the same spend
// threshold `AlertsSettingsView` renders; both now bind through this file, so
// there is exactly one definition of what "off" means and one place where the
// re-enable default lives.
//
// This file holds adapters only. It never performs an effect (scheduling,
// network, consent stamping) — effects belong to the owning service, so both
// surfaces inherit them instead of one surface having them and the other not.

enum SettingsBindings {

    /// Default threshold offered when a user re-enables the spend alert after
    /// having turned it off. Lives here so the deck and the settings pane can
    /// never offer different numbers.
    static let defaultCostAlertThreshold: Double = 25

    /// `AlertSettings.costAlertThreshold` is `Double?` where `nil` means "off"
    /// (it is persisted as the paired `hasCostAlertThreshold` +
    /// `costAlertThreshold` keys). Views want a `Bool`; this is the one adapter
    /// between the two.
    ///
    /// Turning it **on** restores the previous amount when there is one, so a
    /// user who toggles off and on again does not silently get a different
    /// budget than they set.
    static func costAlertEnabled(_ settingsManager: SettingsManager) -> Binding<Bool> {
        Binding(
            get: { settingsManager.costAlertThreshold != nil },
            set: { enabled in
                settingsManager.costAlertThreshold = enabled
                    ? max(settingsManager.costAlertThreshold ?? defaultCostAlertThreshold, 1)
                    : nil
            }
        )
    }

    /// The amount itself, as a non-optional `Double` for numeric entry. Writing
    /// zero or less is the same as turning the alert off — the single place
    /// that equivalence is defined.
    static func costAlertThreshold(_ settingsManager: SettingsManager) -> Binding<Double> {
        Binding(
            get: { settingsManager.costAlertThreshold ?? 0 },
            set: { settingsManager.costAlertThreshold = $0 > 0 ? $0 : nil }
        )
    }
}
