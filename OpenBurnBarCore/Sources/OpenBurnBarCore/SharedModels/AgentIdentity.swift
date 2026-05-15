import Foundation

// MARK: - Agent Identity (Hermes Square §6.1)
//
// `AgentIdentity` is the rich record that replaces the thin
// `AssistantRuntimeID` enum for surfaces in Hermes Square. The enum stays
// load-bearing for legacy persistence (`assistants.activeRuntime`,
// `ChatTilePreferences`) — `AgentIdentity` *wraps* it for built-in runtimes
// and extends it for third-party + user-installed agents whose identifiers
// don't fit a fixed enum.
//
// The stable URI takes the form `agent://burnbar/<token>` for built-ins and
// `agent://third-party/<vendor>/<token>` for installed agents. Tokens are
// case-insensitive, kebab-case, and persisted as a single `String` so that
// future agents can be addressed without enum migrations.
//
// **Design notes**
//   • This type is the single source of identity across the Living Inbox,
//     Constellation brand-zone, dispatch flow, and federated search index.
//   • Built-in agents derive their `displayName` / `glyph` / `palette` /
//     `runtimeID` from `AssistantRuntimeID`, so existing UI (pill, mission
//     console, dispatcher) keeps working unchanged.
//   • `AgentIdentity` is `Codable` + `Sendable` + `Hashable` + `Identifiable`
//     so it persists, ships through XPC / Firestore, and identifies in
//     SwiftUI lists.
//   • Avoid widening this struct casually — the Mission Console snapshot,
//     CardEnvelope, and federated search all carry agents by reference and
//     a heavy identity ripples through every wire format.

public struct AgentIdentity: Codable, Sendable, Hashable, Identifiable {
    /// Stable URI. `id` is the canonical token used everywhere — Firestore
    /// document IDs, deep links, search index keys, persisted pins. Never
    /// mutate after creation. Example: `agent://burnbar/claude`.
    public let id: String

    /// Optional bridge to the legacy enum. Built-in agents set this so
    /// existing dispatchers can route via the enum. Third-party agents leave
    /// it `nil` and dispatch via `dispatchTransport`.
    public let runtimeID: AssistantRuntimeID?

    /// Human-readable name surfaced in the inbox, pill, and brand zone.
    public let displayName: String

    /// One-character glyph or emoji for the pinned-grid badge. Mirrors
    /// `AssistantRuntimeID.glyph` for built-ins.
    public let glyph: String

    /// Hex string anchor color (provider palette). Renderers compose this
    /// with the design-system `DesignSystemColors.primary(for:)` lookup for
    /// built-ins; third-party agents declare a manifest color.
    public let paletteHex: String

    /// Service vs subscription tier (WeChat Official Accounts split).
    public let tier: AgentTier

    /// Current online status snapshot.
    public let availability: Availability

    /// Where the agent comes from — built-in (shipped with the app),
    /// user-installed (via manifest URL or QR), shared by a teammate, or
    /// downloaded from the marketplace.
    public let installSource: InstallSource

    /// Capabilities declared by the agent. For built-ins these are derived
    /// from the CLI bridge; for third-party agents these are read from the
    /// `AgentManifest`.
    public let capabilities: AgentCapabilities

    /// How the host dispatches a mission to this agent.
    public let dispatchTransport: DispatchTransport

    /// Optional persona slots installed against this identity. The empty
    /// list means "default persona only".
    public let personas: [AgentPersona]

    /// Pre-aggregated stats over the trailing 7 days. Hydrated by the host;
    /// `nil` while the host hasn't loaded telemetry yet.
    public let lastSevenDays: AgentRecentStats?

    /// ISO-8601 timestamp the host last hydrated the identity from a fresh
    /// source. Lets the UI dim stale agent cards. Encoded as ISO string for
    /// portability across iOS / Android / Mac / Cloud Functions.
    public let lastRefreshedAt: Date?

    /// Free-form one-liner shown beneath the name in the brand zone.
    /// Manifest-driven for third-party agents; nil for most built-ins.
    public let tagline: String?

