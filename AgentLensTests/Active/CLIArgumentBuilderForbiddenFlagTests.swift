import XCTest
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
