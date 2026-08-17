// reason: XCTest helper base class exposes shared fleet fixtures to subclasses.
// swiftlint:disable test_case_accessibility
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Darwin
import Foundation
import GRDB
import XCTest

enum BurnBarFleetTestTimeoutError: Error, CustomStringConvertible, Sendable {
    case deadlineExceeded(operation: String, timeout: TimeInterval)

    var description: String {
        switch self {
        case let .deadlineExceeded(operation, timeout):
            return "\(operation) did not complete within \(timeout)s"
        }
    }
}

let fleetTestAuthToken = "fleet-test-token"
private let fleetSocketIOTimeoutSeconds: TimeInterval = 5

func authenticatedFleetRawPayload(_ payload: String) -> String {
    guard let data = payload.data(using: .utf8),
          var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return payload
    }
    if object["authToken"] == nil {
        object["authToken"] = fleetTestAuthToken
    }
    guard let encoded = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: encoded, encoding: .utf8) else {
        return payload
    }
    return text
}
private let fleetSocketResponseMaxBytes = 65_536

func configureFleetSocketTimeouts(
    _ fileDescriptor: Int32,
    seconds: TimeInterval = fleetSocketIOTimeoutSeconds
) throws {
    var timeout = timeval(
        tv_sec: Int(seconds),
        tv_usec: Int32((seconds - floor(seconds)) * 1_000_000)
    )
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            option,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

func writeFleetSocketData(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
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
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw POSIXError(.ETIMEDOUT)
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            bytesRemaining -= bytesWritten
            offset += bytesWritten
        }
    }
}

func readFleetSocketResponse(from fileDescriptor: Int32) throws -> Data {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let bytesRead = read(fileDescriptor, &buffer, buffer.count)
        if bytesRead == 0 {
            break
        }
        guard bytesRead > 0 else {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK {
                throw POSIXError(.ETIMEDOUT)
            }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        response.append(contentsOf: buffer.prefix(bytesRead))
        guard response.count <= fleetSocketResponseMaxBytes else {
            throw POSIXError(.EMSGSIZE)
        }
        if response.last == 0x0A {
            break
        }
    }

    while response.last == 0x0A || response.last == 0x0D {
        response.removeLast()
    }
    return response
}

func fleetSocketAddress(for socketPath: String) throws -> sockaddr_un {
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

func connectFleetSocket(socketPath: String) throws -> Int32 {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor != -1 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    var noSigPipe: Int32 = 1
    guard setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        let code = errno
        close(fileDescriptor)
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }
    try configureFleetSocketTimeouts(fileDescriptor)

    var address = try fleetSocketAddress(for: socketPath)
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
            connect(
                fileDescriptor,
                reboundPointer,
                socklen_t(MemoryLayout<sockaddr_un>.stride)
            )
        }
    }
    guard connectResult == 0 else {
        let code = errno
        close(fileDescriptor)
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }
    return fileDescriptor
}

func sendFleetEnvelope<Envelope: Encodable, Response: Decodable>(
    _ envelope: Envelope,
    socketPath: String
) throws -> BurnBarRPCResponseEnvelope<Response> {
    let fileDescriptor = try connectFleetSocket(socketPath: socketPath)
    defer { close(fileDescriptor) }

    var encoded = try JSONEncoder().encode(envelope)
    if var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
       object["authToken"] == nil {
        object["authToken"] = fleetTestAuthToken
        encoded = try JSONSerialization.data(withJSONObject: object)
    }
    let payload = encoded + Data([0x0A])
    try writeFleetSocketData(payload, to: fileDescriptor)
    let response = try readFleetSocketResponse(from: fileDescriptor)
    return try JSONDecoder().decode(
        BurnBarRPCResponseEnvelope<Response>.self,
        from: response
    )
}

/// Shared fixtures + socket helpers for the RPC transport/error-matrix tests
/// (VAL-RPC-002..007, 010..014, 016). Kept in a support file so each test
/// class stays under the lint type-body budget.
class BurnBarFleetRPCTestCase: XCTestCase {
    private(set) var tempRoots: URL!

    override func setUpWithError() throws {
        tempRoots = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-rpc-transport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoots, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoots {
            try? FileManager.default.removeItem(at: tempRoots)
        }
    }

