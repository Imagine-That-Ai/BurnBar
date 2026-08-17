import Foundation
import OpenBurnBarKernel

// MARK: - Control Kind
//
// The registry of every feature the Control Deck can render as a tile. Each
// kind carries its own editorial metadata (title, "why it matters" microcopy,
// symbol, group) so the deck reads as a curated instrument panel rather than a
// grid of anonymous switches — the same contract `ChartKind` uses for Charts.
//
// Adding a tile = add a case here, give it a group, and give it an arm in
// `ControlTileView`. `ControlDeckLayout.reconciled(_:)` appends new kinds with
// their defaults, so a shipped user layout survives every addition.
//
// The governing rule, enforced per tile in `ControlTileView`:
//
//   A deck control may flip a preference. It may never grant trust, egress
//   data off-device, open a network listener, or destroy a ledger.
//
// And the rule that keeps the deck from decaying into a Settings mirror:
//
//   Every tile renders one live fact read from real state. A tile that can
//   only render a label gets cut, not shipped as a link.
//
// Deliberately Foundation-only so `ControlDeckLayout` and the registry are
// unit-testable without mounting a view. The accent, the route, and the tile
// bodies live in the view layer (`ControlTileChrome` / `ControlTileView`) —
// exactly where `ChartKind.accent` lives relative to `ChartKind`.

/// The six fixed bands the deck renders, in render order. The IA *is* the
/// product here: reorder is allowed **within** a group and never across one,
/// so a user can prioritise their own cast tiles without dissolving the map.
enum ControlGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Agent fan-out and model routing — the things that spend on your behalf.
    case cast
    /// Money: what it cost, what it will cost, what shouts when it climbs.
    case spend
    /// What OpenBurnBar knows and what it types for you.
    case know
    /// Health and limits — the surfaces you check when something feels wrong.
    case watch
    /// Anything that reaches off this Mac, or lets something reach in.
    case reach
    /// The app itself: how it looks, who lives in it, how it updates.
    case house

    var id: String { rawValue }

    /// Rendered uppercased by `ControlDeckGroupHeader`; stored in title case so
    /// VoiceOver reads a word rather than an acronym.
    var title: String {
        switch self {
        case .cast: return "Cast"
        case .spend: return "Spend"
        case .know: return "Know"
        case .watch: return "Watch"
        case .reach: return "Reach"
        case .house: return "House"
        }
    }

    var caption: String {
        switch self {
        case .cast: return "Agents and routing"
        case .spend: return "Money and alarms"
        case .know: return "Memory and typing"
        case .watch: return "Health and limits"
        case .reach: return "Off-device and permissions"
        case .house: return "The app itself"
        }
    }
}

