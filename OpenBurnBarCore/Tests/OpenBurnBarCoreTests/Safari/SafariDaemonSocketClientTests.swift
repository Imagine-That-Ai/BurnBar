#if canImport(Darwin)
import Darwin
#endif
import Foundation
@testable import OpenBurnBarKernel
import XCTest

final class SafariDaemonSocketClientTests: XCTestCase {
    func test_liveRuntimePathsUseSharedContainerSocketAndSharedToken() throws {
        let paths = try BurnBarSafariDaemonRuntimePaths.live(
            sharedContainerRoot: URL(
                fileURLWithPath: "/Users/tester/Library/Group Containers/group.com.openburnbar.app",
                isDirectory: true
            ),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        XCTAssertEqual(
            paths.socketURL.path,
            "/Users/tester/Library/Group Containers/group.com.openburnbar.app/daemon.sock"
        )
        XCTAssertEqual(
            paths.socketAuthTokenFileURL.path,
            "/Users/tester/Library/Group Containers/group.com.openburnbar.app/daemon-socket-auth-token"
        )
    }

    func test_liveSocketClientPreservesSharedContainerAndCanonicalHomeInjection() throws {
        let client = try BurnBarSafariDaemonSocketClient.live(
            sharedContainerRoot: URL(
                fileURLWithPath: "/Users/tester/Library/Group Containers/group.com.openburnbar.app",
                isDirectory: true
            ),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        XCTAssertEqual(
            client.socketURL.path,
            "/Users/tester/Library/Group Containers/group.com.openburnbar.app/daemon.sock"
        )
        XCTAssertEqual(
            client.tokenResolver.tokenFileURL.path,
            "/Users/tester/Library/Group Containers/group.com.openburnbar.app/daemon-socket-auth-token"
        )
    }

    #if canImport(Darwin)
    func test_liveRuntimeSocketPathFitsDarwinUnixSocketLimit() throws {
        let paths = try BurnBarSafariDaemonRuntimePaths.live(
            sharedContainerRoot: URL(
                fileURLWithPath: "/Users/tester/Library/Group Containers/group.com.openburnbar.app",
                isDirectory: true
            )
        )
        XCTAssertLessThan(
            paths.socketURL.path.utf8.count,
            MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        )
    }
    #endif

    func test_tokenResolverPrefersFileThenFallsBackOnlyWhenUnavailable() throws {
        let fileFirst = BurnBarSafariDaemonTokenResolver(
            tokenFileURL: URL(fileURLWithPath: "/unused"),
            tokenFileReader: { _ in "file-token" },
            keychainReader: {
                XCTFail("Keychain must not be consulted after a valid file token")
                return "keychain-token"
            }
        )
        XCTAssertEqual(
            try fileFirst.resolve(),
            BurnBarSafariDaemonAuthToken(value: "file-token", source: .tokenFile)
        )

        let keychainFallback = BurnBarSafariDaemonTokenResolver(
            tokenFileURL: URL(fileURLWithPath: "/missing"),
            tokenFileReader: { _ in nil },
            keychainReader: { "  keychain-token\n" }
        )
        XCTAssertEqual(
            try keychainFallback.resolve(),
            BurnBarSafariDaemonAuthToken(value: "keychain-token", source: .keychain)
        )
    }

    func test_tamperedTokenFileFailsClosedWithoutKeychainFallback() throws {
        let directory = try temporaryDirectory()
        let tokenURL = directory.appendingPathComponent("daemon-token")
        try Data("tampered-token".utf8).write(to: tokenURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: tokenURL.path
        )
        let probe = TokenReaderProbe()
        let resolver = BurnBarSafariDaemonTokenResolver(
            tokenFileURL: tokenURL,
            tokenFileReader: { url in
                try BurnBarSafariDaemonTokenResolver.readOwnerOnlyTokenFile(
                    at: url,
                    fileManager: .default
                )
            },
            keychainReader: probe.read
        )
        XCTAssertThrowsError(try resolver.resolve()) { error in
            XCTAssertEqual(error as? BurnBarSafariDaemonTokenError, .insecureTokenFile)
        }
        XCTAssertEqual(probe.callCount, 0)
    }

    func test_requestBoundIsEnforcedBeforeSocketIO() throws {
        let client = BurnBarSafariDaemonSocketClient(
            socketURL: URL(fileURLWithPath: "/tmp/does-not-need-to-exist.sock"),
            tokenResolver: fixedTokenResolver()
        )
        XCTAssertThrowsError(
            try client.send(
                method: .safariPageContext,
                id: "oversized",
                params: .object([
                    "payload": .string(String(repeating: "x", count: 70 * 1024))
                ])
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariDaemonSocketError, .requestTooLarge)
        }
    }

    func test_overlongInjectedSocketPathFailsBeforeConnect() {
        let client = BurnBarSafariDaemonSocketClient(
            socketURL: URL(
                fileURLWithPath: "/tmp/\(String(repeating: "x", count: 256)).sock"
            ),
            tokenResolver: fixedTokenResolver()
        )

        XCTAssertThrowsError(
            try client.send(
                method: .safariBootstrap,
                id: "overlong-path",
                params: .object([:])
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariDaemonSocketError, .socketPathTooLong)
        }
    }

    #if canImport(Darwin)
    func test_socketClientReadsResponseAcrossMultiple64KiBReads() throws {
        let id = "large-response"
        let large = String(repeating: "art", count: 90_000)
        let server = try SafariTestUnixServer(
            response: try responseLine(
                id: id,
                result: .object(["payload": .string(large)])
            ),
            writeChunkSize: 7_919
        )
        defer { server.close() }
        let client = socketClient(server: server, maximumResponseBytes: 512 * 1024)
        let result = try client.send(
            method: .safariUISnapshot,
            id: id,
            params: .object([:])
        )
        guard case .object(let object) = result,
              case .string(let received)? = object["payload"] else {
            XCTFail("expected large payload response")
            return
        }
        XCTAssertEqual(received, large)
        try server.waitForCompletion()
        XCTAssertEqual(server.receivedRequest?.hasSuffix("\n"), true)
    }

    func test_socketClientRejectsTruncatedResponse() throws {
        let server = try SafariTestUnixServer(response: Data(#"{"id":"truncated""#.utf8))
        defer { server.close() }
        let client = socketClient(server: server)
        XCTAssertThrowsError(
            try client.send(
                method: .safariBootstrap,
                id: "truncated",
                params: .object([:])
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariDaemonSocketError, .malformedResponse)
        }
        try server.waitForCompletion()
    }

    func test_socketClientRejectsResponseIdentifierMismatch() throws {
        let server = try SafariTestUnixServer(
            response: try responseLine(
                id: "different-id",
                result: .object(["ok": .bool(true)])
            )
        )
        defer { server.close() }
        let client = socketClient(server: server)
        XCTAssertThrowsError(
            try client.send(
                method: .safariBootstrap,
                id: "expected-id",
                params: .object([:])
            )
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariDaemonSocketError,
                .responseIdentifierMismatch
            )
        }
        try server.waitForCompletion()
    }

    func test_socketClientRejectsDaemonProtocolMismatch() throws {
        let server = try SafariTestUnixServer(
            response: try responseLine(
                id: "protocol-id",
                protocolVersion: BurnBarProtocolVersion.current + 1,
                result: .object(["ok": .bool(true)])
            )
        )
        defer { server.close() }
        let client = socketClient(server: server)
        XCTAssertThrowsError(
            try client.send(
                method: .safariBootstrap,
                id: "protocol-id",
                params: .object([:])
            )
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariDaemonSocketError,
                .protocolMismatch(
                    expected: BurnBarProtocolVersion.current,
                    actual: BurnBarProtocolVersion.current + 1
                )
            )
        }
        try server.waitForCompletion()
    }

    func test_socketClientRejectsResponseBeyondConfiguredBound() throws {
        let server = try SafariTestUnixServer(
            response: Data(repeating: 0x41, count: 80 * 1024),
            writeChunkSize: 4_096
        )
        defer { server.close() }
        let client = socketClient(server: server, maximumResponseBytes: 64 * 1024)
        XCTAssertThrowsError(
            try client.send(
                method: .safariUISnapshot,
                id: "too-large",
                params: .object([:])
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariDaemonSocketError, .responseTooLarge)
        }
        try server.waitForCompletion()
    }

    private func socketClient(
        server: SafariTestUnixServer,
        maximumResponseBytes: Int = 256 * 1024
    ) -> BurnBarSafariDaemonSocketClient {
        BurnBarSafariDaemonSocketClient(
            socketURL: server.socketURL,
            tokenResolver: fixedTokenResolver(),
            timeoutSeconds: 3,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private func responseLine(
        id: String,
        protocolVersion: Int = BurnBarProtocolVersion.current,
        result: BurnBarJSONValue
    ) throws -> Data {
        var data = try JSONEncoder().encode(
            BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: protocolVersion,
                result: result
            )
        )
        data.append(0x0A)
        return data
    }
    #endif

    private func fixedTokenResolver() -> BurnBarSafariDaemonTokenResolver {
        BurnBarSafariDaemonTokenResolver(
            tokenFileURL: URL(fileURLWithPath: "/unused"),
            tokenFileReader: { _ in "test-token" },
            keychainReader: { nil }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private final class TokenReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    lazy var read: BurnBarSafariDaemonTokenResolver.KeychainReader = { [self] in
        lock.lock()
        calls += 1
        lock.unlock()
        return "should-not-be-used"
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

#if canImport(Darwin)
private final class SafariTestUnixServer: @unchecked Sendable {
    let socketURL: URL

    private let listenerFD: Int32
    private let response: Data
    private let writeChunkSize: Int
    private let completion = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var request: Data?
    private var serverError: Error?
    private var isClosed = false

    init(response: Data, writeChunkSize: Int = 64 * 1024) throws {
        self.response = response
        self.writeChunkSize = max(1, writeChunkSize)
        socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-safari-\(UUID().uuidString.prefix(12)).sock")
        listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        unlink(socketURL.path)
        var address = try Self.address(path: socketURL.path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(
                    listenerFD,
                    rebound,
                    socklen_t(MemoryLayout<sockaddr_un>.stride)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(listenerFD, 1) == 0 else {
            let code = errno
            Darwin.close(listenerFD)
            unlink(socketURL.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serveOneClient()
        }
    }

    deinit {
        close()
    }

    var receivedRequest: String? {
        lock.lock()
        defer { lock.unlock() }
        return request.flatMap { String(data: $0, encoding: .utf8) }
    }

    func waitForCompletion() throws {
        XCTAssertEqual(
            completion.wait(timeout: .now() + 5),
            .success,
            "test UNIX server did not complete"
        )
        lock.lock()
        defer { lock.unlock() }
        if let serverError {
            throw serverError
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        unlink(socketURL.path)
    }

    private func serveOneClient() {
        defer { completion.signal() }
        let accepted = Darwin.accept(listenerFD, nil, nil)
        guard accepted >= 0 else {
            record(error: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            return
        }
        defer { Darwin.close(accepted) }

        do {
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 8 * 1024)
            while received.last != 0x0A {
                let count = Darwin.read(accepted, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                received.append(contentsOf: buffer.prefix(count))
                if received.count > 2 * 1024 * 1024 { break }
            }
            lock.lock()
            request = received
            lock.unlock()

            var offset = 0
            while offset < response.count {
                let count = min(writeChunkSize, response.count - offset)
                let written = response.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(accepted, base.advanced(by: offset), count)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if errno == EINTR { continue }
                if errno == EPIPE || errno == ECONNRESET {
                    break
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            record(error: error)
        }
    }

    private func record(error: Error) {
        lock.lock()
        serverError = error
        lock.unlock()
    }

    private static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BurnBarSafariDaemonSocketError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        return address
    }
}
#endif
