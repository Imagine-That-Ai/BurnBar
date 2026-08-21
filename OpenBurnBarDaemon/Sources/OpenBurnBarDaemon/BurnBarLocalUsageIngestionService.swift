import Foundation
import OpenBurnBarEngine
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

public actor BurnBarLocalUsageIngestionService {
    public struct RefreshReport: Equatable, Sendable {
        public let parsedRows: Int
        public let insertedDeltas: Int
        public let unchangedRows: Int
        public let failures: [String]
    }

    private struct Checkpoint: Codable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let reasoningTokens: Int
        let cost: Double
        let startTime: Date
        let endTime: Date
    }

    private struct CheckpointDocument: Codable {
        let schemaVersion: Int
        var rows: [String: Checkpoint]
    }

    private let parsers: [any LogParser]
    private let usageRecorder: BurnBarUsageRecorder
    private let checkpointURL: URL
    private let fileManager: FileManager
    private var checkpoints: [String: Checkpoint]?

    public init(
        parsers: [any LogParser],
        usageRecorder: BurnBarUsageRecorder,
        checkpointURL: URL,
        fileManager: FileManager = .default
    ) {
        self.parsers = parsers
        self.usageRecorder = usageRecorder
        self.checkpointURL = checkpointURL
        self.fileManager = fileManager
    }

    public static func linuxDefault(usageRecorder: BurnBarUsageRecorder) -> BurnBarLocalUsageIngestionService {
        let paths = OpenBurnBarAppPaths.live()
        return BurnBarLocalUsageIngestionService(
            parsers: linuxDefaultParsers(),
            usageRecorder: usageRecorder,
            checkpointURL: paths.supportDirectory.appendingPathComponent("local-usage-ingestion-checkpoints.json")
        )
    }

    static func linuxDefaultParsers(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [any LogParser] {
        let clinePaths = linuxClineStoragePaths(
            environment: environment,
            homeDirectoryURL: homeDirectoryURL
        )
        // Keep parser construction local to the daemon, but let the generated
        // provider-ingestion catalog own membership and ordering. The catalog
        // is also consumed by Linux discovery and the renderer; filtering this
        // factory map through it prevents a newly declared provider from being
        // silently omitted (or an API-only provider from being parsed locally).
        let factories: [AgentProvider: () -> any LogParser] = [
            .factory: { FactoryDroidParser() },
            .claudeCode: { ClaudeCodeParser() },
            .openClaude: { ClaudeCodeParser(provider: .openClaude) },
            .copilot: { CopilotParser() },
            .cursorAgent: { CursorAgentParser() },
            .codex: { CodexParser() },
            .windsurf: { WindsurfParser() },
            .warp: { WarpParser() },
            .kimi: { KimiParser() },
            .xAI: { GrokParser() },
            .cline: { ClineFormatParser(provider: .cline, storagePaths: clinePaths[.cline] ?? []) },
            .kiloCode: { ClineFormatParser(provider: .kiloCode, storagePaths: clinePaths[.kiloCode] ?? []) },
            .rooCode: { ClineFormatParser(provider: .rooCode, storagePaths: clinePaths[.rooCode] ?? []) },
            .forgeDev: { ForgeDevParser() },
            .augment: { AugmentParser() },
            .hermes: { HermesParser() },
            .geminiCLI: { GeminiCLIParser() },
            .antigravity: { AntigravityParser() },
            .goose: { GooseParser() },
            .aider: { AiderParser() },
            .cursor: { CursorParser() },
            .openCode: { OpenCodeParser() },
            .piAgent: { PiAgentParser() },
            .omp: { OMPParser() },
            .openClaw: { OpenClawParser() },
            .ollama: { OllamaParser() },
            .junie: { JunieParser() },
            .primeAgent: { PrimeAgentParser() },
            .muse: { MuseParser() },
            .fx: { FxParser() },
            .zai: { ModelFilterParser(modelPattern: "zai", provider: .zai) },
            .minimax: { ModelFilterParser(modelPattern: "minimax", provider: .minimax) }
        ]

        return AgentProviderIngestionCatalog.entries.compactMap { entry in
            guard entry.ingestion == .localParser else { return nil }
            guard let factory = factories[entry.provider] else {
                preconditionFailure(
                    "Missing Linux parser factory for catalog provider \(entry.provider.rawValue)"
                )
            }
            return factory()
        }
    }

    static func linuxClineStoragePaths(
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> [AgentProvider: [String]] {
        let configuredRoot = environment["XDG_CONFIG_HOME"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { value -> URL? in
                guard value.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        let configRoot = configuredRoot
            ?? homeDirectoryURL.appendingPathComponent(".config", isDirectory: true)
        let editorDirectories = ["Code", "VSCodium", "Cursor", "Windsurf"]

        func taskPaths(extensionIDs: [String]) -> [String] {
            editorDirectories.flatMap { editor in
                extensionIDs.map { extensionID in
                    configRoot
                        .appendingPathComponent(editor, isDirectory: true)
                        .appendingPathComponent("User", isDirectory: true)
                        .appendingPathComponent("globalStorage", isDirectory: true)
                        .appendingPathComponent(extensionID, isDirectory: true)
                        .appendingPathComponent("tasks", isDirectory: true)
                        .path
                }
            }
        }

        return [
            .cline: taskPaths(extensionIDs: ["saoudrizwan.claude-dev"]),
            .kiloCode: taskPaths(extensionIDs: ["kilocode.kilo-code"]),
            .rooCode: taskPaths(extensionIDs: [
                "rooveterinaryinc.roo-cline",
                "roo-inc.roo-code"
            ])
        ]
    }

    public func refresh() async -> RefreshReport {
        var parsedRows = 0
        var insertedDeltas = 0
        var unchangedRows = 0
        var failures: [String] = []
        do {
            try loadCheckpointsIfNeeded()
        } catch {
            return RefreshReport(
                parsedRows: 0,
                insertedDeltas: 0,
                unchangedRows: 0,
                failures: ["checkpoint: \(error)"]
            )
        }

        for parser in parsers {
            do {
                let result = try await parser.parse(
                    options: LogParseOptions(includeConversationBodies: false)
                )
                parsedRows += result.usages.count
                for usage in result.usages {
                    do {
                        if try await ingest(usage) {
                            insertedDeltas += 1
                        } else {
                            unchangedRows += 1
                        }
                    } catch {
                        failures.append("\(parser.provider.rawValue)/\(usage.sessionId): \(error)")
                    }
                }
            } catch {
                failures.append("\(parser.provider.rawValue): \(error)")
            }
        }
        return RefreshReport(
            parsedRows: parsedRows,
            insertedDeltas: insertedDeltas,
            unchangedRows: unchangedRows,
            failures: failures.sorted()
        )
    }

    private func ingest(_ usage: TokenUsage) async throws -> Bool {
        let checkpointKey = Self.checkpointKey(for: usage)
        let current = Checkpoint(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens,
            reasoningTokens: usage.reasoningTokens,
            cost: usage.cost,
            startTime: usage.startTime,
            endTime: usage.endTime
        )
        let previous = checkpoints?[checkpointKey]
        let countersRegressed = previous.map {
            current.inputTokens < $0.inputTokens
                || current.outputTokens < $0.outputTokens
                || current.cacheCreationTokens < $0.cacheCreationTokens
                || current.cacheReadTokens < $0.cacheReadTokens
                || current.reasoningTokens < $0.reasoningTokens
        } ?? false
        if let previous, countersRegressed, current.startTime <= previous.endTime {
            // An overlapping/truncated read is not a new generation. Retain the
            // high-water mark so a transient rotation gap cannot be re-imported.
            return false
        }
        let baseline = countersRegressed ? nil : previous
        let input = current.inputTokens - (baseline?.inputTokens ?? 0)
        let output = current.outputTokens - (baseline?.outputTokens ?? 0)
        let cacheCreation = current.cacheCreationTokens - (baseline?.cacheCreationTokens ?? 0)
        let cacheRead = current.cacheReadTokens - (baseline?.cacheReadTokens ?? 0)
        let reasoning = current.reasoningTokens - (baseline?.reasoningTokens ?? 0)
        let cost = max(current.cost - (baseline?.cost ?? 0), 0)
        guard input > 0 || output > 0 || cacheCreation > 0 || cacheRead > 0 || reasoning > 0 || cost > 0 else {
            return false
        }

        let event = BurnBarUsageEvent(
            providerID: usage.providerID.rawValue,
            modelID: usage.model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            cost: cost,
            recordedAt: usage.endTime,
            sessionID: usage.sessionId,
            projectName: usage.projectName,
            confidence: Self.confidence(for: usage.provenanceConfidence)
        )
        let snapshotKey = Self.snapshotKey(checkpointKey: checkpointKey, checkpoint: current)
        _ = try await usageRecorder.record(event, idempotencyKey: "local-usage:\(snapshotKey)")

        checkpoints?[checkpointKey] = current
        try persistCheckpoints()
        return true
    }

    private func loadCheckpointsIfNeeded() throws {
        guard checkpoints == nil else { return }
        guard fileManager.fileExists(atPath: checkpointURL.path) else {
            checkpoints = [:]
            return
        }
        let data = try Data(contentsOf: checkpointURL)
        let document = try JSONDecoder().decode(CheckpointDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        checkpoints = document.rows
    }

    private func persistCheckpoints() throws {
        let directory = checkpointURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        let document = CheckpointDocument(schemaVersion: 1, rows: checkpoints ?? [:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: checkpointURL, options: .atomic)
        #if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
        #endif
    }

    private static func checkpointKey(for usage: TokenUsage) -> String {
        // Copilot counters are session-scoped even when the selected model
        // changes mid-session. Model must not create a fresh cumulative scope.
        digest("\(usage.providerID.rawValue)\u{1f}\(usage.sessionId)")
    }

    private static func snapshotKey(checkpointKey: String, checkpoint: Checkpoint) -> String {
        digest([
            checkpointKey,
            String(checkpoint.inputTokens),
            String(checkpoint.outputTokens),
            String(checkpoint.cacheCreationTokens),
            String(checkpoint.cacheReadTokens),
            String(checkpoint.reasoningTokens),
            String(checkpoint.cost.bitPattern),
            String(checkpoint.startTime.timeIntervalSinceReferenceDate.bitPattern),
            String(checkpoint.endTime.timeIntervalSinceReferenceDate.bitPattern)
        ].joined(separator: "\u{1f}"))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func confidence(for value: UsageProvenanceConfidence) -> BurnBarUsageConfidence {
        switch value {
        case .exact: .exact
        case .derivedExact: .derivedExact
        case .highConfidenceEstimate: .highConfidenceEstimate
        case .lowConfidenceEstimate: .lowConfidenceEstimate
        case .unknown: .unknown
        }
    }
}
