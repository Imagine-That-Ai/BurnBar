import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarLogParsers
@testable import OpenBurnBarQuota

/// Package-lane coverage for quota/parser/CLI files that the app XCTest bundle
/// already exercises. SwiftPM never links AgentLensTests, so these seams must
/// run here or `DIFF_COVERAGE_SCOPE=packages` fails closed.
final class PackageDiffCoverageQuotaAndCLITests: XCTestCase {
    private static let referenceEpochMs: Double = 1_750_000_000_000

    func testAntigravityFetchCombinesHistoryAndBrainTranscripts() async throws {
        let root = try makeTemporaryDirectory("antigravity-fetch")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowMs = Self.referenceEpochMs
        let hourMs = 60.0 * 60.0 * 1000.0
        let antigravityRoot = root.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: antigravityRoot, withIntermediateDirectories: true)
        try write(
            """
            {"display":"Request 1","timestamp":\(Int64(nowMs - (2.0 * hourMs))),"workspace":"/tmp/ws"}
            {"display":"Request 2","timestamp":\(Int64(nowMs - (3.0 * hourMs))),"workspace":"/tmp/ws"}
            {"display":"stale","timestamp":\(Int64(nowMs - (6.0 * hourMs))),"workspace":"/tmp/ws"}
            """,
            to: antigravityRoot.appendingPathComponent("history.jsonl")
        )
        try write(
            #"{"model":"Gemini 3.1 Pro (High)"}"#,
            to: antigravityRoot.appendingPathComponent("settings.json")
        )

        let logs = antigravityRoot
            .appendingPathComponent("brain/session-coverage/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let createdAt = iso.string(from: Date(timeIntervalSince1970: (nowMs - (1.0 * hourMs)) / 1000.0))
        try write(
            """
            {"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"\(createdAt)","content":"Changed `Model Selection` from Claude Opus 4.6 (Thinking) to Gemini 3.1 Pro (High). "}
            {"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\(createdAt)","content":"Ready."}
            """,
            to: logs.appendingPathComponent("transcript_full.jsonl")
        )

        let snapshot = try await AntigravityQuotaAdapter().fetch(context: makeContext(root: root, referenceEpochMs: nowMs))
        XCTAssertEqual(snapshot.provider, AgentProvider.antigravity.rawValue)
        XCTAssertEqual(snapshot.sourceKind, .localCLI)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.buckets.count, AntigravityQuotaAdapter.availableModels.count)

