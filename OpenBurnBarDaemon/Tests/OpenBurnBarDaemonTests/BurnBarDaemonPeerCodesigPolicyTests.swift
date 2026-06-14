@testable import OpenBurnBarDaemon
import XCTest

/// T-DMN-05: the peer-codesig-disable env opt-out must be compiled out of
/// release/distribution builds so an attacker controlling the launch environment
/// cannot strip the first-party code-signature gate. The build-mode-aware
/// decision is exercised here for both arms without recompiling.
final class BurnBarDaemonPeerCodesigPolicyTests: XCTestCase {
    private let optOutEnv = ["OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG": "1"]
    private let legacyOptOutEnv = ["BURNBAR_DAEMON_DISABLE_PEER_CODESIG": "1"]

    func test_releaseBuildIgnoresOptOutAndAlwaysEnforces() {
        // In a release build the env value is never consulted: enforcement stays on.
        XCTAssertTrue(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(environment: optOutEnv, isDebugBuild: false),
            "release build must enforce even when the disable env var is set"
        )
        XCTAssertTrue(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(environment: legacyOptOutEnv, isDebugBuild: false)
        )
        XCTAssertTrue(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(environment: [:], isDebugBuild: false)
        )
    }

    func test_debugBuildHonorsOptOut() {
        // The DEBUG-only escape hatch still works for unsigned developer builds.
        XCTAssertFalse(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(environment: optOutEnv, isDebugBuild: true)
        )
        XCTAssertFalse(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(environment: legacyOptOutEnv, isDebugBuild: true)
        )
    }

    func test_debugBuildDefaultsToEnforcedWithoutOptOut() {
        XCTAssertTrue(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(environment: [:], isDebugBuild: true)
        )
        XCTAssertTrue(
            BurnBarDaemonPeerAuthenticator.resolveEnforcement(
                environment: ["OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG": "0"],
                isDebugBuild: true
            )
        )
    }
}