    public init(
        id: String,
        runtimeID: AssistantRuntimeID? = nil,
        displayName: String,
        glyph: String,
        paletteHex: String,
        tier: AgentTier = .service,
        availability: Availability = .unknown,
        installSource: InstallSource = .builtIn,
        capabilities: AgentCapabilities = .empty,
        dispatchTransport: DispatchTransport = .nativeRelay,
        personas: [AgentPersona] = [],
        lastSevenDays: AgentRecentStats? = nil,
        lastRefreshedAt: Date? = nil,
        tagline: String? = nil
    ) {
        self.id = id
        self.runtimeID = runtimeID
        self.displayName = displayName
        self.glyph = glyph
        self.paletteHex = paletteHex
        self.tier = tier
        self.availability = availability
        self.installSource = installSource
        self.capabilities = capabilities
        self.dispatchTransport = dispatchTransport
        self.personas = personas
        self.lastSevenDays = lastSevenDays
        self.lastRefreshedAt = lastRefreshedAt
        self.tagline = tagline
    }
}

// MARK: - Availability

extension AgentIdentity {
    public enum Availability: String, Codable, Sendable, Hashable {
        case online
        case offline
        case degraded
        case unknown

        public var displayLabel: String {
            switch self {
            case .online:   return "Online"
            case .offline:  return "Offline"
            case .degraded: return "Degraded"
            case .unknown:  return "Unknown"
            }
        }

        /// Whether dispatching to this agent is expected to succeed.
        public var isDispatchable: Bool {
            switch self {
            case .online, .degraded, .unknown: return true
            case .offline: return false
            }
        }
    }
}

// MARK: - Install Source

extension AgentIdentity {
    public enum InstallSource: Codable, Sendable, Hashable {
        case builtIn
        case userInstalled(manifestURL: String)
        case sharedByTeammate(uid: String)
        case marketplace(catalogID: String)

        public var displayLabel: String {
            switch self {
            case .builtIn:               return "Built-in"
            case .userInstalled:         return "User-installed"
            case .sharedByTeammate:      return "Shared by teammate"
            case .marketplace:           return "Marketplace"
            }
        }

        public var canBeUninstalled: Bool {
            switch self {
            case .builtIn:    return false
            default:          return true
            }
        }

        // Codable shape: { "kind": "builtIn" } or { "kind": "userInstalled",
        // "manifestURL": "https://..." } etc. Keep the discriminator key as
        // `kind` to stay consistent with `CardEnvelope` and other union
        // shapes in the package.
        private enum CodingKeys: String, CodingKey {
            case kind, manifestURL, uid, catalogID
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "builtIn":
                self = .builtIn
            case "userInstalled":
                let url = try container.decode(String.self, forKey: .manifestURL)
                self = .userInstalled(manifestURL: url)
            case "sharedByTeammate":
                let uid = try container.decode(String.self, forKey: .uid)
                self = .sharedByTeammate(uid: uid)
            case "marketplace":
                let cid = try container.decode(String.self, forKey: .catalogID)
                self = .marketplace(catalogID: cid)
            default:
                self = .builtIn
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .builtIn:
                try container.encode("builtIn", forKey: .kind)
            case .userInstalled(let url):
                try container.encode("userInstalled", forKey: .kind)
                try container.encode(url, forKey: .manifestURL)
            case .sharedByTeammate(let uid):
                try container.encode("sharedByTeammate", forKey: .kind)
                try container.encode(uid, forKey: .uid)
            case .marketplace(let cid):
                try container.encode("marketplace", forKey: .kind)
                try container.encode(cid, forKey: .catalogID)
            }
        }
    }
}

// MARK: - Capabilities

