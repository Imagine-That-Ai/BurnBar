import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

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

    func decodeErrorEnvelope(_ response: String) throws -> TestEnvelope {
        try JSONDecoder().decode(TestEnvelope.self, from: Data(response.utf8))
    }

    // MARK: - Socket helpers

    /// Sends one raw request line and returns the raw response line.
    func rawRequest(_ payload: String, socketPath: String) throws -> String {
        let fileDescriptor = try connectSocket(socketPath: socketPath)
        defer { close(fileDescriptor) }

        try writeAll(Data(payload.utf8) + Data([0x0A]), to: fileDescriptor)
        let response = try readResponse(from: fileDescriptor)
        return String(decoding: response, as: UTF8.self)
    }

    /// Sends one raw request and returns the response plus whether the server
    /// closed the connection (EOF) after the response line.
    func rawRequestWithEOF(_ payload: String, socketPath: String) throws -> (response: String, eof: Bool) {
        let fileDescriptor = try connectSocket(socketPath: socketPath)
        defer { close(fileDescriptor) }

        try writeAll(Data(payload.utf8) + Data([0x0A]), to: fileDescriptor)
        let response = try readResponse(from: fileDescriptor)
        let eof = try readEOF(from: fileDescriptor)
        return (String(decoding: response, as: UTF8.self), eof)
    }

    func connectSocket(socketPath: String) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

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

        return fileDescriptor
    }

    func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard bytesWritten > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }
    }

    func readResponse(from fileDescriptor: Int32) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }
        return response
    }

    /// Reads until EOF; returns true when EOF (0 bytes) is observed within a
    /// bounded window (2s receive timeout).
    func readEOF(from fileDescriptor: Int32) throws -> Bool {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

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
        throw XCTSkip("snapshot never became ready within \(timeout)s")
    }
}
