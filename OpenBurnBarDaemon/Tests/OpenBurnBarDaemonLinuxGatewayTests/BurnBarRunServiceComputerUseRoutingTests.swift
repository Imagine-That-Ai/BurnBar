import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

private actor BrowserInvocationRecorder {
    private(set) var invocations: [BurnBarToolInvocation] = []

    func record(_ invocation: BurnBarToolInvocation) {
        invocations.append(invocation)
    }
}

final class BurnBarRunServiceComputerUseRoutingTests: XCTestCase {
    func testComputerUseDispatcherOwnsBrowserExecutionAndPreservesToolOutput() async throws {
        let recorder = BrowserInvocationRecorder()
        let service = try makeRunService { invocation in
            await recorder.record(invocation)
            return ComputerUseInvokeResponse(
                sessionId: "cu-session",
                callID: invocation.callID,
                status: .executed,
                auditEntryIndex: 3,
                auditHeadHashHex: String(repeating: "a", count: 64),
                result: BurnBarToolResult(
                    callID: invocation.callID,
                    runID: invocation.runID,
                    succeeded: true,
                    output: .object(["text": .string("coordinator result")]),
                    completedAt: Date()
                )
            )
        }
        let invocation = browserInvocation()

        let outcome = await service.executeBrowserAction(invocation)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.output, .object(["text": .string("coordinator result")]))
        let recordedInvocations = await recorder.invocations
        XCTAssertEqual(recordedInvocations, [invocation])
    }

    func testComputerUseDenialBecomesTerminalOperatorDeniedFailure() async throws {
        let service = try makeRunService { invocation in
            ComputerUseInvokeResponse(
                sessionId: "cu-session",
                callID: invocation.callID,
                status: .denied,
                denyReason: "user_rejected"
            )
        }

        let outcome = await service.executeBrowserAction(browserInvocation())

        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.output)
        XCTAssertEqual(outcome.error?.code, .operatorDenied)
        XCTAssertEqual(outcome.error?.message, "user_rejected")
    }

    func testComputerUsePolicyDenialIsNotAttributedToOperator() async throws {
        let service = try makeRunService { invocation in
            ComputerUseInvokeResponse(
                sessionId: "cu-session",
                callID: invocation.callID,
                status: .denied,
                denyReason: ComputerUseDenyReason.scopeDenied.rawValue
            )
        }

        let outcome = await service.executeBrowserAction(browserInvocation())

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.error?.code, .computerUseDenied)
        XCTAssertEqual(outcome.error?.message, ComputerUseDenyReason.scopeDenied.rawValue)
    }

    func testExecutedComputerUseResponseRequiresToolResult() async throws {
        let service = try makeRunService { invocation in
            ComputerUseInvokeResponse(
                sessionId: "cu-session",
                callID: invocation.callID,
                status: .executed
            )
        }

        let outcome = await service.executeBrowserAction(browserInvocation())

        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.output)
        XCTAssertEqual(
            outcome.error?.message,
            "Computer Use reported an executed browser action without a tool result."
        )
    }

    func testExecutedComputerUseResponseRequiresMatchingRunAndCallIdentity() async throws {
        let service = try makeRunService { invocation in
            ComputerUseInvokeResponse(
                sessionId: "cu-session",
                callID: invocation.callID,
                status: .executed,
                result: BurnBarToolResult(
                    callID: "different-call",
                    runID: BurnBarRunID(rawValue: "different-run"),
                    succeeded: true,
                    output: .string("must not escape"),
                    completedAt: Date()
                )
            )
        }

        let outcome = await service.executeBrowserAction(browserInvocation())

        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.output)
        XCTAssertEqual(
            outcome.error?.message,
            "Computer Use returned a browser result for a different run or tool call."
        )
    }

    func testComputerUseDispatcherErrorFailsClosedWithoutLegacyPlaywrightFallback() async throws {
        let service = try makeRunService { invocation in
            throw ComputerUseService.ServiceError.runNotBound(invocation.runID.rawValue)
        }

        let outcome = await service.executeBrowserAction(browserInvocation())

        XCTAssertFalse(outcome.succeeded)
        XCTAssertNil(outcome.output)
        XCTAssertEqual(outcome.error?.code, .unknown)
        XCTAssertEqual(
            outcome.error?.message,
            "Start Browser Computer Use for agent run run-1 before allowing browser actions."
        )
    }

    #if os(Linux)
    func testDefaultLinuxServerInstallsComputerUseBrowserDispatcher() async throws {
        let server = BurnBarDaemonServer()
        let dispatcher = await server.runService.computerUseBrowserDispatcher
        XCTAssertNotNil(dispatcher)
    }
    #endif

    private func makeRunService(
        dispatcher: @escaping @Sendable (BurnBarToolInvocation) async throws -> ComputerUseInvokeResponse
    ) throws -> BurnBarRunService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-run-cu-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configStore = BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "run-cu-routing-tests")
        )
        return BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "run-cu-routing-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: root.appendingPathComponent("usage.jsonl"),
                logger: BurnBarDaemonLogger(category: "run-cu-routing-tests")
            ),
            clientRegistry: BurnBarClientRegistry(
                logger: BurnBarDaemonLogger(category: "run-cu-routing-tests")
            ),
            computerUseBrowserDispatcher: { invocation in
                BurnBarComputerUseBrowserDispatchResult(
                    expectedSessionID: ComputerUseSessionID("cu-session"),
                    response: try await dispatcher(invocation)
                )
            },
            logger: BurnBarDaemonLogger(category: "run-cu-routing-tests")
        )
    }

    private func browserInvocation() -> BurnBarToolInvocation {
        BurnBarToolInvocation(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .browserExtract,
            arguments: .object(["selector": .string("main")]),
            requestedBy: BurnBarClientID(rawValue: "linux-shell"),
            requestedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }
}