/// One deck tile's identity. `String`-backed so a layout persisted by an older
/// build decodes forward-compatibly (see `ControlDeckLayout.decode(from:)`).
enum ControlKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Declaration order is the default arrangement. Health first, because a
    // sick daemon is the cause of half the other tiles' degraded states.
    case engineRoom
    case aiInbox
    case modelRouter
    case wand
    case textExpansion
    case memoryMCP
    case charts
    case alerts
    case appearance
    case pets
    case updates
    case fleet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engineRoom: return "Engine Room"
        case .aiInbox: return "AI Inbox"
        case .modelRouter: return "Model Router"
        case .wand: return "The Wand"
        case .textExpansion: return "Text Expansion"
        case .memoryMCP: return "Memory MCP"
        case .charts: return "Charts"
        case .alerts: return "Alerts & Digest"
        case .appearance: return "Appearance"
        case .pets: return "Pets"
        case .updates: return "Updates"
        case .fleet: return "Fleet"
        }
    }

    /// One line of "why it matters" — the tile footer, and part of the ⌘K
    /// search corpus.
    var whyItMatters: String {
        switch self {
        case .engineRoom:
            return "The background daemon every other tile depends on."
        case .aiInbox:
            return "A background analyst that reads your work and says what needs you."
        case .modelRouter:
            return "One local endpoint that serves every OpenAI-compatible client."
        case .wand:
            return "Cast one prompt across parallel workers and keep the best."
        case .memoryMCP:
            return "The agents allowed to search your encrypted session memory."
        case .textExpansion:
            return "Short triggers that expand into the text you keep retyping."
        case .charts:
            return "Your usage, drawn honestly — and which drawings you keep."
        case .alerts:
            return "The number that shouts before the month gets expensive."
        case .appearance:
            return "Skin, layout, and how much light the glass lets through."
        case .pets:
            return "A companion on the desktop with a model behind its eyes."
        case .updates:
            return "How this copy of OpenBurnBar finds its next version."
        case .fleet:
            return "Which agents are actually running, and which one you steer."
        }
    }

    var systemImage: String {
        switch self {
        case .engineRoom: return "gearshape.2"
        case .aiInbox: return "tray.full"
        case .modelRouter: return "arrow.triangle.branch"
        case .wand: return "wand.and.stars"
        case .textExpansion: return "text.append"
        case .memoryMCP: return "point.3.connected.trianglepath.dotted"
        case .charts: return "chart.xyaxis.line"
        case .alerts: return "bell.badge"
        case .appearance: return "paintpalette"
        case .pets: return "pawprint"
        case .updates: return "arrow.triangle.2.circlepath"
        case .fleet: return "rectangle.3.group"
        }
    }

    var group: ControlGroup {
        switch self {
        case .engineRoom, .fleet: return .watch
        case .modelRouter, .wand: return .cast
        case .textExpansion, .memoryMCP: return .know
        case .aiInbox, .charts, .alerts: return .spend
        case .appearance, .pets, .updates: return .house
        }
    }

    /// Columns the tile occupies in its group's row. The deck grid is 4 columns
    /// wide at full width; span is clamped to the live column count.
    var defaultSpan: Int {
        switch self {
        // Two columns for the tiles whose live line is a sentence rather than a
        // number — an endpoint URL, a spend-against-budget pair, a client
        // roster. At one column they would truncate the fact they exist for.
        case .engineRoom, .textExpansion, .aiInbox, .modelRouter, .memoryMCP: return 2
        default: return 1
        }
    }

    var defaultVisible: Bool { true }

    /// Extra ⌘K search terms beyond `title` + `whyItMatters`. Typing
    /// "accessibility", "snippet", or "daemon" must reach the deck.
    var searchKeywords: [String] {
        switch self {
        case .engineRoom:
            return ["daemon", "background", "health", "protocol", "restart", "repair", "launchagent"]
        case .aiInbox:
            return ["inbox", "analyst", "brief", "triage", "digest", "egress", "budget", "founder lens"]
        case .modelRouter:
            return ["proxy", "gateway", "router", "openai compatible", "cursor", "vs code", "endpoint", "port", "8317"]
        case .wand:
            return ["wand", "cast", "fan out", "parallel", "workers", "mission", "swarm"]
        case .memoryMCP:
            return ["mcp", "remote mcp", "memory", "claude code", "codex", "droid", "clients", "hosted"]
        case .textExpansion:
            return ["snippet", "trigger", "accessibility", "keyboard", "expand", "abbreviation"]
        case .charts:
            return ["graph", "gallery", "ai insights", "analytics", "burn"]
        case .alerts:
            return ["threshold", "budget", "digest", "notification", "spend alert"]
        case .appearance:
            return ["theme", "skin", "editorial", "aurora", "glass", "transparency", "layout"]
        case .pets:
            return ["companion", "pet", "desktop", "hotkey", "nimbus"]
        case .updates:
            return ["version", "release", "upgrade", "channel", "pre-release"]
        case .fleet:
            return ["agents", "running", "orchestrator", "watch", "control", "live"]
        }
    }

    /// The Settings manifest item this tile clicks through to for its Tier-3
    /// surface (CRUD, credentials, policy). Verified against
    /// `AgentLens/Views/Settings/Search/SettingsManifest.swift`.
    var settingsItemID: String? {
        switch self {
        case .engineRoom: return "daemon.lifecycle.status"
        case .aiInbox: return "aiInbox.overview"
        case .modelRouter: return "modelProxy.overview"
        // The Wand has no Settings pane — it is cast from its own composer and
        // watched on the Missions lane, both dashboard surfaces.
        case .wand: return nil
        case .textExpansion: return "textExpansion.snippets"
        case .memoryMCP: return "cloud.overview"
        case .charts: return nil          // Charts is a dashboard route, not a Settings pane.
        case .alerts: return "alerts.dailySpend"
        case .appearance: return "general.appearance.skin"
        case .pets: return "pets.companion"
        case .updates: return "updates.automaticChecks"
        case .fleet: return nil
        }
    }

    /// Membership gate, when the feature is tier-locked. The locked tile keeps
    /// its value readable and veils only the control — a tier crest is an
    /// invitation, not a wall.
    var gatedFeature: GatedFeatureID? {
        switch self {
        // Hosted Remote MCP is the one deck feature the server, not this Mac,
        // decides you may use. `CloudStoreSettingsView.swift:50` reads the same
        // gate for the Settings card.
        case .memoryMCP: return .hostedMCP
        default: return nil
        }
    }

    /// Kinds this build is allowed to show at all. Build-gated tiles are
    /// **absent, not greyed** — an App Store build must not advertise a
    /// feature it does not ship. Reads the same `OpenBurnBarBuildGates` the
    /// Settings sidebar reads, so the two can never drift.
    static var visibleKinds: [ControlKind] {
        allCases.filter { kind in
            switch kind {
            case .updates: return OpenBurnBarBuildGates.updatesAvailable
            default: return true
            }
        }
    }
}
