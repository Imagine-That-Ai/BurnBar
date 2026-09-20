import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `daemon.code.explore` over the real socket client.
///
/// `BurnBarCLISocketClient.codeExplore` is the courier's half of the fix: the
/// method the Python MCP could never reach on a signed install, because no
/// signed command carried it and the direct socket it fell back to is refused by
/// the first-party peer gate. A fake control socket is the only way to assert
/// what this method actually puts on the wire — the method string the daemon's
/// capability allowlist is keyed on, the auth token, and the caller's parameters
/// — and what it makes of the two answers the daemon can give.
final class BurnBarCLISocketClientCodeExploreTests: XCTestCase {
    func testCodeExploreSendsTheDaemonCodeExploreMethodWithTheCallersParameters() throws {
        let reply = try JSONEncoder().encode(
            BurnBarRPCResponseEnvelope<BurnBarProjectCodeExploreResponse>(
                id: "envelope-fixture",
                result: BurnBarProjectCodeExploreResponse(
                    traceID: "trace-fixture",
                    projectID: "proj_fixture",
                    files: [
                        BurnBarProjectCodeExploreFile(
                            filePath: "Sources/App.swift",
                            lang: "swift",
                            symbolCount: 3
                        )
                    ],
                    context: "context-fixture",
                    truncated: true,
                    // The daemon's explore never indexes on demand; with no
                    // checkpoint it answers `degraded` rather than writing.
                    status: "degraded"
                )
            )
        )
        let daemon = try FakeDaemonControlSocket(reply: reply)
        defer { daemon.shutdown() }

        let client = BurnBarCLISocketClient(socketURL: daemon.url, authToken: "token-fixture")
        let decoded = try client.codeExplore(
            BurnBarProjectCodeExploreRequest(
                projectPath: "/tmp/fixture",
                query: "sprocket",
                limit: 7,
                maxBytes: 2048
            )
        )

        // What came back, decoded into the typed response the runner serializes.
        XCTAssertEqual(decoded.projectID, "proj_fixture")
        XCTAssertEqual(decoded.status, "degraded")
        XCTAssertEqual(decoded.files.first?.filePath, "Sources/App.swift")
        XCTAssertEqual(decoded.context, "context-fixture")
        XCTAssertTrue(decoded.truncated)

        // What went out. `daemon.code.explore` is the key the daemon's peer
        // allowlist is matched on, so pin the literal wire string rather than
        // the enum case that produced it.
        let wire = try XCTUnwrap(daemon.capturedRequest())
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(envelope["method"] as? String, "daemon.code.explore")
        XCTAssertEqual(envelope["authToken"] as? String, "token-fixture")

        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        XCTAssertEqual(params["projectPath"] as? String, "/tmp/fixture")
        XCTAssertEqual(params["query"] as? String, "sprocket")
        XCTAssertEqual(params["limit"] as? Int, 7)
        XCTAssertEqual(params["maxBytes"] as? Int, 2048)
    }

    /// The refusal this PR exists to move. When the daemon answers with a JSON-RPC
    /// error, the socket client must surface the daemon's own code and message —
    /// that `NSError` in the `OpenBurnBarCLI` domain is exactly what
    /// `BurnBarCLIRunner.runCodeExplore` translates into `privacy_rpc_error`, so
    /// the operator reads the daemon's verdict instead of a transport failure.
    func testCodeExploreSurfacesTheDaemonsCapabilityRefusal() throws {
        let refusal = "OpenBurnBar RPC method 'daemon.code.explore' is outside this peer's capability scope."
        let reply = try JSONEncoder().encode(
            BurnBarRPCResponseEnvelope<BurnBarProjectCodeExploreResponse>(
                id: "envelope-fixture",
                error: BurnBarRPCError(code: -32001, message: refusal)
            )
        )
        let daemon = try FakeDaemonControlSocket(reply: reply)
        defer { daemon.shutdown() }

        let client = BurnBarCLISocketClient(socketURL: daemon.url, authToken: nil)

        XCTAssertThrowsError(
            try client.codeExplore(BurnBarProjectCodeExploreRequest(limit: 3, maxBytes: 512))
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "OpenBurnBarCLI")
            XCTAssertEqual(nsError.code, -32001)
            XCTAssertEqual(nsError.localizedDescription, refusal)
        }

        // An unauthenticated courier still identifies itself the same way; the
        // refusal above is the daemon's, not a malformed request.
        let wire = try XCTUnwrap(daemon.capturedRequest())
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(envelope["method"] as? String, "daemon.code.explore")
        XCTAssertNil(envelope["authToken"])
    }
}

/// A one-shot stand-in for the daemon's control socket: binds a UNIX socket,
/// accepts a single connection, captures the newline-terminated JSON request and
/// answers with a canned envelope. Enough to observe both directions of one RPC
/// without a daemon, a database or a code signature.
private final class FakeDaemonControlSocket: @unchecked Sendable {
    let url: URL

    private let listenerDescriptor: Int32
    private let lock = NSLock()
    private var request = Data()
    private let served = DispatchSemaphore(value: 0)

    init(reply: Data) throws {
        let path = "/tmp/obb-code-explore-\(UInt32.random(in: 0..<UInt32.max)).sock"
        url = URL(fileURLWithPath: path)
        unlink(path)

        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        listenerDescriptor = socket(AF_UNIX, socketType, 0)
        guard listenerDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                bind(listenerDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bound == 0, listen(listenerDescriptor, 1) == 0 else {
            close(listenerDescriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }

        let descriptor = listenerDescriptor
        DispatchQueue.global().async { [self] in
            serveOnce(listener: descriptor, reply: reply)
        }
    }

    /// The bytes the client put on the wire, once the exchange is complete.
    func capturedRequest(timeout: TimeInterval = 15) -> Data? {
        guard served.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var line = request
        while line.last == 0x0A || line.last == 0x0D {
            line.removeLast()
        }
        return line.isEmpty ? nil : line
    }

    func shutdown() {
        close(listenerDescriptor)
        unlink(url.path)
    }

    private func serveOnce(listener: Int32, reply: Data) {
        let connection = accept(listener, nil, nil)
        guard connection != -1 else {
            served.signal()
            return
        }
        defer {
            close(connection)
            served.signal()
        }

        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(connection, &buffer, buffer.count)
            guard bytesRead > 0 else { break }
            incoming.append(contentsOf: buffer.prefix(bytesRead))
            if incoming.last == 0x0A { break }
        }
        lock.lock()
        request = incoming
        lock.unlock()

        let payload = reply + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let wrote = write(connection, baseAddress.advanced(by: offset), remaining)
                guard wrote > 0 else { return }
                remaining -= wrote
                offset += wrote
            }
        }
    }
}
