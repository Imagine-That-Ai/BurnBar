import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Atom Environment Key
//
// Injects a `HermesAtomNavigator` into the SwiftUI environment so any
// view in the chat surface tree can request navigation when an atom chip
// is tapped, without needing to know the concrete router implementation.

private struct HermesAtomNavigatorKey: EnvironmentKey {
    static let defaultValue: any HermesAtomNavigator = NoopHermesAtomNavigator()
}

extension EnvironmentValues {
    /// Concrete `HermesAtomNavigator` that handles atom-tap dispatch in the
    /// surrounding chat surface. Defaults to a no-op logger; provide the
    /// real router via `.environment(\.hermesAtomNavigator, …)` in the chat
    /// view's tree.
    var hermesAtomNavigator: any HermesAtomNavigator {
        get { self[HermesAtomNavigatorKey.self] }
        set { self[HermesAtomNavigatorKey.self] = newValue }
    }
}
