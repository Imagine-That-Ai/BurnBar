import Darwin
import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore
import OpenBurnBarComputerUseCore

final class PrivilegedInputExecutionSocketServerTests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeSocketDirectory(permissions: Int16 = 0o700) throws -> String {
        let directory = NSTemporaryDirectory() + "obb-exec-server-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        temporaryDirectories.append(directory)
        return directory
    }

    // MARK: - Socket-directory trust (the structural anti-squat defense)

    func test_init_refusesWorldAccessibleSocketDirectory() throws {
        let directory = try makeSocketDirectory(permissions: 0o755)
        XCTAssertThrowsError(
            try PrivilegedInputExecutionSocketServer(socketPath: directory + "/input.sock") { _ in
                PrivilegedInputDispatchResponse(ok: true)
            }
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedInputExecutionSocketServer.ServerError,
                .socketDirectoryPermissionsTooOpen(directory)
            )
        }
    }

    func test_init_refusesMissingSocketDirectory() {
        let directory = NSTemporaryDirectory() + "obb-exec-missing-" + String(UUID().uuidString.prefix(8))
        XCTAssertThrowsError(
            try PrivilegedInputExecutionSocketServer(socketPath: directory + "/input.sock") { _ in
                PrivilegedInputDispatchResponse(ok: true)
            }
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedInputExecutionSocketServer.ServerError,
                .socketDirectoryMissing(directory)
            )
        }
    }

    func test_validateSocketDirectory_refusesDirectoryInsideTmp() throws {
        // /tmp is sticky-bit world-writable: any other local user can
        // pre-create a socket path there before this user's helper binds,
        // which is exactly the squatting lane this validation closes. Even a
        // correctly-permissioned 0700 directory is refused when its parent is
        // world-writable.
        let directory = "/tmp/obb-exec-server-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)

        XCTAssertThrowsError(
            try PrivilegedInputExecutionSocketServer.validateSocketDirectory(
                forSocketAt: directory + "/input.sock"
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedInputExecutionSocketServer.ServerError,
                .socketParentDirectoryUntrusted("/tmp")
            )
        }
    }

    func test_validateSocketDirectory_acceptsOwned0700Directory() throws {
        let directory = try makeSocketDirectory()
        XCTAssertNoThrow(
            try PrivilegedInputExecutionSocketServer.validateSocketDirectory(
                forSocketAt: directory + "/input.sock"
            )
        )
    }

    // MARK: - Live socket round trips (real bind/accept/getpeereid/audit-token)

    func test_roundtrip_acceptsTrustedPeerAndDispatchesEnvelope() throws {
        let directory = try makeSocketDirectory()
        let socketPath = directory + "/input.sock"

        let received = TestEnvelopeRecorder()
        let server = try PrivilegedInputExecutionSocketServer(
            socketPath: socketPath,
            codeSignatureValidator: { _ in },
            handler: { envelope in
                received.record(envelope)
                return PrivilegedInputDispatchResponse(ok: true)
            }
        )
        server.start()
        defer { server.stop() }

        let client = PrivilegedInputSocketClient(
            socketPath: socketPath,
            serverCodeSignatureValidator: { _ in }
        )
        let envelope = PrivilegedInputDispatchEnvelope(
            request: PrivilegedInputDispatchRequest(operation: "health")
        )
        let response = try client.perform(envelope)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(received.envelopes.first?.request.operation, "health")
    }

    func test_roundtrip_rejectsPeerWhenCodeSignatureValidatorFails() throws {
        let directory = try makeSocketDirectory()
        let socketPath = directory + "/input.sock"

        let server = try PrivilegedInputExecutionSocketServer(
            socketPath: socketPath,
            codeSignatureValidator: { _ in
                throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: -1)
            },
            handler: { _ in
                XCTFail("handler must never run for a rejected peer")
                return PrivilegedInputDispatchResponse(ok: true)
            }
        )
        server.start()
        defer { server.stop() }

        let client = PrivilegedInputSocketClient(
            socketPath: socketPath,
            serverCodeSignatureValidator: { _ in }
        )
        let envelope = PrivilegedInputDispatchEnvelope(
            request: PrivilegedInputDispatchRequest(operation: "health")
        )
        XCTAssertThrowsError(try client.perform(envelope)) { error in
            guard case PrivilegedInputXPCClient.ClientError.rejected = error else {
                return XCTFail("expected rejected, got \(error)")
            }
        }
    }

    func test_socketNode_isOwnerOnlyAfterBind() throws {
        let directory = try makeSocketDirectory()
        let socketPath = directory + "/input.sock"
        let server = try PrivilegedInputExecutionSocketServer(
            socketPath: socketPath,
            codeSignatureValidator: { _ in },
            handler: { _ in PrivilegedInputDispatchResponse(ok: true) }
        )
        defer { server.stop() }

        var nodeStat = stat()
        XCTAssertEqual(lstat(socketPath, &nodeStat), 0)
        XCTAssertEqual(nodeStat.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(nodeStat.st_mode & 0o777, 0o600)
        XCTAssertEqual(nodeStat.st_uid, getuid())
    }
}

