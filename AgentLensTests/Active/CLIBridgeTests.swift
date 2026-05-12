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

    func test_cliExecutableResolver_checksUserManagedBinsBeforeLoginShell() async throws {
        CLIExecutableResolver.clearCache()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-resolver-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root
            .appendingPathComponent(".npm-global", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executable = binDirectory.appendingPathComponent("droid")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let marker = root.appendingPathComponent("shell-invoked")
        let shell = root.appendingPathComponent("slow-shell")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 1\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        defer {
            CLIExecutableResolver.clearCache()
            try? FileManager.default.removeItem(at: root)
        }

        let resolver = CLIExecutableResolver(
            environmentProvider: { ["PATH": "/usr/bin:/bin", "SHELL": shell.path] },
            homeDirectoryProvider: { root.path }
        )

        let resolved = await resolver.resolveExecutable(named: "droid")

        XCTAssertEqual(resolved, executable.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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

        // Usage is yielded immediately, then tool call is buffered and flushed
        // when content arrives, so tool call precedes text.
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[0], .usage(CLIUsageSnapshot(inputTokens: 2, outputTokens: 3, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0)))
        // Tool call flushed before text; detail is summarized from the JSON arguments
        XCTAssertEqual(result.events[1], .toolUse(name: "search", detail: "burnbar"))
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

    // MARK: - OpenAI-Compatible SSE Multi-Delta Tool Call Accumulation

    func test_openAICompatibleSSEParser_accumulatesMultiDeltaToolCall() {
        var parser = OpenAICompatibleSSEParser()

        // First delta: name only, arguments empty — buffered
        let first = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"Read","arguments":""}}]}}]}
        """)
        // Should not emit tool event yet — we buffer until content or [DONE]
        XCTAssertEqual(first.events.filter { if case .toolUse = $0 { true } else { false } }.count, 0)

        // Second delta: arguments fragment arrives
        let second = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"/src/main.swift"}}]}}]}
        """)
        XCTAssertEqual(second.events.filter { if case .toolUse = $0 { true } else { false } }.count, 0)

        // Third delta: content starts — flush pending tool calls
        let third = parser.events(fromLine: """
        data: {"choices":[{"delta":{"content":"Here is the file:"}}]}
        """)
        let toolEvents = third.events.filter { if case .toolUse = $0 { true } else { false } }
        XCTAssertEqual(toolEvents.count, 1)
        if case .toolUse(let name, let detail) = third.events[0] {
            XCTAssertEqual(name, "Read")
            // Accumulated arguments: "" + "/src/main.swift" → summarizeToolArguments extracts path
            XCTAssertEqual(detail, "/src/main.swift")
        } else {
            XCTFail("Expected toolUse event as first event")
        }
        XCTAssertEqual(third.events.last, .text("Here is the file:"))
    }

    func test_openAICompatibleSSEParser_multipleToolCallsAcrossDeltas() {
        var parser = OpenAICompatibleSSEParser()

        // First tool call: name arrives with empty arguments — buffered
        let first = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"Read","arguments":""}}]}}]}
        """)
        // With accumulation, name-only delta is buffered (not emitted yet)
        XCTAssertEqual(first.events.count, 0)

        // Second tool call name arrives (different index)
        let second = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"Bash","arguments":""}}]}}]}
        """)
        // Also buffered
        XCTAssertEqual(second.events.count, 0)

        // Content arrives — flush all pending tool calls, then emit text
        let third = parser.events(fromLine: """
        data: {"choices":[{"delta":{"content":"Done."}}]}
        """)
        // Should flush 2 tool calls then emit text
        XCTAssertEqual(third.events.count, 3)
        XCTAssertEqual(third.events[0], .toolUse(name: "Read", detail: nil))
        XCTAssertEqual(third.events[1], .toolUse(name: "Bash", detail: nil))
        XCTAssertEqual(third.events[2], .text("Done."))
    }

    func test_openAICompatibleSSEParser_accumulatesArgumentsAcrossDeltas() {
        var parser = OpenAICompatibleSSEParser()

        // Delta 1: tool call name + first argument fragment
        _ = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"search","arguments":"bu"}}]}}]}
        """)
        // No content, no flush — buffered

        // Delta 2: more arguments
        _ = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"rn"}}]}}]}
        """)
        // Still buffered

        // [DONE] — flush all pending
        let done = parser.events(fromLine: "data: [DONE]")
        let toolEvents = done.events.filter { if case .toolUse = $0 { true } else { false } }
        XCTAssertEqual(toolEvents.count, 1)
        if case .toolUse(let name, let detail) = toolEvents[0] {
            XCTAssertEqual(name, "search")
            // Accumulated arguments: "bu" + "rn" = "burn"
            // summarizeToolArguments gets a non-JSON string, falls back to truncated preview
            XCTAssertEqual(detail, "burn")
        }
    }

    func test_openAICompatibleSSEParser_finishReasonFlushesToolCalls() {
        var parser = OpenAICompatibleSSEParser()

        // Tool call with arguments
        _ = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"Bash","arguments":"{\\"command\\":\\"ls\\"}"}}]}}]}
        """)

        // finish_reason: stop should flush pending tool calls
        let stop = parser.events(fromLine: """
        data: {"choices":[{"finish_reason":"stop","delta":{}}]}
        """)
        let tools = stop.events.filter { if case .toolUse = $0 { true } else { false } }
        XCTAssertEqual(tools.count, 1)
        if case .toolUse(let name, let detail) = tools[0] {
            XCTAssertEqual(name, "Bash")
            XCTAssertEqual(detail, "ls")
        }
    }

    func test_openAICompatibleSSEParser_finishReasonToolCallsFlushes() {
        var parser = OpenAICompatibleSSEParser()

        // Tool call buffered
        _ = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"EditFile","arguments":"{\\"path\\":\\"/foo.swift\\"}"}}]}}]}
        """)

        // finish_reason: tool_calls should flush
        let flush = parser.events(fromLine: """
        data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}
        """)
        let tools = flush.events.filter { if case .toolUse = $0 { true } else { false } }
        XCTAssertEqual(tools.count, 1)
        if case .toolUse(let name, let detail) = tools[0] {
            XCTAssertEqual(name, "EditFile")
            XCTAssertEqual(detail, "/foo.swift")
        }
    }

    func test_openAICompatibleSSEParser_backwardsCompatible_singleDeltaWithContentAndTool() {
        // Existing behavior: tool name + content in same delta still works
        var parser = OpenAICompatibleSSEParser()
        let line = #"""
        data: {"usage":{"input_tokens":2,"output_tokens":3},"choices":[{"delta":{"content":"hi","tool_calls":[{"function":{"name":"search","arguments":"{\"q\":\"burnbar\"}"}}]}}]}
        """#
        let result = parser.events(fromLine: line)
        // Usage flushed immediately (not a tool call), then tool call buffered,
        // then content arrives and flushes the tool call.
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events[0], .usage(CLIUsageSnapshot(inputTokens: 2, outputTokens: 3, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0)))
        // Tool call flushed before text
        XCTAssertEqual(result.streamedText, true)
    }

    func test_openAICompatibleSSEParser_argumentOnlyDeltaWithoutPriorName() {
        var parser = OpenAICompatibleSSEParser()

        // Argument fragment arrives without a name for a tool call we haven't seen yet
        _ = parser.events(fromLine: """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":\\"/tmp/test.swift\\"}"}}]}}]}
        """)

        // [DONE] — should synthesize a generic name
        let done = parser.events(fromLine: "data: [DONE]")
        let tools = done.events.filter { if case .toolUse = $0 { true } else { false } }
        XCTAssertEqual(tools.count, 1)
        if case .toolUse(let name, let detail) = tools[0] {
            XCTAssertEqual(name, "tool")  // generic fallback
            XCTAssertEqual(detail, "/tmp/test.swift")
        }
    }
}
