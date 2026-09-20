import Darwin
import Security
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

    func test_trustErrorsHaveOperatorReadableDescriptions() {
        let description = PrivilegedSocketTrustError.codeSignatureInvalid(status: -67050).localizedDescription

        XCTAssertTrue(description.contains("code-signature validation failed"))
        XCTAssertTrue(description.contains("OSStatus -67050"))
        XCTAssertTrue(description.contains("allowed identifier"))
        XCTAssertFalse(description.contains("PrivilegedSocketTrustError error 0"))
    }

    // MARK: - Designated requirement parity with the daemon-side tests

    func test_designatedRequirement_enumeratesExactPrivilegedInputPeers() {
        let req = OpenBurnBarPrivilegedTrust.privilegedPeerDesignatedRequirement
        for id in OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers {
            XCTAssertTrue(req.contains("identifier \"\(id)\""))
        }
        XCTAssertTrue(OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers.contains("com.openburnbar.app"))
        XCTAssertTrue(OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers.contains("com.openburnbar.daemon"))
        XCTAssertTrue(OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers.contains("com.openburnbar.privileged-input-execution"))
        XCTAssertTrue(OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers.contains("com.openburnbar.virtual-hid-bridge"))
        XCTAssertFalse(
            OpenBurnBarPrivilegedTrust.privilegedPeerBundleIdentifiers.contains("com.openburnbar.cli"),
            "the general-purpose CLI is a daemon RPC client, not a privileged-input peer"
        )
        XCTAssertFalse(req.contains("identifier \"com.openburnbar.cli\""))
        XCTAssertFalse(req.contains("com.openburnbar.*"))
    }

    func test_daemonRPCRequirementKeepsCLIOutOfPrivilegedInputProfile() {
        let daemonReq = OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement
        XCTAssertTrue(OpenBurnBarPrivilegedTrust.daemonRPCPeerBundleIdentifiers.contains("com.openburnbar.cli"))
        XCTAssertTrue(daemonReq.contains("identifier \"com.openburnbar.cli\""))
        XCTAssertFalse(
            OpenBurnBarPrivilegedTrust.privilegedInputPeerDesignatedRequirement.contains("identifier \"com.openburnbar.cli\"")
        )
    }

    // MARK: - Certificate-type independence
    //
    // Regression: the Python MCP courier gate in `tools/openburnbar-mcp/server.py`
    // used to substring-match a binary's auto-generated designated-requirement
    // TEXT for `certificate leaf[subject.OU] = "<team>"`. codesign phrases a
    // Developer ID identity that way but phrases an Apple Development identity as
    // `certificate leaf[subject.CN] = "Apple Development: …"`, even though BOTH
    // leaves carry `OU = <team id>`. Locally built installs were therefore refused
    // and ~10 MCP tools died. The requirements below are *evaluated* by the
    // Security framework rather than matched as text, and they bind identity to
    // the OU so they hold for either certificate type. Keep it that way.

    func test_requirementsBindTeamViaLeafOUSoDevelopmentAndDeveloperIDBothPass() {
        let requirements = [
            OpenBurnBarPrivilegedTrust.privilegedInputPeerDesignatedRequirement,
            OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement,
            OpenBurnBarPrivilegedTrust.remoteAccessAgentDesignatedRequirement
        ]
        for req in requirements {
            XCTAssertTrue(
                req.contains("certificate leaf[subject.OU] = \"\(OpenBurnBarPrivilegedTrust.teamID)\""),
                "requirement must pin the team on the leaf OU, which both Developer ID and Apple Development leaves carry"
            )
            XCTAssertTrue(req.contains("anchor apple generic"), "the Apple anchor is what makes the OU pin meaningful")
            XCTAssertFalse(
                req.contains("subject.CN"),
                "pinning a common name would admit only one certificate type and is weaker than the OU + anchor pair"
            )
        }
    }

    func test_everyDesignatedRequirementCompilesAsRequirementLanguage() throws {
        let requirements = [
            OpenBurnBarPrivilegedTrust.privilegedInputPeerDesignatedRequirement,
            OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement,
            OpenBurnBarPrivilegedTrust.remoteAccessAgentDesignatedRequirement
        ]
        for req in requirements {
            var requirement: SecRequirement?
            let status = SecRequirementCreateWithString(req as CFString, [], &requirement)
            XCTAssertEqual(status, errSecSuccess, "requirement failed to compile: \(req)")
            XCTAssertNotNil(requirement)
        }
    }

    func test_daemonRPCRequirementIsASupersetOfTheMCPCourierPin() {
        // tools/openburnbar-mcp/server.py builds
        //   anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "com.openburnbar.cli"
        // which must remain a strict NARROWING of this requirement, never a widening.
        let courierPin = "anchor apple generic and certificate leaf[subject.OU] = "
            + "\"\(OpenBurnBarPrivilegedTrust.teamID)\" and identifier \"com.openburnbar.cli\""
        let daemonReq = OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement
        XCTAssertTrue(daemonReq.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = \"\(OpenBurnBarPrivilegedTrust.teamID)\""))
        XCTAssertTrue(courierPin.contains("identifier \"com.openburnbar.cli\""))
        XCTAssertTrue(daemonReq.contains("identifier \"com.openburnbar.cli\""))
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(courierPin as CFString, [], &requirement), errSecSuccess)
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
