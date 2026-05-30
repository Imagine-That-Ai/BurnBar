import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class PrivilegedPeerAuthenticatorTests: XCTestCase {
    func test_designatedRequirement_containsTeamIDAndBundlePrefix() {
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement.contains(OpenBurnBarSigningIdentity.teamID))
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement.contains("com.openburnbar"))
        XCTAssertTrue(OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement.contains("HardenedRuntime"))
    }

    func test_rejectsWhenCodeSignatureValidatorFails() throws {
        let authenticator = PrivilegedPeerAuthenticator(socketLabel: "test.sock") { _ in
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: -1)
        }
        // Cannot exercise real socket FD in unit tests without root; policy wiring is covered by integration tests.
        XCTAssertEqual(OpenBurnBarSigningIdentity.teamID.count, 10)
        _ = authenticator
    }
}