final class TestEnvelopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrivilegedInputDispatchEnvelope] = []

    func record(_ envelope: PrivilegedInputDispatchEnvelope) {
        lock.lock()
        stored.append(envelope)
        lock.unlock()
    }

    var envelopes: [PrivilegedInputDispatchEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Real-validator paths: no injected trust judgments. These pin the
/// fail-closed behavior of the PRODUCTION code-signature validation against
/// an unsigned (test) process — the in-process counterpart of the nightly
/// privileged-socket red-team gate.
final class PrivilegedInputSocketServerRealValidationTests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeSocketDirectory() throws -> String {
        let directory = NSTemporaryDirectory() + "obb-exec-real-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory
    }

    func test_defaultValidator_rejectsUnsignedPeerOnLiveSocket() throws {
        // Server constructed with ALL defaults — the production validator.
        // The connecting test process is not first-party signed, so the
        // handler must never run and the client must see a rejection.
        let socketPath = try makeSocketDirectory() + "/input.sock"
        let server = try PrivilegedInputExecutionSocketServer(socketPath: socketPath) { _ in
            XCTFail("handler must never run for an unsigned peer")
            return PrivilegedInputDispatchResponse(ok: true)
        }
        server.start()
        defer { server.stop() }

        let client = PrivilegedInputSocketClient(
            socketPath: socketPath,
            serverCodeSignatureValidator: { _ in }
        )
        let envelope = PrivilegedInputDispatchEnvelope(
            request: PrivilegedInputDispatchRequest(operation: "health")
        )
        XCTAssertThrowsError(try client.perform(envelope)) { error in
            guard case PrivilegedInputXPCClient.ClientError.rejected = error else {
                return XCTFail("expected rejected, got \(error)")
            }
        }
    }

    func test_init_closesSocketWhenBindFails() throws {
        // A socket name beyond sun_path's 104 bytes makes bind impossible;
        // init must throw and release the descriptor it opened.
        let directory = try makeSocketDirectory()
        let socketPath = directory + "/" + String(repeating: "x", count: 120) + ".sock"
        XCTAssertThrowsError(
            try PrivilegedInputExecutionSocketServer(socketPath: socketPath) { _ in
                PrivilegedInputDispatchResponse(ok: true)
            }
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedInputExecutionSocketServer.ServerError,
                .socketPathTooLong
            )
        }
    }

    func test_validateSocketDirectory_refusesFileAtDirectoryPath() throws {
        let parent = try makeSocketDirectory()
        let filePath = parent + "/not-a-directory"
        FileManager.default.createFile(atPath: filePath, contents: Data())

        XCTAssertThrowsError(
            try PrivilegedInputExecutionSocketServer.validateSocketDirectory(
                forSocketAt: filePath + "/input.sock"
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedInputExecutionSocketServer.ServerError,
                .socketDirectoryMissing(filePath)
            )
        }
    }
}