/// Bitmask-style capability declaration. Each flag corresponds to a host
/// primitive the agent advertises in its manifest. The host uses this set
/// to render capability pills on the brand zone and to gate features
/// (e.g., a fan-out diff card only ships if all selected agents have the
/// `.diff` capability).
public struct AgentCapabilities: Codable, Sendable, Hashable, OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let toolUse        = AgentCapabilities(rawValue: 1 << 0)
    public static let vision         = AgentCapabilities(rawValue: 1 << 1)
    public static let audio          = AgentCapabilities(rawValue: 1 << 2)
    public static let agentLoops     = AgentCapabilities(rawValue: 1 << 3)
    public static let fileEdits      = AgentCapabilities(rawValue: 1 << 4)
    public static let shell          = AgentCapabilities(rawValue: 1 << 5)
    public static let webBrowse      = AgentCapabilities(rawValue: 1 << 6)
    public static let codeExecution  = AgentCapabilities(rawValue: 1 << 7)
    public static let imageGen       = AgentCapabilities(rawValue: 1 << 8)
    public static let memory         = AgentCapabilities(rawValue: 1 << 9)
    public static let streamingDiff  = AgentCapabilities(rawValue: 1 << 10)
    public static let mcpUI          = AgentCapabilities(rawValue: 1 << 11)

    public static let empty: AgentCapabilities = []
    /// Convenience: everything a fully-loaded CLI runtime supports.
    public static let fullCLI: AgentCapabilities = [
        .toolUse, .agentLoops, .fileEdits, .shell, .streamingDiff
    ]
    public static let fullChat: AgentCapabilities = [
        .toolUse, .vision, .audio, .imageGen, .memory, .mcpUI
    ]

    /// Stable string list for human display + manifest serialisation.
    public var displayPills: [String] {
        var out: [String] = []
        if contains(.toolUse)       { out.append("Tool use") }
        if contains(.vision)        { out.append("Vision") }
        if contains(.audio)         { out.append("Voice") }
        if contains(.agentLoops)    { out.append("Agent loops") }
        if contains(.fileEdits)     { out.append("File edits") }
        if contains(.shell)         { out.append("Shell") }
        if contains(.webBrowse)     { out.append("Web") }
        if contains(.codeExecution) { out.append("Code execution") }
        if contains(.imageGen)      { out.append("Image gen") }
        if contains(.memory)        { out.append("Memory") }
        if contains(.streamingDiff) { out.append("Streaming diff") }
        if contains(.mcpUI)         { out.append("MCP-UI") }
        return out
    }
}

// MARK: - Dispatch Transport

extension AgentIdentity {
    /// How the host actually delivers a mission to this agent.
    public enum DispatchTransport: Codable, Sendable, Hashable {
        /// In-process native runtime (Hermes / Pi today on mobile).
        case nativeRelay
        /// Firestore relay to a paired Mac, claimed by `CLIAgentMissionRequestListener`.
        case macRelay(runtime: String)
        /// HTTP gateway to a remote endpoint (for SaaS-shipped agents).
        case httpGateway(endpoint: String)
        /// MCP server discovered on LAN or paired explicitly.
        case mcpServer(url: String)

        public var displayLabel: String {
            switch self {
            case .nativeRelay:           return "Native relay"
            case .macRelay:              return "Mac relay"
            case .httpGateway:           return "HTTP gateway"
            case .mcpServer:             return "MCP server"
            }
        }

        public var requiresMacBridge: Bool {
            switch self {
            case .macRelay: return true
            default:        return false
            }
        }

        private enum CodingKeys: String, CodingKey {
            case kind, runtime, endpoint, url
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "nativeRelay":
                self = .nativeRelay
            case "macRelay":
                let runtime = try container.decode(String.self, forKey: .runtime)
                self = .macRelay(runtime: runtime)
            case "httpGateway":
                let endpoint = try container.decode(String.self, forKey: .endpoint)
                self = .httpGateway(endpoint: endpoint)
            case "mcpServer":
                let url = try container.decode(String.self, forKey: .url)
                self = .mcpServer(url: url)
            default:
                self = .nativeRelay
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .nativeRelay:
                try container.encode("nativeRelay", forKey: .kind)
            case .macRelay(let runtime):
                try container.encode("macRelay", forKey: .kind)
                try container.encode(runtime, forKey: .runtime)
            case .httpGateway(let endpoint):
                try container.encode("httpGateway", forKey: .kind)
                try container.encode(endpoint, forKey: .endpoint)
            case .mcpServer(let url):
                try container.encode("mcpServer", forKey: .kind)
                try container.encode(url, forKey: .url)
            }
        }
    }
}

// MARK: - Recent Stats

/// Pre-aggregated activity over a trailing window (default 7d). Hosts
/// hydrate this before showing the brand zone or pinned grid badge.
public struct AgentRecentStats: Codable, Sendable, Hashable {
    public let threadCount: Int
    public let missionCount: Int
    public let burnUSD: Double
    public let successRate: Double          // 0…1
    public let medianRoundtripSeconds: Double?
    public let windowDays: Int

