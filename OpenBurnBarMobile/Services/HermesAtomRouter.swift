import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Atom Router (iOS)
//
// Observable bridge between an atom-tap and the chat view's presentation
// state. When an atom chip is tapped, `open(_:)` is invoked which sets the
// `pending` value; the chat view binds to `pending` to drive
// `.sheet(item:)` of the `HermesAtomDetailSheet`.
//
// When the user confirms the sheet's primary action, `confirm(_:)` fires
// `onPerform` (if installed by the host surface) **and** broadcasts the
// canonical `Notification.Name.hermesAtomActivated` with the atom in
// `userInfo["atom"]`. Top-level navigation (tab switching, sheet
// presentation) listens to that notification and routes accordingly. The
// router stays presentation-agnostic and never imports `RootTabView` or
// any other concrete surface.

@MainActor
@Observable
final class HermesAtomRouter: HermesAtomNavigator {

    /// Pending atom that drives the detail sheet presentation. Set by
    /// `open(_:)`, cleared on dismiss.
    var pending: PendingAtom?

    /// Most-recently-confirmed destination — read by the chat view inside
    /// `.onChange(of: router.confirmedDestination)` to perform navigation.
    /// Updated even when `onPerform` is installed, so reactive observers
    /// can react idempotently.
    var confirmedDestination: HermesAtomDestination?

    /// Optional caller-supplied destination handler. Installed by the chat
    /// surface in its `.task`; defaults to `nil` so the router stays
    /// usable in previews without external context. Always called on the
    /// main actor.
    var onPerform: ((HermesAtom) -> Void)?

    init() {}

    // MARK: HermesAtomNavigator

    func open(_ atom: HermesAtom) {
        pending = PendingAtom(atom: atom, label: atom.fallbackLabel)
    }

    /// Invoked from `HermesAtomDetailSheet`'s primary action button.
    /// Drives three things, in order:
    ///   1. Updates `confirmedDestination` so reactive observers fire.
    ///   2. Calls the host-installed `onPerform` closure if present.
    ///   3. Broadcasts `Notification.Name.hermesAtomActivated` for any
    ///      ambient subscriber that wants to handle the navigation.
    func confirm(_ pending: PendingAtom) {
        let destination = HermesAtomDestination(atom: pending.atom)
        confirmedDestination = destination
        onPerform?(pending.atom)
        NotificationCenter.default.post(
            name: .hermesAtomActivated,
            object: nil,
            userInfo: [HermesAtomNotificationKey.atom: pending.atom]
        )
    }

    /// Identifier for the pending sheet — mirrors atom equality so the same
    /// chip tapped twice doesn't recreate the sheet identity (smoother UI).
    struct PendingAtom: Identifiable, Hashable {
        let atom: HermesAtom
        let label: String
        var id: HermesAtom { atom }
    }
}

// MARK: - Destination

/// A resolved destination produced when the user confirms the detail sheet.
/// The chat view inspects this to decide where to send the user — push a
/// route, switch a tab, or present a focused sheet.
struct HermesAtomDestination: Equatable, Hashable {
    let atom: HermesAtom
}

// MARK: - Notification Bridge

extension Notification.Name {
    /// Posted by `HermesAtomRouter.confirm(_:)` whenever the user taps a
    /// chip's primary action. `userInfo[HermesAtomNotificationKey.atom]`
    /// carries the typed `HermesAtom`. Subscribed to by the iOS root
    /// surfaces (RootTabView, deep-link handler) to perform navigation
    /// without coupling chat surfaces to specific destinations.
    static let hermesAtomActivated = Notification.Name("hermesAtomActivated")
}

enum HermesAtomNotificationKey {
    /// `userInfo` key carrying the activated `HermesAtom`.
    static let atom = "atom"
}
