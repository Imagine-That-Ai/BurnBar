import XCTest
@testable import OpenBurnBarCore

/// Release-lane smoke: Developer-ID entitlements include Firebase Auth's
/// Keychain group, while hosted account capabilities stay out of the
/// direct-download profile until the release lane explicitly supports them.
final class DeveloperIDReleaseEntitlementsSmokeTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func test_releaseEntitlements_matchExpectedGracefulDegradationMatrix() throws {
        let url = repoRoot.appendingPathComponent("AgentLens/Resources/OpenBurnBarRelease.entitlements")
        let capability = try XCTUnwrap(DeveloperIDReleaseCapability.fromEntitlementsPlist(at: url))
        XCTAssertEqual(capability, .expectedDeveloperIDRelease)
    }

    func test_fullMacEntitlements_exposeProfiledCapabilities() throws {
        let url = repoRoot.appendingPathComponent("AgentLens/Resources/OpenBurnBar.entitlements")
        let capability = try XCTUnwrap(DeveloperIDReleaseCapability.fromEntitlementsPlist(at: url))
        XCTAssertEqual(capability, .expectedFullMacApp)
    }

    func test_releaseLaneClaimsKeychainGroupOnlyForFirebaseAuth() throws {
        let release = try XCTUnwrap(
            DeveloperIDReleaseCapability.fromEntitlementsPlist(
                at: repoRoot.appendingPathComponent("AgentLens/Resources/OpenBurnBarRelease.entitlements")
            )
        )
        XCTAssertTrue(release.keychainAccessGroups)
        XCTAssertFalse(release.iCloudDocuments)
        XCTAssertFalse(release.appleSignIn)
    }
}
