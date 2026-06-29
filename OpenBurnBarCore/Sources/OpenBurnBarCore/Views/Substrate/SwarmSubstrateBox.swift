import SwiftUI

/// Resolves + caches the live ``SwarmSubstrate`` instance for a swarm host from
/// the three shared `@AppStorage` keys (substrate id, enabled gate, active
/// backdrop kernel). Caching by descriptor id keeps per-layout state (sprites,
/// kNN graphs) alive across frames instead of rebuilding every render.
///
/// Hosts hold one of these (`@State`/`@StateObject`) and feed
/// ``SwarmCanvasView``'s `substrate:` parameter, so the macOS dashboard, the
/// desktop wallpaper, and iOS all honor the same selection automatically.
@MainActor
public final class SwarmSubstrateBox: ObservableObject {
    private var cachedID: String?
    private var cached: SwarmSubstrate?

    public init() {}

    /// The substrate to render for `(kernelID, selectedID, enabled)`. Returns a
    /// `PlainDotsSubstrate` (the no-op default) when disabled or when the pick
    /// doesn't belong to the active kernel's family. The instance is rebuilt only
    /// when the resolved descriptor id changes.
    public func resolve(kernelID: String, selectedID: String, enabled: Bool) -> SwarmSubstrate {
        let descriptor: SubstrateDescriptor = enabled
            ? SubstrateCatalog.resolved(forKernel: kernelID, selectedID: selectedID)
            : SubstrateCatalog.plain(for: .forKernel(kernelID))

        if descriptor.id == cachedID, let cached { return cached }
        let made = descriptor.make()
        cachedID = descriptor.id
        cached = made
        return made
    }

    /// Convenience overload reading the live `UserDefaults` selection.
    public func resolveCurrent(kernelID: String) -> SwarmSubstrate {
        resolve(kernelID: kernelID,
                selectedID: SwarmSubstratePreferences.currentID,
                enabled: SwarmSubstratePreferences.isEnabled)
    }
}
