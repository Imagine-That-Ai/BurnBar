import Foundation

// MARK: - Control Deck Readout
//
// "Which controls are on right now", as a pure value type over explicitly
// supplied live values.
//
// The header and every group header need this count, and computing it inside a
// tile would mean the summary could disagree with the tiles it summarises. So
// the predicate for each kind lives here, once, and `ControlDeckView` feeds it
// the same values the tiles read.
//
// Pure and `Sendable` on purpose: it is unit-testable without mounting a view,
// and it is the seed of the `ControlDeckSnapshot` the attention layer will be
// derived from. Nothing here reads a store, opens a listener, or awaits.

struct ControlDeckReadout: Equatable, Sendable {

    /// The live values the deck can read synchronously. One field per fact, so
    /// a test can construct any state without a running app.
    struct Inputs: Equatable, Sendable {
        var daemonIsHealthy: Bool
        var textExpansionInApp: Bool
        var textExpansionEverywhere: Bool
        var chartsAIInsights: Bool
        var spendAlertThreshold: Double?
        var petCompanionEnabled: Bool
        var updatesAutomaticChecks: Bool

        init(
            daemonIsHealthy: Bool = false,
            textExpansionInApp: Bool = false,
            textExpansionEverywhere: Bool = false,
            chartsAIInsights: Bool = false,
            spendAlertThreshold: Double? = nil,
            petCompanionEnabled: Bool = false,
            updatesAutomaticChecks: Bool = false
        ) {
            self.daemonIsHealthy = daemonIsHealthy
            self.textExpansionInApp = textExpansionInApp
            self.textExpansionEverywhere = textExpansionEverywhere
            self.chartsAIInsights = chartsAIInsights
            self.spendAlertThreshold = spendAlertThreshold
            self.petCompanionEnabled = petCompanionEnabled
            self.updatesAutomaticChecks = updatesAutomaticChecks
        }
    }

    let on: Set<ControlKind>

    init(inputs: Inputs) {
        var on: Set<ControlKind> = []
        for kind in ControlKind.visibleKinds where Self.isOn(kind, inputs) {
            on.insert(kind)
        }
        self.on = on
    }

    func isOn(_ kind: ControlKind) -> Bool { on.contains(kind) }

    /// Visible tiles in a band that are currently on.
    func onCount(in group: ControlGroup, among kinds: [ControlKind]) -> Int {
        kinds.filter { $0.group == group && on.contains($0) }.count
    }

    /// The one definition of "on" per kind. Exhaustive on purpose: adding a
    /// `ControlKind` without deciding what "on" means for it is a compile error.
    private static func isOn(_ kind: ControlKind, _ inputs: Inputs) -> Bool {
        switch kind {
        case .engineRoom:
            return inputs.daemonIsHealthy
        case .textExpansion:
            return inputs.textExpansionInApp || inputs.textExpansionEverywhere
        case .charts:
            return inputs.chartsAIInsights
        case .alerts:
            return inputs.spendAlertThreshold != nil
        case .appearance:
            // Appearance has no off state — the app always has a skin and a
            // layout. Counting it as on keeps "N of M on" honest rather than
            // permanently one short.
            return true
        case .pets:
            return inputs.petCompanionEnabled
        case .updates:
            return inputs.updatesAutomaticChecks
        }
    }
}
