import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// MARK: - Usage Provenance Method

/// Describes how token usage values were obtained for a given row.
public enum UsageProvenanceMethod: String, Codable, Hashable, CaseIterable, Sendable, Comparable {
    case providerLog = "provider_log"
    case connectorBridge = "connector_bridge"
    case daemonBridge = "daemon_bridge"
    case inAppChat = "in_app_chat"
    case billingAPI = "billing_api"
    case heuristicEstimate = "heuristic_estimate"
    case cloudSync = "cloud_sync"
    case unknown = "unknown"

    public var precedence: Int {
        switch self {
        case .providerLog: return 6
        case .billingAPI: return 5
        case .connectorBridge: return 4
        case .daemonBridge: return 4
        case .inAppChat: return 3
        case .cloudSync: return 2
        case .heuristicEstimate: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: UsageProvenanceMethod, rhs: UsageProvenanceMethod) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Provenance Confidence

public enum UsageProvenanceConfidence: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case exact = "exact"
    case derivedExact = "derived_exact"
    case highConfidenceEstimate = "high_confidence_estimate"
    case lowConfidenceEstimate = "low_confidence_estimate"
    case unknown = "unknown"

    public var precedence: Int {
        switch self {
        case .exact: return 4
        case .derivedExact: return 3
        case .highConfidenceEstimate: return 2
        case .lowConfidenceEstimate: return 1
        case .unknown: return 0
        }
    }

    public static func < (lhs: UsageProvenanceConfidence, rhs: UsageProvenanceConfidence) -> Bool {
        lhs.precedence < rhs.precedence
    }
}

// MARK: - Usage Source

public enum UsageSource: String, Codable, Hashable, CaseIterable, Sendable {
    case providerLog = "provider_log"
    case inAppChat = "in_app_chat"
    case cursorBridge = "cursor_bridge"
    case billingAPI = "billing_api"
    case daemon = "daemon"
    case unknown = "unknown"
}

// MARK: - Execution Source

/// The product surface that executed a model request. This is intentionally
/// separate from `UsageSource`, which describes how BurnBar ingested the row.
public enum UsageExecutionSourceKind: String, Codable, Hashable, CaseIterable, Sendable {
    case ide
    case cli
    case desktopApp = "desktop_app"
    case service
    case automation
    case unknown
}

public struct UsageExecutionSource: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: UsageExecutionSourceKind
    public let confidence: UsageProvenanceConfidence

    public init(
        id: String,
        name: String,
        kind: UsageExecutionSourceKind,
        confidence: UsageProvenanceConfidence
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.confidence = confidence
    }

    public static let unknown = UsageExecutionSource(
        id: "unknown",
        name: "Unknown",
        kind: .unknown,
        confidence: .unknown
    )
}

/// Normalizes parser identities and client headers into stable reporting IDs.
/// Raw user-agent strings are never retained.
public enum UsageExecutionSourceResolver {
    public static func resolve(
        provider: AgentProvider,
        usageSource: UsageSource,
        explicitID: String? = nil,
        explicitName: String? = nil,
        explicitKind: UsageExecutionSourceKind? = nil,
        explicitConfidence: UsageProvenanceConfidence? = nil
    ) -> UsageExecutionSource {
        if let explicitID,
           let normalizedID = normalizedID(explicitID),
           normalizedID != "unknown" {
            let known = knownSource(matching: normalizedID) ?? UsageExecutionSource(
                id: normalizedID,
                name: normalizedDisplayName(explicitName) ?? displayName(for: normalizedID),
                kind: explicitKind ?? .unknown,
                confidence: explicitConfidence ?? .exact
            )
            return UsageExecutionSource(
                id: known.id,
                name: normalizedDisplayName(explicitName) ?? known.name,
                kind: explicitKind ?? known.kind,
                confidence: explicitConfidence ?? known.confidence
            )
        }

        guard usageSource == .providerLog,
              let inferred = providerLogSource(for: provider) else {
            return .unknown
        }
        return inferred
    }

    /// Resolves a first-party client marker or a user-agent into a bounded,
    /// normalized source. Callers should prefer `x-openburnbar-client` and use
    /// the user-agent only as a fallback.
    public static func fromClientMarker(
        _ rawValue: String?,
        allowCustom: Bool = false
    ) -> UsageExecutionSource? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let normalized = value.lowercased()

