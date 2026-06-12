import Darwin
import Security
import XCTest
@testable import OpenBurnBarComputerUseCore

/// Exercises the REAL SecCode validation paths — no injected validators.
/// Unit tests cannot mint a first-party-signed process, so the assertions pin
/// the fail-closed behavior an ad-hoc/test-host process must produce. The
/// 0x102 incident proved that trust code nothing executes is trust code that
/// ships broken.
final class PrivilegedTrustRealValidationTests: XCTestCase {
    func test_realValidation_rejectsTestProcessAuditToken() throws {
        // The test process is not Developer-ID signed with a privileged
        // identifier, so the full production validation (anchor + team +
        // identifier) must refuse its own audit token.
        let connection = try TrustTestUnixSocketConnection.establish()
        defer { connection.closeAll() }
        let ownToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: connection.clientFD)

        XCTAssertThrowsError(
            try OpenBurnBarPrivilegedTrust.validateCodeSignature(ofAuditToken: ownToken)
        ) { error in
            guard case PrivilegedSocketTrustError.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }

    func test_staticCodeAndFlagPlumbing_executesAgainstAppleSignedHost() throws {
        // Relax only the requirement string (injectable for tests) so the
        // Apple-signed test host passes SecCodeCheckValidity and the
        // static-code → signing-info → CodeDirectory-flag plumbing actually
        // runs. The host is not hardened-runtime+library-validation signed
        // the way first-party daemons are, so the only acceptable failure is
        // the M-9 policy refusal — any other status means the plumbing broke.
        var selfCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &selfCode), errSecSuccess)
        let code = try XCTUnwrap(selfCode)

        do {
            try OpenBurnBarPrivilegedTrust.validateCodeSignature(code, requirementString: "anchor apple")
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            XCTAssertEqual(
                status,
                errSecCSReqFailed,
                "flag policy must be the only refusal for an Apple-signed host (got \(status))"
            )
        }
    }

    func test_codeDirectoryFlagPolicy_requiresBothBits() {
        let runtime = OpenBurnBarPrivilegedTrust.hardenedRuntimeFlag
        let library = OpenBurnBarPrivilegedTrust.libraryValidationFlag

        XCTAssertNoThrow(try OpenBurnBarPrivilegedTrust.validateCodeDirectoryFlags(runtime | library))
        for incomplete in [UInt32(0), runtime, library] {
            XCTAssertThrowsError(try OpenBurnBarPrivilegedTrust.validateCodeDirectoryFlags(incomplete)) { error in
                XCTAssertEqual(
                    error as? PrivilegedSocketTrustError,
                    .codeSignatureInvalid(status: errSecCSReqFailed)
                )
            }
        }
    }

    func test_invalidRequirementString_failsClosed() throws {
        var selfCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &selfCode), errSecSuccess)
        let code = try XCTUnwrap(selfCode)

        XCTAssertThrowsError(
            try OpenBurnBarPrivilegedTrust.validateCodeSignature(code, requirementString: "not a requirement ((")
        ) { error in
            guard case PrivilegedSocketTrustError.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }

    func test_peerAuditToken_failsClosedOnNonSocketDescriptor() {
        let fd = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        XCTAssertThrowsError(try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: fd)) { error in
            XCTAssertEqual(error as? PrivilegedSocketTrustError, .auditTokenUnavailable)
        }
        XCTAssertThrowsError(try OpenBurnBarPrivilegedTrust.peerAuditTokenData(socketFD: fd))
    }
}

/// The socket-path layout is the structural anti-squat defense — pin it.
final class PrivilegedInputXPCConstantsTests: XCTestCase {
    func test_socketLayout_isPerUserUnderRootOwnedParent() {
        let parent = PrivilegedInputXPCConstants.userSessionSocketDirectoryParent
        XCTAssertTrue(parent.hasPrefix("/Library/Application Support/OpenBurnBar/"))
        XCTAssertFalse(parent.hasPrefix("/tmp"), "sticky-bit /tmp is the squatting lane this layout closes")

        let directory = PrivilegedInputXPCConstants.userSessionSocketDirectory(uid: 501)
        XCTAssertEqual(directory, parent + "/501")
        XCTAssertEqual(PrivilegedInputXPCConstants.userSessionSocketPath(uid: 501), directory + "/input.sock")
    }

    func test_socketPath_defaultsToCurrentUser() {
        XCTAssertTrue(
            PrivilegedInputXPCConstants.userSessionSocketPath().contains("/\(getuid())/")
        )
        // sun_path caps at 104 bytes; the layout must always fit (uid_t max is
        // 10 digits).
        XCTAssertLessThan(
            PrivilegedInputXPCConstants.userSessionSocketPath(uid: uid_t.max).utf8.count,
            104
        )
    }
}
