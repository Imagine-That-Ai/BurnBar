import Foundation

// MARK: - Agent Manifest (Hermes Square §6.1 / §6.6)
//
// Install manifest for third-party agents, modelled after the W3C MiniApp
// Manifest spec and MCP-UI / MCP-Apps shapes:
//   • https://www.w3.org/TR/miniapp-packaging/
//   • https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/
//
// JSON-on-disk shape — emitted by manifest authors, consumed by the host
// during install. Validation is strict: any field missing or malformed
// rejects the install with an explanatory error.
//
// Size budgets (plan §2 Pillar 3, anti-pattern 6, WeChat-derived):
//   • Manifest doc: ≤ 8 KB
//   • Per card payload: ≤ 2 MB
//   • Per agent total package: ≤ 20 MB

public struct AgentManifest: Codable, Sendable, Hashable {
    /// Manifest schema version. Bump when wire format changes incompatibly.
    public let manifestVersion: Int

    /// Stable URI for the agent (matches `AgentIdentity.id`).
    public let agentURI: String

    /// Display name shown in the inbox / brand zone.
    public let displayName: String

    /// One-line tagline shown beneath the name.
    public let tagline: String?

    /// One-character glyph or emoji.
    public let glyph: String

    /// 6-character hex string palette color.
    public let paletteHex: String

    /// Service or subscription tier.
    public let tier: AgentTier

    /// Capabilities declared by the agent. The host gates dispatch on
    /// these.
    public let capabilities: AgentCapabilities

    /// Dispatch transport — how the host actually invokes the agent.
    public let dispatchTransport: AgentIdentity.DispatchTransport

    /// Author / publisher details for the brand zone "About" section.
    public let author: Author

    /// Required scopes the user must grant on install. Presented in a
    /// single permission dialog (one row per scope, one explanation each).
    public let requiredScopes: [Scope]

    /// Card surfaces this agent emits. Lets the host pre-allocate
    /// renderers and reject manifests that exceed allowed kinds.
    public let cardSurfaces: [CardSurface]

    /// Push topics — only relevant for `tier == .subscription`. Each topic
    /// needs its own explicit consent.
    public let pushTopics: [PushTopic]

    /// Size declarations the host verifies on download.
    public let sizeDeclarations: SizeDeclarations

    /// Optional default personas shipped with the manifest.
    public let defaultPersonas: [AgentPersona]

    /// ISO-8601 manifest creation timestamp.
    public let createdAt: Date

    /// Semver string for the agent itself, displayed in the brand zone.
    public let version: String

    public init(
        manifestVersion: Int = 1,
        agentURI: String,
        displayName: String,
        tagline: String? = nil,
        glyph: String,
        paletteHex: String,
        tier: AgentTier,
        capabilities: AgentCapabilities,
        dispatchTransport: AgentIdentity.DispatchTransport,
        author: Author,
        requiredScopes: [Scope] = [],
        cardSurfaces: [CardSurface] = [],
        pushTopics: [PushTopic] = [],
        sizeDeclarations: SizeDeclarations = .default,
        defaultPersonas: [AgentPersona] = [.defaultPersona],
        createdAt: Date = Date(),
        version: String = "1.0.0"
    ) {
        self.manifestVersion = manifestVersion
        self.agentURI = agentURI
        self.displayName = displayName
        self.tagline = tagline
        self.glyph = glyph
        self.paletteHex = paletteHex
        self.tier = tier
        self.capabilities = capabilities
        self.dispatchTransport = dispatchTransport
        self.author = author
        self.requiredScopes = requiredScopes
        self.cardSurfaces = cardSurfaces
        self.pushTopics = pushTopics
        self.sizeDeclarations = sizeDeclarations
        self.defaultPersonas = defaultPersonas
        self.createdAt = createdAt
        self.version = version
    }
}

// MARK: - Author

extension AgentManifest {
    public struct Author: Codable, Sendable, Hashable {
        public let name: String
        public let url: String?
        public let email: String?

