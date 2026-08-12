import Foundation

// MARK: - Agent Deck · shared models
//
// The three models every Agent Deck surface reads, owned in exactly one place.
//
// Presence, switching and the Mac model catalog are *app*-scoped, not
// pane-scoped: one presence resolution for the whole fleet, one catalog
// discovery per runtime, and one place a click becomes a switch. Giving each
// pane its own copy would re-probe every executable and re-run discovery per
// tile, which is the thing the deck was built to stop.
//
// They are still singular, but they are no longer globals. The app's root
// `ChatSessionController` constructs this deck once, and every pane controller
// receives that same instance by reference in
// `PaneWorkspaceModel.makePaneController` — the pattern the controller already
// uses to share `memoryService` and `memoryExtractionEngine` across panes. Deck
// views reach the models through the `controller` they already hold, so no view
// needs a new collaborator threaded into it and nothing reads a global.

/// The fleet-wide Agent Deck collaborators, injected via `ChatSessionController`.
@MainActor
final class AgentDeck {
    /// Fleet presence (`ready` / `busy` / `needs auth` / …) per backend.
    let presence: AgentPresenceModel
    /// The one path from a click to a backend switch.
    let switcher: AgentDeckSwitcher
    /// Per-runtime Mac model catalogs, discovered once and shared by the Sigil's
    /// model segment and `ChatEngineModelMenu`.
    let modelCatalog: CLIRuntimeModelCatalogCache

    init(
        presence: AgentPresenceModel = AgentPresenceModel(),
        switcher: AgentDeckSwitcher = AgentDeckSwitcher(),
        modelCatalog: CLIRuntimeModelCatalogCache = CLIRuntimeModelCatalogCache()
    ) {
        self.presence = presence
        self.switcher = switcher
        self.modelCatalog = modelCatalog
    }
}
