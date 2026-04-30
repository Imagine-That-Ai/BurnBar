import XCTest
@testable import OpenBurnBar

@MainActor
final class CLIBridgeTests: XCTestCase {

    // MARK: - Executable Path Parsing Tests

    func test_cliBridge_parseExecutablePath_prefersAbsolutePathLine() {
        let output = """
        Loading shell config...
        /Users/tester/.nvm/versions/node/v24.14.0/bin/codex
        """
        let path = CLIBridge.parseExecutablePath(fromCommandOutput: output)
        XCTAssertEqual(path, "/Users/tester/.nvm/versions/node/v24.14.0/bin/codex")
    }

    func test_cliBridge_parseExecutablePath_handlesEmptyOutput() {
        let output = ""
        let path = CLIBridge.parseExecutablePath(fromCommandOutput: output)
        XCTAssertNil(path)
    }

    func test_cliBridge_parseExecutablePath_skipsNonAbsoluteLines() {
        let output = "codex not found\n/usr/local/bin/codex"
        let path = CLIBridge.parseExecutablePath(fromCommandOutput: output)
        XCTAssertEqual(path, "/usr/local/bin/codex")
    }

    // MARK: - Claude Arguments Tests

    func test_cliBridge_claudeArguments_includeVerboseForStreamJSON() {
        let args = CLIBridge.claudeArguments(prompt: "test prompt")
        XCTAssertTrue(args.contains("--output-format"))
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertTrue(args.contains("--verbose"))
    }