        public init(name: String, url: String? = nil, email: String? = nil) {
            self.name = name
            self.url = url
            self.email = email
        }
    }
}

// MARK: - Scope (permission)

extension AgentManifest {
    /// A permission the agent requests at install. Presented in a single
    /// dialog. The user can revoke individually from the brand zone.
    public struct Scope: Codable, Sendable, Hashable, Identifiable {
        /// Stable scope token (e.g., `files:read`, `network:fetch`,
        /// `calendar:read`, `inbox:write`). Convention is `domain:verb`.
        public let id: String

        /// Human display label.
        public let displayName: String

        /// One-line justification shown beneath the label. Manifest
        /// authors are expected to be specific here ("read your repo's
        /// files so I can summarise them") rather than generic.
        public let justification: String

        /// True if the agent cannot function without this scope (so the
        /// install dialog explains it as required vs optional).
        public let isRequired: Bool

        public init(id: String, displayName: String, justification: String, isRequired: Bool = true) {
            self.id = id
            self.displayName = displayName
            self.justification = justification
            self.isRequired = isRequired
        }
    }
}

// MARK: - Card Surface

extension AgentManifest {
    /// A kind of card the agent may emit. Host uses this to pre-bind
    /// renderers; rejects emissions outside the declared kinds.
    public struct CardSurface: Codable, Sendable, Hashable {
        public let kind: String          // matches `CardEnvelope` discriminator
        public let maxPayloadBytes: Int  // ≤ 2_097_152 (2 MB) per plan
        public let description: String?

        public init(kind: String, maxPayloadBytes: Int = 524_288, description: String? = nil) {
            self.kind = kind
            self.maxPayloadBytes = maxPayloadBytes
            self.description = description
        }
    }
}

// MARK: - Push Topic

extension AgentManifest {
    /// A subscription topic for `tier == .subscription` agents. Each topic
    /// needs explicit per-template consent (WeChat school).
    public struct PushTopic: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public let displayName: String
        public let description: String
        public let recommendedCadence: Cadence

        public enum Cadence: String, Codable, Sendable, Hashable {
            case onDemand     = "on_demand"
            case daily
            case weekly
            case monthly

            public var maxPerMonth: Int {
                switch self {
                case .onDemand: return AgentTier.subscriptionMonthlyHardCap
                case .daily:    return 30
                case .weekly:   return 4
                case .monthly:  return 1
                }
            }
        }

        public init(id: String, displayName: String, description: String, recommendedCadence: Cadence) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.recommendedCadence = recommendedCadence
        }
    }
}

// MARK: - Size Declarations

extension AgentManifest {
    public struct SizeDeclarations: Codable, Sendable, Hashable {
        public let manifestBytes: Int
        public let totalPackageBytes: Int
        public let perCardMaxBytes: Int

        public init(manifestBytes: Int, totalPackageBytes: Int, perCardMaxBytes: Int) {
            self.manifestBytes = manifestBytes
            self.totalPackageBytes = totalPackageBytes
            self.perCardMaxBytes = perCardMaxBytes
        }

        public static let `default` = SizeDeclarations(
            manifestBytes: 8_192,            // 8 KB
            totalPackageBytes: 20_971_520,   // 20 MB
            perCardMaxBytes: 2_097_152       // 2 MB
        )

        public var isWithinBudget: Bool {
            manifestBytes <= 8_192
                && totalPackageBytes <= 20_971_520
                && perCardMaxBytes <= 2_097_152
        }
    }
}

// MARK: - Validation

