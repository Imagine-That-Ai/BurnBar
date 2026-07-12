import Foundation

public enum CastleWorkerPhase: String, Codable, CaseIterable, Sendable {
    case fanoutWakes = "fanout_wakes"
    case houseLit = "house_lit"
    case running
    case completing
    case completed
    case landed
    case noOp = "no_op"
    case failed
    case demoted

    public var isTerminal: Bool {
        switch self {
        case .landed, .noOp, .failed, .demoted:
            return true
        case .fanoutWakes, .houseLit, .running, .completing, .completed:
            return false
        }
    }

    public var countsAsLanded: Bool { self == .landed }

    public var displayLabel: String {
        switch self {
        case .fanoutWakes: return "Fan-out wakes"
        case .houseLit: return "House lit"
        case .running: return "Running"
        case .completing: return "Completing"
        case .completed: return "Collecting verdict"
        case .landed: return "Banner raised"
        case .noOp: return "No commit"
        case .failed: return "Dimmed"
        case .demoted: return "Demoted"
        }
    }

    /// User-facing label for The Wand UI. Uses plain developer language instead
    /// of Castle metaphor, so a user understands the state without docs.
    public var wandLabel: String {
        switch self {
        case .fanoutWakes: return "Waking"
        case .houseLit: return "Starting"
        case .running: return "Running"
        case .completing: return "Completing"
        case .completed: return "Collecting verdict"
        case .landed: return "Work landed"
        case .noOp: return "No work landed"
        case .failed: return "Failed"
        case .demoted: return "Demoted"
        }
    }
}

public enum CastleHonestyFlag: String, Codable, CaseIterable, Sendable {
    case quotaUnknown = "quota_unknown"
    case routeDemoted = "route_demoted"
    case noOp = "no_op"
    case quotaPressure = "quota_pressure"
    case failed

    public var displayLabel: String {
        switch self {
        case .quotaUnknown: return "Quota unknown"
        case .routeDemoted: return "Route demoted"
        case .noOp: return "No commit landed"
        case .quotaPressure: return "Quota pressure"
        case .failed: return "Failed"
        }
    }
}

public struct CastleHouse: Codable, Equatable, Identifiable, Sendable {
    public let runtime: String
    public let provider: AgentProvider
    public let name: String
    public let crestAsset: String?
    public let sigil: String

    public var id: String { runtime }

    public init(runtime: String, provider: AgentProvider, name: String? = nil) {
        self.runtime = Self.normalizedRuntime(runtime)
        self.provider = provider
        self.name = name ?? "House \(provider.rawValue)"
        self.crestAsset = provider.bundledLogoName
        self.sigil = provider.iconName
    }

    public static func forRuntime(_ runtime: String) -> CastleHouse {
        let normalized = normalizedRuntime(runtime)
        switch normalized {
        case "droid":
            return CastleHouse(runtime: normalized, provider: .factory, name: "House Droid")
        case "codex":
            return CastleHouse(runtime: normalized, provider: .codex, name: "House Codex")
        case "claude":
            return CastleHouse(runtime: normalized, provider: .claudeCode, name: "House Claude")
        case "gemini":
            return CastleHouse(runtime: normalized, provider: .geminiCLI, name: "House Gemini")
        case "opencode":
            return CastleHouse(runtime: normalized, provider: .openCode, name: "House OpenCode")
        case "cursor-agent", "cursoragent":
            return CastleHouse(runtime: "cursor-agent", provider: .cursorAgent, name: "House Cursor")
        case "kimi":
            return CastleHouse(runtime: normalized, provider: .kimi, name: "House Kimi")
        case "pi":
            return CastleHouse(runtime: normalized, provider: .piAgent, name: "House Pi")
        default:
            return CastleHouse(runtime: normalized, provider: .openBurnBar, name: "House \(runtime)")
        }
    }

    public static func normalizedRuntime(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalized == "cursoragent" || normalized == "cursor" {
            return "cursor-agent"
        }
        return normalized
    }
}

