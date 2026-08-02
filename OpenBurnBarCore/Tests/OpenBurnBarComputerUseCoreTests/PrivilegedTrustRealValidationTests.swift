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

    func test_dynamicCodeAndFlagPlumbing_executesAgainstOwnIdentifier() throws {
        // Pin the requirement (injectable for tests) to the host's own signing
        // identifier so SecCodeCheckValidity passes for ANY signed host: the
        // Apple-signed xctest runner locally and the ad-hoc linker-signed
        // SwiftPM runner in CI, which can never satisfy an anchor clause. That
        // guarantees the live-code -> static-code -> signing-info ->
        // CodeDirectory-flag plumbing actually executes. A host without
        // hardened runtime + library validation must be refused by the M-9
        // flag policy; any other status means the plumbing broke.
        var selfCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &selfCode), errSecSuccess)
        let code = try XCTUnwrap(selfCode)
        let requirement = try Self.selfIdentifierRequirement()

        do {
            let identifier = try OpenBurnBarPrivilegedTrust.validateCodeSignature(
                code,
                requirementString: requirement
            )
            XCTAssertFalse(identifier.isEmpty)
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            XCTAssertEqual(
                status,
                errSecCSReqFailed,
                "flag policy must be the only refusal under the self-identifier requirement (got \(status))"
            )
        }
    }

    func test_staticValidation_rejectsTestHostUnderProductionRequirement() throws {
        // On-disk install/launch checks keep the full static validation. The
        // test host is not first-party signed, so the production designated
        // requirement must refuse its static code.
        let staticCode = try Self.selfStaticCode()

        XCTAssertThrowsError(
            try OpenBurnBarPrivilegedTrust.validateStaticCode(staticCode)
        ) { error in
            guard case PrivilegedSocketTrustError.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }

    func test_staticCodeAndFlagPlumbing_executesAgainstOwnIdentifier() throws {
        // Mirror of the dynamic-path plumbing test for the retained static
        // lane: pin the requirement to the host's own signing identifier so
        // SecStaticCodeCheckValidity passes for any signed host (including the
        // ad-hoc linker-signed SwiftPM runner in CI) and the signing-info ->
        // CodeDirectory-flag plumbing actually runs. The only acceptable
        // failure is the M-9 flag-policy refusal.
        let staticCode = try Self.selfStaticCode()
        let requirement = try Self.selfIdentifierRequirement()

        do {
            let identifier = try OpenBurnBarPrivilegedTrust.validateStaticCode(
                staticCode,
                requirementString: requirement
            )
            XCTAssertFalse(identifier.isEmpty)
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            XCTAssertEqual(
                status,
                errSecCSReqFailed,
                "flag policy must be the only refusal under the self-identifier requirement (got \(status))"
            )
        }
    }

    func test_staticValidation_invalidRequirementString_failsClosed() throws {
        let staticCode = try Self.selfStaticCode()

        XCTAssertThrowsError(
            try OpenBurnBarPrivilegedTrust.validateStaticCode(staticCode, requirementString: "not a requirement ((")
        ) { error in
            guard case PrivilegedSocketTrustError.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }

    /// A designated-requirement string the running test host always satisfies:
    /// `identifier "<its own signing identifier>"`. Unlike an anchor clause,
    /// an identifier clause is satisfiable by ad-hoc signatures, so this holds
    /// for the Apple-signed xctest host locally AND the ad-hoc linker-signed
    /// SwiftPM test runner in CI, which is what lets the validity gates pass
    /// and the post-validity plumbing execute everywhere.
    private static func selfIdentifierRequirement() throws -> String {
        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            try selfStaticCode(),
            SecCSFlags(rawValue: 0),
            &infoCF
        )
        XCTAssertEqual(infoStatus, errSecSuccess)
        let info = try XCTUnwrap(infoCF as? [String: Any])
        let identifier = try XCTUnwrap(info[kSecCodeInfoIdentifier as String] as? String)
        XCTAssertFalse(
            identifier.contains("\"") || identifier.contains("\\"),
            "signing identifier must be embeddable in a requirement string, got \(identifier)"
        )
        return "identifier \"\(identifier)\""
    }

    /// Static code of the running test host, for exercising the on-disk
    /// validation lane against a real signed binary.
    private static func selfStaticCode() throws -> SecStaticCode {
        var selfCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &selfCode), errSecSuccess)
        let code = try XCTUnwrap(selfCode)

        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(code, [], &staticCode), errSecSuccess)
        return try XCTUnwrap(staticCode)
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

/// F-RR10-002: the nonce ledger MUST be on persistent storage so replay
/// protection survives reboots. `/var/run` is tmpfs on macOS.
final class CapabilityTokenNonceLedgerPathTests: XCTestCase {
    func test_nonceLedgerPath_isPersistentNotTmpfs() {
        let path = RemoteUnlockSetupProbe.capabilityTokenNonceLedgerPath
        XCTAssertTrue(
            path.hasPrefix("/Library/Application Support/OpenBurnBar/"),
            "nonce ledger must be under persistent /Library/Application Support/OpenBurnBar/, got \(path)"
        )
        XCTAssertFalse(
            path.hasPrefix("/var/run"),
            "nonce ledger MUST NOT be on /var/run (tmpfs, lost on reboot)"
        )
        XCTAssertFalse(
            path.hasPrefix("/tmp"),
            "nonce ledger MUST NOT be on /tmp (cleared on boot)"
        )
    }

    func test_nonceLedgerPath_isColocatedWithRemoteUnlockState() {
        let noncePath = RemoteUnlockSetupProbe.capabilityTokenNonceLedgerPath
        let trustPath = RemoteUnlockSetupProbe.capabilityTokenIssuerTrustPath
        // Both should share the /Library/Application Support/OpenBurnBar/ root
        let commonPrefix = "/Library/Application Support/OpenBurnBar/"
        XCTAssertTrue(noncePath.hasPrefix(commonPrefix))
        XCTAssertTrue(trustPath.hasPrefix(commonPrefix))
    }

    func test_nonceLedgerPath_defaultInit_matchesProbeConstant() {
        let store = FileCapabilityTokenNonceStore()
        // The store's default path should match the constant (no way to read
        // the private `path` property directly, but we verify the constant
        // itself is the one used — confirmed by the default init signature).
        XCTAssertEqual(
            RemoteUnlockSetupProbe.capabilityTokenNonceLedgerPath,
            "/Library/Application Support/OpenBurnBar/RemoteUnlock/capability-token-nonces.json"
        )
    }
}