    // MARK: - Fixtures

    /// Stub probe returning a fixed row (deterministic snapshot content).
    struct FixedProbe: BurnBarFleetProbe {
        let agentID: BurnBarFleetAgentID
        let rootPath: String
        let agent: BurnBarFleetAgent

        func probe(now: Date) async -> BurnBarFleetProbeResult {
            BurnBarFleetProbeResult(
                agent: agent,
                health: BurnBarFleetProbeHealth(
                    agent: agentID,
                    state: .ok,
                    rootPath: rootPath,
                    checkedAt: now
                )
            )
        }
    }

    func makeProbes(
        runningAgent: BurnBarFleetAgent? = nil
    ) -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = tempRoots
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
            let agent: BurnBarFleetAgent
            if let runningAgent, runningAgent.id == agentID {
                agent = runningAgent
            } else {
                agent = BurnBarFleetAgent(
                    id: agentID,
                    displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                    status: .unknown,
                    confidence: .unsupported
                )
            }
            probes[agentID] = FixedProbe(agentID: agentID, rootPath: rootPath, agent: agent)
        }
        return probes
    }

    func makeFleetService(
        cadenceSeconds: Int = 15,
        runningAgent: BurnBarFleetAgent? = nil
    ) -> BurnBarFleetService {
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: makeProbes(runningAgent: runningAgent)
        )
        return BurnBarFleetService(builder: builder)
    }

    func makeConfiguration(name: String) -> BurnBarDaemonConfiguration {
        let fleetDir = tempRoots.appendingPathComponent("fleet-\(name)-\(UUID().uuidString)", isDirectory: true)
        return BurnBarDaemonConfiguration(
            socketPath: makeSocketPath(name: name),
            socketAuthToken: fleetTestAuthToken,
            startsMissionControlBackgroundLoops: false,
            fleetStorePath: fleetDir.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: fleetDir.appendingPathComponent("fleet-snapshot.json").path
        )
    }

    func makeSocketPath(name: String) -> String {
        "/tmp/burnbar-rpc-transport-\(name)-\(UUID().uuidString).sock"
    }

    // MARK: - Envelope decoding

    struct TestEnvelope: Decodable {
        let id: String
        let protocolVersion: Int
        let result: BurnBarJSONValue?
        let error: BurnBarRPCError?
    }

    /// Decodes the raw error envelope and asserts the contract-required
    /// `details` key is present and a string (VAL-RPC-016): the error object
    /// must ALWAYS carry `code`, `message`, AND `details`.
    func decodeErrorEnvelope(_ response: String) throws -> TestEnvelope {
        let envelope = try JSONDecoder().decode(TestEnvelope.self, from: Data(response.utf8))
        if let error = envelope.error {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                "error envelope must be a JSON object"
            )
            let errorObject = try XCTUnwrap(object["error"] as? [String: Any], "error object required")
            // OpenBurnBar's BurnBarRPCError is code+message only. Isolated
            // AgentLens required a `details` string; do not invent that field.
            XCTAssertNotNil(errorObject["code"])
            XCTAssertTrue(errorObject["message"] is String)
        }
        return envelope
    }

    // MARK: - Socket helpers

    /// Sends one raw request line and returns the raw response line.
    func rawRequest(_ payload: String, socketPath: String) throws -> String {
        let fileDescriptor = try connectSocket(socketPath: socketPath)
        defer { close(fileDescriptor) }

        try writeAll(Data(authenticatedFleetRawPayload(payload).utf8) + Data([0x0A]), to: fileDescriptor)
        let response = try readResponse(from: fileDescriptor)
        return String(decoding: response, as: UTF8.self)
    }

    /// Sends one raw request and returns the response plus whether the server
    /// closed the connection (EOF) after the response line.
    func rawRequestWithEOF(_ payload: String, socketPath: String) throws -> (response: String, eof: Bool) {
        let fileDescriptor = try connectSocket(socketPath: socketPath)
        defer { close(fileDescriptor) }

        try writeAll(Data(authenticatedFleetRawPayload(payload).utf8) + Data([0x0A]), to: fileDescriptor)
        let response = try readResponse(from: fileDescriptor)
        let eof = try readEOF(from: fileDescriptor)
        return (String(decoding: response, as: UTF8.self), eof)
    }

    func connectSocket(socketPath: String) throws -> Int32 {
        try connectFleetSocket(socketPath: socketPath)
    }

    func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try writeFleetSocketData(data, to: fileDescriptor)
    }

    func readResponse(from fileDescriptor: Int32) throws -> Data {
        try readFleetSocketResponse(from: fileDescriptor)
    }

    /// Reads until EOF; returns true when EOF (0 bytes) is observed within the
    /// bounded receive timeout configured when the socket was connected.
    func readEOF(from fileDescriptor: Int32) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = read(fileDescriptor, &buffer, buffer.count)
        if bytesRead == 0 {
            return true
        }
        if bytesRead < 0 {
            // EAGAIN means the server kept the connection open past the bound.
            return false
        }
        return false
    }

    func socketAddress(for socketPath: String) throws -> sockaddr_un {
        try fleetSocketAddress(for: socketPath)
    }

    /// Polls `daemon.fleet.snapshot` until a ready snapshot is served.
    func waitForSnapshot(socketPath: String, timeout: TimeInterval) async throws -> BurnBarFleetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = try? rawRequest("{\"id\":\"wait\",\"method\":\"daemon.fleet.snapshot\"}", socketPath: socketPath),
               let envelope = try? JSONDecoder().decode(
                   BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
                   from: Data(response.utf8)
               ),
               let snapshot = envelope.result?.snapshot {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BurnBarFleetTestTimeoutError.deadlineExceeded(
            operation: "snapshot readiness poll",
            timeout: timeout
        )
    }
}