extension AgentManifest {
    public enum ValidationError: LocalizedError {
        case invalidURI(String)
        case unsupportedManifestVersion(Int)
        case missingDisplayName
        case missingGlyph
        case invalidPaletteHex(String)
        case sizeOverBudget(field: String, requested: Int, max: Int)
        case unsupportedCardKind(String)
        case subscriptionWithoutTopics
        case duplicateScope(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURI(let s):
                return "Agent URI '\(s)' is not a valid agent:// URI."
            case .unsupportedManifestVersion(let v):
                return "Manifest version \(v) is unsupported (this host accepts version 1)."
            case .missingDisplayName:
                return "Manifest is missing displayName."
            case .missingGlyph:
                return "Manifest is missing glyph."
            case .invalidPaletteHex(let h):
                return "Palette hex '\(h)' is not a valid 6-character hex color."
            case .sizeOverBudget(let f, let r, let m):
                return "Manifest \(f) is \(r) bytes, exceeds the \(m)-byte budget."
            case .unsupportedCardKind(let k):
                return "Card kind '\(k)' is not in the host renderer set."
            case .subscriptionWithoutTopics:
                return "Subscription-tier agents must declare at least one push topic."
            case .duplicateScope(let s):
                return "Duplicate scope id '\(s)'."
            }
        }
    }

    public static let supportedCardKinds: Set<String> = [
        "text", "table", "diff", "image", "chart", "approval", "mission", "custom"
    ]

    /// Validates the manifest against host rules. Returns silently on
    /// success, throws on any failure.
    public func validate() throws {
        if manifestVersion != 1 {
            throw ValidationError.unsupportedManifestVersion(manifestVersion)
        }
        if !agentURI.hasPrefix("agent://") {
            throw ValidationError.invalidURI(agentURI)
        }
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.missingDisplayName
        }
        if glyph.isEmpty {
            throw ValidationError.missingGlyph
        }
        if !Self.isValidHex(paletteHex) {
            throw ValidationError.invalidPaletteHex(paletteHex)
        }
        if !sizeDeclarations.isWithinBudget {
            let s = sizeDeclarations
            if s.manifestBytes > 8_192 {
                throw ValidationError.sizeOverBudget(field: "manifestBytes", requested: s.manifestBytes, max: 8_192)
            }
            if s.totalPackageBytes > 20_971_520 {
                throw ValidationError.sizeOverBudget(field: "totalPackageBytes", requested: s.totalPackageBytes, max: 20_971_520)
            }
            if s.perCardMaxBytes > 2_097_152 {
                throw ValidationError.sizeOverBudget(field: "perCardMaxBytes", requested: s.perCardMaxBytes, max: 2_097_152)
            }
        }
        for surface in cardSurfaces where !Self.supportedCardKinds.contains(surface.kind) {
            throw ValidationError.unsupportedCardKind(surface.kind)
        }
        if tier == .subscription && pushTopics.isEmpty {
            throw ValidationError.subscriptionWithoutTopics
        }
        let scopeIDs = requiredScopes.map(\.id)
        if Set(scopeIDs).count != scopeIDs.count {
            let dupes = Dictionary(grouping: scopeIDs, by: { $0 }).filter { $0.value.count > 1 }.keys
            throw ValidationError.duplicateScope(dupes.first ?? "?")
        }
    }

    private static func isValidHex(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6 else { return false }
        return trimmed.allSatisfy { c in
            let hex: Set<Character> = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f","A","B","C","D","E","F"]
            return hex.contains(c)
        }
    }
}

// MARK: - JSON Convenience

extension AgentManifest {
    public static func from(jsonString raw: String) throws -> AgentManifest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw ValidationError.missingDisplayName
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AgentManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func jsonString() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Manifest → Identity bridge

extension AgentIdentity {
    /// Construct an `AgentIdentity` from a validated manifest. Used at
    /// install time by the host's manifest registry.
    public init(fromManifest manifest: AgentManifest, installSource: InstallSource) {
        self.init(
            id: manifest.agentURI,
            runtimeID: AgentIdentity.builtInRuntime(from: manifest.agentURI),
            displayName: manifest.displayName,
            glyph: manifest.glyph,
            paletteHex: manifest.paletteHex,
            tier: manifest.tier,
            availability: .unknown,
            installSource: installSource,
            capabilities: manifest.capabilities,
            dispatchTransport: manifest.dispatchTransport,
            personas: manifest.defaultPersonas.personasSanitized(),
            lastSevenDays: nil,
            lastRefreshedAt: nil,
            tagline: manifest.tagline
        )
    }
}
