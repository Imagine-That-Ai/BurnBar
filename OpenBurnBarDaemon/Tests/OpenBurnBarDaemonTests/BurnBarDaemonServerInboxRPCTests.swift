import Darwin
import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// AI Inbox RPCs exercised end to end through the production dispatch:
/// real Unix socket, `responseData` routing, `handleInboxRPC`, and the
/// lazily bootstrapped inbox service bound to the configured index database.
final class BurnBarDaemonServerInboxRPCTests: XCTestCase {
    private let authToken = "inbox-rpc-test-token"

    func test_allSixInboxRPCsDispatchThroughTheServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path

        // The index database must exist BEFORE the daemon bootstraps the inbox,
        // exactly as production requires. Seed one item and one run so every
        // read RPC has something real to return.
        let store = try BurnBarAIInboxStore(
            databasePath: databasePath,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let now = Date()
        let seeded = try store.upsertItem(
            AIInboxFixtures.itemWrite(
                fingerprint: "ci_waste:rpc-seed",
                title: "95% of ci runs are wasted"
            ),
            now: now
        )
        let seedTelemetry = BurnBarInboxRunTelemetry(
            tickID: "tick_rpc_seed",
            startedAt: now,
            finishedAt: now,
            gateResult: .forced,
            egressMode: .off
        )
        try store.beginRun(seedTelemetry, gateSignature: "seed-signature")
        try store.finishRun(seedTelemetry)

        let socketPath = makeSocketPath(name: "inbox-full")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. daemon.inbox.config.get returns the conservative defaults.
        let defaults: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "config-get", method: .inboxConfigGet, authToken: authToken),
            socketPath: socketPath
        )
        XCTAssertNil(defaults.error)
        let defaultConfig = try XCTUnwrap(defaults.result)
        XCTAssertFalse(defaultConfig.enabled)
        XCTAssertEqual(defaultConfig.egressMode, .off)
        XCTAssertEqual(defaultConfig.tickSeconds, BurnBarInboxConfig.defaultTickSeconds)

        // 2. daemon.inbox.config.update returns the clamped, stored values.
        let update: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "config-update",
                method: .inboxConfigUpdate,
                authToken: authToken,
                params: BurnBarInboxConfig(
                    enabled: false,
                    egressMode: .local,
                    tickSeconds: 1,
                    remotePhaseEveryNTicks: 0,
                    dailyBudgetUSD: -3
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(update.error)
        let storedConfig = try XCTUnwrap(update.result)
        XCTAssertEqual(storedConfig.egressMode, .local)
        XCTAssertEqual(
            storedConfig.tickSeconds,
            BurnBarInboxConfig.minimumTickSeconds,
            "An RPC caller cannot persist a 1-second cadence"
        )
        XCTAssertEqual(storedConfig.remotePhaseEveryNTicks, 1)
        XCTAssertEqual(storedConfig.dailyBudgetUSD, 0, "A negative budget clamps to zero")

        // 3. daemon.inbox.list returns the seeded item.
        let list: BurnBarRPCResponseEnvelope<BurnBarInboxListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "list",
                method: .inboxList,
                authToken: authToken,
                params: BurnBarInboxListRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(list.error)
        let listResult = try XCTUnwrap(list.result)
        XCTAssertEqual(listResult.openCount, 1)
        XCTAssertEqual(listResult.items.first?.id, seeded.id)
        XCTAssertEqual(listResult.items.first?.kind, .ciWaste)

        // 4. daemon.inbox.get returns the full detail, and nil for unknown ids.
        let detail: BurnBarRPCResponseEnvelope<BurnBarInboxGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "get",
                method: .inboxGet,
                authToken: authToken,
                params: BurnBarInboxGetRequest(id: seeded.id)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(detail.error)
        let fetched = try XCTUnwrap(detail.result?.item)
        XCTAssertEqual(fetched.summary.title, "95% of ci runs are wasted")
        XCTAssertEqual(fetched.tickID, "tick_test")

        let missing: BurnBarRPCResponseEnvelope<BurnBarInboxGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "get-missing",
                method: .inboxGet,
                authToken: authToken,
                params: BurnBarInboxGetRequest(id: "inb_does_not_exist")
            ),
            socketPath: socketPath
        )
        XCTAssertNil(missing.error)
        XCTAssertNil(missing.result?.item, "An unknown id is an empty result, not an error")

        // 5. daemon.inbox.runs.recent returns the seeded telemetry plus the
        // budget the config update just persisted.
        let runs: BurnBarRPCResponseEnvelope<BurnBarInboxRunsResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "runs",
                method: .inboxRunsRecent,
                authToken: authToken,
                params: BurnBarInboxRunsRequest(limit: 10)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(runs.error)
        let runsResult = try XCTUnwrap(runs.result)
        XCTAssertEqual(runsResult.runs.first?.tickID, "tick_rpc_seed")
        XCTAssertEqual(runsResult.runs.first?.gateResult, .forced)
        XCTAssertEqual(runsResult.dailyBudgetUSD, 0, "The stored (clamped) budget is reported")

        // 6. daemon.inbox.run_now is rejected while the inbox is disabled.
        let runNow: BurnBarRPCResponseEnvelope<BurnBarInboxRunNowResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-now",
                method: .inboxRunNow,
                authToken: authToken,
                params: BurnBarInboxRunNowRequest(force: false)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(runNow.error)
        let runNowResult = try XCTUnwrap(runNow.result)
        XCTAssertFalse(runNowResult.accepted)
        XCTAssertNil(runNowResult.tickID)
        XCTAssertEqual(runNowResult.reason, "The AI Inbox is turned off.")
    }

    func test_inboxRPCsFailClosedWhenNoIndexDatabaseIsConfigured() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-rpc-nil")
        let socketPath = makeSocketPath(name: "inbox-nil")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "config-get", method: .inboxConfigGet, authToken: authToken),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.internalError)
        XCTAssertTrue(
            error.message.contains("AI Inbox is not available"),
            "The error must tell the operator how to fix it: \(error.message)"
        )
    }

    // MARK: - Server construction

    private func makeServer(
        rootURL: URL,
        socketPath: String,
        indexDatabasePath: String?
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: authToken,
                indexDatabasePath: indexDatabasePath,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "inbox-rpc-tests"),
            configStore: BurnBarConfigStore(
                fileURL: rootURL.appendingPathComponent("provider-config.json"),
                secretStore: BurnBarInMemorySecretStore(),
                logger: BurnBarDaemonLogger(category: "inbox-rpc-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl")
            )
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return rootURL
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/obb-inbox-\(name)-\(String(UUID().uuidString.prefix(8))).sock"
    }

    // MARK: - Socket transport

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
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
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }
        return address
    }
}
