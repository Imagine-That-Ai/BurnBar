import Darwin
import Foundation
import OpenBurnBarComputerUseCore
import Security
@testable import OpenBurnBarDaemon
import XCTest

/// RR-3: the main daemon control socket must gate accepted peers by first-party
/// code signature, exactly the way the privileged HID/input sockets already do.
///
/// These run against a real accepted UNIX-socket connection (the test process
/// talking to itself), so the LOCAL_PEERTOKEN audit-token read is exercised for
/// real — only the code-signature judgment is injected, because a unit test
/// process can never be signed with the first-party identity.
final class BurnBarDaemonPeerAuthenticatorTests: XCTestCase {
    func test_validatePeer_rejectsWhenCodeSignatureValidatorFails() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let authenticator = BurnBarDaemonPeerAuthenticator(enforced: true) { _ in
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: -1)
        }
        XCTAssertThrowsError(
            try authenticator.validatePeer(socketFD: pair.acceptedFD, peerPID: 1234)
        ) { error in
            XCTAssertEqual(
                error as? BurnBarDaemonPeerAuthenticationFailure,
                .codeSignatureInvalid(status: -1)
            )
        }
    }

    func test_validatePeer_acceptsWhenValidatorPasses() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let observed = DaemonTestObservedToken()
        let authenticator = BurnBarDaemonPeerAuthenticator(enforced: true) { token in
            observed.record(token)
        }
        XCTAssertNoThrow(try authenticator.validatePeer(socketFD: pair.acceptedFD, peerPID: nil))
        XCTAssertTrue(observed.wasInvoked, "code-signature validator must receive the live audit token")
    }

    func test_validatePeer_isNoOpWhenNotEnforced() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let observed = DaemonTestObservedToken()
        // Even a validator that would throw must never run when enforcement is off.
        let authenticator = BurnBarDaemonPeerAuthenticator(enforced: false) { token in
            observed.record(token)
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: -1)
        }
        XCTAssertNoThrow(try authenticator.validatePeer(socketFD: pair.acceptedFD, peerPID: nil))
        XCTAssertFalse(observed.wasInvoked, "non-enforcing authenticator must skip the signature check entirely")
    }

    func test_disabled_admitsEveryPeer() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }
        XCTAssertFalse(BurnBarDaemonPeerAuthenticator.disabled.isEnforced)
        XCTAssertNoThrow(try BurnBarDaemonPeerAuthenticator.disabled.validatePeer(socketFD: pair.acceptedFD, peerPID: nil))
    }

    func test_mapsSharedTrustErrorToDaemonFailure() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let authenticator = BurnBarDaemonPeerAuthenticator(enforced: true) { _ in
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: -67050)
        }
        XCTAssertThrowsError(
            try authenticator.validatePeer(socketFD: pair.acceptedFD, peerPID: nil)
        ) { error in
            XCTAssertEqual(
                error as? BurnBarDaemonPeerAuthenticationFailure,
                .codeSignatureInvalid(status: -67050)
            )
        }
    }

    func test_defaultCodeSignatureValidation_rejectsUnsignedTestProcess() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }
        // The XCTest host is Apple-signed but is NOT the first-party OpenBurnBar
        // daemon/app, so the designated requirement must reject it — proving the
        // production default validator fails closed against a non-first-party peer.
        let ownToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: pair.clientFD)
        XCTAssertThrowsError(
            try BurnBarDaemonPeerAuthenticator.defaultCodeSignatureValidation(auditToken: ownToken)
        ) { error in
            guard case BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }
}

/// Thread-safe recorder for validator invocations.
final class DaemonTestObservedToken: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false

    func record(_ token: audit_token_t) {
        lock.lock()
        invoked = true
        lock.unlock()
    }

    var wasInvoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invoked
    }
}

/// A real listen → connect → accept UNIX-socket connection within the test
/// process, so peer-identity syscalls (LOCAL_PEERTOKEN) operate on genuine
/// kernel state. Mirrors the privileged-socket test harness.
struct DaemonTestUnixSocketConnection {
    let listenerFD: Int32
    let clientFD: Int32
    let acceptedFD: Int32
    let socketPath: String

    static func establish() throws -> DaemonTestUnixSocketConnection {
        let directory = NSTemporaryDirectory() + "obb-daemon-peer-test-" + String(UUID().uuidString.prefix(8))
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
        return DaemonTestUnixSocketConnection(
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
    }
}