/// Shared fixtures for the M4 orchestrator/directive RPC tests (VAL-RPC-008/009/
/// 015, VAL-ORCH-001..004/015/017/018/019/020/029, VAL-ORCH-038/039,
/// VAL-CROSS-009): hermetic daemon servers with a wired control store, a
/// deterministic non-running probe set, and read-only sqlite3 inspection of
/// the daemon-owned store.
class BurnBarFleetOrchestratorRPCTestCase: XCTestCase {
    private(set) var tempRoots: URL!

    override func setUpWithError() throws {
        tempRoots = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-orch-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoots, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoots {
            try? FileManager.default.removeItem(at: tempRoots)
        }
    }

    /// A stub probe returning a fixed non-running row (deterministic snapshot
    /// content; the exact statuses do not matter for control-state tests).
    struct FixedProbe: BurnBarFleetProbe {
        let agentID: BurnBarFleetAgentID
        let rootPath: String

        func probe(now: Date) async -> BurnBarFleetProbeResult {
            BurnBarFleetProbeResult(
                agent: BurnBarFleetAgent(
                    id: agentID,
                    displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                    status: .unknown,
                    confidence: .unsupported
                ),
                health: BurnBarFleetProbeHealth(
                    agent: agentID,
                    state: .ok,
                    rootPath: rootPath,
                    checkedAt: now
                )
            )
        }
    }

