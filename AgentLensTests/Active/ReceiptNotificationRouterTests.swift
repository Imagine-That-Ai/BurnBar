import XCTest
import UserNotifications
@testable import OpenBurnBar
@testable import OpenBurnBarKernel

final class ReceiptNotificationRouterTests: XCTestCase {
    func test_userInfo_isAReceiptPrintedPayloadWithAnOpenBurnBarLink() {
        let receipt = ReceiptRecord(
            id: "rcpt_session-1",
            sessionId: "session-1",
            projectName: "OpenBurnBar",
            provider: .codex,
            modelName: "gpt-5.6-sol"
        )
        let info = ReceiptNotificationRouter.userInfo(for: receipt)
        XCTAssertEqual(info["type"], ReceiptNotificationRouter.payloadType)
        XCTAssertEqual(info["receipt_id"], "rcpt_session-1")
        XCTAssertEqual(info["session_id"], "session-1")

        let payload = ReceiptNotificationRouter.payload(from: info)
        XCTAssertEqual(payload?.receiptID, "rcpt_session-1")
        XCTAssertEqual(payload?.deepLink.scheme, "openburnbar")
        XCTAssertEqual(payload?.deepLink.host, "receipts")
        XCTAssertEqual(payload?.deepLink.path, "/rcpt_session-1")
    }

    func test_payload_rejectsForeignBanners() {
        XCTAssertNil(ReceiptNotificationRouter.payload(from: [
            "type": "agent_reply",
            "deep_link": "openburnbar://sessions/x"
        ]))
        XCTAssertNil(ReceiptNotificationRouter.payload(from: [
            "type": ReceiptNotificationRouter.payloadType,
            "deep_link": "https://example.com"
        ]))
    }

    func test_handleTap_opensTheDeepLinkAndIgnoresOtherNotifications() {
        var opened: URL?
        let receipt = ReceiptRecord(
            sessionId: "session-1",
            projectName: "OpenBurnBar",
            provider: .factory,
            modelName: "unknown"
        )
        let openedReceipt = ReceiptNotificationRouter.handleTap(
            userInfo: ReceiptNotificationRouter.userInfo(for: receipt)
        ) { url in
            opened = url
            return true
        }
        XCTAssertTrue(openedReceipt)
        XCTAssertEqual(opened?.host, "receipts")

        XCTAssertFalse(
            ReceiptNotificationRouter.handleTap(userInfo: ["type": "agent_reply"]) { _ in
                XCTFail("must not open foreign banners")
                return true
            }
        )
    }

    func test_foregroundPresentation_doesNotRequestASecondSystemSound() {
        XCTAssertFalse(
            ReceiptNotificationRouter.foregroundPresentationOptions.contains(.sound)
        )
        XCTAssertTrue(
            ReceiptNotificationRouter.foregroundPresentationOptions.contains(.banner)
        )
        XCTAssertTrue(
            ReceiptNotificationRouter.foregroundPresentationOptions.contains(.list)
        )
    }

    func test_bannerCopy_leadsWithTheChatSummary() {
        let receipt = ReceiptRecord(
            sessionId: "session-1",
            projectName: "OpenBurnBar",
            provider: .factory,
            modelName: "unknown",
            harness: "Factory CLI",
            promptSummary: "Wire receipts to the indexed chat."
        )
        let copy = ReceiptNotificationRouter.bannerCopy(for: receipt)
        XCTAssertEqual(copy.title, "Wire receipts to the indexed chat.")
        XCTAssertTrue(copy.body.contains("Factory CLI"))
        XCTAssertTrue(copy.body.contains("OpenBurnBar"))
        XCTAssertFalse(copy.title.contains("New Receipt"))

        let untitled = ReceiptRecord(
            sessionId: "session-2",
            projectName: "OpenBurnBar",
            provider: .factory,
            modelName: "unknown",
            harness: "Factory CLI"
        )
        let overlay = ReceiptConversationOverlay(
            conversationID: "conv-2",
            sessionID: "session-2",
            inferredTaskTitle: "",
            summary: "Hydrate the banner from the conversation overlay.",
            summaryTitle: "",
            workingDirectory: nil,
            messageCount: 4,
            keyFiles: []
        )
        XCTAssertEqual(
            ReceiptNotificationRouter.bannerCopy(for: untitled, overlay: overlay).title,
            "Hydrate the banner from the conversation overlay."
        )
    }