        let aliases: [(needles: [String], source: UsageExecutionSource)] = [
            (["codex desktop", "codex-desktop", "chatgpt desktop"], known("codex-desktop", "Codex Desktop", .desktopApp)),
            (["codex vscode", "codex-vscode", "codex_vscode"], known("codex-vscode", "Codex for VS Code", .ide)),
            (["codex web", "codex-web", "codex cloud", "codex-cloud"], known("codex-cloud", "Codex Cloud", .service)),
            (["claude desktop", "claude-desktop"], known("claude-desktop", "Claude Desktop", .desktopApp)),
            (["cursor desktop", "cursor-desktop", "cursor ide", "cursor-ide"], known("cursor-desktop", "Cursor Desktop", .ide)),
            (["factory desktop", "factory-desktop"], known("factory-desktop", "Factory Desktop", .desktopApp)),
            (["minimax desktop", "minimax-desktop", "minimax agent", "minimax-agent"], known("minimax-desktop", "MiniMax Desktop", .desktopApp)),
            (["zcode desktop", "zcode-desktop", "z.ai desktop", "z.ai-desktop", "zai desktop", "zai-desktop"], known("zcode-desktop", "ZCode Desktop", .desktopApp)),
            (["devin desktop", "devin-desktop"], known("devin-desktop", "Devin Desktop", .desktopApp)),
            (["devin cli", "devin-cli", "devin"], known("devin-cli", "Devin CLI", .cli)),
            (["warp desktop", "warp-desktop", "warp terminal", "warp-terminal"], known("warp-desktop", "Warp Desktop", .desktopApp)),
            (["ollama desktop", "ollama-desktop"], known("ollama-desktop", "Ollama Desktop", .desktopApp)),
            (["hermes dashboard", "hermes-desktop", "hermes dashboard tui"], known("hermes-desktop", "Hermes Dashboard", .desktopApp)),
            (["cursor"], known("cursor", "Cursor", .ide)),
            (["grok build", "grok-build"], known("grok-build", "Grok Build", .cli)),
            (["claude code", "claude-code"], known("claude-code", "Claude Code", .cli)),
            (["factory-droid", "factory droid", "factory"], known("factory-droid", "Factory Droid", .automation)),
            (["opencode", "open-code"], known("opencode", "OpenCode", .cli)),
            (["codex"], known("codex-cli", "Codex CLI", .cli)),
            (["cline"], known("cline", "Cline", .ide)),
            (["kilo code", "kilo-code"], known("kilo-code", "Kilo Code", .ide)),
            (["roo code", "roo-code"], known("roo-code", "Roo Code", .ide)),
            (["windsurf"], known("windsurf", "Windsurf", .ide)),
            (["warp"], known("warp", "Warp", .cli)),
            (["gemini cli", "gemini-cli"], known("gemini-cli", "Gemini CLI", .cli)),
            (["openburnbar-cli", "burnbar-cli"], known("openburnbar-cli", "OpenBurnBar CLI", .cli)),
            (["openburnbar", "burnbar"], known("openburnbar", "OpenBurnBar", .desktopApp))
        ]
        if let known = aliases.first(where: { needles, _ in
            needles.contains { normalized.contains($0) }
        })?.source {
            return known
        }