        let active = try XCTUnwrap(snapshot.buckets.first { $0.label.contains("(Active)") })
        XCTAssertTrue(active.label.contains("Gemini 3.1 Pro (High)"))
        XCTAssertGreaterThan(try XCTUnwrap(active.usedValue), 0)
        XCTAssertEqual(active.unit, .requests)
        XCTAssertNotNil(snapshot.primaryDisplayableBucket)
    }

    func testAntigravityFetchReturnsUnavailableWithoutSessionSources() async throws {
        let root = try makeTemporaryDirectory("antigravity-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try await AntigravityQuotaAdapter().fetch(context: makeContext(root: root))
        XCTAssertEqual(snapshot.sourceKind, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertEqual(snapshot.statusMessage?.contains("not found"), true)
    }

    func testAntigravityTranscriptScanReadsModelSelectionAndWindowedTurns() throws {
        let root = try makeTemporaryDirectory("antigravity-transcripts")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: Self.referenceEpochMs / 1000.0)
        let logs = root.appendingPathComponent("brain/session-1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let createdAt = iso.string(from: now.addingTimeInterval(-30 * 60))
        try write(
            """
            {"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"\(createdAt)","content":"Changed `Model Selection` from Old Model to GPT-OSS 120B (Medium).</note>"}
            {"source":"USER","type":"USER_INPUT","created_at":"\(createdAt)","content":"go"}
            {"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"\(createdAt)","content":"done"}
            """,
            to: logs.appendingPathComponent("transcript.jsonl")
        )

        let scan = AntigravityQuotaAdapter.scanTranscripts(
            candidateRoots: [root],
            fileManager: .default,
            now: now
        )
        XCTAssertTrue(scan.sawAnyEvent)
        XCTAssertEqual(scan.inWindowCount, 3)
        XCTAssertEqual(scan.latestModel, "GPT-OSS 120B (Medium)")
        XCTAssertGreaterThan(scan.bytesRead, 0)
    }

    func testPrimaryDisplayableBucketPrefersProviderWindowsAndDemotesAuxiliaryBuckets() {
        XCTAssertEqual(
            primaryKey(
                provider: .cursor,
                buckets: [
                    bucket(key: "cursor-api", label: "API usage", used: 10, limit: 100),
                    bucket(key: "cursor-plan", label: "Included usage", used: 40, limit: 100),
                    bucket(key: "cursor-auto", label: "Auto + Composer", used: 5, limit: 100)
                ]
            ),
            "cursor-plan"
        )
        XCTAssertEqual(
            primaryKey(
                provider: .factory,
                buckets: [
                    bucket(key: "factory-30d", label: "Monthly", windowKind: .monthly, used: 10, limit: 100),
                    bucket(key: "factory-7d", label: "7-day", windowKind: .rollingDays, used: 50, limit: 100),
                    bucket(key: "factory-standard", label: "Standard", used: 1, limit: 100)
                ]
            ),
            "factory-7d"
        )
        XCTAssertEqual(
            primaryKey(
                provider: .claudeCode,
                buckets: [
                    bucket(key: "claude-seven-day", label: "7-day window", windowKind: .rollingDays, used: 10, limit: 100),
                    bucket(key: "claude-five-hour", label: "5-hour window", used: 80, limit: 100)
                ]
            ),
            "claude-five-hour"
        )
        XCTAssertEqual(
            primaryKey(
                provider: .openClaude,
                buckets: [
                    bucket(key: "openclaude-7d", label: "7-day window", windowKind: .rollingDays, used: 10, limit: 100),
                    bucket(key: "openclaude-5h", label: "5h window", used: 20, limit: 100)
                ]
            ),
            "openclaude-5h"
        )
        XCTAssertEqual(
            primaryKey(
                provider: .antigravity,
                buckets: [
                    bucket(key: "model_gemini", label: "Gemini 3.1 Pro (High)", used: 0, limit: 150),
                    bucket(key: "active_model_claude", label: "Claude Opus 4.6 (Thinking) (Active)", used: 12, limit: 60)
                ]
            ),
            "active_model_claude"
        )
        XCTAssertEqual(
            primaryKey(
                provider: .zai,
                buckets: [
                    bucket(key: "limits", label: "limits", used: 1, limit: 10),
                    bucket(key: "zai-weekly", label: "Token usage (Weekly)", windowKind: .weekly, used: 20, limit: 100),
                    bucket(key: "zai-5h", label: "Credit usage (5-hour)", used: 70, limit: 100),
                    bucket(key: "zai-time", label: "time_limit", used: 3, limit: 10)
                ]
            ),
            "zai-5h"
        )
        XCTAssertEqual(
            primaryKey(
                provider: .codex,
                buckets: [
                    bucket(key: "codex-month", label: "Monthly", windowKind: .monthly, used: 10, limit: 100),
                    bucket(key: "codex-hour", label: "Hourly", windowKind: .rollingHours, used: 40, limit: 100)
                ]
            ),
            "codex-hour"
        )

        let demoted = snapshot(
            provider: .factory,
            buckets: [
                bucket(key: "factory-7d", label: "7-day", windowKind: .rollingDays, used: 90, limit: 100),
                bucket(key: "factory-payg", label: "On-demand extra usage", used: 1, limit: 100),
                bucket(key: "factory-cache", label: "Cache hit rate", used: 1, limit: 100),
                bucket(key: "factory-core", label: "Droid core open-weight", used: 1, limit: 100),
                bucket(key: "factory-mcp", label: "MCP tool", used: 1, limit: 100)
            ]
        )
        XCTAssertEqual(demoted.primaryDisplayableBucket?.key, "factory-7d")
        XCTAssertTrue(demoted.summaryText.contains("7-day"))
    }

    func testFlexibleNormalizerMapsZaiCreditLimitsAndReinfersCustomWindows() throws {
        XCTAssertEqual(
            FlexibleQuotaBucketNormalizer.normalizedBucketLabel(
                "credit_limit",
                provider: .zai,
                unit: 3,
                number: 5
            ),
            "Credit usage (5-hour)"
        )
        XCTAssertEqual(
            FlexibleQuotaBucketNormalizer.normalizedBucketLabel(
                "credits_limit",
                provider: .zai,
                unit: 6,
                number: 1
            ),
            "Credit usage (Weekly)"
        )
        XCTAssertEqual(
            FlexibleQuotaBucketNormalizer.normalizedBucketLabel(
                "tokens_limit",
                provider: .zai,
                unit: 5,
                number: 1
            ),
            "MCP usage (1 month)"
        )

        let payload: [String: Any] = [
            "data": [
                [
                    "type": "credit_limit",
                    "used": 25,
                    "limit": 100,
                    "unit": 3,
                    "number": 5
                ]
            ]
        ]
        let buckets = FlexibleQuotaBucketNormalizer.extractFlexibleBuckets(
            from: payload,
            provider: .zai,
            endpointLabel: "zai"
        )
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.label, "Credit usage (5-hour)")
        XCTAssertEqual(bucket.windowKind, .rollingHours)
        XCTAssertEqual(bucket.usedValue, 25)
        XCTAssertEqual(bucket.limitValue, 100)
    }

    func testForgeAndStubAdaptersReturnDeterministicSnapshots() async throws {
        let root = try makeTemporaryDirectory("stub-quota")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = makeContext(root: root)

        let forge = try await ForgeQuotaAdapter().fetch(context: context)
        XCTAssertEqual(forge.provider, AgentProvider.forgeDev.rawValue)
        XCTAssertTrue(forge.buckets.isEmpty || forge.sourceKind == .localSession)

        let goose = try await GooseQuotaAdapter().fetch(context: context)
        XCTAssertEqual(goose.provider, AgentProvider.goose.rawValue)
        XCTAssertNotNil(goose.statusMessage)

        let openClaw = try await OpenClawQuotaAdapter().fetch(context: context)
        XCTAssertEqual(openClaw.sourceKind, .unavailable)
        XCTAssertEqual(openClaw.provider, AgentProvider.openClaw.rawValue)

        let openClaude = try await OpenClaudeQuotaAdapter().fetch(context: context)
        XCTAssertEqual(openClaude.sourceKind, .unavailable)
        XCTAssertEqual(openClaude.provider, AgentProvider.openClaude.rawValue)

        let gemini = try await GeminiCLIQuotaAdapter().fetch(context: context)
        XCTAssertEqual(gemini.provider, AgentProvider.geminiCLI.rawValue)
        XCTAssertTrue(gemini.buckets.isEmpty)

        let cline = try await ClineQuotaAdapter().fetch(context: context)
        XCTAssertEqual(cline.provider, AgentProvider.cline.rawValue)
    }

    func testClaudeJSONLFetchUsesProCapsWhenNoOAuthCredentialsAreInjected() async throws {
        let root = try makeTemporaryDirectory("claude-jsonl-pro")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let projects = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let timestamp = iso.string(from: now.addingTimeInterval(-600))
        try write(
            """
            {"type":"assistant","timestamp":"\(timestamp)","message":{"usage":{"input_tokens":2200,"output_tokens":0}}}
            """,
            to: projects.appendingPathComponent("session.jsonl")
        )

        let snapshot = try await ClaudeQuotaAdapter().fetch(context: makeContext(root: root))
        let fiveHour = try XCTUnwrap(snapshot.buckets.first { $0.key.contains("five-hour") })
        XCTAssertEqual(fiveHour.limitValue, 220_000)
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedPercent), 1.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.sourceKind, .localSession)
    }

    func testGooseParserReadsLegacyJSONLFromAnOverriddenSessionDirectory() async throws {
        let root = try makeTemporaryDirectory("goose-jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","role":"user","content":"inspect"}
            {"timestamp":"2026-07-01T00:00:01Z","role":"assistant","content":"done","model":"goose-model","usage":{"input_tokens":11,"output_tokens":4}}
            """,
            to: root.appendingPathComponent("session-coverage.jsonl")
        )

        let result = try await GooseParser(sessionDirectoryOverride: root.path).parse()
        XCTAssertEqual(result.usages.first?.provider, .goose)
        XCTAssertEqual(result.usages.first?.inputTokens, 11)
        XCTAssertEqual(result.usages.first?.outputTokens, 4)
        XCTAssertEqual(result.conversations.first?.lastAssistantMessage, "done")

        // Default discovery is the only path that appends ~/.goose/sessions and
        // ~/.config/goose/sessions. Gate reads in the future so a populated
        // developer machine cannot turn this into a full-home parse.
        _ = try await GooseParser().parse(
            options: LogParseOptions(
                includeConversationBodies: false,
                minimumFileModificationDate: Date.distantFuture
            )
        )
    }

    func testSwitcherCLIProfilesExposeNewToolsAndTrustedPaths() {
        XCTAssertEqual(SwitcherCLIProfileType.hermes.displayName, "Hermes")
        XCTAssertEqual(SwitcherCLIProfileType.goose.displayName, "Goose")
        XCTAssertEqual(SwitcherCLIProfileType.windsurf.displayName, "Windsurf")
        XCTAssertEqual(SwitcherCLIProfileType.openClaude.displayName, "OpenClaude")
        XCTAssertEqual(SwitcherCLIProfileType.openClaw.displayName, "OpenClaw")

        XCTAssertEqual(SwitcherCLIProfileType.opencode.bundledLogoName, "OpenCodeLogo")
        XCTAssertEqual(SwitcherCLIProfileType.hermes.bundledLogoName, "HermesLogo")
        XCTAssertEqual(SwitcherCLIProfileType.goose.bundledLogoName, "GooseLogo")
        XCTAssertEqual(SwitcherCLIProfileType.windsurf.bundledLogoName, "WindsurfLogo")
        XCTAssertEqual(SwitcherCLIProfileType.openClaude.bundledLogoName, "ClaudeCodeLogo")
        XCTAssertEqual(SwitcherCLIProfileType.openClaw.bundledLogoName, "OpenClawLogo")

        XCTAssertEqual(SwitcherCLIProfileType.hermes.canonicalAgentProvider, .hermes)
        XCTAssertEqual(SwitcherCLIProfileType.goose.canonicalAgentProvider, .goose)
        XCTAssertEqual(SwitcherCLIProfileType.windsurf.canonicalAgentProvider, .windsurf)
        XCTAssertEqual(SwitcherCLIProfileType.openClaude.canonicalAgentProvider, .openClaude)
        XCTAssertEqual(SwitcherCLIProfileType.openClaw.canonicalAgentProvider, .openClaw)

        XCTAssertTrue(SwitcherCLIProfileType.opencode.trustedExecutablePaths.contains("$HOME/.local/bin/opencode"))
        XCTAssertTrue(SwitcherCLIProfileType.antigravity.trustedExecutablePaths.contains("$HOME/.gemini/antigravity/bin/agy"))
        XCTAssertTrue(SwitcherCLIProfileType.antigravity.trustedExecutablePaths.contains("$HOME/.gemini/antigravity/agy"))
        XCTAssertTrue(SwitcherCLIProfileType.antigravity.trustedExecutablePaths.contains("$HOME/.gemini/antigravity/bin/antigravity"))
        XCTAssertTrue(SwitcherCLIProfileType.cursorAgent.trustedExecutablePaths.contains("$HOME/.local/bin/cursor-agent"))
        XCTAssertTrue(SwitcherCLIProfileType.hermes.trustedExecutablePaths.contains("$HOME/.hermes/bin/hermes"))
        XCTAssertTrue(SwitcherCLIProfileType.goose.trustedExecutablePaths.contains("$HOME/.cargo/bin/goose"))
        XCTAssertTrue(SwitcherCLIProfileType.windsurf.trustedExecutablePaths.contains("/Applications/Windsurf.app/Contents/MacOS/Windsurf"))
        XCTAssertTrue(SwitcherCLIProfileType.openClaude.trustedExecutablePaths.contains("$HOME/.local/bin/openclaude"))
        XCTAssertTrue(SwitcherCLIProfileType.openClaw.trustedExecutablePaths.contains("$HOME/.local/bin/openclaw"))
    }

    #if canImport(Darwin)
    func testClassifierMatchesNewCLIQuotaPhrases() {
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .hermes, in: "hermes quota exceeded"),
            "hermes quota exceeded"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .goose, in: "block goose quota reached"),
            "block goose quota reached"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .windsurf, in: "flex credit exhausted"),
            "flex credit exhausted"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .openClaude, in: "claude code usage limit reached"),
            "claude code usage limit reached"
        )
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .openClaw, in: "openclaw limit reached"),
            "openclaw limit reached"
        )
    }
    #endif

    #if os(macOS)
    func testCLILaunchInjectsConfigEnvironmentKeysForNewCLITypes() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-cli-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        CLILaunchAdapter.executableResolver = { _ in executable }
        defer {
            CLILaunchAdapter.executableResolver = nil
            CLILaunchAdapter.environmentProvider = { ProcessInfo.processInfo.environment }
            CLILaunchAdapter.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser.path }
        }

        let cases: [(SwitcherCLIProfileType, [String])] = [
            (.hermes, ["HERMES_HOME", "HERMES_CONFIG_PATH"]),
            (.goose, ["GOOSE_HOME", "GOOSE_PATH_ROOT"]),
            (.windsurf, ["WINDSURF_HOME", "CODEIUM_HOME"]),
            (.openClaude, ["OPENCLAUDE_CONFIG_DIR"]),
            (.openClaw, ["OPENCLAW_HOME", "OPENCLAW_CONFIG_PATH"])
        ]

        for (cliType, keys) in cases {
            let configDirectory = "/tmp/obb-\(cliType.rawValue)-config"
            let profile = SwitcherProfileRecord(
                id: cliType.rawValue,
                targetKind: .cli,
                cliType: cliType,
                cliMetadata: SwitcherCLIProfileMetadata(
                    displayLabel: cliType.displayName,
                    configDirectory: configDirectory
                ),
                sortKey: 0
            )
            switch CLILaunchAdapter.buildCLILaunch(profile: profile) {
            case .failure(let error):
                XCTFail("\(cliType.rawValue): \(error)")
            case .success(let launch):
                for key in keys {
                    XCTAssertEqual(launch.env[key], configDirectory, "\(cliType.rawValue) \(key)")
                }
            }
        }
    }
    #endif

    // MARK: - Helpers

    private func primaryKey(provider: AgentProvider, buckets: [ProviderQuotaBucket]) -> String? {
        snapshot(provider: provider, buckets: buckets).primaryDisplayableBucket?.key
    }

    private func snapshot(provider: AgentProvider, buckets: [ProviderQuotaBucket]) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "\(provider.rawValue)_coverage",
            provider: provider.rawValue,
            providerID: provider.providerID,
            sourceKind: .localCLI,
            sourceId: "coverage",
            fetchedAt: Date(),
            source: "localCLI",
            confidence: .high,
            buckets: buckets,
            updatedAt: Date()
        )
    }

    private func bucket(
        key: String,
        label: String,
        windowKind: ProviderQuotaWindowKind = .rollingHours,
        used: Double,
        limit: Double
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: used,
            limitValue: limit,
            remainingValue: max(limit - used, 0),
            usedPercent: limit > 0 ? (used / limit) * 100 : nil,
            resetsAt: nil,
            unit: .tokens,
            isEstimated: false
        )
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeContext(
        root: URL,
        referenceEpochMs: Double? = nil
    ) -> ProviderQuotaAdapterContext {
        var environment: [String: String] = [:]
        if let referenceEpochMs {
            environment[AntigravityQuotaAdapter.referenceDateEnvironmentKey] = String(format: "%.0f", referenceEpochMs)
            environment[AntigravityQuotaAdapter.referenceDateOptInEnvironmentKey] = "1"
        }
        return ProviderQuotaAdapterContext(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root),
            fileManager: .default,
            session: URLSession(configuration: .ephemeral),
            environment: environment,
            homeDirectoryURL: root,
            snapshotStore: CoverageStubQuotaSnapshotStore(),
            bridgeManager: CoverageStubClaudeBridge(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .pro,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: [:]
        )
    }

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct CoverageStubQuotaSnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct CoverageStubClaudeBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}
