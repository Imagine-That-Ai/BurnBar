import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarDaemonRPCValidationTests: XCTestCase {
    private let clientID = BurnBarClientID(rawValue: "client-1")
    private let sessionID = BurnBarSessionID(rawValue: "session-1")
    private let runID = BurnBarRunID(rawValue: "run-1")
    private let approvalID = BurnBarApprovalID(rawValue: "approval-1")

    func testClientAttachValidationRejectsUntrustedProtocolAndIdentifierInputs() async throws {
        let server = makeServer()

        try await server.validateClientAttachRequest(
            BurnBarClientAttachRequest(
                clientID: clientID,
                sessionID: sessionID,
                clientName: "Cursor",
                supportedProtocolVersions: BurnBarProtocolVersion.supported
            )
        )

        await assertInvalidParams("clientID") {
            try await server.validateClientAttachRequest(
                BurnBarClientAttachRequest(
                    clientID: BurnBarClientID(rawValue: ""),
                    sessionID: sessionID,
                    clientName: "Cursor",
                    supportedProtocolVersions: BurnBarProtocolVersion.supported
                )
            )
        }

        await assertInvalidParams("clientName") {
            try await server.validateClientAttachRequest(
                BurnBarClientAttachRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    clientName: String(repeating: "x", count: 201),
                    supportedProtocolVersions: BurnBarProtocolVersion.supported
                )
            )
        }

        await assertInvalidParams("supportedProtocolVersions") {
            try await server.validateClientAttachRequest(
                BurnBarClientAttachRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    clientName: "Cursor",
                    supportedProtocolVersions: Array(repeating: BurnBarProtocolVersion.current, count: 17)
                )
            )
        }
    }

    func testRunValidationRejectsOversizedPromptsMetadataAndPagination() async throws {
        let server = makeServer()

        try await server.validateRunCreateRequest(
            BurnBarRunCreateRequest(
                clientID: clientID,
                sessionID: sessionID,
                prompt: "ship the patch",
                modelID: "glm-5"
            )
        )

        await assertInvalidParams("prompt") {
            try await server.validateRunCreateRequest(
                BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: String(repeating: "x", count: (48 * 1024) + 1),
                    modelID: "glm-5"
                )
            )
        }

        await assertInvalidParams("metadata") {
            try await server.validateRunCreateRequest(
                BurnBarRunCreateRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    prompt: "ship the patch",
                    modelID: "glm-5",
                    metadata: ["nested": nestedJSON(depth: 9)]
                )
            )
        }

        await assertInvalidParams("limit") {
            try await server.validateRunListRequest(BurnBarRunListRequest(clientID: clientID, limit: 201))
        }

        await assertInvalidParams("offset") {
            try await server.validateRunListRequest(BurnBarRunListRequest(clientID: clientID, offset: 10_001))
        }
    }

    func testToolResultValidationRejectsReplayAndResourceExhaustionPayloads() async throws {
        let server = makeServer()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await server.validateToolResultSubmissionRequest(
            BurnBarToolResultSubmissionRequest(
                clientID: clientID,
                sessionID: sessionID,
                runID: runID,
                callID: "call-1",
                succeeded: true,
                output: .object(["ok": .bool(true)]),
                error: nil,
                completedAt: now
            ),
            now: now
        )

        await assertInvalidParams("completedAt") {
            try await server.validateToolResultSubmissionRequest(
                toolResult(completedAt: now.addingTimeInterval(301)),
                now: now
            )
        }

        await assertInvalidParams("completedAt") {
            try await server.validateToolResultSubmissionRequest(
                toolResult(completedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1)),
                now: now
            )
        }

        await assertInvalidParams("output") {
            try await server.validateToolResultSubmissionRequest(
                toolResult(output: .string(String(repeating: "x", count: (32 * 1024) + 1)), completedAt: now),
                now: now
            )
        }

        await assertInvalidParams("output") {
            try await server.validateToolResultSubmissionRequest(
                toolResult(output: nestedJSON(depth: 17), completedAt: now),
                now: now
            )
        }

        await assertInvalidParams("output") {
            try await server.validateToolResultSubmissionRequest(
                toolResult(output: .array(Array(repeating: .string("x"), count: 201)), completedAt: now),
                now: now
            )
        }

        await assertInvalidParams("error.message") {
            try await server.validateToolResultSubmissionRequest(
                toolResult(
                    output: nil,
                    error: BurnBarToolExecutionError(code: .applyFailed, message: String(repeating: "x", count: 4_097)),
                    completedAt: now
                ),
                now: now
            )
        }
    }

    func testApprovalValidationRejectsReplayAndOversizedNotes() async throws {
        let server = makeServer()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await server.validateApprovalRespondRequest(
            approvalResponse(note: "looks good", respondedAt: now),
            now: now
        )

        await assertInvalidParams("respondedAt") {
            try await server.validateApprovalRespondRequest(
                approvalResponse(respondedAt: now.addingTimeInterval(301)),
                now: now
            )
        }

        await assertInvalidParams("respondedAt") {
            try await server.validateApprovalRespondRequest(
                approvalResponse(respondedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1)),
                now: now
            )
        }

        await assertInvalidParams("note") {
            try await server.validateApprovalRespondRequest(
                approvalResponse(note: String(repeating: "x", count: 4_097), respondedAt: now),
                now: now
            )
        }
    }

    private func makeServer() -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("openburnbar-rpc-validation-\(UUID().uuidString).sock")
                    .path,
                socketAuthToken: "test-token"
            )
        )
    }

    private func toolResult(
        output: BurnBarJSONValue? = .object(["ok": .bool(true)]),
        error: BurnBarToolExecutionError? = nil,
        completedAt: Date
    ) -> BurnBarToolResultSubmissionRequest {
        BurnBarToolResultSubmissionRequest(
            clientID: clientID,
            sessionID: sessionID,
            runID: runID,
            callID: "call-1",
            succeeded: error == nil,
            output: output,
            error: error,
            completedAt: completedAt
        )
    }

    private func approvalResponse(note: String? = nil, respondedAt: Date) -> BurnBarApprovalRespondRequest {
        BurnBarApprovalRespondRequest(
            response: BurnBarApprovalResponse(
                approvalID: approvalID,
                clientID: clientID,
                decision: .approve,
                note: note,
                respondedAt: respondedAt
            )
        )
    }

    private func nestedJSON(depth: Int) -> BurnBarJSONValue {
        var value: BurnBarJSONValue = .string("leaf")
        for index in 0..<depth {
            value = .object(["level\(index)": value])
        }
        return value
    }

    private func assertInvalidParams(
        _ expectedMessageFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected BurnBarRPCValidationError.invalidParams.", file: file, line: line)
        } catch BurnBarRPCValidationError.invalidParams(let message) {
            XCTAssertTrue(
                message.contains(expectedMessageFragment),
                "Expected '\(message)' to contain '\(expectedMessageFragment)'.",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected invalidParams, got \(error).", file: file, line: line)
        }
    }
}
