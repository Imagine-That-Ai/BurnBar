import Darwin
import XCTest
@testable import OpenBurnBarComputerUseCore

/// Proves the client authenticates the SERVER before writing anything: a
/// listener that fails trust validation receives ZERO bytes — the exact
/// defense against a squatted socket harvesting `typeCredential` passwords.
final class PrivilegedInputSocketClientTrustTests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeSocketPath() throws -> String {
        let directory = NSTemporaryDirectory() + "obb-client-trust-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory + "/input.sock"
    }

    private func credentialEnvelope() -> PrivilegedInputDispatchEnvelope {
        PrivilegedInputDispatchEnvelope(
            request: PrivilegedInputDispatchRequest(
                operation: "typeCredential",
                password: "super-secret-login-password"
            )
        )
    }

    func test_perform_writesNothingToServerThatFailsTrustValidation() throws {
        let socketPath = try makeSocketPath()
        let impostor = try ImpostorSocketServer(socketPath: socketPath)
        defer { impostor.shutdown() }

        let client = PrivilegedInputSocketClient(
            socketPath: socketPath,
            serverCodeSignatureValidator: { _ in
                throw PrivilegedSocketTrustError.codeSignatureInvalid(status: -67050)
            }
        )

        XCTAssertThrowsError(try client.perform(credentialEnvelope())) { error in
            guard case PrivilegedInputXPCClient.ClientError.serverUntrusted = error else {
                return XCTFail("expected serverUntrusted, got \(error)")
            }
        }
        XCTAssertEqual(
            impostor.receivedByteCount(),
            0,
            "client must not write a credential-bearing envelope to an untrusted server"
        )
    }

    func test_perform_writesNothingWhenServerUIDUnexpected() throws {
        let socketPath = try makeSocketPath()
        let impostor = try ImpostorSocketServer(socketPath: socketPath)
        defer { impostor.shutdown() }

        let client = PrivilegedInputSocketClient(
            socketPath: socketPath,
            expectedServerUID: getuid() &+ 1,
            serverCodeSignatureValidator: { _ in }
        )

        XCTAssertThrowsError(try client.perform(credentialEnvelope())) { error in
            guard case PrivilegedInputXPCClient.ClientError.serverUntrusted = error else {
                return XCTFail("expected serverUntrusted, got \(error)")
            }
        }
        XCTAssertEqual(impostor.receivedByteCount(), 0)
    }

    func test_perform_completesAgainstTrustedServer() throws {
        let socketPath = try makeSocketPath()
        let impostor = try ImpostorSocketServer(
            socketPath: socketPath,
            response: "{\"ok\":true,\"version\":\"1\"}\n"
        )
        defer { impostor.shutdown() }

        let client = PrivilegedInputSocketClient(
            socketPath: socketPath,
            serverCodeSignatureValidator: { _ in }
        )
        let response = try client.perform(
            PrivilegedInputDispatchEnvelope(request: PrivilegedInputDispatchRequest(operation: "health"))
        )
        XCTAssertTrue(response.ok)
        XCTAssertGreaterThan(impostor.receivedByteCount(), 0)
    }
}

/// Minimal single-connection UNIX-socket listener that records exactly how
/// many bytes the client sent.
final class ImpostorSocketServer: @unchecked Sendable {
    private let listenerFD: Int32
    private let socketPath: String
    private let response: String?
    private let lock = NSLock()
    private var receivedBytes = 0
    private let finished = DispatchSemaphore(value: 0)

    init(socketPath: String, response: String? = nil) throws {
        self.socketPath = socketPath
        self.response = response

        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = socketPath.withCString { path -> Int in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    strncpy($0, path, pathCapacity - 1)
                }
            }
            return 0
        }
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindStatus == 0, listen(listenerFD, 1) == 0 else {
            close(listenerFD)
            throw POSIXError(.EIO)
        }

        Thread.detachNewThread { [self] in
            let client = accept(listenerFD, nil, nil)
            defer { finished.signal() }
            guard client >= 0 else { return }
            defer { close(client) }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                lock.lock()
                receivedBytes += count
                lock.unlock()
                if buffer[count - 1] == 0x0A { break }
            }

            if let response, receivedByteCount() > 0 {
                _ = response.withCString { Darwin.write(client, $0, strlen($0)) }
            }
        }
    }

    func receivedByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    func shutdown() {
        close(listenerFD)
        unlink(socketPath)
        _ = finished.wait(timeout: .now() + 3)
    }
}
