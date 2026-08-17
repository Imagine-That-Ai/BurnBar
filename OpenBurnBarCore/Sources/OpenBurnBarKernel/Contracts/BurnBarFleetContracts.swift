import Foundation

// MARK: - Contract errors

/// Typed errors thrown by the fleet contract layer. Decoding never crashes:
/// malformed wire payloads surface as one of these (or a `DecodingError`).
public enum BurnBarFleetContractError: Error, LocalizedError, Equatable, Sendable {
    /// The payload's `schemaVersion` is not in the supported set.
    case incompatibleSchemaVersion(found: Int, supported: [Int])
    /// A date field did not parse as an ISO-8601 UTC string.
    case invalidISODateString(String)
    /// An unknown `BurnBarFleetConfidence` wire string.
    case unknownConfidence(String)
    /// An unknown `BurnBarFleetAgentStatus` wire string.
    case unknownStatus(String)
    /// An unknown orchestrator designation kind.
    case unknownDesignationKind(String)
    /// An unknown directive kind wire string.
    case unknownDirectiveKind(String)
    /// An unknown directive state kind.
    case unknownDirectiveStateKind(String)
    /// An unknown sensor state kind.
    case unknownSensorStateKind(String)
    /// An unknown probe-health state kind.
    case unknownProbeHealthStateKind(String)
    /// An unknown persistence-health kind.
    case unknownPersistenceHealthKind(String)
    /// A reason-bearing state carried an empty (whitespace-only) reason.
    case emptyReason(field: String)
    /// Schema-level status/confidence consistency rule violation.
    case inconsistentStatusConfidence(status: BurnBarFleetAgentStatus, confidence: BurnBarFleetConfidence)

    public var errorDescription: String? {
        switch self {
        case .incompatibleSchemaVersion(let found, let supported):
            return "BurnBar fleet snapshot schemaVersion \(found) is not supported (supported: \(supported))."
        case .invalidISODateString(let raw):
            return "Invalid ISO-8601 UTC date string: \(raw)"
        case .unknownConfidence(let raw):
            return "Unknown BurnBar fleet confidence wire value: \(raw)"
        case .unknownStatus(let raw):
            return "Unknown BurnBar fleet agent status wire value: \(raw)"
        case .unknownDesignationKind(let raw):
            return "Unknown orchestrator designation kind: \(raw)"
        case .unknownDirectiveKind(let raw):
            return "Unknown fleet directive kind: \(raw)"
        case .unknownDirectiveStateKind(let raw):
            return "Unknown fleet directive state kind: \(raw)"
        case .unknownSensorStateKind(let raw):
            return "Unknown sensor state kind: \(raw)"
        case .unknownProbeHealthStateKind(let raw):
            return "Unknown probe-health state kind: \(raw)"
        case .unknownPersistenceHealthKind(let raw):
            return "Unknown persistence-health kind: \(raw)"
        case .emptyReason(let field):
            return "\(field) requires a non-empty reason."
        case .inconsistentStatusConfidence(let status, let confidence):
            return "Inconsistent fleet row: status '\(status.rawValue)' with confidence '\(confidence.rawValue)'."
        }
    }
}

// MARK: - Agent identity

/// Stable wire identity for fleet agents. The declared roster is exactly these
/// ten cases; the daemon does not know the app-side `AgentProvider` enum.
///
/// Wire strings (golden, do not change):
/// `claude-code`, `factory-droid`, `codex`, `hermes`, `grok-bot`, `grok-cli`,
/// `pi`, `cursor`, `kimi`, `gemini-cli`.
///
/// Unknown ids decode losslessly to `.unknown(String)` for additive forward
/// compatibility and re-encode to the exact same string; they are not part of
/// the declared ten-ID roster (`allCases` / `declaredRoster`).
public enum BurnBarFleetAgentID: Hashable, Sendable, Codable, CaseIterable {
    case claudeCode
    case factoryDroid
    case codex
    case hermes
    case grokBot
    case grokCLI
    case pi
    case cursor
    case kimi
    case geminiCLI
    /// Forward-compatible holder for an id outside the declared ten.
    case unknown(String)

    /// The exact ten declared roster IDs, in canonical order.
    public static let declaredRoster: [BurnBarFleetAgentID] = [
        .claudeCode, .factoryDroid, .codex, .hermes, .grokBot,
        .grokCLI, .pi, .cursor, .kimi, .geminiCLI
    ]