    func test_category_registersAnOpenActionOnTheReceiptBanner() {
        XCTAssertEqual(ReceiptNotificationRouter.category.identifier, ReceiptNotificationRouter.categoryID)
        XCTAssertEqual(ReceiptNotificationRouter.category.actions.map(\.identifier), [
            ReceiptNotificationRouter.openActionID
        ])
        XCTAssertEqual(ReceiptNotificationRouter.category.actions.first?.title, "Open")
    }

    func test_classifier_matchesPixelClockAndIgnoresCursorApp() {
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "cursor-agent worker start"),
            .cursor
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "cursor-agent /Applications/Cursor.app/Contents/Resources/app/bin/cursor-agent --workspace /tmp"
            ),
            .cursor,
            "Bundled cursor-agent is still a live CLI even though the path contains .app/Contents"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.runtimeFamily(for: .cursorAgent),
            .cursor
        )
        XCTAssertNil(AgentCLIProcessClassifier.provider(forProcessLine: "/Applications/Cursor.app/Contents/MacOS/Cursor"))
        XCTAssertNil(AgentCLIProcessClassifier.provider(forProcessLine: "droid daemon --remote-access"))
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "/opt/homebrew/bin/grok --model grok"),
            .xAI
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "codex-code-mode-host --listen"),
            .codex
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "pi-agent --workspace /tmp"),
            .piAgent
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "pi --workspace /tmp"),
            .piAgent,
            "The app-launched Pi executable is `pi`"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "agy --add-dir /tmp"),
            .antigravity,
            "The app-launched Antigravity executable is `agy`"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "node /Users/x/.cursor/extensions/foo/dist/main.js"
            ),
            "A ~/.cursor path is not cursor-agent"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "node /Users/x/factory/docs/build.js"
            ),
            "A .../factory/... path is not the Factory CLI"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "droid exec --input-format stream-jsonrpc"),
            .factory
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "node /Users/x/claude/docs/build.js"
            ),
            "A .../claude/... path is not the Claude CLI"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "claude --dangerously-skip-permissions"),
            .claudeCode
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "node /Users/x/grok/docs/build.js --model grok-code-fast"
            ),
            "A .../grok/... path plus a --model flag is not the Grok CLI"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "/opt/homebrew/bin/gemini --yolo"),
            .geminiCLI
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "aider --message ship"),
            .aider
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "/usr/local/bin/goose run"),
            .goose
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "antigravity-cli --workspace /tmp"),
            .antigravity
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "aider --message grok"),
            .aider,
            "A later argv word must not impersonate the Grok CLI"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(forProcessLine: "git commit -m claude"),
            "A commit message is not the Claude CLI"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "/Users/x/server/bin/codex exec"),
            .codex,
            "A directory named server must not hide a live Codex CLI"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "codex exec fix the server"),
            .codex,
            "A later prompt word must not classify a live CLI as a daemon"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(forProcessLine: "droid daemon"),
            "The first subcommand daemon is a service"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "droid /Users/alberto/.local/lib/factory/droid daemon --remote-access"
            ),
            "ps repeats the executable in ARGS; the subcommand is still daemon"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "node node /Users/alberto/.nvm/versions/node/bin/codex"
            ),
            .codex
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "muse --workspace /tmp"),
            .muse
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "openclaude --yolo"),
            .openClaude
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "prime-agent --provider openburnbar"),
            .primeAgent,
            "A later argv word naming this repo must not hide Prime"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "/Volumes/DevSSD/worktrees/openburnbar/.local/bin/codex exec"
            ),
            .codex,
            "A worktree path that contains OpenBurnBar must not hide Codex"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(
                forProcessLine: "/Applications/OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
            ),
            "The BurnBar app itself is not a live agent CLI"
        )
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(forProcessLine: "/bin/ps -axo comm,args")
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "junie --session /tmp"),
            .junie
        )
        XCTAssertTrue(
            ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .factory).contains("com.factory.app")
        )
        XCTAssertTrue(
            ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .claudeCode)
                .contains("com.anthropic.claude-code")
        )
        XCTAssertFalse(
            ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .claudeCode)
                .contains("com.anthropic.claudefordesktop"),
            "Claude Desktop must not hold a Claude Code CLI slip open"
        )
        XCTAssertTrue(ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .cursor).isEmpty)
        XCTAssertTrue(ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .cursorAgent).isEmpty)
        XCTAssertTrue(ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .warp).contains("dev.warp.Warp-Stable"))
        XCTAssertTrue(ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: .warp).contains("dev.warp.Warp-Nightly"))
        XCTAssertNil(
            AgentCLIProcessClassifier.provider(forProcessLine: "ollama serve"),
            "The Ollama daemon is not a live agent session"
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "ollama run llama3"),
            .ollama
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "copilot --prompt ship"),
            .copilot
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "cline --workspace /tmp"),
            .cline
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "auggie --workspace /tmp"),
            .augment
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "kilo-code --workspace /tmp"),
            .kiloCode
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "roo-code --workspace /tmp"),
            .rooCode
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.provider(forProcessLine: "fx --session /tmp"),
            .fx
        )
        XCTAssertEqual(
            CLISessionCloseMonitor.resolveHarnessName(for: .zai),
            "Z.ai"
        )
        XCTAssertEqual(
            CLISessionCloseMonitor.resolveHarnessName(for: .openClaw),
            "OpenClaw"
        )
        XCTAssertEqual(
            CLISessionCloseMonitor.resolveHarnessName(for: .kiloCode),
            "Kilo Code"
        )
        XCTAssertFalse(AgentCLIProcessClassifier.canObserveRuntime(for: .windsurf))
        XCTAssertFalse(AgentCLIProcessClassifier.canObserveRuntime(for: .devin))
        XCTAssertTrue(AgentCLIProcessClassifier.canObserveRuntime(for: .cursor))
        XCTAssertTrue(AgentCLIProcessClassifier.canObserveRuntime(for: .factory))
        XCTAssertTrue(AgentCLIProcessClassifier.canObserveRuntime(for: .warp))
        XCTAssertEqual(
            AgentCLIProcessClassifier.processLines(fromPSOutput: "COMM ARGS\ncursor-agent worker start\n").count,
            1
        )
        XCTAssertEqual(
            AgentCLIProcessClassifier.processListArguments,
            ["-axo", "comm,args"]
        )
        XCTAssertTrue(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: ["codex exec --cd /Users/a/burnbar"]
            )
        )
        XCTAssertFalse(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: ["codex exec --cd /Users/a/other-app"]
            ),
            "A sibling Codex in another repo must not hold this slip"
        )
        XCTAssertTrue(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: ["codex exec"]
            ),
            "Bare argv with no workspace stays conservative"
        )
        XCTAssertTrue(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: [
                    "codex exec",
                    "codex exec --cd /Users/a/other-app"
                ]
            ),
            "A bare family process plus a sibling in another repo stays conservative"
        )
        XCTAssertTrue(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: ["codex /Users/x/.local/bin/codex exec"]
            ),
            "An executable under /Users is not a different workspace"
        )
        XCTAssertTrue(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: [#"codex exec "inspect /Users/a/other-app/file""#]
            ),
            "A later prompt path is not a different workspace"
        )
        XCTAssertTrue(
            AgentCLIProcessClassifier.isUnknownProcessSnapshot(
                [AgentCLIProcessClassifier.unknownProcessSnapshotSentinel]
            )
        )
        XCTAssertFalse(
            AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
                projectPath: "/Users/a/burnbar",
                familyLines: ["codex exec --cd /Users/a/burnbar-old"]
            ),
            "A path prefix must not count as the same project"
        )
        XCTAssertFalse(
            ProcessReceiptCLIRuntimeProbe.familyIsOpen(
                family: .codex,
                projectPath: "/Users/a/burnbar",
                lines: ["codex exec --cd /Users/a/other-app"]
            )
        )
        XCTAssertTrue(
            ProcessReceiptCLIRuntimeProbe.familyIsOpen(
                family: .codex,
                projectPath: "/Users/a/burnbar",
                lines: ["codex exec --cd /Users/a/burnbar"]
            )
        )
    }

    @MainActor
    func test_receiptSettings_bannersAndFlyoutDefaultOn() {
        let suite = "ReceiptSettingsDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = ReceiptSettings(
            persistence: SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        )
        XCTAssertTrue(settings.receiptSystemNotificationsEnabled)
        XCTAssertTrue(settings.receiptFlyoutEnabled)
    }
}
