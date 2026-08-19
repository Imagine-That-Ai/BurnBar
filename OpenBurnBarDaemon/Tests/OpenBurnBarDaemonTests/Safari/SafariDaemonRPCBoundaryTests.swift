import Darwin
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class SafariDaemonRPCBoundaryTests: XCTestCase {
    func testSafariBootstrapCapabilityRequiresTheExactAttachedSession()
        async throws {
        let socketPath = socketPath(name: "bootstrap-attribution")
        let gateway = BurnBarGatewayConfiguration(
            isEnabled: true,
            host: "127.0.0.1",
            port: 8317,
            authToken: "gateway-attribution-test-token"
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: Self.authToken,
                daemonVersion: "safari-rpc-boundary-tests",
                gateway: gateway,
                startsMissionControlBackgroundLoops: false
            )
        )

        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        let unattached: BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(id: "bootstrap-unattached"),
                socketPath: socketPath
            )
        XCTAssertNil(unattached.error)
        XCTAssertEqual(unattached.result?.gatewayAvailable, true)
        XCTAssertEqual(
            unattached.result?.gatewayBearerToken,
            "gateway-attribution-test-token"
        )

        let attached = try attachSafariSession(
            to: socketPath,
            extensionInstanceID: "bootstrap-attribution-extension",
            page: pageState()
        )
        let attachedBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-attached",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        XCTAssertNil(attachedBootstrap.error)
        // The bootstrap wire shape is pinned to what `extensions/safari/dist`
        // validates today: its parser rejects unknown keys, so the daemon must
        // not emit gateway attribution fields until that dist ships support.
        XCTAssertEqual(attachedBootstrap.result?.gatewayAvailable, true)
        XCTAssertEqual(
            attachedBootstrap.result?.gatewayBearerToken,
            "gateway-attribution-test-token"
        )

        let detached: BurnBarRPCResponseEnvelope<BurnBarSafariCommandCompletionResponse> =
            try sendEnvelope(
                detachEnvelope(
                    id: "bootstrap-detach",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        XCTAssertNil(detached.error)
        XCTAssertEqual(detached.result?.accepted, true)

        let detachedBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-detached",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        assertRPCError(
            detachedBootstrap,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "detached or has been replaced"
        )

        let replacement = try attachSafariSession(
            to: socketPath,
            extensionInstanceID: "bootstrap-attribution-extension",
            page: pageState(url: "https://example.com/replacement")
        )
        XCTAssertNotEqual(replacement.sessionId, attached.sessionId)

        let replacedBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-replaced",
                    sessionID: attached.sessionId
                ),
                socketPath: socketPath
            )
        assertRPCError(
            replacedBootstrap,
            code: BurnBarRPCErrorCode.unauthorized,
            contains: "detached or has been replaced"
        )

        let replacementBootstrap:
            BurnBarRPCResponseEnvelope<BurnBarSafariBootstrapResponse> =
            try sendEnvelope(
                bootstrapEnvelope(
                    id: "bootstrap-replacement",
                    sessionID: replacement.sessionId
                ),
                socketPath: socketPath
            )
        XCTAssertNil(replacementBootstrap.error)
        XCTAssertEqual(replacementBootstrap.result?.gatewayAvailable, true)
    }

    func testSafariPayloadResolutionPreservesLegacyRequestsWithoutParams()
        async throws {
        let socketPath = socketPath(name: "legacy-no-params")
        let server = BurnBarDaemonServer(
            configuration: configuration(socketPath: socketPath)
        )

        try await server.start()
        addTeardownBlock {
            await server.stop()
        }

        let health: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelope(
                    id: "legacy-health",
                    method: .health,
                    authToken: Self.authToken
                ),
                socketPath: socketPath
            )

        XCTAssertNil(health.error)
        XCTAssertEqual(health.result?.ok, true)
        XCTAssertEqual(
            health.result?.protocolVersion,
            BurnBarProtocolVersion.current
        )
    }



    func testInvalidOpenTabCompletionErrorMapsToInvalidParams() async throws {
        let server = BurnBarDaemonServer(
            configuration: configuration(
                socketPath: socketPath(name: "invalid-open-tab-error")
            )
        )
        let data = await server.safariRPCErrorResponse(
            id: "invalid-open-tab-error",
            error: BurnBarSafariSessionBroker.BrokerError.invalidOpenTabResult
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarSafariCommandCompletionResponse>.self,
            from: data
        )

        assertRPCError(
            response,
            code: BurnBarRPCErrorCode.invalidParams,
            contains: "unambiguous newly opened tab"
        )
    }

    private static let authToken = "safari-rpc-boundary-token"
    private static let minimumJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])


    private func activeCapabilityStateStore(
        at root: URL
    ) async throws -> ComputerUseCapabilityStateStore {
        let now = Date()
        let store = ComputerUseCapabilityStateStore(
            fileURL: root.appendingPathComponent("capability-state.json"),
            now: { now }
        )
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: now,
            updatedAt: now
        )
        _ = try await store.update(
            ComputerUseCapabilityStateSnapshot(
                publisherInstanceID: "safari-rpc-boundary-tests",
                revision: 1,
                generatedAt: now,
                userID: "safari-rpc-test-user",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: ComputerUseEntitlementSnapshot.hostedProductID,
                    expireAt: now.addingTimeInterval(3_600),
                    allowsBrowser: true,
                    allowsSystem: true,
                    allowsPhoneControl: true,
                    allowsTrustedScopes: true,
                    allowsAuditExport: true
                ),
                entitlementProvenance: provenance,
                budgetEnvelope: ComputerUseBudgetEnvelope(
                    level: .normal,
                    projectedMonthEndUSD: 0,
                    monthToDateUSD: 0,
                    activeActionsPerRun: 50,
                    activeActionsPerDay: 200,
                    activeSessionsPerDay: 4,
                    perUserDailySpendCeilingUSD: 5,
                    updatedAt: now
                ),
                budgetProvenance: provenance,
                quotaUsage: ComputerUseQuotaUsage(
                    dayKey: String(
                        ISO8601DateFormatter().string(from: now).prefix(10)
                    ),
                    updatedAt: now
                ),
                quotaProvenance: provenance,
                concurrentSessionActive: false,
                killSwitch: false,
                isComplete: true
            )
        )
        return store
    }

    private func waitForPendingApproval(
        safariSessionID: String,
        runID: BurnBarRunID,
        service: ComputerUseService,
        runService: BurnBarRunService
    ) async throws -> PendingSafariApproval {
        for _ in 0..<500 {
            if let computerUseSessionID = await service.computerUseSessionID(
                forSafariSessionID: safariSessionID
            ) {
                let pending = await service.pendingApprovals(
                    ComputerUseApprovalPendingRequest(
                        sessionId: computerUseSessionID.rawValue
                    )
                )
                if let approval = pending.requests.first {
                    return PendingSafariApproval(
                        computerUseSessionID: computerUseSessionID,
                        approval: approval
                    )
                }
            }
            if let snapshot = await runService.snapshot(for: runID),
               [.completed, .failed, .cancelled].contains(snapshot.phase) {
                throw SafariRPCBoundaryTestError.approvalUnavailable(
                    "run \(runID.rawValue) became \(snapshot.phase.rawValue): "
                        + (snapshot.errorMessage ?? "no error message")
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await runService.snapshot(for: runID)
        throw SafariRPCBoundaryTestError.approvalUnavailable(
            "timed out with run phase \(snapshot?.phase.rawValue ?? "missing"): "
                + (snapshot?.errorMessage ?? "no error message")
        )
    }

    private func waitForSafariCommand(
        idPrefix: String,
        safariSessionID: String,
        page: BurnBarSafariPageState,
        socketPath: String
    ) async throws -> BurnBarSafariCommand {
        for attempt in 0..<500 {
            let response: BurnBarRPCResponseEnvelope<BurnBarSafariCommandPollResponse> =
                try sendEnvelope(
                    BurnBarRPCRequestEnvelopeWithParams(
                        id: "\(idPrefix)-\(attempt)",
                        method: .safariCommandPoll,
                        authToken: Self.authToken,
                        params: BurnBarSafariCommandPollRequest(
                            sessionId: safariSessionID,
                            activePage: page,
                            knownTabs: [tabSnapshot(page)]
                        )
                    ),
                    socketPath: socketPath
                )
            if let error = response.error {
                throw SafariRPCBoundaryTestError.commandUnavailable(
                    "poll failed with \(error.code): \(error.message)"
                )
            }
            if let command = response.result?.command {
                return command
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SafariRPCBoundaryTestError.commandUnavailable(
            "timed out waiting for the Safari evidence command"
        )
    }

    private func attachSafariSession(
        to socketPath: String,
        extensionInstanceID: String,
        page: BurnBarSafariPageState
    ) throws -> BurnBarSafariSessionAttachResponse {
        let response: BurnBarRPCResponseEnvelope<BurnBarSafariSessionAttachResponse> =
            try sendEnvelope(
                BurnBarRPCRequestEnvelopeWithParams(
                    id: "attach-\(extensionInstanceID)",
                    method: .safariSessionAttach,
                    authToken: Self.authToken,
                    params: BurnBarSafariSessionAttachRequest(
                        extensionInstanceId: extensionInstanceID,
                        clientName: "Safari RPC Boundary Tests",
                        activePage: page,
                        capabilities: safariCapabilities()
                    )
                ),
                socketPath: socketPath
            )
        XCTAssertNil(response.error)
        return try XCTUnwrap(response.result)
    }

    private func bootstrapEnvelope(
        id: String,
        sessionID: String? = nil
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariBootstrapRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariBootstrap,
            authToken: Self.authToken,
            params: BurnBarSafariBootstrapRequest(sessionId: sessionID)
        )
    }

    private func detachEnvelope(
        id: String,
        sessionID: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariSessionDetachRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariSessionDetach,
            authToken: Self.authToken,
            params: BurnBarSafariSessionDetachRequest(
                sessionId: sessionID,
                reason: "bootstrap_attribution_test"
            )
        )
    }


    private func approvalEnvelope(
        id: String,
        safariSessionID: String,
        approvalID: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<BurnBarSafariApprovalRespondRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .safariApprovalRespond,
            authToken: Self.authToken,
            params: BurnBarSafariApprovalRespondRequest(
                safariSessionId: safariSessionID,
                approvalId: approvalID,
                decision: .allowOnce
            )
        )
    }

    private func pageState(
        tabID: Int = 7,
        url: String = "https://example.com/plans",
        navigationEpoch: Int = 11,
        capturedAt: Date = Date()
    ) -> BurnBarSafariPageState {
        BurnBarSafariPageState(
            tabId: tabID,
            windowId: 3,
            url: url,
            title: "Plans",
            navigationEpoch: navigationEpoch,
            isActive: true,
            isTopFrame: true,
            capturedAt: capturedAt
        )
    }

    private func tabSnapshot(
        _ page: BurnBarSafariPageState
    ) -> BurnBarSafariTabSnapshot {
        BurnBarSafariTabSnapshot(
            tabId: page.tabId,
            windowId: page.windowId,
            url: page.url,
            title: page.title,
            isActive: page.isActive,
            isOwned: true,
            navigationEpoch: page.navigationEpoch
        )
    }

    private func safariCapabilities() -> BurnBarSafariExtensionCapabilities {
        BurnBarSafariExtensionCapabilities(
            captureVisibleTab: true,
            scripting: true,
            nativeMessaging: true,
            activeTabPermission: true,
            siteAccessGranted: true
        )
    }

    private func configuration(
        socketPath: String
    ) -> BurnBarDaemonConfiguration {
        BurnBarDaemonConfiguration(
            socketPath: socketPath,
            socketAuthToken: Self.authToken,
            daemonVersion: "safari-rpc-boundary-tests",
            startsMissionControlBackgroundLoops: false
        )
    }

    private func temporaryRoot(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-safari-rpc-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func socketPath(name: String) -> String {
        let nonce = String(UUID().uuidString.prefix(8))
        return "/tmp/obb-safari-\(name)-\(nonce).sock"
    }

    private func assertRPCError<Result>(
        _ response: BurnBarRPCResponseEnvelope<Result>,
        code: Int,
        contains messageFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) where Result: Codable & Sendable {
        XCTAssertNil(response.result, file: file, line: line)
        XCTAssertEqual(response.error?.code, code, file: file, line: line)
        XCTAssertEqual(
            response.error?.message.contains(messageFragment),
            true,
            "Expected RPC error message to contain '\(messageFragment)', got '\(response.error?.message ?? "nil")'.",
            file: file,
            line: line
        )
    }

    private func sendEnvelope<Envelope, Response>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response>
    where Envelope: Encodable, Response: Codable & Sendable {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { reboundPointer in
                connect(
                    fileDescriptor,
                    reboundPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.stride)
                )
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytesRemaining
                )
                guard bytesWritten > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while response.last != 0x0A {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard bytesRead > 0 else { break }
            response.append(contentsOf: buffer.prefix(bytesRead))
        }
        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<Response>.self,
            from: response
        )
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }
}


private struct PendingSafariApproval {
    let computerUseSessionID: ComputerUseSessionID
    let approval: HermesRealtimeRelayApprovalRequest
}

private enum SafariRPCBoundaryTestError: Error, LocalizedError {
    case approvalUnavailable(String)
    case commandUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .approvalUnavailable(let detail):
            return "Safari approval did not become pending: \(detail)"
        case .commandUnavailable(let detail):
            return "Safari command did not become available: \(detail)"
        }
    }
}


private struct SafariRPCBoundaryProviderExecutor: BurnBarProviderExecuting {
    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        BurnBarProviderExecutionResult(
            outputText:
                #"{"action":"complete","rationale":"Safari RPC boundary test completed.","message":"done"}"#,
            inputTokens: max(1, request.userPrompt.count / 4),
            outputTokens: 1,
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

private extension BurnBarDaemonServer {
}
