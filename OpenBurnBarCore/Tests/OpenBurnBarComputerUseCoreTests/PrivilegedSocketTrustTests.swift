import Darwin
import XCTest
@testable import OpenBurnBarComputerUseCore

final class PrivilegedSocketTrustTests: XCTestCase {
    // MARK: - LOCAL_PEERTOKEN constant (regression: 0x102 shipped once and
    // killed the whole socket lane fail-closed because nothing exercised a
    // live socket; this test reads the token from real kernel state)

    func test_localPeerTokenOption_matchesSDKValue() {
        // <sys/un.h>: #define LOCAL_PEERTOKEN 0x006
        XCTAssertEqual(OpenBurnBarPrivilegedTrust.localPeerTokenOption, 0x006)
    }

    func test_peerAuditToken_readsTokenOnLiveSocket() throws {
        let connection = try TrustTestUnixSocketConnection.establish()
        defer { connection.closeAll() }

        // Both directions: server reading the client, client reading the server.
        let serverSideToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: connection.acceptedFD)
        let clientSideToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: connection.clientFD)

        let serverBytes = withUnsafeBytes(of: serverSideToken) { Data($0) }
        let clientBytes = withUnsafeBytes(of: clientSideToken) { Data($0) }
        XCTAssertEqual(serverBytes.count, MemoryLayout<audit_token_t>.size)
        XCTAssertFalse(serverBytes.allSatisfy { $0 == 0 }, "audit token must carry real identity bits")
        // Same process on both ends of the pair → identical audit token.
        XCTAssertEqual(serverBytes, clientBytes)
    }

    func test_peerAuditTokenData_matchesTokenBytes() throws {
        let connection = try TrustTestUnixSocketConnection.establish()
        defer { connection.closeAll() }

        let token = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: connection.acceptedFD)
        let data = try OpenBurnBarPrivilegedTrust.peerAuditTokenData(socketFD: connection.acceptedFD)
        XCTAssertEqual(data, withUnsafeBytes(of: token) { Data($0) })
    }

    // MARK: - Server-peer validation (client authenticating the server)

    func test_validateServerPeer_acceptsExpectedUIDAndPassingValidator() throws {
        let connection = try TrustTestUnixSocketConnection.establish()
        defer { connection.closeAll() }

        var validatorRan = false
        XCTAssertNoThrow(
            try OpenBurnBarPrivilegedTrust.validateServerPeer(
                socketFD: connection.clientFD,
                expectedUID: getuid(),
                codeSignatureValidator: { _ in validatorRan = true }
            )
        )
        XCTAssertTrue(validatorRan, "server validation must include the code-signature check")
    }

    func test_validateServerPeer_rejectsUnexpectedUID() throws {
        let connection = try TrustTestUnixSocketConnection.establish()
        defer { connection.closeAll() }

        var validatorRan = false
        XCTAssertThrowsError(
            try OpenBurnBarPrivilegedTrust.validateServerPeer(
                socketFD: connection.clientFD,
                expectedUID: getuid() &+ 1,
                codeSignatureValidator: { _ in validatorRan = true }
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedSocketTrustError,
                .serverNotExpectedUser(expected: getuid() &+ 1, actual: getuid())
            )
        }
        XCTAssertFalse(validatorRan, "UID mismatch must reject before the signature check runs")
    }

    func test_validateServerPeer_propagatesValidatorFailure() throws {
        let connection = try TrustTestUnixSocketConnection.establish()
        defer { connection.closeAll() }

        XCTAssertThrowsError(
            try OpenBurnBarPrivilegedTrust.validateServerPeer(
                socketFD: connection.clientFD,
                expectedUID: getuid(),
                codeSignatureValidator: { _ in
                    throw PrivilegedSocketTrustError.codeSignatureInvalid(status: -67050)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedSocketTrustError,
                .codeSignatureInvalid(status: -67050)
            )
        }
    }

    // MARK: - Designated requirement parity with the daemon-side tests

    func test_designatedRequirement_enumeratesExactPrivilegedPeers() {
        let req = OpenBurnBarPrivilegedTrust.privilegedPeerDesignatedRequirement
        for id in OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers {
            XCTAssertTrue(req.contains("identifier \"\(id)\""))
        }
        XCTAssertFalse(req.contains("com.openburnbar.*"))
    }
}

/// Real listen → connect → accept UNIX-socket connection inside the test
/// process so peer-identity syscalls run against genuine kernel state.
struct TrustTestUnixSocketConnection {
    let listenerFD: Int32
    let clientFD: Int32
    let acceptedFD: Int32
    let socketPath: String

    static func establish() throws -> TrustTestUnixSocketConnection {
        let directory = NSTemporaryDirectory() + "obb-trust-test-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let socketPath = directory + "/test.sock"

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }

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
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindStatus == 0, listen(listener, 1) == 0 else {
            close(listener)
            throw POSIXError(.EIO)
        }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else {
            close(listener)
            throw POSIXError(.EIO)
        }
        let connectStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let accepted = accept(listener, nil, nil)
        guard connectStatus == 0, accepted >= 0 else {
            close(listener)
            close(client)
            throw POSIXError(.EIO)
        }
        return TrustTestUnixSocketConnection(
            listenerFD: listener,
            clientFD: client,
            acceptedFD: accepted,
            socketPath: socketPath
        )
    }

    func closeAll() {
        close(acceptedFD)
        close(clientFD)
        close(listenerFD)
        unlink(socketPath)
        try? FileManager.default.removeItem(atPath: (socketPath as NSString).deletingLastPathComponent)
    }
}