    public init(
        threadCount: Int,
        missionCount: Int,
        burnUSD: Double,
        successRate: Double,
        medianRoundtripSeconds: Double? = nil,
        windowDays: Int = 7
    ) {
        self.threadCount = threadCount
        self.missionCount = missionCount
        self.burnUSD = burnUSD
        self.successRate = max(0, min(1, successRate))
        self.medianRoundtripSeconds = medianRoundtripSeconds
        self.windowDays = windowDays
    }

    public static let empty = AgentRecentStats(
        threadCount: 0,
        missionCount: 0,
        burnUSD: 0,
        successRate: 0,
        medianRoundtripSeconds: nil,
        windowDays: 7
    )
}

// MARK: - Built-in Identity Catalog

extension AgentIdentity {
    /// Stable URI for a built-in runtime. Mirrors `AssistantRuntimeID`
    /// rawValues so the URI is parseable by the legacy dispatcher.
    public static func builtInURI(_ runtime: AssistantRuntimeID) -> String {
        "agent://burnbar/\(runtime.rawValue)"
    }

    /// Try to recover the `AssistantRuntimeID` from a stable URI. Returns
    /// `nil` for non-built-in URIs.
    public static func builtInRuntime(from uri: String) -> AssistantRuntimeID? {
        let prefix = "agent://burnbar/"
        guard uri.hasPrefix(prefix) else { return nil }
        let token = String(uri.dropFirst(prefix.count))
        return AssistantRuntimeID(rawValue: token)
    }

    /// Construct the canonical built-in identity for a runtime. Used by
    /// `AgentIdentityRegistry.builtIns` to seed the registry on every cold
    /// start. Palette comes from `AssistantRuntimeID` / `AgentProvider`.
    public static func builtIn(
        _ runtime: AssistantRuntimeID,
        availability: Availability = .unknown,
        lastSevenDays: AgentRecentStats? = nil,
        lastRefreshedAt: Date? = nil
    ) -> AgentIdentity {
        let paletteHex: String
        let tagline: String?
        let capabilities: AgentCapabilities
        let dispatchTransport: DispatchTransport

        switch runtime {
        case .hermes:
            paletteHex = "AEA69C"            // mercury silver from the editorial vocab
            tagline = "Editorial synthesis and mission triage."
            capabilities = .fullChat
            dispatchTransport = .nativeRelay
        case .pi:
            paletteHex = "7C3AED"
            tagline = "Conversational sidekick. Warm, fast, casual."
            capabilities = .fullChat.subtracting(.imageGen)
            dispatchTransport = .nativeRelay
        case .claude:
            paletteHex = "CC785C"
            tagline = "Anthropic Claude Code via your Mac."
            capabilities = [.fullCLI, .vision, .mcpUI]
            dispatchTransport = .macRelay(runtime: "claude")
        case .codex:
            paletteHex = "00A67E"
            tagline = "OpenAI Codex via your Mac."
            capabilities = [.fullCLI, .codeExecution, .mcpUI]
            dispatchTransport = .macRelay(runtime: "codex")
        case .openClaw:
            paletteHex = "FF6B6B"
            tagline = "Local-first agent runtime. Yours by default."
            capabilities = [.fullCLI, .memory, .mcpUI]
            dispatchTransport = .macRelay(runtime: "openclaw")
        }

        return AgentIdentity(
            id: AgentIdentity.builtInURI(runtime),
            runtimeID: runtime,
            displayName: runtime.displayName,
            glyph: runtime.glyph,
            paletteHex: paletteHex,
            tier: .service,
            availability: availability,
            installSource: .builtIn,
            capabilities: capabilities,
            dispatchTransport: dispatchTransport,
            personas: [],
            lastSevenDays: lastSevenDays,
            lastRefreshedAt: lastRefreshedAt,
            tagline: tagline
        )
    }

    /// Convenience: the canonical seed set for the Hermes Square pinned grid
    /// on first run. Mirrors `AssistantRuntimeID.allCases` order.
    public static let defaultBuiltIns: [AgentIdentity] = AssistantRuntimeID.allCases.map {
        AgentIdentity.builtIn($0)
    }
}

// MARK: - Deep-link helpers

extension AgentIdentity {
    /// Renders a deep link path the host opens when a notification or
    /// shared URL references this agent — `agent://...` URIs are routed by
    /// the iOS / Android router to the brand zone or the inbox thread.
    public var deepLinkURL: URL? {
        URL(string: id)
    }
}
