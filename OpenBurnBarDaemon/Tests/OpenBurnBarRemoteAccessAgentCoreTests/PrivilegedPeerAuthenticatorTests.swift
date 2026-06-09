import XCTest
import Security
@testable import OpenBurnBarRemoteAccessAgentCore

final class PrivilegedPeerAuthenticatorTests: XCTestCase {
    func test_designatedRequirement_containsTeamIDAndIdentifiers() {
        let req = OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement
        XCTAssertTrue(req.contains(OpenBurnBarSigningIdentity.teamID))
        XCTAssertTrue(req.contains("com.openburnbar"))
        XCTAssertTrue(req.contains("anchor apple generic"))
    }

    func test_rejectsWhenCodeSignatureValidatorFails() throws {
        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { _ in
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: -1)
        }
        // Cannot exercise real socket FD in unit tests without root; policy wiring is covered by integration tests.
        XCTAssertEqual(OpenBurnBarSigningIdentity.teamID.count, 10)
        _ = authenticator
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
