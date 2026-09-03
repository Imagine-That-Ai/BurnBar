import XCTest
import OpenBurnBarAssistantModels
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

final class CLIArgumentBuilderForbiddenFlagTests: XCTestCase {
    func testGrokACPDoesNotEmitPromptFileOrAlwaysApprove() {
        let args = CLIArgumentBuilder.grokACPArguments()
        XCTAssertEqual(args, ["agent", "stdio"])
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: args).isEmpty)
    }

    func testKimiACPDoesNotEmitYoloOrDashP() {
        let args = CLIArgumentBuilder.kimiACPArguments()
        XCTAssertEqual(args, ["acp"])
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: args).isEmpty)
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("--yolo"))
    }

    func testAntigravityIncludesPromptAndNotDangerouslySkip() {
        let args = CLIArgumentBuilder.antigravityArguments(prompt: "hello world")
        XCTAssertTrue(args.contains("--print"))
        XCTAssertTrue(args.contains("hello world"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: args).isEmpty)
    }

    func testForbiddenFlagDetectorCatchesYoloAndPromptFile() {
        let hits = CLIArgumentBuilder.forbiddenLaunchFlags(in: ["-p", "hi", "--yolo", "--prompt-file", "x"])
        XCTAssertTrue(hits.contains("--yolo"))
        XCTAssertTrue(hits.contains("--prompt-file"))
    }

    func testForbiddenFlagDetectorCatchesMuseAutonomyBypasses() {
        let hits = CLIArgumentBuilder.forbiddenLaunchFlags(in: [
            "exec", "--json",
            "--disable-approval",
            "--disable-sandbox",
            "--trust-workspace",
            "--approval-mode", "never",
            "--yolo"
        ])
        XCTAssertTrue(hits.contains("--disable-approval"))
        XCTAssertTrue(hits.contains("--disable-sandbox"))
        XCTAssertTrue(hits.contains("--trust-workspace"))
        XCTAssertTrue(hits.contains("--approval-mode never"))
        XCTAssertTrue(hits.contains("--yolo"))
        XCTAssertTrue(
            CLIArgumentBuilder.forbiddenLaunchFlags(in: ["--approval-mode=never"]).contains("--approval-mode=never")
        )
    }

    func testMuseExecUsesHeadlessFormWithModelAndWorkspace() {
        let args = CLIArgumentBuilder.museArguments(
            prompt: "hello world",
            model: "muse-spark",
            workspaceDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(args.first, "exec")
        // Load-bearing: stdout must be the JSONL event log MuseExecJSONLParser reads.
        XCTAssertEqual(args.dropFirst().first, "--json")
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("muse-spark-1.3"))
        // The bare alias is rejected by `muse exec`; it must be normalized.
        XCTAssertFalse(args.contains("muse-spark"))
        XCTAssertTrue(args.contains("--workspace"))
        XCTAssertTrue(args.contains("/tmp"))
        XCTAssertTrue(args.last?.contains("hello world") == true)
        // No grant: fully read-only.
        XCTAssertTrue(args.contains("--disable-write"))
        XCTAssertTrue(args.contains("--disable-shell"))
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: args).isEmpty)
    }

    func testMuseExecCanonicalizesDashCatalogSlugsToWireIDs() {
        let standard = CLIArgumentBuilder.museArguments(prompt: "hi", model: "muse-spark-1-3-standard")
        XCTAssertTrue(standard.contains("muse-spark-1.3"))
        XCTAssertFalse(standard.contains("muse-spark-1-3-standard"))

        let contributor = CLIArgumentBuilder.museArguments(prompt: "hi", model: "muse-spark-1-3-contributor")
        XCTAssertTrue(contributor.contains("muse-spark-1.3-contributor"))
        XCTAssertFalse(contributor.contains("muse-spark-1-3-contributor"))

        XCTAssertEqual(CLIArgumentBuilder.resolvedMuseModelID("muse-spark-1-2-standard"), "muse-spark-1.2")
        XCTAssertEqual(CLIArgumentBuilder.resolvedMuseModelID("muse-spark-1.3"), "muse-spark-1.3")
    }

    func testMuseNeverEmitsFullAutonomyBypasses() {
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .muse,
            threadID: "thread-1",
            capabilities: Set(AgentDesktopCapability.allCases),
            trustMode: .trusted,
            now: Date(),
            duration: 60
        )
        let args = CLIArgumentBuilder.museArguments(prompt: "hi", model: "muse-spark-1.3", capabilityGrant: grant)
        XCTAssertFalse(args.contains("--yolo"))
        XCTAssertFalse(args.contains("--disable-approval"))
        XCTAssertFalse(args.contains("--disable-sandbox"))
        XCTAssertFalse(args.contains("--trust-workspace"))
        // Full grant: no read-only gates.
        XCTAssertFalse(args.contains("--disable-write"))
        XCTAssertFalse(args.contains("--disable-shell"))
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: args).isEmpty)
    }

    func testMusePartialGrantDisablesOnlyMissingCapabilities() {
        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: .muse,
            threadID: "thread-1",
            capabilities: [.workspaceRead, .shell],
            now: Date(),
            duration: 60
        )
        let args = CLIArgumentBuilder.museArguments(prompt: "hi", capabilityGrant: grant)
        XCTAssertTrue(args.contains("--disable-write"))
        XCTAssertFalse(args.contains("--disable-shell"))
        XCTAssertFalse(args.contains("--model"), "empty model must omit --model so Muse picks the logged-in SKU")
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: args).isEmpty)
    }

    func testRemoteMissionOMPDoesNotAutoApprove() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .omp)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OMP tools",
            prompt: "read only",
            backend: backend,
            data: [
                "commandsAllowed": true,
                "fileEditsAllowed": true
            ]
        ))
        XCTAssertFalse(plan.arguments.contains("--auto-approve"))
        XCTAssertTrue(CLIArgumentBuilder.forbiddenLaunchFlags(in: plan.arguments).isEmpty)
    }
}