    func makeProbes() -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = tempRoots
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
            probes[agentID] = FixedProbe(agentID: agentID, rootPath: rootPath)
        }
        return probes
    }

    func makeConfiguration(name: String) -> BurnBarDaemonConfiguration {
        let fleetDir = tempRoots.appendingPathComponent("fleet-\(name)-\(UUID().uuidString)", isDirectory: true)
        return BurnBarDaemonConfiguration(
            socketPath: makeSocketPath(name: name),
            socketAuthToken: fleetTestAuthToken,
            startsMissionControlBackgroundLoops: false,
            fleetStorePath: fleetDir.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: fleetDir.appendingPathComponent("fleet-snapshot.json").path
        )
    }

    func makeSocketPath(name: String) -> String {
        "/tmp/burnbar-orch-rpc-\(name)-\(UUID().uuidString).sock"
    }

    func makeDirective(
        id: String = "dir-1",
        kind: BurnBarFleetDirectiveKind = .summarize,
        targetAgent: BurnBarFleetAgentID? = .claudeCode,
        payload: String = "Summarize current work",
        state: BurnBarFleetDirectiveState = .approved,
        createdAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
        decidedAt: Date? = Date(timeIntervalSince1970: 1_752_000_100),
        deliveryChannel: String? = nil
    ) -> BurnBarFleetDirective {
        BurnBarFleetDirective(
            id: id,
            kind: kind,
            targetAgent: targetAgent,
            payload: payload,
            state: state,
            createdAt: createdAt,
            decidedAt: decidedAt,
            deliveryChannel: deliveryChannel
        )
    }

    /// Builds a fleet service wired exactly like the daemon factory: real
    /// persister + control store on the configuration's fleet.sqlite, with an
    /// injectable cadence for fast tick tests.
    func makeFleetService(
        configuration: BurnBarDaemonConfiguration,
        cadenceSeconds: Int = 15
    ) -> BurnBarFleetService {
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: cadenceSeconds, probes: makeProbes())
        let store = BurnBarFleetStore(
            databasePath: configuration.fleetStorePath,
            eventRetentionSeconds: 3600,
            snapshotRetentionCount: 5
        )
        let writer = BurnBarFleetFileWriter(fileURL: URL(fileURLWithPath: configuration.fleetSnapshotFilePath))
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)
        let controlStore = BurnBarFleetControlStore(store: store)
        return BurnBarFleetService(builder: builder, persister: persister, controlStore: controlStore)
    }

    /// Starts a server with a wired control store (persistent) and returns
    /// the server plus its configuration.
    func makeServer(
        name: String,
        cadenceSeconds: Int = 15
    ) async throws -> (server: BurnBarDaemonServer, configuration: BurnBarDaemonConfiguration) {
        let configuration = makeConfiguration(name: name)
        let fleetService = makeFleetService(configuration: configuration, cadenceSeconds: cadenceSeconds)
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        return (server, configuration)
    }

    /// Opens the hermetic fleet.sqlite READ-ONLY (the documented directive
    /// read surface — no list RPC exists by design) and returns the directive
    /// rows plus the orchestrator-state payload.
    func readStoreRows(
        databasePath: String
    ) throws -> (directives: [BurnBarFleetDirective], state: String?) {
        let queue = try DatabaseQueue(path: databasePath, configuration: {
            var config = Configuration()
            config.readonly = true
            return config
        }())
        defer { try? queue.close() }
        let payloads = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM fleet_directives ORDER BY id ASC")
        }
        let directives = try payloads.map { payload -> BurnBarFleetDirective in
            try JSONDecoder().decode(BurnBarFleetDirective.self, from: Data(payload.utf8))
        }
        let state = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM orchestrator_state WHERE id = 1")
        }
        return (directives, state)
    }

    /// The orchestrator_state row count (read-only).
    func orchestratorStateRowCount(databasePath: String) throws -> Int {
        let queue = try DatabaseQueue(path: databasePath, configuration: {
            var config = Configuration()
            config.readonly = true
            return config
        }())
        defer { try? queue.close() }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM orchestrator_state") ?? -1
        }
    }

    // MARK: - Socket helpers

    /// Sends one typed envelope and returns the decoded response envelope.
    func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendFleetEnvelope(envelope, socketPath: socketPath)
    }

    /// Sends one raw request line and returns the raw response line.
    func rawRequest(_ payload: String, socketPath: String) throws -> String {
        let fileDescriptor = try connectSocket(socketPath: socketPath)
        defer { close(fileDescriptor) }

        try writeFleetSocketData(Data(authenticatedFleetRawPayload(payload).utf8) + Data([0x0A]), to: fileDescriptor)
        let response = try readFleetSocketResponse(from: fileDescriptor)
        return String(decoding: response, as: UTF8.self)
    }

    func connectSocket(socketPath: String) throws -> Int32 {
        try connectFleetSocket(socketPath: socketPath)
    }

    func socketAddress(for socketPath: String) throws -> sockaddr_un {
        try fleetSocketAddress(for: socketPath)
    }

    func readResponse(from fileDescriptor: Int32) throws -> Data {
        return try readFleetSocketResponse(from: fileDescriptor)
    }
}
// swiftlint:enable test_case_accessibility
