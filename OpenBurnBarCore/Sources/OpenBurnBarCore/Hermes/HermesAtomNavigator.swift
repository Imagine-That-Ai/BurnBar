import Foundation
import OSLog

// MARK: - Hermes Atom Navigator
//
// Abstract dispatcher for atom-tap navigation. Each platform implements this
// protocol against its own navigation primitives:
//
//   - iOS: pushes onto the active NavigationStack, presents sheets, switches
//     tabs via the root tab model.
//   - macOS: opens the matching sidebar route, presents popovers / overlays.
//
// We keep this in Core so the shared `HermesRichBubble` can call into a
// navigator via SwiftUI environment without leaking platform types.

public protocol HermesAtomNavigator: AnyObject, Sendable {
    /// User tapped a chip for the given atom — perform the most useful
    /// navigation. Implementations should be idempotent and safe to call
    /// from any view in any state. Concrete implementations decide their
    /// own actor isolation (typically `@MainActor`); the protocol stays
    /// nonisolated so a no-op default value can be constructed by
    /// SwiftUI's `EnvironmentKey` machinery from any context.
    @MainActor func open(_ atom: HermesAtom)
}

// MARK: - No-op default
//
// A safe default navigator used when no concrete one has been injected yet.
// Logs to OS log so missed wiring is visible during development.

public final class NoopHermesAtomNavigator: HermesAtomNavigator {
    private let logger = Logger(subsystem: "com.openburnbar.core", category: "HermesAtomNavigator")
    public init() {}
    @MainActor public func open(_ atom: HermesAtom) {
        logger.notice("Atom tapped but no navigator is wired: \(String(describing: atom), privacy: .public)")
    }
}
