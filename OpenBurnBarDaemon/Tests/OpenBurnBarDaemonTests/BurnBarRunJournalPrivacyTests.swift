import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarRunJournalPrivacyTests: XCTestCase {
    func testAppendRedactsSensitiveEventPayloadBeforePersistence() async throws {
        let secret = "dummy-event-secret-value"
        let bearer = "Bearer dummy-event-token-1234567890"
        let (journal, rootURL) = try makeJournal(name: "event-redaction")
        let runID = BurnBarRunID(rawValue: "run-event-redaction")

        try await journal.append(
            BurnBarRunJournalEvent(
                runID: runID,
                kind: .toolDispatched,
                phase: .executingTool,
                payload: .object([
                    "apiKey": .string(secret),
                    "message": .string("Authorization: \(bearer)"),
                    "nested": .object([
                        "client_secret": .string(secret),
                        "tokenUsage": .object([
                            "promptTokens": .number(3)
                        ])
                    ]),
                    "usage": .object([
                        "input_tokens": .number(42),
                        "output_tokens": .number(7)
                    ])
                ]),
                emittedAt: Date()
            )
        )

        let journalURL = rootURL.appendingPathComponent("run-journal.jsonl")
        try assertFile(at: journalURL, doesNotContain: secret)
        try assertFile(at: journalURL, doesNotContain: bearer)

        let events = try await journal.events(for: runID)
        let payload = try XCTUnwrap(events.first?.payload?.objectValue())
        XCTAssertEqual(payload["apiKey"], .string("[REDACTED]"))
        XCTAssertEqual(payload["nested"]?.objectValue()?["client_secret"], .string("[REDACTED]"))
        XCTAssertEqual(payload["nested"]?.objectValue()?["tokenUsage"]?.objectValue()?["promptTokens"], .number(3))
        XCTAssertEqual(payload["usage"]?.objectValue()?["input_tokens"], .number(42))
        XCTAssertEqual(payload["usage"]?.objectValue()?["output_tokens"], .number(7))
        XCTAssertFalse(payload["message"]?.stringValue()?.contains(bearer) ?? true)
    }

    func testCheckpointRedactsSensitivePromptMetadataAndToolStateBeforePersistence() async throws {
        let promptSecret = "api_key=dummy-checkpoint-secret"
        let toolSecret = "dummy-tool-secret-value"
        let fileSecret = "password=dummy-file-secret"
        let (journal, rootURL) = try makeJournal(name: "checkpoint-redaction")
        let runID = BurnBarRunID(rawValue: "run-checkpoint-redaction")
        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "Inspect without persisting \(promptSecret)",
            summary: "Check journal privacy",
            requestedTools: [.runTerminal],
            toolArguments: .object(["token": .string(toolSecret)])
        )
        let planOutline = BurnBarPlanOutline(
            objective: "Run command with \(promptSecret)",
            steps: [
                BurnBarPlanStep(title: "Inspect", detail: "Use \(promptSecret)")
            ]
        )
        let invocation = BurnBarToolInvocation(
            callID: "call-redaction",
            runID: runID,
            tool: .runTerminal,
            arguments: .object([
                "command": .string("printenv"),
                "access_token": .string(toolSecret)
            ]),
            requestedBy: BurnBarClientID(rawValue: "client-redaction"),
            requestedAt: requestedAt
        )
        let lastToolCall = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: runID,
            tool: .runTerminal,
            arguments: invocation.arguments,
            status: .completed,
            requestedBy: invocation.requestedBy,
            requestedAt: requestedAt,
            output: .object([
                "content": .string(fileSecret),
                "input_tokens": .number(9)
            ])
        )

        try await journal.writeCheckpoint(
            BurnBarRunJournalCheckpoint(
                runID: runID,
                clientID: invocation.requestedBy,
                sessionID: BurnBarSessionID(rawValue: "session-redaction"),
                phase: .planning,
                modelID: "glm-5",
                originalPrompt: "Please use \(promptSecret)",
                metadata: BurnBarRunCreateMetadata([
                    "apiKey": .string(toolSecret),
                    "openAIAPIKey": .string(toolSecret),
                    "inputTokens": .number(42),
                    "path": .string("/tmp/openburnbar")
                ]),
                intent: intent,
                planOutline: planOutline,
                attempt: 1,
                errorMessage: "Failed with \(promptSecret)",
                approvalRequest: BurnBarApprovalRequest(
                    approvalID: BurnBarApprovalID(rawValue: "approval-redaction"),
                    runID: runID,
                    tool: .runTerminal,
                    title: "Approve command",
                    message: "Command includes \(promptSecret)",
                    requestedAt: requestedAt
                ),
                approvalResolvedForAttempt: false,
                activeApprovalID: BurnBarApprovalID(rawValue: "approval-redaction"),
                pendingApprovalToolInvocation: invocation,
                lastToolCall: lastToolCall,
                lastToolCallID: lastToolCall.callID,
                workflowStep: 1,
                workflowReadContent: "Read file with \(fileSecret)",
                companionToolCompleted: false,
                lastRecoveryDecision: BurnBarRecoveryDecision(
                    action: .requestApproval,
                    reason: "Secret-shaped error \(promptSecret)",
                    userMessage: "Approval required"
                ),
                updatedAt: requestedAt
            )
        )

        let checkpointURL = rootURL
            .appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent("\(runID.rawValue).json")
        for secret in [promptSecret, toolSecret, fileSecret] {
            try assertFile(at: checkpointURL, doesNotContain: secret)
        }

        let loadedCheckpoint = try await journal.checkpoint(for: runID)
        let checkpoint = try XCTUnwrap(loadedCheckpoint)
        XCTAssertEqual(checkpoint.metadata.storage["apiKey"], .string("[REDACTED]"))
        XCTAssertEqual(checkpoint.metadata.storage["openAIAPIKey"], .string("[REDACTED]"))
        XCTAssertEqual(checkpoint.metadata.storage["inputTokens"], .number(42))
        XCTAssertEqual(checkpoint.metadata.storage["path"], .string("/tmp/openburnbar"))
        XCTAssertFalse(checkpoint.originalPrompt.contains(promptSecret))
        XCTAssertFalse(checkpoint.intent.objective.contains(promptSecret))
        XCTAssertFalse(checkpoint.planOutline.objective.contains(promptSecret))
        XCTAssertEqual(checkpoint.pendingApprovalToolInvocation?.arguments.objectValue()?["access_token"], .string("[REDACTED]"))
        XCTAssertEqual(checkpoint.lastToolCall?.output?.objectValue()?["input_tokens"], .number(9))
        XCTAssertFalse(checkpoint.workflowReadContent?.contains(fileSecret) ?? true)
    }

    private func makeJournal(name: String) throws -> (journal: BurnBarRunJournal, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-run-journal-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return (
            BurnBarRunJournal(
                fileURL: rootURL.appendingPathComponent("run-journal.jsonl"),
                checkpointsDirectoryURL: rootURL.appendingPathComponent("checkpoints", isDirectory: true),
                logger: BurnBarDaemonLogger(category: "run-journal-privacy-tests")
            ),
            rootURL
        )
    }

    private func assertFile(
        at url: URL,
        doesNotContain forbiddenText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            content.contains(forbiddenText),
            "\(url.lastPathComponent) should not persist sensitive run-journal material",
            file: file,
            line: line
        )
    }
}
