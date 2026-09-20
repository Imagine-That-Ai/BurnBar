import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// The app's client half of `daemon.memory.analytics` — an RPC that already
/// exists, is already mapped to the `memory_read` capability, and is already
/// `.full` for the `.app` peer. No new id, no new contract, no new capability:
/// these tests pin that the client speaks the REGISTERED method, decodes the
/// daemon's own field names, and reports an unreachable daemon as unavailable
/// rather than as a project with zero memories.
final class DaemonMemoryAnalyticsClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken("test-token")
    }

    override func tearDown() {
        OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken(nil)
        super.tearDown()
    }

    // MARK: - Method id

    /// The request must carry the id the canon registered. A typo here is a
    /// method-not-found at runtime and a silently empty health card.
    func test_the_request_uses_the_registered_method_id() throws {
        XCTAssertEqual(
            BurnBarRPCMethod.memoryAnalytics.rawValue,
            "daemon.memory.analytics",
            "the registered id is the contract; the client must not invent its own"
        )

        let server = try FakeAnalyticsDaemon { _, requestID in
            try Self.successBody(id: requestID)
        }
        defer { server.stop() }

        _ = try OpenBurnBarDaemonSocketClient.memoryAnalytics(
            projectPath: "/tmp/project-a",
            at: server.socketURL
        )

        XCTAssertEqual(server.requestedMethods, [BurnBarRPCMethod.memoryAnalytics.rawValue])
        // The project path travels as the daemon's own param name; the daemon
        // resolves project identity, the app never guesses it.
        XCTAssertEqual(server.requestedParams.first?["projectPath"] as? String, "/tmp/project-a")
    }

    // MARK: - Error handling

    /// A daemon that refuses must surface as a thrown failure. Returning a
    /// zeroed response would draw a health card claiming the project has no
    /// memories, which is a different — and false — statement.
    func test_a_daemon_error_surfaces_as_unavailable_rather_than_zero_counters() throws {
        let server = try FakeAnalyticsDaemon { _, requestID in
            let envelope = BurnBarRPCResponseEnvelope<BurnBarProjectMemoryAnalyticsResponse>(
                id: requestID,
                error: BurnBarRPCError(code: -32_000, message: "memory store unavailable")
            )
            return try JSONEncoder().encode(envelope)
        }
        defer { server.stop() }

        XCTAssertThrowsError(
            try OpenBurnBarDaemonSocketClient.memoryAnalytics(
                projectPath: nil,
                at: server.socketURL
            )
        ) { error in
            guard let managerError = error as? OpenBurnBarDaemonManagerError else {
                return XCTFail("expected a daemon manager error, got \(error)")
            }
            guard case .rpcError(let message) = managerError else {
                return XCTFail("expected an rpcError, got \(managerError)")
            }
            XCTAssertEqual(message, "memory store unavailable")
        }
    }

    /// An unreachable socket is also a throw, never an empty analytics record.
    func test_an_unreachable_daemon_throws_rather_than_returning_empty_counters() {
        let missing = URL(fileURLWithPath: "/tmp/obb-analytics-no-such-socket-\(UUID().uuidString).sock")
        XCTAssertThrowsError(
            try OpenBurnBarDaemonSocketClient.memoryAnalytics(projectPath: nil, at: missing)
        )
    }

    // MARK: - Decoding

    /// The response decodes the daemon's field names verbatim — `total`,
    /// `byKind`, `byScope`, `lastAuditHash`, `projectID`, `traceID` — the exact
    /// members `BurnBarProjectCodeMemoryStore.memoryAnalytics` emits. Renaming
    /// any of them on the app side would silently zero a counter.
    func test_the_response_decodes_the_daemons_field_names_verbatim() throws {
        let raw = """
        {
          "id": "REQUEST_ID",
          "protocolVersion": \(BurnBarProtocolVersion.current),
          "result": {
            "traceID": "trace-abc",
            "projectID": "proj_fixture_openburnbar",
            "total": 42,
            "byKind": { "fact": 30, "decision": 12 },
            "byScope": { "project": 40, "personal": 2 },
            "lastAuditHash": "b8f1c0de"
          }
        }
        """
        let server = try FakeAnalyticsDaemon { _, requestID in
            Data(raw.replacingOccurrences(of: "REQUEST_ID", with: requestID).utf8)
        }
        defer { server.stop() }

        let response = try OpenBurnBarDaemonSocketClient.memoryAnalytics(
            projectPath: "/tmp/project-a",
            at: server.socketURL
        )

        XCTAssertEqual(response.traceID, "trace-abc")
        XCTAssertEqual(response.projectID, "proj_fixture_openburnbar")
        XCTAssertEqual(response.total, 42)
        XCTAssertEqual(response.byKind, ["fact": 30, "decision": 12])
        XCTAssertEqual(response.byScope, ["project": 40, "personal": 2])
        XCTAssertEqual(response.lastAuditHash, "b8f1c0de")
    }

    /// `lastAuditHash` is nullable on the daemon side (an empty ledger has no
    /// last hash) and must decode as nil rather than failing the whole read.
    func test_a_null_last_audit_hash_decodes_as_absent() throws {
        let raw = """
        {
          "id": "REQUEST_ID",
          "protocolVersion": \(BurnBarProtocolVersion.current),
          "result": {
            "traceID": "trace-empty",
            "projectID": "proj_empty",
            "total": 0,
            "byKind": {},
            "byScope": {},
            "lastAuditHash": null
          }
        }
        """
        let server = try FakeAnalyticsDaemon { _, requestID in
            Data(raw.replacingOccurrences(of: "REQUEST_ID", with: requestID).utf8)
        }
        defer { server.stop() }

        let response = try OpenBurnBarDaemonSocketClient.memoryAnalytics(projectPath: nil, at: server.socketURL)
        XCTAssertNil(response.lastAuditHash)
        XCTAssertEqual(response.total, 0)
    }

    // MARK: - Fixtures

    private static func successBody(id: String) throws -> Data {
        try JSONEncoder().encode(
            BurnBarRPCResponseEnvelope(
                id: id,
                result: BurnBarProjectMemoryAnalyticsResponse(
                    traceID: "trace-ok",
                    projectID: "proj_ok",
                    total: 1,
                    byKind: ["fact": 1],
                    byScope: ["project": 1],
                    lastAuditHash: "hash"
                )
            )
        )
    }
}

// MARK: - Fake daemon socket server

/// Minimal newline-framed unix-socket server speaking the daemon's
/// connection-per-request protocol, so `OpenBurnBarDaemonSocketClient` can be
/// exercised without a running daemon. Records the full request object, not
/// just the method, so the params the client sends are assertable too.
private final class FakeAnalyticsDaemon: @unchecked Sendable {
    let socketURL: URL
    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "fake-analytics-daemon")
    private let respond: @Sendable (_ method: String, _ requestID: String) throws -> Data
    private let lock = NSLock()
    private var methods: [String] = []
    private var params: [[String: Any]] = []
    private var stopped = false

    var requestedMethods: [String] { lock.withLock { methods } }
    var requestedParams: [[String: Any]] { lock.withLock { params } }

    init(respond: @escaping @Sendable (_ method: String, _ requestID: String) throws -> Data) throws {
        self.respond = respond
        let path = "/tmp/obb-fake-analytics-\(UUID().uuidString.prefix(8)).sock"
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
        lock.withLock {
            methods.append(method)
            params.append((object["params"] as? [String: Any]) ?? [:])
        }

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
