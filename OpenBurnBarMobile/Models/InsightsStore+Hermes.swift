import Foundation
import OpenBurnBarCore

/// Hermes wiring for the mobile `InsightsStore`.
///
/// Lives in its own file (instead of being folded into `InsightsStore`)
/// because the canonical store is co-edited by multiple agents — adding
/// surface area here keeps the Hermes glue diff-isolated and trivial to
/// review.
///
/// The shell calls `attachHermesIfReachable(_:)` whenever the user's
/// `HermesService` reachability changes. When the relay is connected we
/// register a fresh `HermesInsightAdapter` into the catalog and refresh;
/// when it drops we unregister so the picker no longer surfaces a stale
/// "Hermes" entry the user can't actually reach.
@MainActor
extension InsightsStore {
    /// Wire (or rewire) the Hermes Insights gateway against the user's
    /// current relay connection.
    ///
    /// Pass the live `HermesService`; the method snapshots its current
    /// connection (URL + auth + reachability) and registers an adapter
    /// only when reachable. Safe to call repeatedly — re-registering
    /// overwrites the previous adapter so a connection switch updates
    /// the catalog without leaking the old transport.
    func attachHermesIfReachable(via service: HermesService) async {
        let provider = service.makeInsightProvider()
        if let adapter = provider() {
            await catalog.register(adapter)
        } else {
            await catalog.unregister(providerKey: "hermes")
        }
        await refreshCatalog()
    }

    /// Unwire Hermes — call when the user signs out of the relay or
    /// the daemon goes away. Removes the catalog entry and forces
    /// automatic-selection to fall back to the next-best gateway.
    func detachHermes() async {
        await catalog.unregister(providerKey: "hermes")
        await refreshCatalog()
    }
}