    public static var allCases: [BurnBarFleetAgentID] { declaredRoster }

    /// The exact wire string for this id (lossless for `.unknown`).
    public var wireValue: String {
        switch self {
        case .claudeCode:
            return "claude-code"
        case .factoryDroid:
            return "factory-droid"
        case .codex:
            return "codex"
        case .hermes:
            return "hermes"
        case .grokBot:
            return "grok-bot"
        case .grokCLI:
            return "grok-cli"
        case .pi:
            return "pi"
        case .cursor:
            return "cursor"
        case .kimi:
            return "kimi"
        case .geminiCLI:
            return "gemini-cli"
        case .unknown(let raw):
            return raw
        }
    }

    /// Known-only lookup: returns nil for ids outside the declared ten.
    public init?(wireValue: String) {
        switch wireValue {
        case "claude-code":
            self = .claudeCode
        case "factory-droid":
            self = .factoryDroid
        case "codex":
            self = .codex
        case "hermes":
            self = .hermes
        case "grok-bot":
            self = .grokBot
        case "grok-cli":
            self = .grokCLI
        case "pi":
            self = .pi
        case "cursor":
            self = .cursor
        case "kimi":
            self = .kimi
        case "gemini-cli":
            self = .geminiCLI
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let known = BurnBarFleetAgentID(wireValue: raw) {
            self = known
        } else {
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Agent status & confidence

/// Liveness status of a fleet agent row.
///
/// Wire strings (golden): `running`, `idle`, `stale`, `unknown`.
/// Semantics: `running` = active work signal right now; `idle` = agent
/// infrastructure alive but no active work; `stale` = last signal beyond the
/// freshness window; `unknown` = probe could not determine.
public enum BurnBarFleetAgentStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case idle
    case stale
    case unknown

    /// Roll-up rank: running outranks idle, then stale, then unknown.
    public var rollupRank: Int {
        switch self {
        case .running:
            return 3
        case .idle:
            return 2
        case .stale:
            return 1
        case .unknown:
            return 0
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = BurnBarFleetAgentStatus(rawValue: raw) else {
            throw BurnBarFleetContractError.unknownStatus(raw)
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Liveness confidence of a fleet agent row, ordered strongest to weakest:
/// `exactProcess > activeSessionFile > logHeartbeat > estimated > unsupported`.
///
/// Wire strings (golden): `exactProcess`, `activeSessionFile`, `logHeartbeat`,
/// `estimated`, `unsupported`.
public enum BurnBarFleetConfidence: String, Codable, CaseIterable, Comparable, Sendable {
    case exactProcess
    case activeSessionFile
    case logHeartbeat
    case estimated
    case unsupported

    private var rank: Int {
        switch self {
        case .exactProcess:
            return 5
        case .activeSessionFile:
            return 4
        case .logHeartbeat:
            return 3
        case .estimated:
            return 2
        case .unsupported:
            return 1
        }
    }

    public static func < (lhs: BurnBarFleetConfidence, rhs: BurnBarFleetConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = BurnBarFleetConfidence(rawValue: raw) else {
            throw BurnBarFleetContractError.unknownConfidence(raw)
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Evidence & process

/// One piece of probe evidence behind an agent row (the evidence trail).
public struct BurnBarFleetSignalSource: Codable, Hashable, Sendable {
    /// e.g. "session-registry", "heartbeat-file", "task-ledger", "lock-file",
    /// "log-mtime", "process-list".
    public let kind: String
    /// Absolute path of the signal file inside the agent's declared roots.
    public let path: String
    public let detail: String?

    public init(kind: String, path: String, detail: String? = nil) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

/// Process-level detail, present only when exact-process confidence permits.
public struct BurnBarFleetProcessInfo: Codable, Hashable, Sendable {
    public let pid: Int
    public let cpuPercent: Double?
    public let memoryBytes: Int?
    /// ISO-8601 UTC string on the wire.
    public let startedAt: Date?

    public init(pid: Int, cpuPercent: Double? = nil, memoryBytes: Int? = nil, startedAt: Date? = nil) {
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case pid, cpuPercent, memoryBytes, startedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int.self, forKey: .pid)
        cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent)
        memoryBytes = try container.decodeIfPresent(Int.self, forKey: .memoryBytes)
        startedAt = try container.decodeFleetDateIfPresent(forKey: .startedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
        try container.encodeIfPresent(memoryBytes, forKey: .memoryBytes)
        try container.encodeFleetDateIfPresent(startedAt, forKey: .startedAt)
    }
}

// MARK: - Agent row

/// One fixed-roster agent row in a fleet snapshot.
///
/// Schema-level consistency rule (enforced via `validateConsistency()`, an
/// encode-side guard the daemon must call before persisting/serving):
/// - a `running` row may NEVER carry `unsupported` or `estimated` confidence;
/// - an `unknown`-status row never carries `exactProcess`.
/// Decoding stays tolerant so forward-compatible payloads are not rejected.
public struct BurnBarFleetAgent: Codable, Hashable, Sendable {
    public let id: BurnBarFleetAgentID
    public let displayName: String
    public let status: BurnBarFleetAgentStatus
    public let confidence: BurnBarFleetConfidence
    public let currentTask: String?
    public let projectName: String?
    public let model: String?
    /// ISO-8601 UTC string on the wire.
    public let lastActivityAt: Date?
    public let process: BurnBarFleetProcessInfo?
    public let signals: [BurnBarFleetSignalSource]
    /// Honest caveats, e.g. "lock-file heuristic".
    public let note: String?

    public init(
        id: BurnBarFleetAgentID,
        displayName: String,
        status: BurnBarFleetAgentStatus,
        confidence: BurnBarFleetConfidence,
        currentTask: String? = nil,
        projectName: String? = nil,
        model: String? = nil,
        lastActivityAt: Date? = nil,
        process: BurnBarFleetProcessInfo? = nil,
        signals: [BurnBarFleetSignalSource] = [],
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.confidence = confidence
        self.currentTask = currentTask
        self.projectName = projectName
        self.model = model
        self.lastActivityAt = lastActivityAt
        self.process = process
        self.signals = signals
        self.note = note
    }

    /// Encode-side guard for the schema-level status/confidence consistency
    /// rule. Throws `inconsistentStatusConfidence` for invalid combinations.
    @discardableResult
    public func validateConsistency() throws -> BurnBarFleetAgent {
        switch (status, confidence) {
        case (.running, .unsupported), (.running, .estimated):
            throw BurnBarFleetContractError.inconsistentStatusConfidence(status: status, confidence: confidence)
        case (.unknown, .exactProcess):
            throw BurnBarFleetContractError.inconsistentStatusConfidence(status: status, confidence: confidence)
        default:
            return self
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, status, confidence, currentTask, projectName,
             model, lastActivityAt, process, signals, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BurnBarFleetAgentID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        status = try container.decode(BurnBarFleetAgentStatus.self, forKey: .status)
        confidence = try container.decode(BurnBarFleetConfidence.self, forKey: .confidence)
        currentTask = try container.decodeIfPresent(String.self, forKey: .currentTask)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        lastActivityAt = try container.decodeFleetDateIfPresent(forKey: .lastActivityAt)
        process = try container.decodeIfPresent(BurnBarFleetProcessInfo.self, forKey: .process)
        signals = try container.decode([BurnBarFleetSignalSource].self, forKey: .signals)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(status, forKey: .status)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(currentTask, forKey: .currentTask)
        try container.encodeIfPresent(projectName, forKey: .projectName)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeFleetDateIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encodeIfPresent(process, forKey: .process)
        try container.encode(signals, forKey: .signals)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

// MARK: - Thread

/// Hard cap on threads emitted per roster CLI per tick. Older threads
/// beyond the cap are dropped and the probe notes the truncation.
public enum BurnBarFleetThreadLimits {
    public static let maxPerAgent = 50
}

/// One live-or-fresh session/lock/transcript/worker for a roster CLI.
///
/// `id` is the stable `sessionRef` (never a PID alone). The ten agent rows
/// remain the honesty roll-up; this is the command-center atom.
public struct BurnBarFleetThread: Codable, Hashable, Sendable {
    public let id: String
    public let agentID: BurnBarFleetAgentID
    public let status: BurnBarFleetAgentStatus
    public let confidence: BurnBarFleetConfidence
    public let currentTask: String?
    public let projectName: String?
    public let model: String?
    /// ISO-8601 UTC string on the wire.
    public let lastActivityAt: Date?
    public let process: BurnBarFleetProcessInfo?
    public let signals: [BurnBarFleetSignalSource]
    public let note: String?

    public init(
        id: String,
        agentID: BurnBarFleetAgentID,
        status: BurnBarFleetAgentStatus,
        confidence: BurnBarFleetConfidence,
        currentTask: String? = nil,
        projectName: String? = nil,
        model: String? = nil,
        lastActivityAt: Date? = nil,
        process: BurnBarFleetProcessInfo? = nil,
        signals: [BurnBarFleetSignalSource] = [],
        note: String? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.status = status
        self.confidence = confidence
        self.currentTask = currentTask
        self.projectName = projectName
        self.model = model
        self.lastActivityAt = lastActivityAt
        self.process = process
        self.signals = signals
        self.note = note
    }

    @discardableResult
    public func validateConsistency() throws -> BurnBarFleetThread {
        switch (status, confidence) {
        case (.running, .unsupported), (.running, .estimated):
            throw BurnBarFleetContractError.inconsistentStatusConfidence(status: status, confidence: confidence)
        case (.unknown, .exactProcess):
            throw BurnBarFleetContractError.inconsistentStatusConfidence(status: status, confidence: confidence)
        default:
            return self
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentID, status, confidence, currentTask, projectName,
             model, lastActivityAt, process, signals, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentID = try container.decode(BurnBarFleetAgentID.self, forKey: .agentID)
        status = try container.decode(BurnBarFleetAgentStatus.self, forKey: .status)
        confidence = try container.decode(BurnBarFleetConfidence.self, forKey: .confidence)
        currentTask = try container.decodeIfPresent(String.self, forKey: .currentTask)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        lastActivityAt = try container.decodeFleetDateIfPresent(forKey: .lastActivityAt)
        process = try container.decodeIfPresent(BurnBarFleetProcessInfo.self, forKey: .process)
        signals = try container.decodeIfPresent([BurnBarFleetSignalSource].self, forKey: .signals) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(status, forKey: .status)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(currentTask, forKey: .currentTask)
        try container.encodeIfPresent(projectName, forKey: .projectName)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeFleetDateIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try container.encodeIfPresent(process, forKey: .process)
        try container.encode(signals, forKey: .signals)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

// MARK: - Machine status

/// Honest sensor reading: either a real value or a typed unavailability with a
/// non-empty reason. Thermal/power are expected `unavailable` on machines where
/// no cheap API proves otherwise; values are never invented.
///
/// Wire shapes: `{"kind":"available","value":<double>}` or
/// `{"kind":"unavailable","reason":"<non-empty>"}`.
public enum BurnBarSensorState: Codable, Hashable, Sendable {
    case available(value: Double)
    case unavailable(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, value, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "available":
            self = .available(value: try container.decode(Double.self, forKey: .value))
        case "unavailable":
            let reason = try container.decode(String.self, forKey: .reason)
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "sensor.reason")
            self = .unavailable(reason: reason)
        default:
            throw BurnBarFleetContractError.unknownSensorStateKind(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let value):
            try container.encode("available", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .unavailable(let reason):
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "sensor.reason")
            try container.encode("unavailable", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Machine status block. Numeric fields are optional and degrade honestly per
/// field (absent, never fabricated); `thermal`/`power` are typed sensors.
public struct BurnBarMachineStatus: Codable, Hashable, Sendable {
    public let cpuPercent: Double?
    public let memoryUsedBytes: Int?
    public let memoryTotalBytes: Int
    public let loadAverage: [Double]?
    public let diskFreeBytes: Int?
    public let thermal: BurnBarSensorState
    public let power: BurnBarSensorState

    public init(
        cpuPercent: Double? = nil,
        memoryUsedBytes: Int? = nil,
        memoryTotalBytes: Int,
        loadAverage: [Double]? = nil,
        diskFreeBytes: Int? = nil,
        thermal: BurnBarSensorState,
        power: BurnBarSensorState
    ) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.loadAverage = loadAverage
        self.diskFreeBytes = diskFreeBytes
        self.thermal = thermal
        self.power = power
    }
}

// MARK: - Repos, probe health, persistence health

/// Derived per-repo grouping of agent rows.
public struct BurnBarFleetRepoGroup: Codable, Hashable, Sendable {
    public let projectName: String
    public let agents: [BurnBarFleetAgentID]

    public init(projectName: String, agents: [BurnBarFleetAgentID]) {
        self.projectName = projectName
        self.agents = agents
    }
}

/// Typed per-agent probe health. Reasons are non-empty.
///
/// Wire shapes: `{"kind":"ok"}`,
/// `{"kind":"degraded","reason":"<non-empty>"}`,
/// `{"kind":"failed","reason":"<non-empty>"}`.
public enum BurnBarFleetProbeHealthState: Codable, Hashable, Sendable {
    case ok
    case degraded(reason: String)
    case failed(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "ok":
            self = .ok
        case "degraded":
            let reason = try container.decode(String.self, forKey: .reason)
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "probeHealth.reason")
            self = .degraded(reason: reason)
        case "failed":
            let reason = try container.decode(String.self, forKey: .reason)
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "probeHealth.reason")
            self = .failed(reason: reason)
        default:
            throw BurnBarFleetContractError.unknownProbeHealthStateKind(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode("ok", forKey: .kind)
        case .degraded(let reason):
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "probeHealth.reason")
            try container.encode("degraded", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .failed(let reason):
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "probeHealth.reason")
            try container.encode("failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// One probe-health entry per declared roster id, naming the root path and a
/// typed state.
public struct BurnBarFleetProbeHealth: Codable, Hashable, Sendable {
    public let agent: BurnBarFleetAgentID
    public let state: BurnBarFleetProbeHealthState
    public let rootPath: String
    /// ISO-8601 UTC string on the wire.
    public let checkedAt: Date

    public init(agent: BurnBarFleetAgentID, state: BurnBarFleetProbeHealthState, rootPath: String, checkedAt: Date) {
        self.agent = agent
        self.state = state
        self.rootPath = rootPath
        self.checkedAt = checkedAt
    }

    private enum CodingKeys: String, CodingKey {
        case agent, state, rootPath, checkedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(BurnBarFleetAgentID.self, forKey: .agent)
        state = try container.decode(BurnBarFleetProbeHealthState.self, forKey: .state)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        checkedAt = try container.decodeFleetDate(forKey: .checkedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        try container.encode(state, forKey: .state)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encodeFleetDate(checkedAt, forKey: .checkedAt)
    }
}

/// Top-level persistence health covering BOTH the daemon-owned SQLite store and
/// the well-known-file writer. Reasons are non-empty and non-secret.
///
/// Wire shapes: `{"kind":"ok"}` or `{"kind":"degraded","reason":"<non-empty>"}`.
public enum BurnBarFleetPersistenceHealth: Codable, Hashable, Sendable {
    case ok
    case degraded(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "ok":
            self = .ok
        case "degraded":
            let reason = try container.decode(String.self, forKey: .reason)
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "persistenceHealth.reason")
            self = .degraded(reason: reason)
        default:
            throw BurnBarFleetContractError.unknownPersistenceHealthKind(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode("ok", forKey: .kind)
        case .degraded(let reason):
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "persistenceHealth.reason")
            try container.encode("degraded", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - Orchestrator

/// Tri-state optionality for a wire string field where absent, explicit null,
/// and present must remain distinct through a round-trip.
public enum BurnBarFleetOptionalString: Hashable, Sendable {
    case absent
    case null
    case present(String)

    /// The string value when `.present`; nil for `.absent` and `.null`.
    public var value: String? {
        if case .present(let value) = self { return value }
        return nil
    }
}

/// Orchestrator designation: who is designated to orchestrate the fleet.
///
/// Wire shapes: `{"kind":"none"}`, `{"kind":"burnBarManaged"}`, or
/// `{"kind":"agent","id":"<wire id>","sessionRef":<string|null|omitted>}`.
/// `sessionRef` preserves absent vs explicit null vs present.
public enum BurnBarOrchestratorDesignation: Codable, Hashable, Sendable {
    case none
    case burnBarManaged
    case agent(id: BurnBarFleetAgentID, sessionRef: BurnBarFleetOptionalString)

    /// The designated agent id when `.agent`; nil otherwise.
    public var agentID: BurnBarFleetAgentID? {
        if case .agent(let id, _) = self { return id }
        return nil
    }

    /// The session reference value when `.agent` and present; nil otherwise.
    public var sessionRef: String? {
        if case .agent(_, let ref) = self { return ref.value }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, sessionRef
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "none":
            self = .none
        case "burnBarManaged":
            self = .burnBarManaged
        case "agent":
            let id = try container.decode(BurnBarFleetAgentID.self, forKey: .id)
            if container.contains(.sessionRef) {
                if let value = try container.decodeIfPresent(String.self, forKey: .sessionRef) {
                    self = .agent(id: id, sessionRef: .present(value))
                } else {
                    self = .agent(id: id, sessionRef: .null)
                }
            } else {
                self = .agent(id: id, sessionRef: .absent)
            }
        default:
            throw BurnBarFleetContractError.unknownDesignationKind(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case .burnBarManaged:
            try container.encode("burnBarManaged", forKey: .kind)
        case .agent(let id, let sessionRef):
            try container.encode("agent", forKey: .kind)
            try container.encode(id, forKey: .id)
            switch sessionRef {
            case .absent:
                break
            case .null:
                try container.encodeNil(forKey: .sessionRef)
            case .present(let value):
                try container.encode(value, forKey: .sessionRef)
            }
        }
    }
}

/// Daemon-owned orchestrator state. `setAt` is an ISO-8601 UTC string on the
/// wire (e.g. `2026-08-12T01:01:05.000Z`).
public struct BurnBarOrchestratorState: Codable, Hashable, Sendable {
    public let designation: BurnBarOrchestratorDesignation
    public let setAt: Date?
    public let pendingDirectives: Int

    public init(designation: BurnBarOrchestratorDesignation, setAt: Date? = nil, pendingDirectives: Int = 0) {
        self.designation = designation
        self.setAt = setAt
        self.pendingDirectives = pendingDirectives
    }

    private enum CodingKeys: String, CodingKey {
        case designation, setAt, pendingDirectives
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        designation = try container.decode(BurnBarOrchestratorDesignation.self, forKey: .designation)
        setAt = try container.decodeFleetDateIfPresent(forKey: .setAt)
        pendingDirectives = try container.decode(Int.self, forKey: .pendingDirectives)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(designation, forKey: .designation)
        try container.encodeFleetDateIfPresent(setAt, forKey: .setAt)
        try container.encode(pendingDirectives, forKey: .pendingDirectives)
    }
}

// MARK: - Directives

/// Directive kind. Wire strings (golden): `summarize`, `focusRepo`,
/// `askStatus`, `suggestAssignee`, `custom`.
public enum BurnBarFleetDirectiveKind: String, Codable, CaseIterable, Hashable, Sendable {
    case summarize
    case focusRepo
    case askStatus
    case suggestAssignee
    case custom

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = BurnBarFleetDirectiveKind(rawValue: raw) else {
            throw BurnBarFleetContractError.unknownDirectiveKind(raw)
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Tagged directive state. Bare `{"kind":...}` objects except failure and
/// unsupported, which carry a non-empty reason.
///
/// Wire shapes: `{"kind":"proposed"}`, `{"kind":"approved"}`,
/// `{"kind":"submitted"}`, `{"kind":"dismissed"}`, `{"kind":"delivered"}`,
/// `{"kind":"failed","reason":"<non-empty>"}`, or
/// `{"kind":"unsupported","reason":"<non-empty>"}`.
///
/// `submitted` means a documented channel accepted the write (inbox,
/// CLI exit 0, or OpenAI-shaped HTTP 200) without a typed
/// `directive_id` acknowledgement. `delivered` requires that ack.
/// UI must never paint `submitted` as Delivered.
public enum BurnBarFleetDirectiveState: Codable, Hashable, Sendable {
    case proposed
    case approved
    case submitted
    case dismissed
    case delivered
    case failed(reason: String)
    case unsupported(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "proposed":
            self = .proposed
        case "approved":
            self = .approved
        case "submitted":
            self = .submitted
        case "dismissed":
            self = .dismissed
        case "delivered":
            self = .delivered
        case "failed":
            let reason = try container.decode(String.self, forKey: .reason)
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "directive.state.reason")
            self = .failed(reason: reason)
        case "unsupported":
            let reason = try container.decode(String.self, forKey: .reason)
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "directive.state.reason")
            self = .unsupported(reason: reason)
        default:
            throw BurnBarFleetContractError.unknownDirectiveStateKind(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .proposed:
            try container.encode("proposed", forKey: .kind)
        case .approved:
            try container.encode("approved", forKey: .kind)
        case .submitted:
            try container.encode("submitted", forKey: .kind)
        case .dismissed:
            try container.encode("dismissed", forKey: .kind)
        case .delivered:
            try container.encode("delivered", forKey: .kind)
        case .failed(let reason):
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "directive.state.reason")
            try container.encode("failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .unsupported(let reason):
            try BurnBarFleetContractError.validateNonEmptyReason(reason, field: "directive.state.reason")
            try container.encode("unsupported", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// A human-approved directive proposal. `createdAt`/`decidedAt` are ISO-8601
/// UTC strings on the wire. `deliveryAttemptID` is an optional durable
/// handoff identity used to fence an external delivery call across crashes.
public struct BurnBarFleetDirective: Codable, Hashable, Sendable {
    public let id: String
    public let kind: BurnBarFleetDirectiveKind
    public let targetAgent: BurnBarFleetAgentID?
    /// Thread this directive addresses. Absent on pre-thread records.
    public let sessionRef: String?
    public let payload: String
    public let state: BurnBarFleetDirectiveState
    public let createdAt: Date
    public let decidedAt: Date?
    public let deliveryChannel: String?
    /// Durable handoff identity for an external delivery attempt. A daemon
    /// record carrying this value is an idempotency fence: recovery candidates
    /// without an attempt id must not erase it before reconciliation.
    public let deliveryAttemptID: String?

    public init(
        id: String,
        kind: BurnBarFleetDirectiveKind,
        targetAgent: BurnBarFleetAgentID? = nil,
        sessionRef: String? = nil,
        payload: String,
        state: BurnBarFleetDirectiveState,
        createdAt: Date,
        decidedAt: Date? = nil,
        deliveryChannel: String? = nil,
        deliveryAttemptID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetAgent = targetAgent
        self.sessionRef = sessionRef
        self.payload = payload
        self.state = state
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.deliveryChannel = deliveryChannel
        self.deliveryAttemptID = deliveryAttemptID
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, targetAgent, sessionRef, payload, state, createdAt, decidedAt, deliveryChannel,
             deliveryAttemptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(BurnBarFleetDirectiveKind.self, forKey: .kind)
        targetAgent = try container.decodeIfPresent(BurnBarFleetAgentID.self, forKey: .targetAgent)
        sessionRef = try container.decodeIfPresent(String.self, forKey: .sessionRef)
        payload = try container.decode(String.self, forKey: .payload)
        state = try container.decode(BurnBarFleetDirectiveState.self, forKey: .state)
        createdAt = try container.decodeFleetDate(forKey: .createdAt)
        decidedAt = try container.decodeFleetDateIfPresent(forKey: .decidedAt)
        deliveryChannel = try container.decodeIfPresent(String.self, forKey: .deliveryChannel)
        deliveryAttemptID = try container.decodeIfPresent(String.self, forKey: .deliveryAttemptID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(targetAgent, forKey: .targetAgent)
        try container.encodeIfPresent(sessionRef, forKey: .sessionRef)
        try container.encode(payload, forKey: .payload)
        try container.encode(state, forKey: .state)
        try container.encodeFleetDate(createdAt, forKey: .createdAt)
        try container.encodeFleetDateIfPresent(decidedAt, forKey: .decidedAt)
        try container.encodeIfPresent(deliveryChannel, forKey: .deliveryChannel)
        try container.encodeIfPresent(deliveryAttemptID, forKey: .deliveryAttemptID)
    }
}

// MARK: - Snapshot

/// The complete fleet snapshot served by the daemon.
///
/// `schemaVersion` is currently 1. Newer versions fail typed with
/// `incompatibleSchemaVersion`; v1 payloads carrying additive unknown keys
/// decode successfully with those keys ignored (JSONDecoder tolerance).
/// `generatedAt` is an ISO-8601 UTC string on the wire.
public struct BurnBarFleetSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let supportedSchemaVersions = [1]

    public let schemaVersion: Int
    public let generatedAt: Date
    public let cadenceSeconds: Int
    public let machine: BurnBarMachineStatus
    public let agents: [BurnBarFleetAgent]
    public let repos: [BurnBarFleetRepoGroup]
    public let runningCount: Int
    public let countsByAgent: [String: Int]
    public let orchestrator: BurnBarOrchestratorState
    public let probeHealth: [BurnBarFleetProbeHealth]
    public let persistenceHealth: BurnBarFleetPersistenceHealth
    /// Bounded live∪fresh threads across every roster CLI. Missing on
    /// pre-thread snapshots; decodes as `[]`.
    public let threads: [BurnBarFleetThread]
    /// Recent directive records (newest first). Missing decodes as `[]`.
    public let recentDirectives: [BurnBarFleetDirective]

    public init(
        schemaVersion: Int = BurnBarFleetSnapshot.currentSchemaVersion,
        generatedAt: Date,
        cadenceSeconds: Int,
        machine: BurnBarMachineStatus,
        agents: [BurnBarFleetAgent],
        repos: [BurnBarFleetRepoGroup],
        runningCount: Int,
        countsByAgent: [String: Int],
        orchestrator: BurnBarOrchestratorState,
        probeHealth: [BurnBarFleetProbeHealth],
        persistenceHealth: BurnBarFleetPersistenceHealth,
        threads: [BurnBarFleetThread] = [],
        recentDirectives: [BurnBarFleetDirective] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.cadenceSeconds = cadenceSeconds
        self.machine = machine
        self.agents = agents
        self.repos = repos
        self.runningCount = runningCount
        self.countsByAgent = countsByAgent
        self.orchestrator = orchestrator
        self.probeHealth = probeHealth
        self.persistenceHealth = persistenceHealth
        self.threads = threads
        self.recentDirectives = recentDirectives
    }

    /// Threads for one roster CLI, in snapshot order.
    public func threads(for agentID: BurnBarFleetAgentID) -> [BurnBarFleetThread] {
        threads.filter { $0.agentID == agentID }
    }

    /// Validates the schema-level status/confidence consistency rule across all
    /// agent rows and threads (encode-side guard).
    @discardableResult
    public func validateConsistency() throws -> BurnBarFleetSnapshot {
        for agent in agents {
            _ = try agent.validateConsistency()
        }
        for thread in threads {
            _ = try thread.validateConsistency()
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, cadenceSeconds, machine, agents, repos,
             runningCount, countsByAgent, orchestrator, probeHealth, persistenceHealth,
             threads, recentDirectives
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard BurnBarFleetSnapshot.supportedSchemaVersions.contains(version) else {
            throw BurnBarFleetContractError.incompatibleSchemaVersion(
                found: version,
                supported: BurnBarFleetSnapshot.supportedSchemaVersions
            )
        }
        schemaVersion = version
        generatedAt = try container.decodeFleetDate(forKey: .generatedAt)
        cadenceSeconds = try container.decode(Int.self, forKey: .cadenceSeconds)
        machine = try container.decode(BurnBarMachineStatus.self, forKey: .machine)
        agents = try container.decode([BurnBarFleetAgent].self, forKey: .agents)
        repos = try container.decode([BurnBarFleetRepoGroup].self, forKey: .repos)
        runningCount = try container.decode(Int.self, forKey: .runningCount)
        countsByAgent = try container.decode([String: Int].self, forKey: .countsByAgent)
        orchestrator = try container.decode(BurnBarOrchestratorState.self, forKey: .orchestrator)
        probeHealth = try container.decode([BurnBarFleetProbeHealth].self, forKey: .probeHealth)
        persistenceHealth = try container.decode(BurnBarFleetPersistenceHealth.self, forKey: .persistenceHealth)
        threads = try container.decodeIfPresent([BurnBarFleetThread].self, forKey: .threads) ?? []
        recentDirectives = try container.decodeIfPresent([BurnBarFleetDirective].self, forKey: .recentDirectives) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        guard BurnBarFleetSnapshot.supportedSchemaVersions.contains(schemaVersion) else {
            throw BurnBarFleetContractError.incompatibleSchemaVersion(
                found: schemaVersion,
                supported: BurnBarFleetSnapshot.supportedSchemaVersions
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeFleetDate(generatedAt, forKey: .generatedAt)
        try container.encode(cadenceSeconds, forKey: .cadenceSeconds)
        try container.encode(machine, forKey: .machine)
        try container.encode(agents, forKey: .agents)
        try container.encode(repos, forKey: .repos)
        try container.encode(runningCount, forKey: .runningCount)
        try container.encode(countsByAgent, forKey: .countsByAgent)
        try container.encode(orchestrator, forKey: .orchestrator)
        try container.encode(probeHealth, forKey: .probeHealth)
        try container.encode(persistenceHealth, forKey: .persistenceHealth)
        try container.encode(threads, forKey: .threads)
        try container.encode(recentDirectives, forKey: .recentDirectives)
    }
}