    func test_cliBridge_claudeArguments_includeExplicitModelWhenProvided() {
        let args = CLIBridge.claudeArguments(prompt: "test", model: "claude-sonnet-4-20250514")
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("claude-sonnet-4-20250514"))
    }

    func test_cliBridge_claudeArguments_omitsModelWhenEmpty() {
        let args = CLIBridge.claudeArguments(prompt: "test", model: "")
        XCTAssertFalse(args.contains("--model"))
    }

    // MARK: - Codex Arguments Tests

    func test_cliBridge_codexArguments_defaultModelAndReasoning() {
        let args = CLIBridge.codexArguments(prompt: "test")
        XCTAssertTrue(args.contains("exec"))
        XCTAssertTrue(args.contains("--json"))
        // Default model should be gpt-5.5
        XCTAssertTrue(args.contains("gpt-5.5"))
    }

    func test_cliBridge_codexArguments_useExplicitModelWhenProvided() {
        let args = CLIBridge.codexArguments(prompt: "test", model: "gpt-5.4")
        XCTAssertTrue(args.contains("gpt-5.4"))
    }

    func test_cliBridge_codexArguments_fallbackToSupportedModelWhenInvalidModelProvided() {
        let args = CLIBridge.codexArguments(prompt: "test", model: "MiniMax-M2.7-highspeed")
        XCTAssertTrue(args.contains("gpt-5.5"))
        XCTAssertFalse(args.contains("MiniMax-M2.7-highspeed"))
    }

    func test_settingsManager_resolvedHermesChatModel_minimaxAdvertised_usesCodexCompatibleDefault() {
        XCTAssertEqual(
            SettingsManager.resolvedHermesChatModel(override: "", gatewayAdvertisedModel: "MiniMax-M2.7-highspeed"),
            "gpt-5.5"
        )
    }

    func test_settingsManager_resolvedHermesChatModel_overrideWins() {
        XCTAssertEqual(
            SettingsManager.resolvedHermesChatModel(override: " custom-model ", gatewayAdvertisedModel: "MiniMax-M2.7-highspeed"),
            "custom-model"
        )
    }

    func test_settingsManager_resolvedHermesChatModel_nonMinimax_usesHermes() {
        XCTAssertEqual(
            SettingsManager.resolvedHermesChatModel(override: "", gatewayAdvertisedModel: "NousResearch/Hermes-3-Llama-3.1-8B"),
            "hermes"
        )
    }

    func test_settingsManager_resolvedHermesChatModel_emptyProbe_usesHermes() {
        XCTAssertEqual(
            SettingsManager.resolvedHermesChatModel(override: "", gatewayAdvertisedModel: nil),
            "hermes"
        )
    }

    func test_cliBridge_codexArguments_includesReasoningEffort() {
        let args = CLIBridge.codexArguments(prompt: "test")
        XCTAssertTrue(args.contains(#"model_reasoning_effort="high""#))
    }

    // MARK: - User Managed Search Directories Tests

    func test_cliBridge_userManagedSearchDirectories_includeNodeManagerBins() throws {
        let directories = CLIBridge.userManagedExecutableSearchDirectories(
            homeDirectory: "/Users/test"
        )
        // Should include common version manager paths
        XCTAssertTrue(directories.contains { $0.contains(".npm-global") })
        XCTAssertTrue(directories.contains { $0.contains(".bun") })
        XCTAssertTrue(directories.contains { $0.contains(".volta") })
        XCTAssertTrue(directories.contains { $0.contains(".asdf") })
    }

    // MARK: - Executable Resolution Tests

    func test_cliBridge_resolveExecutable_findsKnownExecutableInProvidedDirectories() {
        let searchDirectories = ["/usr/bin", "/bin"]
        let result = CLIBridge.resolveExecutable(named: "swift", searchDirectories: searchDirectories)
        XCTAssertNotNil(result)
    }

    // MARK: - Base Executable Search Tests

    func test_cliBridge_baseExecutableSearchDirectories_includesStandardPaths() {
        let env = ["PATH": "/usr/bin:/bin"]
        let dirs = CLIBridge.baseExecutableSearchDirectories(
            environment: env,
            homeDirectory: "/Users/test"
        )
        XCTAssertTrue(dirs.contains("/usr/bin"))
        XCTAssertTrue(dirs.contains("/bin"))
        XCTAssertTrue(dirs.contains("/Users/test/.local/bin"))
    }

    func test_cliExecutableResolver_baseExecutableSearchDirectories_expandsHomeVariables() {
        let dirs = CLIExecutableResolver.baseExecutableSearchDirectories(
            environment: ["PATH": "$HOME/.cursor/extensions/bin:${HOME}/.factory/bin:/usr/bin"],
            homeDirectory: "/Users/test"
        )

        XCTAssertTrue(dirs.contains("/Users/test/.cursor/extensions/bin"))
        XCTAssertTrue(dirs.contains("/Users/test/.factory/bin"))
    }

    func test_cliBridge_openAICompatibleUsage_parsesUsagePayload() {
        let usage = CLIBridge.openAICompatibleUsage(from: [
            "usage": [
                "input_tokens": 120,
                "output_tokens": 80,
                "cache_creation_input_tokens": 40,
                "cache_read_input_tokens": 20
            ]
        ])

        XCTAssertEqual(usage?.inputTokens, 120)
        XCTAssertEqual(usage?.outputTokens, 80)
        XCTAssertEqual(usage?.cacheCreationTokens, 40)
        XCTAssertEqual(usage?.cacheReadTokens, 20)
        XCTAssertEqual(usage?.totalTokens, 240)
    }

    func test_cliBridge_openAICompatibleUsage_parsesFlatPayload() {
        let usage = CLIBridge.openAICompatibleUsage(from: [
            "prompt_tokens": 33,
            "completion_tokens": 11,
            "cached_tokens": 9
        ])

        XCTAssertEqual(usage?.inputTokens, 33)
        XCTAssertEqual(usage?.outputTokens, 11)
        XCTAssertEqual(usage?.cacheReadTokens, 9)
    }

    func test_cliBridge_codexEventError_mapsQuotaEventsToQuotaExhausted() {
        let error = CLIBridge.codexEventError(from: "Error: quota exhausted for the weekly limit.")

        guard case .quotaExhausted(let detail) = error else {
            return XCTFail("Expected quota exhaustion error, got \(error)")
        }
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("weekly limit"))
    }

    func test_claudeCodeStreamJSONParser_extractsTextAndToolEvents() {
        let line = #"""
        {"message":{"content":[{"type":"text","text":"hello"},{"type":"tool_use","name":"Read","input":{"path":"/tmp/file.swift"}}]}}
        """#

        XCTAssertEqual(
            ClaudeCodeStreamJSONParser.events(fromLine: line),
            [
                .text("hello"),
                .toolUse(name: "Read", detail: "/tmp/file.swift")
            ]
        )
    }

    func test_codexExecJSONLParser_emitsOnlyNewAgentMessageDelta() {
        var parser = CodexExecJSONLParser()

        let first = parser.events(fromLine: #"""
        {"type":"item.updated","item":{"id":"m1","type":"agent_message","text":"hello"}}
        """#)
        let second = parser.events(fromLine: #"""
        {"type":"item.updated","item":{"id":"m1","type":"agent_message","text":"hello world"}}
        """#)

        XCTAssertEqual(first.events, [.text("hello")])
        XCTAssertNil(first.error)
        XCTAssertEqual(second.events, [.text(" world")])
        XCTAssertNil(second.error)
    }

    func test_codexExecJSONLParser_resetsDeltaForNewAgentMessageItem() {
        var parser = CodexExecJSONLParser()
        _ = parser.events(fromLine: #"""
        {"type":"item.updated","item":{"id":"m1","type":"agent_message","text":"first"}}
        """#)

        let next = parser.events(fromLine: #"""
        {"type":"item.updated","item":{"id":"m2","type":"agent_message","text":"second"}}
        """#)

        XCTAssertEqual(next.events, [.text("second")])
        XCTAssertNil(next.error)
    }

    func test_codexExecJSONLParser_extractsCommandToolEvent() {
        var parser = CodexExecJSONLParser()

        let result = parser.events(fromLine: #"""
        {"type":"item.started","item":{"type":"command_execution","command":"swift test --package-path OpenBurnBarCore"}}
        """#)

        XCTAssertEqual(
            result.events,
            [.toolUse(name: "Bash", detail: "swift test --package-path OpenBurnBarCore")]
        )
        XCTAssertNil(result.error)
    }

    func test_openAICompatibleSSEParser_extractsUsageToolAndText() {
        var parser = OpenAICompatibleSSEParser()
        let line = #"""
        data: {"usage":{"input_tokens":2,"output_tokens":3},"choices":[{"delta":{"content":"hi","tool_calls":[{"function":{"name":"search","arguments":"{\"q\":\"burnbar\"}"}}]}}]}
        """#

        let result = parser.events(fromLine: line)

        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[0], .usage(CLIUsageSnapshot(inputTokens: 2, outputTokens: 3, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0)))
        XCTAssertEqual(result.events[1], .toolUse(name: "search", detail: #"{"q":"burnbar"}"#))
        XCTAssertEqual(result.events[2], .text("hi"))
        XCTAssertTrue(result.streamedText)
        XCTAssertFalse(result.done)
    }

    func test_openAICompatibleModelListParser_extractsFirstModelID() throws {
        let data = #"{"data":[{"id":"Hermes-3"}]}"#.data(using: .utf8)!

        XCTAssertEqual(OpenAICompatibleModelListParser.modelName(from: data), "Hermes-3")
    }

    func test_streamRuntime_cancelRunningProcess_terminatesMatchingTokenOnly() async throws {
        let runtime = CLIBridgeStreamRuntimeCoordinator()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        let token = await runtime.registerRunningProcess(process)

        await runtime.cancelRunningProcess(token: token + 1)
        XCTAssertTrue(process.isRunning)

        await runtime.cancelRunningProcess(token: token)
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    func test_streamRuntime_cancelHTTPStreamTask_cancelsMatchingTokenOnly() async {
        let runtime = CLIBridgeStreamRuntimeCoordinator()
        let streamID = await runtime.nextHTTPStreamID()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        await runtime.installHTTPStreamTask(task, streamID: streamID)

        await runtime.cancelHTTPStreamTask(streamID: streamID + 1)
        XCTAssertFalse(task.isCancelled)

        await runtime.cancelHTTPStreamTask(streamID: streamID)
        XCTAssertTrue(task.isCancelled)
        await task.value
    }
}
