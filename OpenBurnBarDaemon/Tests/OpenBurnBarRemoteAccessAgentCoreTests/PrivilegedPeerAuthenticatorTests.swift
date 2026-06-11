import Darwin
import Security
import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore
import OpenBurnBarComputerUseCore

final class PrivilegedPeerAuthenticatorTests: XCTestCase {
    func test_designatedRequirement_containsTeamIDAndIdentifiers() {
        let req = OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement
        XCTAssertTrue(req.contains(OpenBurnBarSigningIdentity.teamID))
        XCTAssertTrue(req.contains("com.openburnbar"))
        XCTAssertTrue(req.contains("anchor apple generic"))
    }

    // MARK: - Behavioral peer validation on a live connected socket
    //
    // These run against a real accepted UNIX-socket connection (the test
    // process talking to itself), so getpeereid and the LOCAL_PEERTOKEN
    // audit-token read are exercised for real — only the code-signature
    // judgment is injected. The previous "rejects" test never invoked the
    // authenticator at all.

    func test_validateUnixSocketPeer_rejectsWhenCodeSignatureValidatorFails() throws {
        let pair = try TestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { _ in
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: -1)
        }
        XCTAssertThrowsError(
            try authenticator.validateUnixSocketPeer(
                socketFD: pair.acceptedFD,
                consoleUser: RemoteAccessConsoleUser(uid: getuid(), gid: getgid())
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedPeerAuthenticationFailure,
                .codeSignatureInvalid(status: -1)
            )
        }
    }

    func test_validateUnixSocketPeer_acceptsWhenValidatorPasses() throws {
        let pair = try TestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let observedToken = TestObservedToken()
        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { token in
            observedToken.record(token)
        }
        XCTAssertNoThrow(
            try authenticator.validateUnixSocketPeer(
                socketFD: pair.acceptedFD,
                consoleUser: RemoteAccessConsoleUser(uid: getuid(), gid: getgid())
            )
        )
        XCTAssertTrue(observedToken.wasInvoked, "code-signature validator must receive the live audit token")
    }

    func test_validateUnixSocketPeer_rejectsPeerThatIsNotConsoleUser() throws {
        let pair = try TestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let observedToken = TestObservedToken()
        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { token in
            observedToken.record(token)
        }
        XCTAssertThrowsError(
            try authenticator.validateUnixSocketPeer(
                socketFD: pair.acceptedFD,
                consoleUser: RemoteAccessConsoleUser(uid: getuid() &+ 1, gid: getgid())
            )
        ) { error in
            XCTAssertEqual(error as? PrivilegedPeerAuthenticationFailure, .peerNotConsoleUser)
        }
        XCTAssertFalse(observedToken.wasInvoked, "UID gate must reject before the signature check runs")
    }

    func test_validateUnixSocketPeer_rejectsWhenConsoleUserUnavailable() throws {
        let pair = try TestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { _ in }
        XCTAssertThrowsError(
            try authenticator.validateUnixSocketPeer(socketFD: pair.acceptedFD, consoleUser: nil)
        ) { error in
            XCTAssertEqual(error as? PrivilegedPeerAuthenticationFailure, .consoleUserUnavailable)
        }
    }

    // MARK: - M-9: the designated requirement must be a VALID, exact-identifier requirement

    func test_designatedRequirement_isAValidSecRequirement() {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement as CFString,
            [],
            &requirement
        )
        // The previous string (with `info[ApplicationFlags] & ...`) returned
        // errSecCSReqInvalid (-67052), which made the peer gate reject everyone.
        XCTAssertEqual(status, errSecSuccess, "designated requirement must compile as a valid SecRequirement")
        XCTAssertNotNil(requirement)
    }

    func test_designatedRequirement_doesNotUseLiteralAsteriskIdentifier() {
        XCTAssertFalse(
            OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement.contains("com.openburnbar.*"),
            "the literal-asterisk identifier clause is a bug; use exact identifiers"
        )
    }

    func test_designatedRequirement_enumeratesExactPrivilegedPeers() {
        let req = OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement
        for id in OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers {
            XCTAssertTrue(req.contains("identifier \"\(id)\""), "requirement must include exact identifier \(id)")
        }
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.daemon"))
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.app"))
    }

    func test_hardenedRuntimeAndLibraryValidationFlagConstants() {
        // CodeDirectory flag bits enforced programmatically (M-9): hardened
        // runtime (kSecCodeSignatureRuntime) and library validation
        // (kSecCodeSignatureLibraryValidation).
        XCTAssertEqual(OpenBurnBarSigningIdentity.hardenedRuntimeFlag, 0x1_0000)
        XCTAssertEqual(OpenBurnBarSigningIdentity.libraryValidationFlag, 0x2000)
    }
}

/// Thread-safe recorder for validator invocations.
final class TestObservedToken: @unchecked Sendable {
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
/// process, so peer-identity syscalls (getpeereid, LOCAL_PEERTOKEN) operate on
/// genuine kernel state.
struct TestUnixSocketConnection {
    let listenerFD: Int32
    let clientFD: Int32
    let acceptedFD: Int32
    let socketPath: String

    static func establish() throws -> TestUnixSocketConnection {
        let directory = NSTemporaryDirectory() + "obb-peer-test-" + String(UUID().uuidString.prefix(8))
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
        return TestUnixSocketConnection(
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
