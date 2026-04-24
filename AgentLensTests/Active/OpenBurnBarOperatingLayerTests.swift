import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarOperatingLayerTests: XCTestCase {
    private var savedConversationIndexingEnabled = false
    private var savedConversationCloudBackupEnabled = false
    private var savedICloudSessionMirrorEnabled = false
    private var savedControllerTelegramEnabled = false
    private var savedControllerCalendarIntegrationEnabled = false
    private var savedControllerSimulatorToolsEnabled = false

    override func setUp() {
        super.setUp()
        let settings = SettingsManager.shared
        savedConversationIndexingEnabled = settings.conversationIndexingEnabled
        savedConversationCloudBackupEnabled = settings.conversationCloudBackupEnabled
        savedICloudSessionMirrorEnabled = settings.iCloudSessionMirrorEnabled
        savedControllerTelegramEnabled = settings.controllerTelegramEnabled
        savedControllerCalendarIntegrationEnabled = settings.controllerCalendarIntegrationEnabled
        savedControllerSimulatorToolsEnabled = settings.controllerSimulatorToolsEnabled
    }

    override func tearDown() {
        let settings = SettingsManager.shared
        settings.conversationIndexingEnabled = savedConversationIndexingEnabled
        settings.conversationCloudBackupEnabled = savedConversationCloudBackupEnabled
        settings.iCloudSessionMirrorEnabled = savedICloudSessionMirrorEnabled
        settings.controllerTelegramEnabled = savedControllerTelegramEnabled
        settings.controllerCalendarIntegrationEnabled = savedControllerCalendarIntegrationEnabled
        settings.controllerSimulatorToolsEnabled = savedControllerSimulatorToolsEnabled
        super.tearDown()
    }

    func testOperatingLayerBuildsMissionDirectionBurnFromIndexedProjectData() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        let snapshot = layer.snapshot

        XCTAssertEqual(snapshot.projectName, "Apollo")
        XCTAssertEqual(snapshot.mission.availability, .available)
        XCTAssertEqual(snapshot.direction.availability, .available)
        XCTAssertEqual(snapshot.burn.availability, .available)
        XCTAssertEqual(snapshot.evidence.availability, .available)
        XCTAssertEqual(snapshot.mission.title, "Ship the approval sheet")
        XCTAssertEqual(snapshot.direction.status, .drifting)
        XCTAssertEqual(snapshot.burn.estimatedCostUSD, 8.85, accuracy: 0.001)
        XCTAssertTrue(snapshot.availableActions.contains(where: { $0.kind == .missionApproval && $0.available }))
        XCTAssertTrue(snapshot.availableActions.contains(where: { $0.kind == .directionOverride && $0.available }))
        XCTAssertEqual(snapshot.controllerRuntime.pendingQuestions.count, 1)
        XCTAssertTrue(snapshot.controllerRuntime.openFollowups.count >= 1)
    }

    func testOperatingLayerRepresentsSparseDirectionWhenIndexingIsOff() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store, indexingEnabled: false)

        let snapshot = layer.snapshot

        XCTAssertEqual(snapshot.direction.availability, .sparse)
        XCTAssertEqual(snapshot.evidence.availability, .sparse)
        XCTAssertTrue(snapshot.freshness.provisional)
        XCTAssertEqual(snapshot.freshness.status, .provisional)
    }

    func testApproveMissionAndOverrideDirectionUpdateSharedState() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        layer.approveMission(note: "Ready to ship.")
        var snapshot = layer.snapshot

        XCTAssertEqual(snapshot.mission.approval, .approved)
        XCTAssertEqual(layer.actionFeedback?.kind, .missionApproval)
        XCTAssertEqual(layer.actionFeedback?.tone, .success)
        XCTAssertEqual(try store.countOperatingActionRecords(projectName: "Apollo"), 1)

        layer.saveDirectionOverride(
            mode: .supersedeStatus,
            forcedStatus: .drifting,
            summary: "Pause and reset the current plan.",
            rationale: "The last checkpoint ends with open questions and needs a firmer direction call."
        )
        snapshot = layer.snapshot

        XCTAssertEqual(snapshot.direction.mode, .overrideSuperseding)
        XCTAssertEqual(snapshot.direction.status, .drifting)
        XCTAssertEqual(snapshot.direction.summary, "Pause and reset the current plan.")
        XCTAssertEqual(layer.actionFeedback?.kind, .directionOverride)
        XCTAssertEqual(layer.actionFeedback?.tone, .success)
        XCTAssertEqual(try store.countOperatingActionRecords(projectName: "Apollo"), 2)
        XCTAssertEqual(snapshot.recentHistory.first?.kind, .directionOverride)
        XCTAssertEqual(snapshot.recentHistory.dropFirst().first?.kind, .missionApproval)
    }

    func testDashboardOperatingSectionRendersSharedSummary() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        let text = renderedText(
            OpenBurnBarDashboardOperatingSection(layer: layer),
            size: CGSize(width: 1180, height: 920)
        )
        let bodyDescription = String(reflecting: OpenBurnBarDashboardOperatingSection(layer: layer).body)
        let firstQuestion = layer.snapshot.controllerRuntime.pendingQuestions.first

        XCTAssertTrue(text.contains("Mission"))
        XCTAssertTrue(text.contains("Direction"))
        XCTAssertTrue(text.contains("Burn"))
        XCTAssertTrue(text.contains("Ship the approval sheet"))
        XCTAssertEqual(layer.snapshot.controllerRuntime.missions.first?.latestTakeoverState, .launched)
        XCTAssertEqual(layer.snapshot.controllerRuntime.missions.first?.takeoverCount, 1)
        XCTAssertEqual(firstQuestion?.stageLabel, "Operator Decision")
        XCTAssertEqual(firstQuestion?.suggestedOptions.first?.title, "Proceed")
        XCTAssertTrue(bodyDescription.contains("OpenBurnBarControllerWorkbenchPanel"))
    }

    func testCompactHomeCardRendersPendingHighlightsAndDashboardLink() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        let text = renderedText(
            OpenBurnBarCompactOperatingHomeCard(layer: layer, onOpenDashboard: {}),
            size: CGSize(width: 420, height: 520)
        )
        let bodyDescription = String(reflecting: OpenBurnBarCompactOperatingHomeCard(layer: layer, onOpenDashboard: {}).body)
        let snapshot = layer.snapshot

        XCTAssertEqual(snapshot.projectName, "Apollo")
        XCTAssertFalse((snapshot.pendingHighlight ?? "").isEmpty)
        XCTAssertTrue(bodyDescription.contains("GlassCard"))
        XCTAssertTrue(bodyDescription.contains("OpenBurnBarControllerCompactSummary"))
        XCTAssertTrue(bodyDescription.contains("OpenBurnBarOperatingActionBar"))
        XCTAssertEqual(snapshot.controllerRuntime.missions.first?.latestTakeoverState, .launched)
    }

    func testHermesOperatingStripRendersSameMissionAndDirectionState() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        let text = renderedText(
            OpenBurnBarHermesOperatingStrip(layer: layer),
            size: CGSize(width: 420, height: 320)
        )

        XCTAssertTrue(text.contains("Apollo"))
        XCTAssertTrue(text.contains("Ship the approval sheet"))
        XCTAssertTrue(text.contains("$8.85"))
        XCTAssertTrue(text.contains("Mission"))
        XCTAssertEqual(layer.snapshot.controllerRuntime.missions.first?.latestTakeoverState, .launched)
    }

    func testQuestionAnswerUpdatesControllerRuntimeMirror() async throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        let question = try XCTUnwrap(layer.snapshot.controllerRuntime.pendingQuestions.first)
        await layer.answerPendingQuestion(id: question.id, answer: "Yes. Keep Apollo aligned around the approval sheet.")
        let snapshot = layer.snapshot

        XCTAssertTrue(snapshot.controllerRuntime.pendingQuestions.isEmpty)
        XCTAssertTrue(snapshot.controllerRuntime.questions.contains(where: {
            $0.id == question.id && $0.state == .answered && $0.answer == "Yes. Keep Apollo aligned around the approval sheet."
        }))
    }

    func testSessionLogDetailPaneRendersPendingQuestionAnswerAffordance() throws {
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)
        let record = try XCTUnwrap(try store.fetchAllSessionLogs().first(where: { $0.sessionId == "apollo-2" }))

        let text = renderedText(
            SessionLogDetailPane(record: record, dataStore: store, operatingLayer: layer),
            size: CGSize(width: 960, height: 920)
        )

        XCTAssertTrue(text.contains("Pending Questions"))
        XCTAssertTrue(text.contains("Should Apollo keep the current approval sheet scope?"))
        XCTAssertTrue(text.contains("Operator Decision"))
        XCTAssertTrue(text.contains("Proceed"))
        XCTAssertTrue(text.contains("Open Apollo session log"))
        XCTAssertTrue(text.contains("Mission Runtime"))
        XCTAssertTrue(text.contains("Source run stalled in model_streaming for 21m."))
    }

    func testControllerRuntimeGuideExplainsTelegramCalendarAndReplay() {
        let settings = SettingsManager.shared
        settings.controllerTelegramEnabled = true
        settings.controllerCalendarIntegrationEnabled = true
        settings.controllerSimulatorToolsEnabled = true

        let card = OpenBurnBarControllerRuntimeGuideCard(
            settingsManager: settings,
            daemonManager: OpenBurnBarDaemonManager.shared
        )
        let bodyDescription = String(reflecting: card.body)

        XCTAssertTrue(bodyDescription.contains("GlassCard"))
        XCTAssertTrue(settings.controllerTelegramEnabled)
        XCTAssertTrue(settings.controllerCalendarIntegrationEnabled)
        XCTAssertTrue(settings.controllerSimulatorToolsEnabled)
    }

    func testSetupGuideExplainsLocalAndOptionalCloudModes() {
        let guide = OpenBurnBarSetupGuideBuilder.build(
            detection: [.factory: true, .codex: true],
            indexingEnabled: false,
            isSignedIn: false,
            conversationCloudEnabled: false,
            iCloudMirrorEnabled: false,
            hermesAvailable: true,
            openClawAvailable: false
        )

        XCTAssertEqual(guide.localTitle, "Local by default")
        XCTAssertEqual(guide.cloudTitle, "Cloud is optional")
        XCTAssertTrue(guide.runtimeDetail.contains("2 provider source"))
        XCTAssertTrue(guide.providerHealthDetail.contains("Hermes reachable"))
        XCTAssertTrue(guide.providerHealthDetail.contains("OpenClaw offline"))

        let text = renderedText(
            OpenBurnBarOperatingModelGuideCard(guide: guide),
            size: CGSize(width: 760, height: 420)
        )

        XCTAssertTrue(text.contains("OpenBurnBarOperatingModelGuideCard"))
        XCTAssertTrue(text.contains("GlassCard"))
    }

    private func makeLayer(
        dataStore: DataStore,
        indexingEnabled: Bool = true
    ) -> OpenBurnBarOperatingLayer {
        SettingsManager.shared.conversationIndexingEnabled = indexingEnabled
        SettingsManager.shared.conversationCloudBackupEnabled = false
        SettingsManager.shared.iCloudSessionMirrorEnabled = false
        let controller = ChatSessionController(dataStore: dataStore, settingsManager: .shared)
        return OpenBurnBarOperatingLayer(
            dataStore: dataStore,
            settingsManager: .shared,
            accountManager: .shared,
            chatController: controller
        )
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func seedApolloScenario(into store: DataStore) {
        let now = Date(timeIntervalSince1970: 1_773_114_400)
        let earlier = now.addingTimeInterval(-3_600)

        store.replaceUsages([
            TokenUsage(
                provider: .factory,
                sessionId: "apollo-1",
                projectName: "Apollo",
                model: "gpt-5",
                inputTokens: 18_000,
                outputTokens: 6_000,
                costUSD: 5.20,
                startTime: earlier,
                endTime: earlier.addingTimeInterval(1_200)
            ),
            TokenUsage(
                provider: .codex,
                sessionId: "apollo-2",
                projectName: "Apollo",
                model: "gpt-5-mini",
                inputTokens: 9_500,
                outputTokens: 4_200,
                costUSD: 3.65,
                startTime: now.addingTimeInterval(-1_200),
                endTime: now
            )
        ])

        try? store.upsertConversation(
            ConversationRecord(
                id: "Factory:apollo-1",
                provider: .factory,
                sessionId: "apollo-1",
                projectName: "Apollo",
                startTime: earlier,
                endTime: earlier.addingTimeInterval(1_200),
                messageCount: 18,
                userWordCount: 80,
                assistantWordCount: 210,
                keyFiles: ["/tmp/DashboardView.swift"],
                keyCommands: ["swift test"],
                keyTools: ["Read", "Edit"],
                inferredTaskTitle: "Approval strip experiment",
                lastAssistantMessage: "The dashboard overview now carries the mission strip and the evidence preview for Apollo.",
                fullText: "Approval strip experiment\nDashboard overview now carries the mission strip and the evidence preview for Apollo.",
                indexedAt: earlier.addingTimeInterval(1_500),
                fileModifiedAt: earlier.addingTimeInterval(1_500),
                summary: "OpenBurnBar grounded Apollo in the dashboard and evidence preview without losing the existing layout.",
                summaryTitle: "Ground dashboard state",
                summaryUpdatedAt: earlier.addingTimeInterval(1_520),
                summaryProvider: "openrouter",
                summaryModel: "gpt-5-mini"
            )
        )

        try? store.upsertConversation(
            ConversationRecord(
                id: "Codex:apollo-2",
                provider: .codex,
                sessionId: "apollo-2",
                projectName: "Apollo",
                startTime: now.addingTimeInterval(-1_200),
                endTime: now,
                messageCount: 22,
                userWordCount: 110,
                assistantWordCount: 260,
                keyFiles: ["/tmp/MenuBarPopoverView.swift", "/tmp/HermesPopoverChatView.swift"],
                keyCommands: ["xcodebuild test"],
                keyTools: ["Read", "Edit", "Bash"],
                inferredTaskTitle: "Ship the approval sheet",
                lastAssistantMessage: "The shared operating layer looks aligned across dashboard, popover, and Hermes. Should Apollo keep the current approval sheet scope?",
                fullText: "Ship the approval sheet\nThe shared operating layer looks aligned across dashboard, popover, and Hermes. Should Apollo keep the current approval sheet scope?",
                indexedAt: now,
                fileModifiedAt: now,
                summary: "Mission, direction, burn, freshness, and evidence now all read from one native operating layer for Apollo.",
                summaryTitle: "Ship the approval sheet",
                summaryUpdatedAt: now.addingTimeInterval(30),
                summaryProvider: "openrouter",
                summaryModel: "gpt-5"
            )
        )

        try? store.saveControllerRuntimeMirror(
            OpenBurnBarControllerRuntimeSnapshot(
                source: .daemon,
                updatedAt: now,
                summary: OpenBurnBarControllerSummary(
                    headline: "1 pending question and 1 followup need attention.",
                    detail: "Daemon-backed controller summary. Fresh local signal.",
                    pendingQuestions: 1,
                    unresolvedFollowups: 1,
                    openMissions: 1,
                    replayLabel: "Replay idle",
                    notificationLabel: "Local notifications armed"
                ),
                questions: [
                    OpenBurnBarControllerQuestion(
                        id: "question-apollo",
                        projectName: "Apollo",
                        sessionID: "apollo-2",
                        title: "Scope the approval sheet",
                        prompt: "Should Apollo keep the current approval sheet scope?",
                        stageLabel: "Operator Decision",
                        evidenceHint: "Ship the approval sheet",
                        state: .pending,
                        priority: .high,
                        sourceLabel: "Daemon controller runtime",
                        createdAt: now,
                        answerPlaceholder: "Record the operator call OpenBurnBar should carry forward…",
                        suggestedOptions: [
                            OpenBurnBarControllerQuestionOption(
                                id: "proceed",
                                title: "Proceed",
                                detail: "Keep the current scope.",
                                answer: "Proceed with the current approval sheet scope."
                            ),
                            OpenBurnBarControllerQuestionOption(
                                id: "reset",
                                title: "Reset",
                                detail: "Change direction before shipping.",
                                answer: "Reset the scope before shipping."
                            )
                        ],
                        deepLink: OpenBurnBarControllerQuestionDeepLink(
                            kind: .sessionLog,
                            targetID: "apollo-2",
                            title: "Open Apollo session log",
                            subtitle: "Ship the approval sheet"
                        ),
                        isUnread: true,
                        notificationCount: 1
                    )
                ],
                followups: [
                    OpenBurnBarControllerFollowup(
                        id: "followup-apollo",
                        projectName: "Apollo",
                        title: "Review the approval sheet",
                        summary: "Confirm whether Apollo should keep the current scope.",
                        stageLabel: "Operator Decision",
                        state: .open,
                        kind: .pendingQuestion,
                        linkedQuestionID: "question-apollo",
                        deepLink: OpenBurnBarControllerQuestionDeepLink(
                            kind: .sessionLog,
                            targetID: "apollo-2",
                            title: "Open Apollo session log",
                            subtitle: nil
                        ),
                        createdAt: now,
                        updatedAt: now,
                        dueAt: now.addingTimeInterval(3_600)
                    )
                ],
                missions: [
                    OpenBurnBarControllerMissionRecord(
                        id: "mission-apollo",
                        projectName: "Apollo",
                        title: "Ship the approval sheet",
                        summary: "Keep Apollo aligned around the approval sheet.",
                        state: .running,
                        approval: .pending,
                        packetSummary: "review-worker: inspect rollout evidence",
                        latestResultSummary: "Direction still looks aligned.",
                        latestResultDetail: "Worker completed the review packet and found no blocking drift.",
                        latestResultRunID: "run-apollo-primary",
                        activeWorkerName: "auto-takeover",
                        activeRunID: "run-apollo-takeover",
                        packetRunCount: 2,
                        latestTakeoverState: .launched,
                        latestTakeoverReason: "Source run stalled in model_streaming for 21m.",
                        latestTakeoverRunID: "run-apollo-takeover",
                        takeoverCount: 1,
                        burnCostUSD: 8.85,
                        burnTokens: 37_700,
                        updatedAt: now
                    )
                ],
                recentEvents: [
                    OpenBurnBarControllerEvent(
                        id: "event-question",
                        projectName: "Apollo",
                        category: .question,
                        title: "Question created",
                        summary: "Scope the approval sheet",
                        detail: "Should Apollo keep the current approval sheet scope?",
                        createdAt: now
                    )
                ]
            )
        )
    }

    private func renderedText<V: View>(_ view: V, size: CGSize) -> String {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = NSHostingController(rootView: view)
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        var texts = viewText(controller.view) + accessibilityText(controller.view)
        texts.append(String(reflecting: view.body))
        let subtreeSelector = NSSelectorFromString("_subtreeDescription")
        if controller.view.responds(to: subtreeSelector),
           let descriptionObject = controller.view.perform(subtreeSelector)?.takeUnretainedValue() as? String {
            texts.append(descriptionObject)
        }
        return Array(Set(texts)).joined(separator: "\n")
    }

    private func viewText(_ view: NSView) -> [String] {
        var values: [String] = []

        if let textField = view as? NSTextField {
            let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty == false {
                values.append(text)
            }
        }

        if let button = view as? NSButton {
            let title = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty == false {
                values.append(title)
            }
        }

        for child in view.subviews {
            values.append(contentsOf: viewText(child))
        }
        return values
    }

    private func accessibilityText(_ view: NSView) -> [String] {
        var values: [String] = []

        if let label = view.accessibilityLabel()?.trimmingCharacters(in: .whitespacesAndNewlines),
           label.isEmpty == false {
            values.append(label)
        }

        if let value = view.accessibilityValue() as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                values.append(trimmed)
            }
        }

        for child in view.subviews {
            values.append(contentsOf: accessibilityText(child))
        }
        return values
    }
}
