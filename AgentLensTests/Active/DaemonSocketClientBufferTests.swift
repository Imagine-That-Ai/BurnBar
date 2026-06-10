import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Client-side coverage for the daemon RPC plane changes
/// (docs/architecture/macos-performance.md §16):
///   * the aggregated `daemon.controller.runtime_snapshot` fast path,
///     including a response far larger than one read-buffer chunk,
///   * the fallback to the legacy six-RPC path against an older daemon
///     (methodNotFound), and the process-lifetime downgrade memo.
final class DaemonSocketClientBufferTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken("test-token")
        OpenBurnBarDaemonSocketClient.markAggregatedSnapshotUnsupported(false)
    }

    override func tearDown() {
        OpenBurnBarDaemonSocketClient.markAggregatedSnapshotUnsupported(false)
        OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken(nil)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeQuestion(index: Int, now: Date) -> BurnBarPendingQuestionSnapshot {
        BurnBarPendingQuestionSnapshot(
            id: BurnBarQuestionID(rawValue: "question-\(index)"),
            projectSlug: "apollo",
            title: "Approve batch \(index)?",
            prompt: "Padding prompt so each row carries realistic weight for the multi-chunk read assertion.",
            status: .pending,
            priority: .medium,
            askedAt: now
        )
    }

    private func makePayload(questionCount: Int, now: Date) -> BurnBarControllerRuntimeSnapshotPayload {
        BurnBarControllerRuntimeSnapshotPayload(
            summary: BurnBarControllerSummary(
                updatedAt: now,
                counts: BurnBarControllerCounts(
                    projectCount: 1,
                    pendingQuestionCount: questionCount,
                    openFollowupCount: 0,
                    activeMissionCount: 0,
                    staleProjectCount: 0
                ),
                freshness: .fresh
            ),
            questions: (0..<questionCount).map { makeQuestion(index: $0, now: now) },
            followups: [],
            missions: [],
            notificationHealth: BurnBarNotificationHealthSnapshot(checkedAt: now, channels: []),
            simulatorRuns: []
        )
    }

    // MARK: - Tests

    func testAggregatedSnapshot_decodesResponseLargerThanOneReadChunk() throws {
        let now = Date(timeIntervalSince1970: 1_710_003_000)
        let payload = makePayload(questionCount: 1_500, now: now)
        let encodedSize = try JSONEncoder().encode(
            BurnBarControllerRuntimeSnapshotResponse(snapshot: payload)
        ).count
        XCTAssertGreaterThan(
            encodedSize, 65_536,
            "Fixture must exceed the 64KB read buffer to prove multi-chunk reads"
        )

        let server = try FakeDaemonSocketServer { method, requestID in
            switch method {
            case BurnBarRPCMethod.controllerRuntimeSnapshot.rawValue:
                return try JSONEncoder().encode(
                    BurnBarRPCResponseEnvelope(
                        id: requestID,
                        result: BurnBarControllerRuntimeSnapshotResponse(snapshot: payload)
                    )
                )
            default:
                return try JSONEncoder().encode(
                    BurnBarRPCResponseEnvelope<BurnBarControllerSummaryResponse>(
                        id: requestID,
                        error: BurnBarRPCError(code: -32_601, message: "unexpected method \(method)")
                    )
                )
            }
        }
        defer { server.stop() }

        let snapshot = try OpenBurnBarDaemonSocketClient.controllerRuntimeSnapshot(at: server.socketURL)

        XCTAssertEqual(snapshot.questions.count, 1_500)
        XCTAssertEqual(server.requestedMethods, [BurnBarRPCMethod.controllerRuntimeSnapshot.rawValue])
        XCTAssertFalse(OpenBurnBarDaemonSocketClient.isAggregatedSnapshotMarkedUnsupported)
    }

    func testAggregatedSnapshot_fallsBackToLegacyPath_andMemoizesDowngrade() throws {
        let now = Date(timeIntervalSince1970: 1_710_003_100)
        let payload = makePayload(questionCount: 2, now: now)

        let server = try FakeDaemonSocketServer { method, requestID in
            let encoder = JSONEncoder()
            switch method {
            case BurnBarRPCMethod.controllerRuntimeSnapshot.rawValue:
                // Older daemon: clean methodNotFound error envelope.
                return try encoder.encode(
                    BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse>(
                        id: requestID,
                        error: BurnBarRPCError(
                            code: -32_601,
                            message: "Unsupported OpenBurnBar RPC method '\(method)'."
                        )
                    )
                )
            case BurnBarRPCMethod.controllerSummary.rawValue:
                return try encoder.encode(BurnBarRPCResponseEnvelope(
                    id: requestID,
                    result: BurnBarControllerSummaryResponse(summary: payload.summary)
                ))
            case BurnBarRPCMethod.questionsList.rawValue:
                return try encoder.encode(BurnBarRPCResponseEnvelope(
                    id: requestID,
                    result: BurnBarQuestionsListResponse(questions: payload.questions)
                ))
            case BurnBarRPCMethod.followupsList.rawValue:
                return try encoder.encode(BurnBarRPCResponseEnvelope(
                    id: requestID,
                    result: BurnBarFollowupsListResponse(followups: [])
                ))
            case BurnBarRPCMethod.missionsList.rawValue:
                return try encoder.encode(BurnBarRPCResponseEnvelope(
                    id: requestID,
                    result: BurnBarMissionListResponse(missions: [])
                ))
            case BurnBarRPCMethod.notificationHealth.rawValue:
                return try encoder.encode(BurnBarRPCResponseEnvelope(
                    id: requestID,
                    result: BurnBarNotificationHealthResponse(health: payload.notificationHealth)
                ))
            case BurnBarRPCMethod.simulatorList.rawValue:
                return try encoder.encode(BurnBarRPCResponseEnvelope(
                    id: requestID,
                    result: BurnBarSimulatorListResponse(runs: [])
                ))
            default:
                return try encoder.encode(
                    BurnBarRPCResponseEnvelope<BurnBarControllerSummaryResponse>(
                        id: requestID,
                        error: BurnBarRPCError(code: -32_601, message: "unexpected method \(method)")
                    )
                )
            }
        }
        defer { server.stop() }

        let first = try OpenBurnBarDaemonSocketClient.controllerRuntimeSnapshot(at: server.socketURL)
        XCTAssertEqual(first.questions.count, 2)
        XCTAssertTrue(
            OpenBurnBarDaemonSocketClient.isAggregatedSnapshotMarkedUnsupported,
            "A successful legacy fallback must memoize the daemon downgrade"
        )
        XCTAssertEqual(
            server.requestedMethods.first,
            BurnBarRPCMethod.controllerRuntimeSnapshot.rawValue
        )
        XCTAssertEqual(server.requestedMethods.count, 7, "probe + six legacy RPCs")

        // Second refresh: no failed probe, straight to the legacy path.
        let second = try OpenBurnBarDaemonSocketClient.controllerRuntimeSnapshot(at: server.socketURL)
        XCTAssertEqual(second.questions.count, 2)
        XCTAssertEqual(server.requestedMethods.count, 13, "six legacy RPCs, no second probe")
    }
}