        guard allowCustom else { return nil }
        let productMarker = value
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? value
        guard let id = normalizedID(productMarker), id != "unknown" else { return nil }
        return UsageExecutionSource(
            id: id,
            name: displayName(for: id),
            kind: .unknown,
            confidence: .exact
        )
    }

    private static func providerLogSource(for provider: AgentProvider) -> UsageExecutionSource? {
        switch provider {
        case .factory: return known("factory-droid", "Factory Droid", .automation, .derivedExact)
        case .claudeCode: return known("claude-code", "Claude Code", .cli, .derivedExact)
        case .copilot: return known("github-copilot", "GitHub Copilot", .ide, .derivedExact)
        case .aider: return known("aider", "Aider", .cli, .derivedExact)
        case .cursor, .cursorAgent: return known("cursor", "Cursor", .ide, .derivedExact)
        case .codex: return nil // Rollout session_meta distinguishes CLI from Desktop.
        case .openCode: return known("opencode", "OpenCode", .cli, .derivedExact)
        case .zai: return known("zai-cli", "Z.ai CLI", .cli, .derivedExact)
        case .minimax: return known("minimax-cli", "MiniMax CLI", .cli, .derivedExact)
        case .kimi: return known("kimi-cli", "Kimi CLI", .cli, .derivedExact)
        case .cline: return known("cline", "Cline", .ide, .derivedExact)
        case .kiloCode: return known("kilo-code", "Kilo Code", .ide, .derivedExact)
        case .rooCode: return known("roo-code", "Roo Code", .ide, .derivedExact)
        case .forgeDev: return known("forge", "Forge", .cli, .derivedExact)
        case .augment: return known("augment", "Augment", .ide, .derivedExact)
        case .hermes: return known("hermes", "Hermes", .cli, .derivedExact)
        case .piAgent: return known("pi-agent", "Pi Agent", .cli, .derivedExact)
        case .geminiCLI: return known("gemini-cli", "Gemini CLI", .cli, .derivedExact)
        case .antigravity: return known("antigravity", "Antigravity", .cli, .derivedExact)
        case .goose: return known("goose", "Goose", .cli, .derivedExact)
        case .openClaw: return known("openclaw", "OpenClaw", .service, .derivedExact)
        case .openClaude: return known("openclaude", "OpenClaude", .cli, .derivedExact)
        case .omp: return known("omp", "OMP", .cli, .derivedExact)
        case .ollama: return known("ollama", "Ollama", .service, .derivedExact)
        case .windsurf: return known("windsurf", "Windsurf", .ide, .derivedExact)
        case .devin: return known("devin-cli", "Devin CLI", .cli, .derivedExact)
        case .warp: return known("warp", "Warp", .cli, .derivedExact)
        case .xAI: return known("grok-build", "Grok Build", .cli, .derivedExact)
        case .junie: return known("junie", "Junie", .ide, .derivedExact)
        case .primeAgent: return known("prime-agent", "Prime Agent", .automation, .derivedExact)
        case .muse: return known("muse", "Muse", .cli, .derivedExact)
        case .openAI, .openBurnBar, .deepSeek, .mimo: return nil
        }
    }

    private static func knownSource(matching id: String) -> UsageExecutionSource? {
        let sources: [UsageExecutionSource] = [
            known("codex-cli", "Codex CLI", .cli),
            known("codex-desktop", "Codex Desktop", .desktopApp),
            known("codex-vscode", "Codex for VS Code", .ide),
            known("codex-cloud", "Codex Cloud", .service),
            known("cursor", "Cursor", .ide),
            known("cursor-desktop", "Cursor Desktop", .ide),
            known("grok-build", "Grok Build", .cli),
            known("claude-code", "Claude Code", .cli),
            known("claude-desktop", "Claude Desktop", .desktopApp),
            known("factory-droid", "Factory Droid", .automation),
            known("factory-desktop", "Factory Desktop", .desktopApp),
            known("minimax-cli", "MiniMax CLI", .cli),
            known("minimax-desktop", "MiniMax Desktop", .desktopApp),
            known("zai-cli", "Z.ai CLI", .cli),
            known("zcode-desktop", "ZCode Desktop", .desktopApp),
            known("devin-cli", "Devin CLI", .cli),
            known("devin-desktop", "Devin Desktop", .desktopApp),
            known("warp", "Warp", .cli),
            known("warp-desktop", "Warp Desktop", .desktopApp),
            known("ollama", "Ollama", .service),
            known("ollama-desktop", "Ollama Desktop", .desktopApp),
            known("hermes", "Hermes", .cli),
            known("hermes-desktop", "Hermes Dashboard", .desktopApp),
            known("opencode", "OpenCode", .cli),
            known("openburnbar", "OpenBurnBar", .desktopApp),
            known("windsurf", "Windsurf", .ide),
            known("cline", "Cline", .ide),
            known("kilo-code", "Kilo Code", .ide),
            known("roo-code", "Roo Code", .ide)
        ]
        return sources.first { $0.id == id }
    }

    private static func known(
        _ id: String,
        _ name: String,
        _ kind: UsageExecutionSourceKind,
        _ confidence: UsageProvenanceConfidence = .exact
    ) -> UsageExecutionSource {
        UsageExecutionSource(id: id, name: name, kind: kind, confidence: confidence)
    }

    private static func normalizedID(_ rawValue: String) -> String? {
        let slug = rawValue.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let normalized = String(slug)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(64))
    }

    private static func normalizedDisplayName(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

// MARK: - Token Usage Record

public struct TokenUsage: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let provider: AgentProvider
    public let sessionId: String
    public let projectName: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let cost: Double
    public let startTime: Date
    public let endTime: Date
    public let createdAt: Date
    public let usageSource: UsageSource
    public let executionSourceID: String
    public let executionSourceName: String
    public let executionSourceKind: UsageExecutionSourceKind
    public let executionSourceConfidence: UsageProvenanceConfidence
    public let deviceId: String?
    public let sourceDeviceId: String?
    public let sourceDeviceName: String?
    public let isRemote: Bool
    public let providerID: ProviderID
    public let providerAccountID: String?
    public let providerAccountLabel: String?
    public let providerAccountSource: ProviderAccountStorageScope?
    public let currency: String?
    public let recordedAt: String?
    public let eventKind: String?
    public let idempotencyKey: String?
    public let provenanceMethod: UsageProvenanceMethod
    public let provenanceConfidence: UsageProvenanceConfidence
    public let estimatorVersion: String

    /// The Elder Wand fusion run this row belongs to (`elderwand-<UUID>`), or
    /// `nil` for a normal request. It survives only on the daemon read paths and
    /// is dropped historically on SQLite import; the v49 `token_usage`
    /// migration adds a nullable `parentRequestID` column so imported rows can
    /// carry it, making the period fusion/normal partition a real SQL query.
    public let parentRequestID: String?
    /// Billing provenance: real per-token API dollars (`api`) vs the imputed
    /// list-price value of plan-covered work (`subscription`). `unknown` is
    /// the honest default for rows that predate v60 or resist classification —
    /// consumers surface it as its own bucket. Writers that cannot stamp a
    /// kind leave `.unknown` and the store derives one via
    /// `BurnBarBillingProvenance.classify(provider:usageSource:)`.
    public let billingKind: BurnBarBillingKind

    public var costUSD: Double { cost }

    public var cacheWriteTokens: Int { cacheCreationTokens }

    /// Whether this row belongs to an Elder Wand fusion run.
    public var isFusionRow: Bool {
        parentRequestID?.hasPrefix(FusionUsageRow.fusionParentPrefix) ?? false
    }

    public init(
        id: UUID? = nil,
        provider: AgentProvider,
        sessionId: String,
        projectName: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        costUSD: Double = 0,
        startTime: Date,
        endTime: Date,
        createdAt: Date = Date(),
        usageSource: UsageSource = .providerLog,
        executionSourceID: String? = nil,
        executionSourceName: String? = nil,
        executionSourceKind: UsageExecutionSourceKind? = nil,
        executionSourceConfidence: UsageProvenanceConfidence? = nil,
        deviceId: String? = nil,
        sourceDeviceId: String? = nil,
        sourceDeviceName: String? = nil,
        isRemote: Bool = false,
        providerID: ProviderID? = nil,
        providerAccountID: String? = nil,
        providerAccountLabel: String? = nil,
        providerAccountSource: ProviderAccountStorageScope? = nil,
        currency: String? = nil,
        recordedAt: String? = nil,
        eventKind: String? = nil,
        idempotencyKey: String? = nil,
        provenanceMethod: UsageProvenanceMethod = .unknown,
        provenanceConfidence: UsageProvenanceConfidence = .unknown,
        estimatorVersion: String = "",
        parentRequestID: String? = nil,
        billingKind: BurnBarBillingKind = .unknown
    ) {
        self.id = id ?? Self.deterministicID(
            provider: provider,
            sessionId: sessionId,
            model: model,
            sourceDeviceId: sourceDeviceId,
            providerAccountID: providerAccountID
        )
        self.provider = provider
        self.sessionId = sessionId
        self.projectName = projectName
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = Self.billedTotalTokens(
            input: inputTokens,
            output: outputTokens,
            cacheCreation: cacheCreationTokens,
            cacheRead: cacheReadTokens,
            reasoning: reasoningTokens
        )
        self.cost = costUSD
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.usageSource = usageSource
        let executionSource = UsageExecutionSourceResolver.resolve(
            provider: provider,
            usageSource: usageSource,
            explicitID: executionSourceID,
            explicitName: executionSourceName,
            explicitKind: executionSourceKind,
            explicitConfidence: executionSourceConfidence
        )
        self.executionSourceID = executionSource.id
        self.executionSourceName = executionSource.name
        self.executionSourceKind = executionSource.kind
        self.executionSourceConfidence = executionSource.confidence
        self.deviceId = deviceId
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.isRemote = isRemote
        self.providerID = providerID ?? provider.providerID
        self.providerAccountID = providerAccountID
        self.providerAccountLabel = providerAccountLabel
        self.providerAccountSource = providerAccountSource
        self.currency = currency
        self.recordedAt = recordedAt
        self.eventKind = eventKind
        self.idempotencyKey = idempotencyKey
        self.provenanceMethod = provenanceMethod
        self.provenanceConfidence = provenanceConfidence
        self.estimatorVersion = estimatorVersion
        self.parentRequestID = parentRequestID
        self.billingKind = billingKind
    }

    public static func deterministicID(
        provider: AgentProvider,
        sessionId: String,
        model: String,
        sourceDeviceId: String? = nil,
        providerAccountID: String? = nil
    ) -> UUID {
        let key = deterministicIdentityKey(
            provider: provider,
            sessionId: sessionId,
            model: model,
            sourceDeviceId: sourceDeviceId,
            providerAccountID: providerAccountID
        )
        return uuidV5(namespace: usageIDNamespace, name: key)
    }

    public static func deterministicIdentityKey(
        provider: AgentProvider,
        sessionId: String,
        model: String,
        sourceDeviceId: String? = nil,
        providerAccountID: String? = nil
    ) -> String {
        [
            provider.rawValue,
            sessionId,
            model,
            sourceDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            providerAccountIdentityPartition(from: providerAccountID) ?? ""
        ].joined(separator: "\u{1F}")
    }

    public static func providerAccountIdentityPartition(from rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("acct_sha256_"),
           trimmed.dropFirst("acct_sha256_".count).count == 24,
           trimmed.dropFirst("acct_sha256_".count).allSatisfy({ $0.isHexDigit }) {
            return trimmed
        }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "acct_sha256_\(hex.prefix(24))"
    }

    private static let usageIDNamespace = UUID(uuidString: "8CB8098C-794D-5D3F-A060-395F6B5BA5D8")!

    private static func uuidV5(namespace: UUID, name: String) -> UUID {
        var namespaceBytes = namespace.uuid
        var bytes = withUnsafeBytes(of: &namespaceBytes) { Array($0) }
        bytes.append(contentsOf: name.utf8)
        let digest = Insecure.SHA1.hash(data: Data(bytes))
        var uuidBytes = Array(digest.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }

    public static func billedTotalTokens(
        input: Int,
        output: Int,
        cacheCreation: Int,
        cacheRead: Int,
        reasoning: Int
    ) -> Int {
        max(0, input) + max(0, output) + max(0, cacheCreation) + max(0, cacheRead) + max(0, reasoning)
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, sessionId, projectName, model
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens
        case totalTokens, cost, costUsd, startTime, endTime, createdAt, usageSource
        case executionSourceID, executionSourceName, executionSourceKind, executionSourceConfidence
        case deviceId, sourceDeviceId, sourceDeviceName, isRemote
        case providerID, providerAccountID, providerAccountLabel, providerAccountSource
        case currency, recordedAt, eventKind, idempotencyKey
        case provenanceMethod, provenanceConfidence, estimatorVersion
        case parentRequestID
        case billingKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        projectName = try c.decode(String.self, forKey: .projectName)
        model = try c.decode(String.self, forKey: .model)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
            ?? c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens)
            ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? Self.billedTotalTokens(
                input: inputTokens,
                output: outputTokens,
                cacheCreation: cacheCreationTokens,
                cacheRead: cacheReadTokens,
                reasoning: reasoningTokens
            )
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
            ?? c.decodeIfPresent(Double.self, forKey: .costUsd)
            ?? 0.0
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        usageSource = try c.decodeIfPresent(UsageSource.self, forKey: .usageSource) ?? .unknown
        let decodedExecutionSource = UsageExecutionSourceResolver.resolve(
            provider: provider,
            usageSource: usageSource,
            explicitID: try c.decodeIfPresent(String.self, forKey: .executionSourceID),
            explicitName: try c.decodeIfPresent(String.self, forKey: .executionSourceName),
            explicitKind: try c.decodeIfPresent(UsageExecutionSourceKind.self, forKey: .executionSourceKind),
            explicitConfidence: try c.decodeIfPresent(UsageProvenanceConfidence.self, forKey: .executionSourceConfidence)
        )
        executionSourceID = decodedExecutionSource.id
        executionSourceName = decodedExecutionSource.name
        executionSourceKind = decodedExecutionSource.kind
        executionSourceConfidence = decodedExecutionSource.confidence
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        sourceDeviceId = try c.decodeIfPresent(String.self, forKey: .sourceDeviceId)
        sourceDeviceName = try c.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        isRemote = try c.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? provider.providerID
        providerAccountID = try c.decodeIfPresent(String.self, forKey: .providerAccountID)
        providerAccountLabel = try c.decodeIfPresent(String.self, forKey: .providerAccountLabel)
        providerAccountSource = try c.decodeIfPresent(ProviderAccountStorageScope.self, forKey: .providerAccountSource)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        recordedAt = try c.decodeIfPresent(String.self, forKey: .recordedAt)
        eventKind = try c.decodeIfPresent(String.self, forKey: .eventKind)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        provenanceMethod = try c.decodeIfPresent(UsageProvenanceMethod.self, forKey: .provenanceMethod) ?? .unknown
        provenanceConfidence = try c.decodeIfPresent(UsageProvenanceConfidence.self, forKey: .provenanceConfidence) ?? .unknown
        estimatorVersion = try c.decodeIfPresent(String.self, forKey: .estimatorVersion) ?? ""
        parentRequestID = try c.decodeIfPresent(String.self, forKey: .parentRequestID)
        billingKind = try c.decodeIfPresent(BurnBarBillingKind.self, forKey: .billingKind) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(model, forKey: .model)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(reasoningTokens, forKey: .reasoningTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
        try c.encode(cost, forKey: .cost)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(usageSource, forKey: .usageSource)
        try c.encode(executionSourceID, forKey: .executionSourceID)
        try c.encode(executionSourceName, forKey: .executionSourceName)
        try c.encode(executionSourceKind, forKey: .executionSourceKind)
        try c.encode(executionSourceConfidence, forKey: .executionSourceConfidence)
        try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(sourceDeviceId, forKey: .sourceDeviceId)
        try c.encodeIfPresent(sourceDeviceName, forKey: .sourceDeviceName)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encode(providerID, forKey: .providerID)
        try c.encodeIfPresent(providerAccountID, forKey: .providerAccountID)
        try c.encodeIfPresent(providerAccountLabel, forKey: .providerAccountLabel)
        try c.encodeIfPresent(providerAccountSource, forKey: .providerAccountSource)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(recordedAt, forKey: .recordedAt)
        try c.encodeIfPresent(eventKind, forKey: .eventKind)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try c.encode(provenanceMethod, forKey: .provenanceMethod)
        try c.encode(provenanceConfidence, forKey: .provenanceConfidence)
        try c.encode(estimatorVersion, forKey: .estimatorVersion)
        try c.encodeIfPresent(parentRequestID, forKey: .parentRequestID)
        try c.encode(billingKind, forKey: .billingKind)
    }

    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    public var formattedDuration: String {
        let interval = Int(duration)
        let hours = interval / 3600
        let minutes = (interval % 3600) / 60
        let seconds = interval % 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    public func intersects(dateRange: ClosedRange<Date>) -> Bool {
        let s = min(startTime, endTime)
        let e = max(startTime, endTime)
        return s <= dateRange.upperBound && e >= dateRange.lowerBound
    }
}
