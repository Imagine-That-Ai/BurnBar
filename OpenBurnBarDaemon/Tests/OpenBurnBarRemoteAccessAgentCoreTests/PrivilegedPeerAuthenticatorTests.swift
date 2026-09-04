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

    func test_designatedRequirement_enumeratesExactPrivilegedInputPeers() {
        let req = OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement
        for id in OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers {
            XCTAssertTrue(req.contains("identifier \"\(id)\""), "requirement must include exact identifier \(id)")
        }
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.daemon"))
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.app"))
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.privileged-input-execution"))
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.virtual-hid-bridge"))
        // M-10: the root remote-access agent must be a trusted privileged peer
        // so app clients can authenticate the agent server before writing
        // the login password to its socket.
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.remote-access-agent"))
        XCTAssertFalse(
            OpenBurnBarSigningIdentity.privilegedPeerBundleIdentifiers.contains("com.openburnbar.cli"),
            "the signed CLI must not be accepted as a privileged-input peer"
        )
        XCTAssertFalse(req.contains("identifier \"com.openburnbar.cli\""))
    }

    func test_daemonRPCRequirementEnumeratesCLISeparatelyFromPrivilegedInputPeers() {
        let req = OpenBurnBarSigningIdentity.daemonRPCPeerDesignatedRequirement
        XCTAssertTrue(OpenBurnBarSigningIdentity.daemonRPCPeerBundleIdentifiers.contains("com.openburnbar.cli"))
        XCTAssertTrue(req.contains("identifier \"com.openburnbar.cli\""))
        XCTAssertFalse(OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement.contains("identifier \"com.openburnbar.cli\""))
    }

    // MARK: - M-10 remote-access agent server pin (Codex review round 1)
    //
    // `typeCredential` writes the macOS login password, so the client must
    // authenticate the agent server against the agent's EXACT identifier — not
    // the shared privileged-input allowlist. A first-party daemon or HID bridge
    // running as root and squatting the socket path must not be able to
    // receive the credential by satisfying the shared-allowlist requirement.

    func test_remoteAccessAgentRequirement_pinsExactAgentIdentifier() {
        let req = OpenBurnBarSigningIdentity.remoteAccessAgentDesignatedRequirement
        XCTAssertTrue(
            req.contains("identifier \"com.openburnbar.remote-access-agent\""),
            "server-auth requirement must pin the agent identifier exactly"
        )
        XCTAssertFalse(
            req.contains("identifier \"com.openburnbar.daemon\""),
            "the agent server pin must not accept the daemon's identifier"
        )
        XCTAssertFalse(
            req.contains("identifier \"com.openburnbar.virtual-hid-bridge\""),
            "the agent server pin must not accept the HID bridge's identifier"
        )
        XCTAssertTrue(req.contains("anchor apple generic"))
        XCTAssertTrue(req.contains(OpenBurnBarSigningIdentity.teamID))
    }

    func test_remoteAccessAgentRequirement_compilesAsValidSecRequirement() throws {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            OpenBurnBarSigningIdentity.remoteAccessAgentDesignatedRequirement as CFString,
            [],
            &requirement
        )
        XCTAssertEqual(status, errSecSuccess, "agent-server requirement must compile as a valid SecRequirement")
        XCTAssertNotNil(requirement)
    }

    func test_remoteAccessAgentRequirement_isSatisfiedByAgentIdentifierOnly() {
        // The requirement must be a strict subset of the shared privileged-input
        // allowlist: the agent server gate accepts the agent and nothing else
        // from the first-party privileged set.
        let shared = OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement
        let pinned = OpenBurnBarSigningIdentity.remoteAccessAgentDesignatedRequirement
        XCTAssertTrue(shared.contains("com.openburnbar.remote-access-agent"))
        XCTAssertTrue(pinned.contains("com.openburnbar.remote-access-agent"))
        for other in ["com.openburnbar.daemon", "com.openburnbar.app", "com.openburnbar.privileged-input-execution", "com.openburnbar.virtual-hid-bridge"] {
            XCTAssertFalse(
                pinned.contains("identifier \"\(other)\""),
                "the pinned server requirement must not include \(other)"
            )
        }
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

/// Real-validation and error-mapping paths with no injected judgments.
extension PrivilegedPeerAuthenticatorTests {
    func test_mapsSharedTrustErrorToAuthenticatorFailure() throws {
        let pair = try TestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { _ in
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: -67050)
        }
        XCTAssertThrowsError(
            try authenticator.validateUnixSocketPeer(
                socketFD: pair.acceptedFD,
                consoleUser: RemoteAccessConsoleUser(uid: getuid(), gid: getgid())
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivilegedPeerAuthenticationFailure,
                .codeSignatureInvalid(status: -67050)
            )
        }
    }

    func test_defaultCodeSignatureValidation_rejectsUnsignedTestProcess() throws {
        let pair = try TestUnixSocketConnection.establish()
        defer { pair.closeAll() }
        let ownToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: pair.clientFD)

        XCTAssertThrowsError(
            try PrivilegedPeerAuthenticator.defaultCodeSignatureValidation(auditToken: ownToken)
        ) { error in
            guard case PrivilegedPeerAuthenticationFailure.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }
}

/// Virtual HID device creation needs the com.apple.developer.hid.virtual.device
/// entitlement; an unentitled process (this test) must fail CLOSED, exercising
/// the backend-selection and identified-properties fallback paths on the way.
final class VirtualHIDKeyboardEngineCreationTests: XCTestCase {
    func test_engineCreation_failsClosedWithoutHIDEntitlement() {
        XCTAssertThrowsError(try VirtualHIDKeyboardEngine()) { error in
            XCTAssertTrue(error is VirtualHIDKeyboardEngine.EngineError, "got \(error)")
        }
    }
}