// MARK: - Fake daemon socket server

/// Minimal newline-framed unix-socket server speaking the daemon's
/// connection-per-request protocol, so `OpenBurnBarDaemonSocketClient` can
/// be exercised without a running daemon.
private final class FakeDaemonSocketServer: @unchecked Sendable {
    let socketURL: URL
    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "fake-daemon-socket-server")
    private let respond: @Sendable (_ method: String, _ requestID: String) throws -> Data
    private let lock = NSLock()
    private var methods: [String] = []
    private var stopped = false

    var requestedMethods: [String] {
        lock.withLock { methods }
    }

    init(respond: @escaping @Sendable (_ method: String, _ requestID: String) throws -> Data) throws {
        self.respond = respond
        let path = "/tmp/obb-fake-daemon-\(UUID().uuidString.prefix(8)).sock"
        socketURL = URL(fileURLWithPath: path)

        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD != -1 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(path.utf8)
        precondition(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                raw[index] = byte
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(listenerFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bindResult == 0, listen(listenerFD, 16) == 0 else {
            close(listenerFD)
            throw POSIXError(.EIO)
        }

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        close(listenerFD)
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop() {
        while true {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD == -1 {
                if lock.withLock({ stopped }) || errno == EBADF { return }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = read(clientFD, &chunk, chunk.count)
            if bytesRead <= 0 { break }
            request.append(contentsOf: chunk.prefix(bytesRead))
            if request.last == 0x0A { break }
        }
        while request.last == 0x0A || request.last == 0x0D {
            request.removeLast()
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
            let method = object["method"] as? String
        else { return }
        let requestID = object["id"] as? String ?? "unknown"
        lock.withLock { methods.append(method) }

        guard let body = try? respond(method, requestID) else { return }
        let payload = body + Data([0x0A])
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                let written = write(clientFD, base.advanced(by: offset), remaining)
                if written <= 0 { return }
                remaining -= written
                offset += written
            }
        }
    }
}