public struct CastleWorkerStatus: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: Date?
    public let runtime: String
    public let house: String?
    public let modelArg: String?
    public let phase: CastleWorkerPhase
    public let landsCommit: Bool
    public let baseSHA: String?
    public let headSHA: String?
    public let resultPath: String?
    public let donePath: String?
    public let honesty: [CastleHonestyFlag]
    public let errorReason: String?

    public var id: String {
        [
            CastleHouse.normalizedRuntime(runtime),
            modelArg ?? "model",
            baseSHA ?? resultPath ?? donePath ?? "worker"
        ].joined(separator: ":")
    }

    public var houseModel: CastleHouse { CastleHouse.forRuntime(runtime) }

    public init(
        schemaVersion: Int = 1,
        updatedAt: Date? = nil,
        runtime: String,
        house: String? = nil,
        modelArg: String? = nil,
        phase: CastleWorkerPhase,
        landsCommit: Bool,
        baseSHA: String? = nil,
        headSHA: String? = nil,
        resultPath: String? = nil,
        donePath: String? = nil,
        honesty: [CastleHonestyFlag] = [],
        errorReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.runtime = CastleHouse.normalizedRuntime(runtime)
        self.house = house
        self.modelArg = modelArg
        self.phase = landsCommit ? .landed : phase
        self.landsCommit = landsCommit
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.resultPath = resultPath
        self.donePath = donePath
        self.honesty = honesty
        self.errorReason = errorReason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case runtime
        case house
        case modelArg
        case phase
        case landsCommit
        case baseSHA
        case headSHA
        case resultPath
        case donePath
        case honesty
        case errorReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let raw = try container.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = Self.parseDate(raw)
        } else if let seconds = try container.decodeIfPresent(Double.self, forKey: .updatedAt) {
            updatedAt = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            updatedAt = nil
        }
        runtime = CastleHouse.normalizedRuntime(try container.decode(String.self, forKey: .runtime))
        house = try container.decodeIfPresent(String.self, forKey: .house)
        modelArg = try container.decodeIfPresent(String.self, forKey: .modelArg)
        let decodedPhase = try container.decodeIfPresent(CastleWorkerPhase.self, forKey: .phase) ?? .running
        landsCommit = try container.decodeIfPresent(Bool.self, forKey: .landsCommit) ?? false
        phase = landsCommit ? .landed : decodedPhase
        baseSHA = try container.decodeIfPresent(String.self, forKey: .baseSHA)
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA)
        resultPath = try container.decodeIfPresent(String.self, forKey: .resultPath)
        donePath = try container.decodeIfPresent(String.self, forKey: .donePath)
        honesty = try container.decodeIfPresent([CastleHonestyFlag].self, forKey: .honesty) ?? []
        errorReason = try container.decodeIfPresent(String.self, forKey: .errorReason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(runtime, forKey: .runtime)
        try container.encodeIfPresent(house, forKey: .house)
        try container.encodeIfPresent(modelArg, forKey: .modelArg)
        try container.encode(phase, forKey: .phase)
        try container.encode(landsCommit, forKey: .landsCommit)
        try container.encodeIfPresent(baseSHA, forKey: .baseSHA)
        try container.encodeIfPresent(headSHA, forKey: .headSHA)
        try container.encodeIfPresent(resultPath, forKey: .resultPath)
        try container.encodeIfPresent(donePath, forKey: .donePath)
        try container.encode(honesty, forKey: .honesty)
        try container.encodeIfPresent(errorReason, forKey: .errorReason)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }
}

public struct CastleRunSnapshot: Equatable, Sendable {
    public let workers: [CastleWorkerStatus]

    public init(workers: [CastleWorkerStatus]) {
        self.workers = workers.sorted {
            if $0.phase == $1.phase {
                return $0.id < $1.id
            }
            return Self.phaseSortIndex($0.phase) < Self.phaseSortIndex($1.phase)
        }
    }

    public var totalCount: Int { workers.count }
    public var landedCount: Int { workers.filter(\.landsCommit).count }
    public var failedCount: Int { workers.filter { $0.phase == .failed }.count }
    public var noOpCount: Int { workers.filter { $0.phase == .noOp }.count }
    public var isEmpty: Bool { workers.isEmpty }

    /// True when some workers landed and at least one failed or produced no work.
    public var isPartialSuccess: Bool { landedCount > 0 && (failedCount > 0 || noOpCount > 0) }

    /// True when every worker failed and none landed.
    public var isAllFailed: Bool { !isEmpty && failedCount == totalCount && landedCount == 0 }

    /// True when any worker has a quota-related honesty flag.
    public var hasQuotaUncertainty: Bool {
        workers.contains { $0.honesty.contains(.quotaUnknown) || $0.honesty.contains(.quotaPressure) }
    }

    /// True when any worker has a provider-unavailable honesty flag.
    public var hasProviderUnavailable: Bool {
        workers.contains { $0.honesty.contains(.routeDemoted) }
    }

    public var headline: String {
        guard totalCount > 0 else { return "No Castle run selected" }
        return "\(landedCount) of \(totalCount) banners raised"
    }

    public func worker(id: CastleWorkerStatus.ID) -> CastleWorkerStatus? {
        workers.first { $0.id == id }
    }

    private static func phaseSortIndex(_ phase: CastleWorkerPhase) -> Int {
        switch phase {
        case .landed: return 0
        case .running, .completing, .completed: return 1
        case .fanoutWakes, .houseLit: return 2
        case .noOp: return 3
        case .failed: return 4
        case .demoted: return 5
        }
    }
}
